<#
    Veeam Agent metrics for Prometheus, via the windows_exporter textfile collector.

    Why this exists, and why it does not simply report the job's status:

    On 2026-09-11 the nightly job on this host reported Success every night while
    logging, on every run, "Backup metadata is in inconsistent state" and
    "Unable to decrypt archive key ... archive recovery key ... is missing from
    archive key node" -- and the Veeam UI could not see the backups at all. A
    check that asked "did the job succeed?" would have answered yes for at least
    five days, and for however long before that the logs no longer reach.

    So this collects three independent things, because any one of them can look
    healthy while the others do not:
      1. did the job finish, and when   (staleness)
      2. did it finish successfully     (declared result)
      3. did it log key/metadata errors (declared result is not trustworthy)

    WHERE THE VERDICT ACTUALLY LIVES -- this cost a false alert to learn.

    C:\ProgramData\Veeam\Endpoint\Job.VeeamEndpointBackup.log looks like the job
    log and is not. It is the launcher: it records that a session started and
    then hands off, naming the real file --

      Starting job 'Bases backup', id '...'. See log file at
      'C:\ProgramData\Veeam\Endpoint\Bases_backup\Job.Bases_backup.Backup.log'

    -- and it contains no completion line at all. The first version of this
    script globbed the top directory only, matched the launcher, found no
    verdict, and published "failed or unknown" for a job that had just finished
    Success. Two critical alerts fired on healthy backups.

    So: recurse into the per-job subdirectories, and read Job.*.Backup.log there.

    The verdict line, exactly:

      [11.09.2026 16:34:05] <01> Info     Job session '<guid>' has been
      completed, status: 'Success', '446.1 GB' of '446.1 GB' bytes, ...

    Anchored on "Job session" on purpose. The same file also carries
    "Task session '<guid>' has been completed, status: '...'" -- that is the
    per-object result, and on a multi-object job it is not the job's verdict.

    Read-only. Parses Veeam's own job logs; touches nothing else.
#>

[CmdletBinding()]
param(
    [string] $LogDir  = 'C:\ProgramData\Veeam\Endpoint',
    [string] $OutFile = 'C:\ProgramData\windows_exporter\textfile_inputs\veeam.prom'
)

$ErrorActionPreference = 'Stop'
$lines = New-Object System.Collections.Generic.List[string]
$collectorOk = 1

function Add-Metric { param($Text) $lines.Add($Text) | Out-Null }

# Log stamps are local time in the host's own format: [11.09.2026 16:34:05].
# InvariantCulture, not $null: with the current culture, ':' in the format
# string is the *time separator placeholder*, so a host configured with a
# different separator would silently fail to parse and report timestamp 0 --
# which reads as "backup is 56 years stale".
$epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
function ConvertTo-UnixTime {
    param([string] $Stamp)
    try {
        $dt = [datetime]::ParseExact($Stamp, 'dd.MM.yyyy HH:mm:ss',
                                     [System.Globalization.CultureInfo]::InvariantCulture)
        return [int]($dt.ToUniversalTime() - $epoch).TotalSeconds
    } catch { return 0 }
}

try {
    if (-not (Test-Path $LogDir)) { throw "log directory not found: $LogDir" }

    # Per-job subdirectories hold the real session logs. Rotated generations
    # carry a numeric suffix (Job.X.Backup.1.log) and are skipped: they are
    # older by definition, and reading them would report a stale verdict as
    # current.
    $jobLogs = Get-ChildItem -Path $LogDir -Filter 'Job.*.Backup.log' -File -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notmatch '\.\d+\.log$' }

    if (-not $jobLogs) { throw "no session logs matched Job.*.Backup.log under $LogDir" }

    # Patterns that mean the backup chain itself is damaged: the archive
    # recovery key is gone, or the metadata does not agree with the data. These
    # are the ones that made the chain unrestorable on 2026-09-11 while every
    # session still declared Success.
    #
    # Deliberately NOT counted: "The given key was not present in the dictionary
    # (KeyNotFoundException)" at CBackupVbmReader.RecoverKeys. It appears in
    # every session, including ones that produce a restorable backup, so
    # counting it would pin this metric above zero permanently and turn the
    # alert into wallpaper. If a future incident shows it to be meaningful, it
    # belongs in its own metric, not mixed into this one.
    $keyErrorPattern = 'archive recovery key .* is missing|Unable to decrypt archive key|Backup metadata is in inconsistent state'

    # One file holds several sessions end to end. Boundaries look like:
    #
    #   ===================================================================
    #   Starting new log
    #   ...
    #   CmdLineParams: [startbackupjob owner=[vbsvc] Normal <jobId> <sessionId>]
    #
    # so "Starting new log" is the anchor. Note the header lines carry no
    # [dd.MM.yyyy] stamp at all -- only lines inside a session do.
    $verdictPattern = "Job session '[^']+' has been completed, status: '([^']+)'"
    $namePattern    = "Job has been stopped successfully\. Name: \[([^\]]+)\]"
    $stampPattern   = '^\[(\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}:\d{2})\]'

    # The last *completed* session in one file: its verdict, finish time and
    # the slice of lines from its "Starting new log" to the verdict. $null when
    # the file holds no verdict at all.
    function Get-LastCompletedSession {
        param([string[]] $Content)
        $verdict = $Content | Select-String -Pattern $verdictPattern | Select-Object -Last 1
        if (-not $verdict) { return $null }

        # 0 success, 1 warning, 2 failed.
        $res = 2
        switch -Regex ($verdict.Matches[0].Groups[1].Value) {
            '^Success' { $res = 0 }
            '^Warning' { $res = 1 }
            default    { $res = 2 }
        }
        $ts = 0
        if ($verdict.Line -match $stampPattern) { $ts = ConvertTo-UnixTime $matches[1] }

        # Narrow to the session that produced that verdict: from the last
        # "Starting new log" at or before it, to the verdict itself.
        $vIdx = $verdict.LineNumber - 1
        $sIdx = 0
        for ($i = $vIdx; $i -ge 0; $i--) {
            if ($Content[$i] -match 'Starting new log') { $sIdx = $i; break }
        }
        return [pscustomobject]@{
            Result     = $res
            Ts         = $ts
            Scope      = $Content[$sIdx..$vIdx]
            VerdictIdx = $vIdx
        }
    }

    # Veeam's own job names, from the launcher log, keyed by the session log
    # each one hands off to:
    #
    #   Starting job 'Bases backup', id '...'. See log file at
    #   'C:\ProgramData\Veeam\Endpoint\Bases_backup\Job.Bases_backup.Backup.log'
    #
    # Needed when the session log itself carries no "Job has been stopped
    # successfully. Name: [...]" line -- that line is written only at the end
    # of a session. Without it the name fell back to the directory name
    # ("Bases_backup"), and the series silently split in two: one named
    # "Bases backup" with the real verdict, one named "Bases_backup" with
    # result=2 and timestamp 0. On 2026-11-13 the second one fired
    # VeeamJobFailed and VeeamJobStale at 02:00 on a run that finished Success
    # at 02:45. Hashtable keys are case-insensitive, as Windows paths are.
    $launcherNames = @{}
    $launcher = Join-Path $LogDir 'Job.VeeamEndpointBackup.log'
    if (Test-Path $launcher) {
        Get-Content -Path $launcher -ErrorAction SilentlyContinue |
            Select-String -Pattern "Starting job '([^']+)'.*See log file at '([^']+)'" |
            ForEach-Object { $launcherNames[$_.Matches[0].Groups[2].Value] = $_.Matches[0].Groups[1].Value }
    }

    # A run counts as still going for this long after its log was last
    # written, when no "Starting new log" header marks it (see below).
    $runningWindow = New-TimeSpan -Hours 6

    foreach ($log in $jobLogs) {
        # The whole file, not a -Tail window. Veeam rotates these itself at
        # roughly 10 MB (the retained generations on this host are 10.5 MB each),
        # so "whole file" is bounded, and a window is not free of consequences:
        #
        #   * with -Tail 8000 on a file of 8571 lines, the window began at line
        #     572 and cut off the first occurrence of each error pattern. The
        #     retained count read 8 where the file held 10 -- a number that
        #     drifts as the file grows and matches nothing anyone can verify by
        #     grepping the log;
        #   * worse, if a single session ever exceeded the window, its
        #     "Starting new log" header would fall outside it, the session
        #     boundary below would silently resolve to the top of the window,
        #     and errors from the *previous* session would be attributed to the
        #     last one -- exactly the bug this scoping exists to prevent.
        #
        # Found 2026-09-11 by counting both ways on the host instead of assuming
        # the window was wide enough.
        $content = @(Get-Content -Path $log.FullName -ErrorAction Stop)

        # Anchored on the last *completed* session rather than on the newest
        # session in the file, and that is the point: a backup here runs for
        # about an hour (2h15m on 2026-11-13), so while one is in progress the
        # newest session has no verdict yet. Reading it would publish "failed
        # or unknown" every night and fire a critical alert on a healthy run.
        $session = Get-LastCompletedSession $content

        # Is a run in progress? Two shapes:
        #   * a "Starting new log" header after the last verdict -- a new
        #     session began in this file and has not finished;
        #   * no verdict in this file at all, and the file was written to
        #     recently -- Veeam rotated the log mid-run (or between runs), so
        #     the current generation holds only the unfinished session.
        # A run that dies without a verdict stops writing; after
        # $runningWindow it no longer counts as running and VeeamJobStale or
        # VeeamJobVerdictUnknown take over.
        $afterIdx = if ($session) { $session.VerdictIdx } else { -1 }
        $startIdx = -1
        for ($i = $content.Count - 1; $i -gt $afterIdx; $i--) {
            if ($content[$i] -match 'Starting new log') { $startIdx = $i; break }
        }
        $recent  = ((Get-Date) - $log.LastWriteTime) -lt $runningWindow
        $running = 0
        $runningSince = 0
        if ($recent -and ($startIdx -ge 0 -or -not $session)) {
            $running = 1
            # Lower bound when the header is in an older generation: the first
            # stamped line of this file.
            $from = [Math]::Max($startIdx, 0)
            for ($i = $from; $i -lt $content.Count; $i++) {
                if ($content[$i] -match $stampPattern) { $runningSince = ConvertTo-UnixTime $matches[1]; break }
            }
        }

        # No verdict in the current generation: take the last completed
        # session from the rotated ones (Job.X.Backup.1.log, ...), newest file
        # first. Only as a fallback -- when the current file has a verdict it
        # is newer by definition, and reading older generations would report a
        # stale verdict as current.
        if (-not $session) {
            $rotated = Get-ChildItem -Path $log.DirectoryName -File -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match ('^' + [regex]::Escape($log.BaseName) + '\.\d+\.log$') } |
                       Sort-Object LastWriteTime -Descending
            foreach ($old in $rotated) {
                $session = Get-LastCompletedSession @(Get-Content -Path $old.FullName -ErrorAction Stop)
                if ($session) { break }
            }
        }

        # 0 success, 1 warning, 2 failed or unknown. Unknown is deliberately not
        # success: a collector that cannot find a verdict has not established
        # that the backup worked. Unknown is told apart from a real failure by
        # the finish timestamp: 0 means no verdict was found anywhere.
        $result = 2
        $lastTs = 0
        $scope  = @()
        if ($session) {
            $result = $session.Result
            $lastTs = $session.Ts
            $scope  = $session.Scope
        }

        # Veeam's own name for the job ("Bases backup"), which is not the
        # directory name ("Bases_backup"). It is logged just before the verdict,
        # so it lives inside the scoped slice; failing that, the launcher log
        # names it; failing that, the directory name.
        $job = $log.Directory.Name
        if ($launcherNames.ContainsKey($log.FullName)) { $job = $launcherNames[$log.FullName] }
        $named = $scope | Select-String -Pattern $namePattern | Select-Object -Last 1
        if ($named) { $job = $named.Matches[0].Groups[1].Value }

        # The part a status check cannot see: chain damage logged while the job
        # still declares success. Counted within the last completed session
        # only. Counting the whole retained log instead would keep reporting a
        # fault that has since been fixed -- on 2026-09-11 the repaired run was
        # clean while the previous session in the same file still carried five
        # of these, and an alert that cannot go out once the problem is solved
        # teaches people to close it without looking.
        $keyErrors = ($scope | Select-String -Pattern $keyErrorPattern).Count

        # The same count across every session still in the current file, for
        # context rather than alerting: it answers "has this job been in
        # trouble recently" without holding the alert on.
        $keyErrorsRetained = ($content | Select-String -Pattern $keyErrorPattern).Count

        # The label is job_name, NOT job. Prometheus overwrites `job` with the
        # scrape job's own name unless honor_labels is set, so a metric exported
        # as job="Bases backup" arrives as job="windows-psvc": the Veeam job name
        # is lost, and with two Veeam jobs both series would collapse into one
        # and collide. veeam.rules.yml already renders {{ $labels.job_name }},
        # which until now was always empty.
        $j = $job -replace '"', '\"'
        Add-Metric "veeam_job_last_result{job_name=`"$j`"} $result"
        Add-Metric "veeam_job_last_finish_timestamp_seconds{job_name=`"$j`"} $lastTs"
        Add-Metric "veeam_job_key_errors{job_name=`"$j`"} $keyErrors"
        Add-Metric "veeam_job_key_errors_retained{job_name=`"$j`"} $keyErrorsRetained"
        Add-Metric "veeam_job_running{job_name=`"$j`"} $running"
        Add-Metric "veeam_job_running_since_timestamp_seconds{job_name=`"$j`"} $runningSince"
    }
}
catch {
    # A collector that fails silently is worse than no collector: the series
    # simply stop updating and everything looks calm. Say so explicitly.
    $collectorOk = 0
    Add-Metric ("veeam_collector_error_info{reason=`"" + ($_.Exception.Message -replace '"','\"' -replace '[\r\n]',' ') + "`"} 1")
}

$header = @(
    '# HELP veeam_job_last_result Result of the last run: 0 success, 1 warning, 2 failed or unknown.',
    '# TYPE veeam_job_last_result gauge',
    '# HELP veeam_job_last_finish_timestamp_seconds Unix time the job last finished.',
    '# TYPE veeam_job_last_finish_timestamp_seconds gauge',
    '# HELP veeam_job_key_errors Chain-damage errors within the last completed session, regardless of its declared result.',
    '# TYPE veeam_job_key_errors gauge',
    '# HELP veeam_job_key_errors_retained The same count across every session in the whole log file. Context, not an alerting signal.',
    '# TYPE veeam_job_key_errors_retained gauge',
    '# HELP veeam_job_running Whether a run is in progress: 1 yes, 0 no.',
    '# TYPE veeam_job_running gauge',
    '# HELP veeam_job_running_since_timestamp_seconds Unix time the run in progress started, 0 when none.',
    '# TYPE veeam_job_running_since_timestamp_seconds gauge',
    '# HELP veeam_collector_up Whether this collector produced data.',
    '# TYPE veeam_collector_up gauge'
)

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# Written atomically: windows_exporter reads this file on every scrape, and a
# half-written one makes it report a parse error instead of metrics.
$tmp = "$OutFile.tmp"
($header + $lines + "veeam_collector_up $collectorOk") -join "`n" | Set-Content -Path $tmp -Encoding ASCII
Move-Item -Path $tmp -Destination $OutFile -Force
