#!/usr/bin/env bash
#
# Logical backups of the PostgreSQL container on dkr01 (tutor-postgres,
# pgvector/pg16), which serves the tutor application and, from 2026-09-11, n8n.
#
# Why this exists: that container's data lives on dkr01's local disk and nothing
# backed it up. The VM itself is covered by Proxmox, which gives a
# crash-consistent image -- PostgreSQL recovers from those, but an image cannot
# restore one dropped table, one database, or yesterday's state of a single row.
# That is what a logical dump is for, and there was none.
#
# No credentials anywhere: pg_dump runs INSIDE the container, where pg_hba grants
# local connections `trust`. Nothing to store, nothing to rotate, nothing to leak.
#
# Dumps go to NFS on nas01 rather than dkr01's disk on purpose: a backup on the
# same disk as the database protects against exactly one failure mode (someone
# dropping a table) and none of the others.

set -euo pipefail

CONTAINER="${PG_BACKUP_CONTAINER:-tutor-postgres}"
SUPERUSER="${PG_BACKUP_USER:-tutor}"
DEST="${PG_BACKUP_DEST:-/data/backups/postgres}"
KEEP="${PG_BACKUP_KEEP:-14}"
TEXTFILE_DIR="${PG_BACKUP_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
STAMP="$(date +%Y%m%d-%H%M)"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

mkdir -p "$DEST"

# Ask the server which databases exist rather than hardcoding a list -- a new
# database that nobody told the backup about is the classic way to discover,
# during a restore, that it was never being backed up.
mapfile -t DATABASES < <(
    docker exec "$CONTAINER" psql -U "$SUPERUSER" -d postgres -tAc \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres'"
)

if [[ ${#DATABASES[@]} -eq 0 ]]; then
    log "ОШИБКА: сервер не вернул ни одной базы — прерываюсь, чтобы не считать это успехом"
    exit 1
fi

log "базы к выгрузке: ${DATABASES[*]}"

metrics=""
failed=0

for db in "${DATABASES[@]}"; do
    out="$DEST/${db}-${STAMP}.dump"
    tmp="$out.partial"

    # -Fc: custom format, compressed, and restorable selectively (one table out
    # of a 1.4 GB dump without touching the rest).
    if docker exec "$CONTAINER" pg_dump -U "$SUPERUSER" -d "$db" -Fc > "$tmp" 2>/tmp/pg-backup-err.$$; then
        # Verify before trusting it. pg_restore --list parses the archive's table
        # of contents: a truncated or corrupt dump fails here, while `test -s`
        # would happily call it a backup.
        if docker exec -i "$CONTAINER" pg_restore --list < "$tmp" > /dev/null 2>&1; then
            mv "$tmp" "$out"
            size=$(stat -c %s "$out")
            log "$db: выгружено и проверено, $(numfmt --to=iec "$size")"
            metrics+="pg_backup_last_success_timestamp_seconds{database=\"$db\"} $(date +%s)
pg_backup_last_size_bytes{database=\"$db\"} $size
"
        else
            log "ОШИБКА $db: дамп не читается pg_restore — файл не засчитан"
            rm -f "$tmp"
            failed=1
        fi
    else
        log "ОШИБКА $db: pg_dump завершился с ошибкой: $(head -3 /tmp/pg-backup-err.$$ | tr '\n' ' ')"
        rm -f "$tmp"
        failed=1
    fi
    rm -f /tmp/pg-backup-err.$$
done

# Retention per database, so a rarely-changing database is not evicted by a busy
# one sharing the directory.
for db in "${DATABASES[@]}"; do
    mapfile -t old < <(ls -1t "$DEST/${db}-"*.dump 2>/dev/null | tail -n +$((KEEP + 1)))
    for f in "${old[@]:-}"; do
        [[ -n "$f" ]] || continue
        rm -f "$f"
        log "удалён старый: $(basename "$f")"
    done
done

# Publish freshness to Prometheus through node-exporter's textfile collector.
# Written atomically: node-exporter reads this directory on every scrape, and a
# half-written file would make it log a parse error instead of metrics.
if [[ -d "$TEXTFILE_DIR" ]]; then
    printf '# HELP pg_backup_last_success_timestamp_seconds Unix time of the last verified dump.\n# TYPE pg_backup_last_success_timestamp_seconds gauge\n# HELP pg_backup_last_size_bytes Size of the last verified dump.\n# TYPE pg_backup_last_size_bytes gauge\n%s' "$metrics" > "$TEXTFILE_DIR/pg_backup.prom.tmp"
    mv "$TEXTFILE_DIR/pg_backup.prom.tmp" "$TEXTFILE_DIR/pg_backup.prom"
fi

exit "$failed"
