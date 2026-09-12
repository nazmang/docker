@echo off
setlocal EnableExtensions
REM Usage: backup.bat <pg_user> <database> <pg_host> [extra pg_dump options]
REM The optional 4th argument is passed verbatim to pg_dump (e.g. weekly zabbix:
REM   "--exclude-table-data=history* --exclude-table-data=trends*"). Leave empty
REM for a full dump. cmd does not expand * , so patterns reach pg_dump intact.
REM Secrets are NOT passed on the command line:
REM   C:\pg_dump\pgpass.conf  - libpq password file (PGPASSFILE)
REM   C:\pg_dump\gpg.pass     - passphrase for symmetric gpg encryption (LF only, no CR!)
REM   C:\pg_dump\secrets.cmd  - SB_USER / SB_PASS for the storage box share
REM All three files are readable by locadmin and SYSTEM only.
REM STORAGEBOX_HOST below is a placeholder: this file lives in a public repository.
REM The deployed copy on psvc (C:\pg_dump\backup.bat) carries the real host; the
REM share user/password come from secrets.cmd (SB_USER / SB_PASS), never from here.
REM
REM Every exit goes through :done, which writes the status marker
REM C:\pg_dump\logs\status\<db>.json (see write-status.ps1) while Q: is still
REM mounted, so archive_bytes is the size ON THE SHARE.
REM RESULT: 0 success, 1 warning, 2 error.

SET "PGUSER=%~1"
SET "PGDATABASE=%~2"
SET "PGHOST=%~3"
SET "EXTRA=%~4"
SET "PGPASSFILE=C:\pg_dump\pgpass.conf"
SET "GPGPASSFILE=C:\pg_dump\gpg.pass"
SET "PGBIN=C:\Program Files\PostgreSQL\14.13-1C\bin"
SET "GPGBIN=C:\Program Files (x86)\GnuPG\bin"
SET "GNUPGHOME=C:\pg_dump\gnupg"
SET "STATUSPS=C:\pg_dump\write-status.ps1"
SET "SHARE=\\STORAGEBOX_HOST\backup"
SET "BACKUPDIR=Q:\SQL backup\backups"
SET "LOGFILE=%BACKUPDIR%\backup_log.txt"
SET "LOCALLOG=C:\pg_dump\logs\%PGDATABASE%.log"
SET "RESULT=2"
SET "ERRMSG="
SET "DUMPSIZE=0"
SET "ENCRYPTED_BACKUPFILE="
SET "MOUNTED=0"

IF NOT EXIST "C:\pg_dump\logs" mkdir "C:\pg_dump\logs"
IF NOT EXIST "%GNUPGHOME%" mkdir "%GNUPGHOME%"
IF "%PGDATABASE%"=="" (
    SET "PGDATABASE=unknown"
    SET "ERRMSG=database name not given"
    goto :done
)
echo ---- %DATE% %TIME% start %PGDATABASE% as %PGUSER%@%PGHOST% >> "%LOCALLOG%"

call "C:\pg_dump\secrets.cmd"
IF "%SB_PASS%"=="" (
    SET "ERRMSG=secrets.cmd did not set SB_PASS"
    goto :done
)

REM Mount the storage box share (drop a stale mapping first, never prompt)
net use Q: /delete /y >nul 2>&1 <nul
net use Q: "%SHARE%" /user:%SB_USER% "%SB_PASS%" /persistent:no >> "%LOCALLOG%" 2>&1 <nul
IF ERRORLEVEL 1 (
    SET "ERRMSG=net use Q: failed"
    goto :done
)
SET "MOUNTED=1"
IF NOT EXIST "%BACKUPDIR%" mkdir "%BACKUPDIR%"
echo Backup started: %DATE% %TIME% >> "%LOGFILE%"

FOR /f "tokens=2 delims==" %%i IN ('wmic os get localdatetime /value') DO SET "datetime=%%i"
SET "DATESTR=%datetime:~0,4%%datetime:~4,2%%datetime:~6,2%"
SET "BACKUPFILE=%BACKUPDIR%\%PGDATABASE%_backup_%DATESTR%.sql"
SET "COMPRESSED_BACKUPFILE=%BACKUPDIR%\%PGDATABASE%_backup_%DATESTR%.zip"
SET "ENCRYPTED_BACKUPFILE=%BACKUPDIR%\%PGDATABASE%_backup_%DATESTR%.zip.gpg"

REM Dump. Success = exit code 0 AND non-empty file (an empty file is a failure).
"%PGBIN%\pg_dump.exe" -w -U "%PGUSER%" -h "%PGHOST%" -F c -b %EXTRA% -f "%BACKUPFILE%" "%PGDATABASE%" >> "%LOCALLOG%" 2>&1 <nul
SET "RC=%ERRORLEVEL%"
IF EXIST "%BACKUPFILE%" FOR %%A IN ("%BACKUPFILE%") DO SET "DUMPSIZE=%%~zA"
IF NOT "%RC%"=="0" (
    SET "ERRMSG=pg_dump exit code %RC%"
    IF EXIST "%BACKUPFILE%" del "%BACKUPFILE%"
    goto :done
)
IF "%DUMPSIZE%"=="0" (
    SET "ERRMSG=pg_dump produced an empty file"
    IF EXIST "%BACKUPFILE%" del "%BACKUPFILE%"
    goto :done
)
echo Backup created successfully: %BACKUPFILE% (%DUMPSIZE% bytes) >> "%LOGFILE%"
echo %DATE% %TIME% dump ok, %DUMPSIZE% bytes >> "%LOCALLOG%"

REM Compress
IF EXIST "%COMPRESSED_BACKUPFILE%" del "%COMPRESSED_BACKUPFILE%"
powershell -NoProfile -NonInteractive -Command "Compress-Archive -LiteralPath '%BACKUPFILE%' -DestinationPath '%COMPRESSED_BACKUPFILE%' -CompressionLevel Optimal" >> "%LOCALLOG%" 2>&1 <nul
IF NOT EXIST "%COMPRESSED_BACKUPFILE%" (
    SET "ERRMSG=compression failed"
    goto :done
)

REM Encrypt (batch, no tty, passphrase from a protected file - no agent/pinentry involved)
"%GPGBIN%\gpg.exe" --batch --yes --no-tty --pinentry-mode loopback --passphrase-file "%GPGPASSFILE%" --cipher-algo AES256 --symmetric --output "%ENCRYPTED_BACKUPFILE%" "%COMPRESSED_BACKUPFILE%" >> "%LOCALLOG%" 2>&1 <nul
SET "RC=%ERRORLEVEL%"
SET "ENCSIZE=0"
IF EXIST "%ENCRYPTED_BACKUPFILE%" FOR %%A IN ("%ENCRYPTED_BACKUPFILE%") DO SET "ENCSIZE=%%~zA"
IF NOT "%RC%"=="0" (
    SET "ERRMSG=gpg exit code %RC%"
    goto :done
)
IF %ENCSIZE% LSS 1024 (
    SET "ERRMSG=encrypted file suspiciously small: %ENCSIZE% bytes"
    goto :done
)

del "%COMPRESSED_BACKUPFILE%"
del "%BACKUPFILE%"
SET "RESULT=0"
echo Backup, compression, and encryption completed successfully: %ENCRYPTED_BACKUPFILE% (%ENCSIZE% bytes) %DATE% %TIME% >> "%LOGFILE%"
echo %DATE% %TIME% OK %ENCRYPTED_BACKUPFILE% %ENCSIZE% bytes >> "%LOCALLOG%"

REM Retention, per database (each run cleans only its own archives):
REM   zabbix -> keep the 2 newest (weekly backup)
REM   others -> keep 10 days
IF /I "%PGDATABASE%"=="zabbix" (
    powershell -NoProfile -NonInteractive -Command "Get-ChildItem -LiteralPath '%BACKUPDIR%' -Filter 'zabbix_backup_*.zip.gpg' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 2 | Remove-Item -Force" >> "%LOCALLOG%" 2>&1 <nul
) ELSE (
    forfiles -p "%BACKUPDIR%" -s -m %PGDATABASE%_backup_*.zip.gpg -d -10 -c "cmd /c del @path" >nul 2>&1 <nul
)

:done
IF NOT "%ERRMSG%"=="" (
    echo Error: %ERRMSG% for %PGDATABASE% %DATE% %TIME% >> "%LOCALLOG%"
    IF "%MOUNTED%"=="1" echo Error: %ERRMSG% for %PGDATABASE% %DATE% %TIME% >> "%LOGFILE%"
)
IF "%MOUNTED%"=="1" IF NOT "%COMPRESSED_BACKUPFILE%"=="" IF EXIST "%COMPRESSED_BACKUPFILE%" del "%COMPRESSED_BACKUPFILE%"
REM Status marker - written while Q: is still mounted so archive_bytes is measured on the share
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%STATUSPS%" -Database "%PGDATABASE%" -Result %RESULT% -ArchivePath "%ENCRYPTED_BACKUPFILE%" -DumpBytes %DUMPSIZE% -ErrorText "%ERRMSG%" >> "%LOCALLOG%" 2>&1 <nul
IF "%MOUNTED%"=="1" net use Q: /delete /y >> "%LOCALLOG%" 2>&1 <nul
endlocal & exit /b %RESULT%
