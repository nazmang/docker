# PostgreSQL backups for dkr01

`tutor-postgres` (pgvector/pg16) on dkr01 holds the databases of tutor, n8n,
inboxd, costs and, from the day it is created, approvald. Three layers protect
them, each catching what the one before cannot.

| Layer | Where | When | Catches | Kept |
|---|---|---|---|---|
| `pg-backup.sh` — dump every database, check it with `pg_restore --list` | dkr01 → NFS on nas01 (`/data/backups/postgres`) | daily 02:30 UTC | a dropped table, a bad deploy, yesterday's state | 14 per database |
| `pg-restore-test.sh` — restore the newest dump of each database into a throwaway server | dkr01 | Sundays 03:30 UTC | a dump that is a valid archive but does not go back into a server | — |
| `debian01/pg-offsite.sh` — pull every dump to debian01, encrypted with age | debian01 (home, another site), `/big_pool/pg-offsite` | daily 07:15 Sofia | losing nas01 or the whole Hetzner site | 30 days |

The database list is never written down: `pg-backup.sh` asks the server, the
restore test takes it from the dump files, the off-site copy takes whatever is
listed. A new database is covered from its first night.

Alerts are in `docker-monitoring/prometheus/rules/backup.rules.yml`: staleness
and absence for each layer, plus a dump that suddenly halves.

## Restoring

From nas01 (the normal case):

    docker exec -i tutor-postgres pg_restore -U tutor -d <db> --clean --if-exists < /data/backups/postgres/<db>-YYYYMMDD-HHMM.dump

Stop the application that uses the database first (n8n: scale the Deployment to
0), or it will write into a half-restored schema.

From debian01, when nas01 is gone: the copies are age-encrypted to the same
recipient as the SOPS files in argocd-apps and this repository, so decrypting
needs that private key (`argocd-apps/.age/age.key`, and its offline copy).
**Without it the off-site copy is unreadable by design** — check that the key
has a copy that is not on the laptop.

    scp debian01:/big_pool/pg-offsite/<db>-YYYYMMDD-HHMM.dump.age .
    age -d -i .age/age.key <db>-YYYYMMDD-HHMM.dump.age > <db>.dump
    # then pg_restore as above

`pg_backup_restore_test_duration_seconds` is how long the last test restore
took per database — use it as the expected downtime of a restore.

## Install (dkr01)

`pg-backup.sh` has been installed since 2026-09-11 (`/usr/local/bin`, cron
02:30). The new parts, as root:

    install -m 755 pg-restore-test.sh pg-backup-serve.sh /usr/local/bin/
    install -m 644 pg-restore-test.cron /etc/cron.d/pg-restore-test
    /usr/local/bin/pg-restore-test.sh        # first run by hand, read the log

    # read-only account for the off-site pull
    useradd --system --create-home --shell /bin/bash pgoffsite
    install -d -m 700 -o pgoffsite -g pgoffsite ~pgoffsite/.ssh
    # one line, the public key generated on debian01 (see debian01/README.md):
    echo 'command="/usr/local/bin/pg-backup-serve.sh",restrict ssh-ed25519 AAAA... pg-offsite@debian01' \
        > ~pgoffsite/.ssh/authorized_keys
    chown pgoffsite: ~pgoffsite/.ssh/authorized_keys; chmod 600 ~pgoffsite/.ssh/authorized_keys

`pgoffsite` needs read access to the dumps. `pg-backup.sh` runs as root with the
default umask, so the files are 0644 and readable already; if that ever
changes, the off-site copy fails loudly (`PostgresOffsiteBackupStale`).

## Tests

    DOCKER="docker --context default" ./pg-backup.test.sh

Needs Docker and `age`. Starts its own throwaway Postgres; touches neither
dkr01 nor debian01.
