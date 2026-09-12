<#
    Writes the per-database status marker consumed by pgdump-metrics.ps1
    (windows-psvc/pgdump-metrics.ps1 in nazmang/docker).

    Called from backup.bat at EVERY exit point, success or failure, so the
    marker always reflects the latest run. Overwritten whole, UTF-8 (no BOM).

    result: 0 success, 1 warning, 2 error  (same convention as veeam-metrics.ps1)
    finished_unix: Unix seconds, timezone-free on purpose (three zones are in
    play between this host, its logs and the monitoring side).
    archive_bytes: size of the .gpg ON THE SHARE, measured here while Q: is still
    mounted -- the number that went unchecked for ten days.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Database,
    [Parameter(Mandatory)] [int]    $Result,
    [string] $ArchivePath = '',
    [long]   $DumpBytes   = 0,
    [string] $ErrorText      = '',
    [string] $StatusDir   = 'C:\pg_dump\logs\status'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $StatusDir)) { New-Item -ItemType Directory -Path $StatusDir | Out-Null }

$archiveBytes = 0
$archiveName  = ''
if ($ArchivePath) {
    $archiveName = [IO.Path]::GetFileName($ArchivePath)
    if (Test-Path -LiteralPath $ArchivePath) { $archiveBytes = (Get-Item -LiteralPath $ArchivePath).Length }
}

$now = [int64][Math]::Floor(([DateTimeOffset]::UtcNow).ToUnixTimeSeconds())
$out = Join-Path $StatusDir ("{0}.json" -f $Database)

# last_success_unix: on success = now; on failure CARRY OVER the previous
# marker's value (0 if there is none). Never reset it on failure -- one bad
# night must not turn "last success 26h ago" into "never succeeded".
$lastSuccess = [int64]0
if ($Result -eq 0) {
    $lastSuccess = $now
} elseif (Test-Path -LiteralPath $out) {
    try {
        $prev = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $prev.last_success_unix) { $lastSuccess = [int64]$prev.last_success_unix }
        elseif ($prev.result -eq 0 -and $prev.finished_unix) { $lastSuccess = [int64]$prev.finished_unix }
    } catch { $lastSuccess = 0 }
}

$doc = [ordered]@{
    database          = $Database
    result            = $Result
    finished_unix     = $now
    last_success_unix = $lastSuccess
    archive_bytes     = [int64]$archiveBytes
    dump_bytes        = [int64]$DumpBytes
    archive_name      = $archiveName
    error             = $ErrorText
}

$json = $doc | ConvertTo-Json -Compress
$tmp  = "$out.tmp"
[IO.File]::WriteAllText($tmp, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $out -Force
