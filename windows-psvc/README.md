# windows-psvc

Files that live on the Windows host `psvc.duckdns.org` — not a Docker stack, but
kept here because the Prometheus rules that consume them are in
`docker-monitoring/prometheus/rules/veeam.rules.yml`, and splitting a producer
from its consumer across repositories is how one of them gets forgotten.

That host runs PostgreSQL 14.13-1C (7 databases, the largest 10 GB), a 1C
application server, an Active Directory domain controller, Hyper-V, and the
Veeam Agent that backs the whole machine up nightly to a Hetzner Storage Box.
Until 2026-09-11 none of it was monitored.

## veeam-metrics.ps1

Publishes Veeam job state for Prometheus through windows_exporter's textfile
collector.

It deliberately does not just report the job's status. On 2026-09-11 that job
reported **Success** every night while logging, on every run, that its archive
recovery key was missing and its backup metadata inconsistent — and the Veeam UI
could not see the backup chain at all, though the files were on the storage box.
"Did the job succeed?" answered yes for at least five days. So the script
collects three things that fail independently: whether the job finished, when it
finished, and whether it logged key or metadata errors regardless of its verdict.

### Installation on the host

windows_exporter, with the textfile collector and only the collectors worth
having on this machine:

```powershell
msiexec /i windows_exporter-<version>-amd64.msi --% ENABLED_COLLECTORS="cpu,logical_disk,memory,net,os,service,system,textfile,scheduled_task" TEXTFILE_DIRS="C:\ProgramData\windows_exporter\textfile_inputs" LISTEN_PORT=9182 /qn
```

**No `cs` collector.** It was removed in windows_exporter 0.31.x, and naming it
does not degrade to a warning — the service refuses to start at all:
`couldn't enable collectors: unknown collector cs`. Found during the real
install on 2026-09-11 (0.31.8, revision `c73b596c`). What it used to publish —
physical memory, logical processor count — comes from `os` and `cpu` anyway.

Check the MSI against the release's `sha256sums.txt` before running it.

**Fetching the script: `raw.githubusercontent.com` serves stale content.** During
the 2026-09-11 deployment it kept returning the previous revision even with
`no-cache` and a cache-busting query string, which meant installing a version
with a bug that had already been fixed and then hunting for it. Pull the current
file through the API instead:

```powershell
$h = @{ Accept = 'application/vnd.github.raw'; 'User-Agent' = 'psvc' }
Invoke-WebRequest -Headers $h -UseBasicParsing `
  'https://api.github.com/repos/nazmang/docker/contents/windows-psvc/veeam-metrics.ps1' `
  -OutFile 'C:\Scripts\veeam-metrics.ps1'
```

Then verify the SHA256 against the value from `git`, and only then run it.

Then the collector on a schedule — every 15 minutes is plenty for a nightly job,
and cheap because it only tails log files:

```powershell
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\windows_exporter\textfile_inputs','C:\Scripts' | Out-Null
Copy-Item .\veeam-metrics.ps1 'C:\Scripts\veeam-metrics.ps1'

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NonInteractive -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\veeam-metrics.ps1"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName 'Prometheus\Veeam metrics' -Action $action -Trigger $trigger `
    -User 'SYSTEM' -RunLevel Highest
```

SYSTEM because the Veeam log directory under `C:\ProgramData\Veeam\Endpoint` is
not readable by ordinary accounts — the same ACL that blocked reading it during
the investigation.

### Firewall

Port 9182 must be reachable from the monitoring host and from nowhere else. On
this machine that matters more than usual: its internet-facing NIC is in the
Domain profile, so a rule scoped Domain or Private is a rule open to the world.
Restrict by address, as was done for WinRM:

```powershell
New-NetFirewallRule -DisplayName 'windows_exporter (Prometheus)' -Direction Inbound `
  -Protocol TCP -LocalPort 9182 -Action Allow -RemoteAddress '95.217.42.189'
```

95.217.42.189 is the dedicated server's egress address — the Swarm and the
Kubernetes cluster share it.

### Verifying

```powershell
Get-Content C:\ProgramData\windows_exporter\textfile_inputs\veeam.prom
Invoke-WebRequest http://localhost:9182/metrics -UseBasicParsing |
  Select-String 'veeam_'
```

The scrape job `windows-psvc` in `docker-monitoring/prometheus/prometheus.yml`
picks it up from there.

## pgdump-metrics.ps1

Публикует состояние ночных дампов PostgreSQL — тем же путём, через textfile-коллектор
`windows_exporter`. Правила, которые их потребляют, лежат в
`docker-monitoring/prometheus/rules/pgdump.rules.yml`.

### Зачем

12.09.2026 выяснилось, что все архивы `flying_system` и `parkt_service` на Storage Box
за последние десять дней — то есть за всю глубину хранения — весят по 264 байта. Это
зашифрованный пустой zip.

`PGBIN` указывал на `pg_dump` от версии 13, база давно на 14. `pg_dump` падал на
несовпадении версий, оставляя пустой файл, а скрипт проверял только `IF EXIST` и писал
в журнал `completed successfully`. Десять дней подряд отката не существовало, и никто
об этом не знал: за этими дампами не следило ничего, хотя Veeam и borg наблюдались.

Отсюда устройство коллектора. Он публикует **размер архива** отдельной метрикой, потому
что «задача завершилась успешно» — ровно то утверждение, которое оказалось ложным. Три
величины отказывают независимо: чем закончился прогон, когда он закончился, и сколько
весит то, что он оставил.

### Маркер, который пишет backup.bat

Шара подключается только на время задачи, поэтому опросить её из коллектора нельзя —
размер файла видит лишь сам скрипт, пока `Q:` смонтирован. Он записывает его в маркер:

`C:\pg_dump\logs\status\<db>.json`, кодировка UTF-8, перезаписывается целиком:

```json
{
  "database": "flying_system",
  "result": 0,
  "finished_unix": 1789215830,
  "archive_bytes": 109781387,
  "dump_bytes": 119752731,
  "archive_name": "flying_system_backup_20260912.zip.gpg",
  "error": ""
}
```

`result` — 0 успех, 1 предупреждение, 2 ошибка. `finished_unix` — время окончания в
секундах Unix; именно epoch, а не строка с датой, потому что на этой машине три часовых
пояса (GMT в логах PostgreSQL, UTC+2 локальное, UTC+3 в Zabbix) и разбор строк здесь
уже приводил к путанице. `archive_bytes` — размер `.gpg` **на шаре**, снятый после
записи, а не размер промежуточного файла.

Маркер пишется при любом исходе, включая ошибку. Если задача не запускалась вовсе, он
просто стареет — это ловит правило по возрасту.

### Установка

Скрипт кладётся рядом с `veeam-metrics.ps1` и запускается той же запланированной
задачей или отдельной. Раз в 15 минут достаточно: задачи ночные, а чтение одного
маленького JSON стоит около нуля.

Порядок важен: сначала коллектор и первый маркер на хосте, потом правила в Prometheus.
Наоборот — `PgDumpMetricsMissing` будет справедливо срабатывать всё время между
выкладкой правил и установкой скрипта.
