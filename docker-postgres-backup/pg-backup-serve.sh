#!/usr/bin/env bash
#
# SSH forced command on dkr01 for the off-site copy (debian01 pulls).
#
# debian01 logs in as a dedicated user whose authorized_keys line is
#   command="/usr/local/bin/pg-backup-serve.sh",restrict ssh-ed25519 AAAA... pg-offsite@debian01
# so whatever the client asks for, this script runs instead, and it answers to
# exactly three requests:
#
#   list         one line per dump: "<name> <bytes>"
#   get NAME     the dump's bytes on stdout
#   sum NAME     its sha256
#
# NAME must look like a pg-backup.sh file name (db-YYYYMMDD-HHMM.dump), which
# rules out paths, "..", globbing and options. Read only: nothing here can
# delete or change a dump, so a stolen debian01 key reads backups and nothing
# else -- and the pull direction means dkr01 holds no key to debian01 at all.

set -uo pipefail

SRC="${PG_BACKUP_DEST:-/data/backups/postgres}"
NAME_RE='^[a-z0-9_]+-[0-9]{8}-[0-9]{4}\.dump$'

deny() { printf 'pg-backup-serve: %s\n' "$*" >&2; exit 1; }

read -r verb arg extra <<<"${SSH_ORIGINAL_COMMAND:-}"
[[ -z "${extra:-}" ]] || deny "too many arguments"

case "$verb" in
    list)
        [[ -z "${arg:-}" ]] || deny "list takes no argument"
        cd "$SRC" || deny "no $SRC"
        for f in *.dump; do
            [[ -f "$f" && "$f" =~ $NAME_RE ]] && printf '%s %s\n' "$f" "$(stat -c %s "$f")"
        done
        ;;
    get|sum)
        [[ "${arg:-}" =~ $NAME_RE ]] || deny "bad name"
        [[ -f "$SRC/$arg" ]] || deny "no such dump"
        if [[ "$verb" == get ]]; then exec cat -- "$SRC/$arg"; fi
        sha256sum -- "$SRC/$arg" | cut -d' ' -f1
        ;;
    *)
        deny "unknown request"
        ;;
esac
