<#
    Состояние ночных дампов PostgreSQL для Prometheus, через textfile-коллектор
    windows_exporter -- тем же путём, что и veeam-metrics.ps1.

    Зачем это существует.

    12.09.2026 выяснилось, что все архивы flying_system и parkt_service на
    Storage Box за последние десять дней -- то есть за всю глубину хранения --
    весят по 264 байта. Это зашифрованный пустой zip. Причина: PGBIN указывал
    на pg_dump от версии 13, тот падал на несовпадении версий, создавая пустой
    файл, а скрипт проверял только IF EXIST и писал в журнал "completed
    successfully". Десять дней подряд.

    Отсюда главное свойство этого коллектора: он публикует РАЗМЕР архива
    отдельной метрикой. "Задача завершилась успешно" -- утверждение, которое
    оказалось ложным десять дней подряд, и одного кода возврата мало. Пустой
    дамп весит 264 байта, настоящий -- сотни мегабайт; разница такая, что порог
    можно ставить грубо и не бояться ложных срабатываний.

    Три величины, которые отказывают независимо друг от друга:
      -- чем закончился последний запуск,
      -- когда он закончился (задача могла вообще не запуститься),
      -- сколько весит то, что он оставил на шаре.

    Источник данных -- маркер, который backup.bat пишет в конце каждого
    прогона, уже зная фактический размер файла на смонтированной шаре. Шара
    подключается только на время задачи, поэтому опрашивать её из коллектора
    нельзя: маркер -- единственное место, где размер виден.

    Если задача не запускалась вовсе, маркер не обновляется и стареет -- это
    ловит правило по возрасту, а не по содержимому.
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
        throw "каталог маркеров не найден: $StatusDir"
    }

    $markers = Get-ChildItem -Path $StatusDir -Filter '*.json' -File -ErrorAction Stop
    if (-not $markers) { throw "в $StatusDir нет ни одного маркера" }

    foreach ($m in $markers) {
        $s = Get-Content -Path $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json

        # Имя базы берём из маркера, а не из имени файла: файл можно
        # переименовать, а метрика после этого молча сменит свой label и
        # уедет в другую временную серию.
        $db = if ($s.database) { $s.database } else { $m.BaseName }
        $dbEsc = $db -replace '"','\"'

        $result = if ($null -ne $s.result) { [int]$s.result } else { 2 }
        $run    = if ($s.finished_unix)    { [int64]$s.finished_unix } else { 0 }
        $bytes  = if ($null -ne $s.archive_bytes) { [int64]$s.archive_bytes } else { 0 }

        # Время последнего УСПЕХА отдельно от времени последнего запуска.
        # Без этого разделения ежедневно падающая задача выглядит свежей:
        # она же запускается.
        $okTs = if ($result -eq 0) { $run } else { 0 }

        Add-Metric "pgdump_backup_last_result{database=`"$dbEsc`"} $result"
        Add-Metric "pgdump_backup_last_run_timestamp_seconds{database=`"$dbEsc`"} $run"
        Add-Metric "pgdump_backup_last_success_timestamp_seconds{database=`"$dbEsc`"} $okTs"
        Add-Metric "pgdump_backup_last_archive_bytes{database=`"$dbEsc`"} $bytes"
    }
}
catch {
    # Коллектор, который молча ничего не выдал, хуже отсутствующего: серия
    # просто исчезает, а исчезнувшая серия не срабатывает ни по одному порогу.
    $collectorOk = 0
    Add-Metric ("pgdump_collector_error_info{reason=`"" + ($_.Exception.Message -replace '"','\"' -replace '[\r\n]',' ') + "`"} 1")
}

$header = @(
    '# HELP pgdump_backup_last_result Чем закончился последний прогон: 0 успех, 1 предупреждение, 2 ошибка или неизвестно.',
    '# TYPE pgdump_backup_last_result gauge',
    '# HELP pgdump_backup_last_run_timestamp_seconds Когда прогон закончился, независимо от исхода.',
    '# TYPE pgdump_backup_last_run_timestamp_seconds gauge',
    '# HELP pgdump_backup_last_success_timestamp_seconds Когда закончился последний УСПЕШНЫЙ прогон.',
    '# TYPE pgdump_backup_last_success_timestamp_seconds gauge',
    '# HELP pgdump_backup_last_archive_bytes Размер архива .gpg на шаре. Пустой дамп весит 264 байта.',
    '# TYPE pgdump_backup_last_archive_bytes gauge',
    '# HELP pgdump_collector_up Выдал ли коллектор данные.',
    '# TYPE pgdump_collector_up gauge'
)

# Пишем атомарно: windows_exporter читает файл на каждом опросе, и
# недописанный он превращает в ошибку разбора вместо метрик.
$tmp = "$OutFile.tmp"
($header + $lines + "pgdump_collector_up $collectorOk") -join "`n" | Set-Content -Path $tmp -Encoding ASCII
Move-Item -Path $tmp -Destination $OutFile -Force
