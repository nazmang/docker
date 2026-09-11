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

    Read-only. Parses Veeam's own job logs; touches nothing else.
#>

[CmdletBinding()]
param(
    [string] $LogDir     = 'C:\ProgramData\Veeam\Endpoint',
    [string] $OutFile    = 'C:\ProgramData\windows_exporter\textfile_inputs\veeam.prom',
    [int]    $LookbackHours = 48
)

$ErrorActionPreference = 'Stop'
$lines = New-Object System.Collections.Generic.List[string]
$collectorOk = 1

function Add-Metric { param($Text) $lines.Add($Text) | Out-Null }

try {
    if (-not (Test-Path $LogDir)) { throw "log directory not found: $LogDir" }

    # One file per job, newest generation without a numeric suffix.
    $jobLogs = Get-ChildItem -Path $LogDir -Filter 'Job.*.log' -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notmatch '\.\d+\.log$' }

    if (-not $jobLogs) { throw "no job logs matched in $LogDir" }

    $since = (Get-Date).AddHours(-$LookbackHours)

    foreach ($log in $jobLogs) {
        # Job.Bases_backup.Backup.log -> "Bases_backup"
        $job = ($log.BaseName -split '\.')[1]
        if (-not $job) { $job = $log.BaseName }

        $content = Get-Content -Path $log.FullName -ErrorAction Stop -Tail 4000

        # The job's own verdict. Veeam writes a summary line per run; take the last.
        $finished = $content | Select-String -Pattern 'Job (finished|session) .*(Success|Failed|Warning)' |
                    Select-Object -Last 1
        $result = 2   # 0 success, 1 warning, 2 failed/unknown -- unknown is NOT success
        if ($finished) {
            if ($finished.Line -match 'Success') { $result = 0 }
            elseif ($finished.Line -match 'Warning') { $result = 1 }
            else { $result = 2 }
        }

        # When did it last finish? Veeam timestamps lines as [dd.MM.yyyy HH:mm:ss].
        $lastTs = 0
        if ($finished -and $finished.Line -match '\[(\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}:\d{2})') {
            try {
                $dt = [datetime]::ParseExact($matches[1], 'dd.MM.yyyy HH:mm:ss', $null)
                $lastTs = [int][double]::Parse((Get-Date $dt -UFormat %s))
            } catch { }
        }

        # The part a status check cannot see: encryption key and metadata errors,
        # logged while the job still declares success.
        $keyErrors = ($content | Select-String -Pattern 'archive recovery key .* is missing|Unable to decrypt archive key|Backup metadata is in inconsistent state').Count

        $j = $job -replace '"','\"'
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
