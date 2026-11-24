#!/usr/bin/env bash
#
# Off-site copy of dkr01's PostgreSQL dumps, pulled to debian01.
#
# Why this exists: pg-backup.sh on dkr01 writes its dumps to NFS on nas01. That
# is the only copy, and nas01 sits in the same place as dkr01 and also holds
# every PVC of the Kubernetes cluster -- one site, one box. debian01 is at home,
# a different site behind its own connection, with room on big_pool.
#
# Pull, not push: debian01 holds a key that can only list and read dumps
# (dkr01 forces it into pg-backup-serve.sh), and dkr01 holds no key to here.
# A compromised dkr01 cannot reach or delete the off-site copies.
#
# Nothing is stored in plaintext. Each dump is streamed through `age` to a
# public recipient as it arrives; the private key is not on this host, so a
# stolen debian01 disk yields nothing readable. The stream is hashed on the way
# in and compared with the sha256 dkr01 reports, so a cut or corrupted transfer
# is thrown away instead of kept as a backup.
#
#   pg-offsite.sh                 pull every dump not yet here, then prune
#   pg-offsite.sh --write-metric  write the metric (the unit runs it as root)
#
# Configuration (environment, set in the unit):
#   PG_OFFSITE_HOST   ssh target, e.g. pgoffsite@10.164.1.105
#   PG_OFFSITE_DIR    where the .age files go
#   PG_OFFSITE_AGE_RECIPIENT  age public key
#   PG_OFFSITE_KEEP_DAYS      retention, by the date in the file name (default 30)
# The ssh private key and known_hosts come from systemd LoadCredential=.
#
# Exit codes: 0 ok, 1 some dump failed, 5 config error.

set -uo pipefail

HOST="${PG_OFFSITE_HOST:-}"
DIR="${PG_OFFSITE_DIR:-}"
RECIPIENT="${PG_OFFSITE_AGE_RECIPIENT:-}"
KEEP_DAYS="${PG_OFFSITE_KEEP_DAYS:-30}"
TEXTFILE="${TEXTFILE:-/var/lib/node_exporter/textfile/pg_offsite.prom}"
CRED="${CREDENTIALS_DIRECTORY:-/etc/pg-offsite}"
NAME_RE='^([a-z0-9_]+)-([0-9]{8})-([0-9]{4})\.dump$'

log() { printf 'pg-offsite: %s\n' "$*" >&2; }

# newest_per_db DIR - "db epoch" for the newest .age file of every database
newest_per_db() {
    local f base db d t
    declare -A best
    for f in "$1"/*.dump.age; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .age)
        [[ "$base" =~ $NAME_RE ]] || continue
        db=${BASH_REMATCH[1]}; d=${BASH_REMATCH[2]}; t=${BASH_REMATCH[3]}
        # pg-backup.sh stamps names with dkr01's local time, which is UTC.
        epoch=$(date -u -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}" +%s) || continue
        if [[ -z "${best[$db]:-}" || $epoch -gt ${best[$db]} ]]; then best[$db]=$epoch; fi
    done
    for db in "${!best[@]}"; do echo "$db ${best[$db]}"; done
}

if [[ "${1:-}" == "--write-metric" ]]; then
    [[ -n "$DIR" && -d "$(dirname "$TEXTFILE")" ]] || exit 0
    {
        echo '# HELP pg_backup_offsite_newest_dump_timestamp_seconds Time the newest dump held off-site was taken on dkr01.'
        echo '# TYPE pg_backup_offsite_newest_dump_timestamp_seconds gauge'
        newest_per_db "$DIR" | while read -r db epoch; do
            echo "pg_backup_offsite_newest_dump_timestamp_seconds{database=\"$db\"} $epoch"
        done
    } > "$TEXTFILE.tmp" && mv "$TEXTFILE.tmp" "$TEXTFILE"
    exit 0
fi

[[ -n "$HOST" && -n "$DIR" && -n "$RECIPIENT" ]] || { log "PG_OFFSITE_HOST, PG_OFFSITE_DIR and PG_OFFSITE_AGE_RECIPIENT are required"; exit 5; }
[[ -d "$DIR" && -w "$DIR" ]] || { log "$DIR is not a writable directory"; exit 5; }
command -v age >/dev/null || { log "age is not installed"; exit 5; }

# BatchMode: never prompt. StrictHostKeyChecking=yes against a pinned file: a
# changed dkr01 host key stops the copy instead of being trusted.
SSH=(ssh -i "$CRED/ssh_key" -o BatchMode=yes -o StrictHostKeyChecking=yes
     -o UserKnownHostsFile="$CRED/known_hosts" -o ConnectTimeout=15 -o ServerAliveInterval=30 "$HOST")
# Tests replace ssh with a local stand-in that runs pg-backup-serve.sh.
if [[ -n "${PG_OFFSITE_SSH_CMD:-}" ]]; then SSH=("$PG_OFFSITE_SSH_CMD"); fi

listing=$("${SSH[@]}" list) || { log "list failed"; exit 1; }

failed=0
while read -r name size; do
    [[ "$name" =~ $NAME_RE ]] || continue
    out="$DIR/$name.age"
    [[ -e "$out" ]] && continue

    tmp="$out.partial"
    # Hash the plaintext as it streams past; it is written only through age.
    # The hasher reads a FIFO and runs as a job of this shell, so it can be
    # waited for before its result is read.
    fifo="$DIR/.$name.fifo"
    rm -f "$fifo"; mkfifo -m 600 "$fifo"
    sha256sum < "$fifo" | cut -d' ' -f1 > "$tmp.sha" &
    hasher=$!
    # </dev/null on every ssh in this loop: ssh reads stdin, and stdin here is
    # the listing. Without it the first get swallows the rest of the list and
    # the run "succeeds" with one dump (24.11.2026, first run on debian01).
    "${SSH[@]}" get "$name" </dev/null | tee "$fifo" | age -r "$RECIPIENT" -o "$tmp"
    st=("${PIPESTATUS[@]}")
    wait "$hasher"
    got=$(cat "$tmp.sha" 2>/dev/null)
    want=$("${SSH[@]}" sum "$name" </dev/null)
    if [[ "${st[*]}" == "0 0 0" && -n "$got" && "$got" == "$want" ]]; then
        mv "$tmp" "$out"
        log "$name: $size bytes, sha256 ok"
    else
        log "$name: transfer failed or sha256 mismatch, discarded"
        rm -f "$tmp"
        failed=1
    fi
    rm -f "$tmp.sha" "$fifo"
done <<<"$listing"

# Retention by the date in the name, not mtime: a re-pulled old dump must not
# look new.
cutoff=$(date -u -d "-$KEEP_DAYS days" +%Y%m%d)
for f in "$DIR"/*.dump.age; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f" .age)
    [[ "$base" =~ $NAME_RE ]] || continue
    if [[ "${BASH_REMATCH[2]}" < "$cutoff" ]]; then
        rm -f "$f"; log "pruned $base"
    fi
done

exit "$failed"
