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

    foreach ($log in $jobLogs) {
        $content = Get-Content -Path $log.FullName -ErrorAction Stop -Tail 8000

        # Veeam's own name for the job ("Bases backup"), which is not the
        # directory name ("Bases_backup"). Fall back to the directory when the
        # stop line is not in the retained tail.
        $job = $log.Directory.Name
        $named = $content | Select-String -Pattern "Job has been stopped successfully\. Name: \[([^\]]+)\]" |
                 Select-Object -Last 1
        if ($named) { $job = $named.Matches[0].Groups[1].Value }

        $verdict = $content |
                   Select-String -Pattern "Job session '[^']+' has been completed, status: '([^']+)'" |
                   Select-Object -Last 1

        # 0 success, 1 warning, 2 failed or unknown. Unknown is deliberately not
        # success: a collector that cannot find a verdict has not established
        # that the backup worked.
        $result = 2
        $lastTs = 0
        if ($verdict) {
            switch -Regex ($verdict.Matches[0].Groups[1].Value) {
                '^Success' { $result = 0 }
                '^Warning' { $result = 1 }
                default    { $result = 2 }
            }
            if ($verdict.Line -match '^\[(\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}:\d{2})\]') {
                $lastTs = ConvertTo-UnixTime $matches[1]
            }
        }

        # The part a status check cannot see: encryption key and metadata errors,
        # logged while the job still declares success.
        $keyErrors = ($content | Select-String -Pattern 'archive recovery key .* is missing|Unable to decrypt archive key|Backup metadata is in inconsistent state').Count

        $j = $job -replace '"', '\"'
        Add-Metric "veeam_job_last_result{job=`"$j`"} $result"
        Add-Metric "veeam_job_last_finish_timestamp_seconds{job=`"$j`"} $lastTs"
        Add-Metric "veeam_job_key_errors{job=`"$j`"} $keyErrors"
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
    '# HELP veeam_job_key_errors Encryption-key and metadata errors in the retained log, regardless of declared result.',
    '# TYPE veeam_job_key_errors gauge',
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
