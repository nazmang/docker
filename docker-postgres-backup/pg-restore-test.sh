#!/usr/bin/env bash
#
# Weekly restore test for the dumps pg-backup.sh writes (dkr01).
#
# pg-backup.sh checks every dump with `pg_restore --list`, which proves the
# archive is readable and complete as a file. It does not prove the data goes
# back into a server: a dump that needs an extension the image lacks, or one
# whose objects fail to create, passes --list and fails on the day it is needed.
# This script does the real thing once a week: the newest dump of each database
# is restored into a throwaway container of the same image as production, with
# no network, and counted.
#
# The throwaway server never touches tutor-postgres: own container, own
# anonymous volume, --network none, removed on exit. It does use dkr01's CPU and
# disk for a few minutes, which is why it runs on Sunday night.
#
# Publishes per database, through node-exporter's textfile collector:
#   pg_backup_restore_test_last_success_timestamp_seconds  when a restore last passed
#   pg_backup_restore_test_tables                          tables in the restored database
#   pg_backup_restore_test_duration_seconds                how long pg_restore took (an RTO number)
# A failed database keeps its previous timestamp, so the age alert fires.
#
#   pg-restore-test.sh            test the newest dump of every database
#   pg-restore-test.sh DB...      only these databases

set -uo pipefail

SRC="${PG_BACKUP_DEST:-/data/backups/postgres}"
IMAGE="${PG_RESTORE_TEST_IMAGE:-pgvector/pgvector:pg16}"
TEXTFILE="${PG_BACKUP_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}/pg_restore_test.prom"
# Word-split on purpose: tests run it as "docker --context default".
DOCKER="${DOCKER:-docker}"
NAME="pg-restore-test-$$"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
dk() { $DOCKER "$@"; }

cleanup() { dk rm -f -v "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Databases come from the dump files, not from a list here: a database that is
# dumped is a database that is tested.
if [[ $# -gt 0 ]]; then
    DATABASES=("$@")
else
    mapfile -t DATABASES < <(ls -1 "$SRC"/*.dump 2>/dev/null | sed -E 's#.*/##; s/-[0-9]{8}-[0-9]{4}\.dump$//' | sort -u)
fi
if [[ ${#DATABASES[@]} -eq 0 ]]; then
    log "ОШИБКА: в $SRC нет ни одного дампа"
    exit 1
fi

# Keep previous values for databases that fail this time: a failure must not
# erase the last good timestamp, or the age alert would see nothing at all.
declare -A ts tables dur
if [[ -r "$TEXTFILE" ]]; then
    while read -r metric value; do
        db=$(sed -E 's/.*database="([^"]+)".*/\1/' <<<"$metric")
        case "$metric" in
            pg_backup_restore_test_last_success_timestamp_seconds*) ts[$db]=$value ;;
            pg_backup_restore_test_tables*) tables[$db]=$value ;;
            pg_backup_restore_test_duration_seconds*) dur[$db]=$value ;;
        esac
    done < <(grep -v '^#' "$TEXTFILE")
fi

failed=0
for db in "${DATABASES[@]}"; do
    dump=$(ls -1t "$SRC/$db-"*.dump 2>/dev/null | head -1)
    if [[ -z "$dump" ]]; then
        log "ОШИБКА $db: дампа нет"; failed=1; continue
    fi

    cleanup
    # trust is safe here only because of --network none: nothing can reach it.
    if ! dk run -d --name "$NAME" --network none --cpus 1 \
            -e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" >/dev/null; then
        log "ОШИБКА $db: не стартовал временный сервер"; failed=1; continue
    fi
    ready=0
    for _ in $(seq 1 60); do
        # pg_isready is true during the image's init-time server too; wait for
        # the final one by also requiring the init log line.
        if dk logs "$NAME" 2>&1 | grep -q 'PostgreSQL init process complete' \
           && dk exec "$NAME" pg_isready -U postgres -q 2>/dev/null; then ready=1; break; fi
        sleep 1
    done
    if [[ $ready -ne 1 ]]; then
        log "ОШИБКА $db: временный сервер не поднялся за 60 с"; failed=1; continue
    fi

    start=$(date +%s)
    # --create recreates the database under its own name; --no-owner/--no-acl
    # because the production roles do not exist in the throwaway server.
    if ! err=$(dk exec -i "$NAME" pg_restore -U postgres -d postgres --create \
                 --no-owner --no-acl --exit-on-error < "$dump" 2>&1); then
        log "ОШИБКА $db: pg_restore $(basename "$dump"): $(head -3 <<<"$err" | tr '\n' ' ')"
        failed=1; continue
    fi
    took=$(( $(date +%s) - start ))

    n=$(dk exec "$NAME" psql -U postgres -d "$db" -tAc \
          "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')" 2>/dev/null)
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [[ "$n" -eq 0 ]]; then
        log "ОШИБКА $db: восстановилось, но таблиц нет ($n) — пустой дамп не считается"
        failed=1; continue
    fi

    log "$db: $(basename "$dump") восстановлен за ${took} с, таблиц: $n"
    ts[$db]=$(date +%s); tables[$db]=$n; dur[$db]=$took
done
cleanup

if [[ -d "$(dirname "$TEXTFILE")" ]]; then
    {
        echo '# HELP pg_backup_restore_test_last_success_timestamp_seconds Unix time the newest dump last restored cleanly.'
        echo '# TYPE pg_backup_restore_test_last_success_timestamp_seconds gauge'
        for db in "${!ts[@]}"; do echo "pg_backup_restore_test_last_success_timestamp_seconds{database=\"$db\"} ${ts[$db]}"; done
        echo '# HELP pg_backup_restore_test_tables Tables in the database after the last successful test restore.'
        echo '# TYPE pg_backup_restore_test_tables gauge'
        for db in "${!tables[@]}"; do echo "pg_backup_restore_test_tables{database=\"$db\"} ${tables[$db]}"; done
        echo '# HELP pg_backup_restore_test_duration_seconds Duration of pg_restore in the last successful test.'
        echo '# TYPE pg_backup_restore_test_duration_seconds gauge'
        for db in "${!dur[@]}"; do echo "pg_backup_restore_test_duration_seconds{database=\"$db\"} ${dur[$db]}"; done
    } > "$TEXTFILE.tmp" && mv "$TEXTFILE.tmp" "$TEXTFILE"
fi

exit "$failed"
