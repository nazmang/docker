<#
    Nightly PostgreSQL dump state for Prometheus, through the windows_exporter
    textfile collector -- the same path veeam-metrics.ps1 uses.

    ASCII only, on purpose. Windows PowerShell 5.1 reads a BOM-less file as
    ANSI/cp1251, so a single non-ASCII byte in a comment turns the whole script
    into mojibake and eventually breaks a string literal: "The string is missing
    the terminator". The script then exits 1 and writes nothing, which looks
    exactly like a working collector that found no data. Found on 2026-09-12,
    during the first install of this file. Keep every byte in this file ASCII.

    Why this exists.

    On 2026-09-12 every archive of flying_system and parkt_service on the
    Storage Box -- ten days, the entire retention -- turned out to be 264 bytes:
    an encrypted empty zip. PGBIN pointed at pg_dump 13 while the server had
    been on 14 for months. pg_dump failed on the version mismatch, left an empty
    file behind, and the script checked only IF EXIST and logged "completed
    successfully". Ten days with no restore point, and nobody knew, because
    nothing watched these dumps at all -- Veeam and borg were watched, these
    were not.

    Hence the shape of this collector. It publishes the archive SIZE as its own
    metric, because "the job succeeded" is precisely the claim that was false
    for ten days. Three things fail independently: how the run ended, when it
    ended, and how large the thing it left behind is.

    The data comes from a marker that backup.bat writes at its single exit
    point, while Q: is still mounted. The share is mapped only for the duration
    of the job, so the collector cannot stat it: the marker is the only place
    that size is visible. An intermediate file's size would prove nothing -- it
    was created faithfully all ten days.

    If the task does not run at all, the marker simply ages, and the age rule
    catches that rather than anything in its contents.
#>

param(
    [string] $StatusDir = 'C:\pg_dump\logs\status',
    [string] $OutFile   = 'C:\ProgramData\windows_exporter\textfile_inputs\pgdump.prom'
)

$lines = New-Object System.Collections.ArrayList
function Add-Metric { param($Text) $lines.Add($Text) | Out-Null }
$collectorOk = 1

try {
    if (-not (Test-Path $StatusDir)) {
        throw "marker directory not found: $StatusDir"
    }

    $markers = Get-ChildItem -Path $StatusDir -Filter '*.json' -File -ErrorAction Stop
    if (-not $markers) { throw "no marker files in $StatusDir" }

    foreach ($m in $markers) {
        $s = Get-Content -Path $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

        # The database name comes from inside the marker, not from the file
        # name: a renamed file would silently move the metric to a different
        # label and strand the old series.
        $db = if ($s.database) { $s.database } else { $m.BaseName }
        $dbEsc = $db -replace '"','\"'

        $result = if ($null -ne $s.result) { [int]$s.result } else { 2 }
        $run    = if ($s.finished_unix)    { [int64]$s.finished_unix } else { 0 }
        $bytes  = if ($null -ne $s.archive_bytes) { [int64]$s.archive_bytes } else { 0 }

        # Last SUCCESS, tracked separately from last run. Without that split a
        # job that fails every night still looks fresh -- it does run, on time,
        # every time. That is exactly how ten days of empty archives stayed
        # invisible.
        #
        # The marker carries last_success_unix and backup.bat forwards it from
        # the previous marker when a run fails, so one failure after a good run
        # reports "last success 26h ago" rather than "never succeeded". Deriving
        # it from this run alone was the first version of this script and it was
        # wrong: a single failure erased the entire history of success.
        #
        # The fallback keeps working against a marker written before that field
        # existed.
        $okTs = if ($null -ne $s.last_success_unix) {
            [int64]$s.last_success_unix
        } elseif ($result -eq 0) { $run } else { 0 }

        Add-Metric "pgdump_backup_last_result{database=`"$dbEsc`"} $result"
        Add-Metric "pgdump_backup_last_run_timestamp_seconds{database=`"$dbEsc`"} $run"
        Add-Metric "pgdump_backup_last_success_timestamp_seconds{database=`"$dbEsc`"} $okTs"
        Add-Metric "pgdump_backup_last_archive_bytes{database=`"$dbEsc`"} $bytes"
    }
}
catch {
    # A collector that quietly produces nothing is worse than no collector: the
    # series just disappears, and a series that is gone crosses no threshold.
    $collectorOk = 0
    Add-Metric ("pgdump_collector_error_info{reason=`"" + ($_.Exception.Message -replace '"','\"' -replace '[\r\n]',' ') + "`"} 1")
}

$header = @(
    '# HELP pgdump_backup_last_result Result of the last run: 0 success, 1 warning, 2 failed or unknown.',
    '# TYPE pgdump_backup_last_result gauge',
    '# HELP pgdump_backup_last_run_timestamp_seconds Unix time the last run finished, whatever its result.',
    '# TYPE pgdump_backup_last_run_timestamp_seconds gauge',
    '# HELP pgdump_backup_last_success_timestamp_seconds Unix time the last SUCCESSFUL run finished. Zero means never.',
    '# TYPE pgdump_backup_last_success_timestamp_seconds gauge',
    '# HELP pgdump_backup_last_archive_bytes Size of the .gpg archive on the share. An empty dump encrypts to 264 bytes.',
    '# TYPE pgdump_backup_last_archive_bytes gauge',
    '# HELP pgdump_collector_up Whether this collector produced data.',
    '# TYPE pgdump_collector_up gauge'
)

# Written atomically: windows_exporter reads this file on every scrape, and a
# half-written one makes it report a parse error instead of metrics.
$tmp = "$OutFile.tmp"
($header + $lines + "pgdump_collector_up $collectorOk") -join "`n" | Set-Content -Path $tmp -Encoding ASCII
Move-Item -Path $tmp -Destination $OutFile -Force
