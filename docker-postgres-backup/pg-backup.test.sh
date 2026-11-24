#!/usr/bin/env bash
#
# Tests for pg-backup-serve.sh, pg-restore-test.sh and debian01/pg-offsite.sh.
# Runs on a workstation with Docker and age; never touches dkr01 or debian01.
#
#   DOCKER="docker --context default" ./pg-backup.test.sh
#
# DOCKER defaults to plain `docker` -- set it explicitly if your default
# context points at a production host.

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SERVE="$HERE/pg-backup-serve.sh"
RESTORE="$HERE/pg-restore-test.sh"
OFFSITE="$HERE/../debian01/pg-offsite.sh"
DOCKER="${DOCKER:-docker}"
export DOCKER
T=$(mktemp -d)
SRCPG="pg-backup-test-src-$$"
trap '$DOCKER rm -f -v "$SRCPG" >/dev/null 2>&1; rm -rf "$T"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Fixture dumps are dated yesterday: a fixed date ages past PG_OFFSITE_KEEP_DAYS
# and gets pruned before the offsite checks run (failed this way on 24.11.2026).
D=$(date -u -d yesterday +%Y%m%d)

# --- pg-backup-serve.sh ---------------------------------------------------
mkdir -p "$T/src"
printf 'dump-a' > "$T/src/n8n-${D}-0230.dump"
printf 'dump-b' > "$T/src/tutor-${D}-0230.dump"
printf 'x' > "$T/src/notes.txt"
printf 'secret' > "$T/secret.dump"
serve() { SSH_ORIGINAL_COMMAND="$1" PG_BACKUP_DEST="$T/src" "$SERVE" 2>/dev/null; }

check "serve list shows dumps only" '[[ "$(serve list | sort)" == "$(printf "n8n-${D}-0230.dump 6\ntutor-${D}-0230.dump 6")" ]]'
check "serve get returns bytes"     '[[ "$(serve "get n8n-${D}-0230.dump")" == dump-a ]]'
check "serve sum is sha256"         '[[ "$(serve "sum n8n-${D}-0230.dump")" == "$(printf dump-a | sha256sum | cut -d" " -f1)" ]]'
check "serve rejects traversal"     '! serve "get ../secret.dump"'
check "serve rejects absolute path" '! serve "get /etc/passwd"'
check "serve rejects option"        '! serve "get -n8n-${D}-0230.dump"'
check "serve rejects non-dump name" '! serve "get notes.txt"'
check "serve rejects extra args"    '! serve "get n8n-${D}-0230.dump extra"'
check "serve rejects unknown verb"  '! serve "rm n8n-${D}-0230.dump"'
check "serve rejects empty command" '! serve ""'
check "serve rejects missing dump"  '! serve "get n8n-20991231-0000.dump"'

# --- pg-restore-test.sh ---------------------------------------------------
IMAGE=pgvector/pgvector:pg16
$DOCKER run -d --name "$SRCPG" --network none -e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
    $DOCKER logs "$SRCPG" 2>&1 | grep -q 'init process complete' && $DOCKER exec "$SRCPG" pg_isready -U postgres -q && break
    sleep 1
done
psqlsrc() { $DOCKER exec -i "$SRCPG" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
psqlsrc -c "CREATE DATABASE gooddb" -c "CREATE DATABASE emptydb"
psqlsrc -d gooddb -c "CREATE EXTENSION vector" -c "CREATE TABLE t (id int, v vector(3))" -c "INSERT INTO t VALUES (1,'[1,2,3]')"
mkdir -p "$T/dumps" "$T/textfile"
$DOCKER exec "$SRCPG" pg_dump -U postgres -d gooddb -Fc > "$T/dumps/gooddb-${D}-0230.dump"
$DOCKER exec "$SRCPG" pg_dump -U postgres -d emptydb -Fc > "$T/dumps/emptydb-${D}-0230.dump"
printf 'garbage' > "$T/dumps/brokendb-${D}-0230.dump"

rt() { PG_BACKUP_DEST="$T/dumps" PG_BACKUP_TEXTFILE_DIR="$T/textfile" "$RESTORE" "$@" > "$T/rt.log" 2>&1; }
check "restore test passes a good dump (with pgvector)" 'rt gooddb'
check "metric written for gooddb" 'grep -q "pg_backup_restore_test_tables{database=\"gooddb\"} 1" "$T/textfile/pg_restore_test.prom"'
good_ts=$(grep 'last_success_timestamp_seconds{database="gooddb"}' "$T/textfile/pg_restore_test.prom" | cut -d" " -f2)
check "restore test fails an empty database" '! rt emptydb'
check "restore test fails a broken dump" '! rt brokendb'
check "failed run keeps gooddb timestamp" 'grep -q "last_success_timestamp_seconds{database=\"gooddb\"} $good_ts" "$T/textfile/pg_restore_test.prom"'
check "failed databases get no timestamp" '! grep -q "database=\"emptydb\"" "$T/textfile/pg_restore_test.prom"'
check "no throwaway container left" '[[ -z "$($DOCKER ps -aq --filter name=pg-restore-test-)" ]]'

# --- debian01/pg-offsite.sh -------------------------------------------------
age-keygen -o "$T/age.key" 2>/dev/null
R=$(age-keygen -y "$T/age.key")
mkdir -p "$T/off" "$T/offtf"
cat > "$T/fake-ssh" <<FAKE
#!/usr/bin/env bash
SSH_ORIGINAL_COMMAND="\$*" PG_BACKUP_DEST="$T/src" exec "$SERVE"
FAKE
chmod +x "$T/fake-ssh"
off() { PG_OFFSITE_SSH_CMD="$T/fake-ssh" PG_OFFSITE_HOST=x PG_OFFSITE_DIR="$T/off" PG_OFFSITE_AGE_RECIPIENT="$R" \
        TEXTFILE="$T/offtf/pg_offsite.prom" "$OFFSITE" "$@" 2>"$T/off.log"; }

check "offsite pulls every dump" 'off && [[ -f "$T/off/n8n-${D}-0230.dump.age" && -f "$T/off/tutor-${D}-0230.dump.age" ]]'
check "offsite stores ciphertext, not plaintext" '! grep -q dump-a "$T/off/n8n-${D}-0230.dump.age"'
check "offsite copy decrypts to the original" '[[ "$(age -d -i "$T/age.key" "$T/off/n8n-${D}-0230.dump.age")" == dump-a ]]'
check "offsite skips non-dump files" '[[ ! -e "$T/off/notes.txt.age" ]]'
before=$(stat -c %Y "$T/off/n8n-${D}-0230.dump.age")
sleep 1
check "second run fetches nothing new" 'off && [[ "$(stat -c %Y "$T/off/n8n-${D}-0230.dump.age")" == "$before" ]]'
off --write-metric
want_ts=$(date -u -d "${D:0:4}-${D:4:2}-${D:6:2} 02:30" +%s)
check "metric is the dump time, per database" 'grep -q "pg_backup_offsite_newest_dump_timestamp_seconds{database=\"n8n\"} $want_ts" "$T/offtf/pg_offsite.prom"'

# corrupted transfer: serve a different body for get than for sum
cat > "$T/bad-ssh" <<FAKE
#!/usr/bin/env bash
if [[ "\$1" == get ]]; then printf 'truncated'; exit 0; fi
SSH_ORIGINAL_COMMAND="\$*" PG_BACKUP_DEST="$T/src" exec "$SERVE"
FAKE
chmod +x "$T/bad-ssh"
printf 'dump-c' > "$T/src/inboxd-${D}-0230.dump"
check "sha mismatch is discarded and fails" '! PG_OFFSITE_SSH_CMD="$T/bad-ssh" PG_OFFSITE_HOST=x PG_OFFSITE_DIR="$T/off" PG_OFFSITE_AGE_RECIPIENT="$R" "$OFFSITE" 2>/dev/null'
check "no partial file left behind" '[[ -z "$(ls "$T/off" | grep -v "\.dump\.age$")" && ! -e "$T/off/inboxd-${D}-0230.dump.age" ]]'

# retention by name date
printf 'old' > "$T/off/n8n-20200101-0230.dump.age"
off
check "retention prunes by the date in the name" '[[ ! -e "$T/off/n8n-20200101-0230.dump.age" && -e "$T/off/n8n-${D}-0230.dump.age" ]]'
check "missing config exits 5" 'PG_OFFSITE_HOST= "$OFFSITE" 2>/dev/null; [[ $? -eq 5 ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
