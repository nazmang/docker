# debian01

OpenMediaVault 7 on 192.168.88.152: the home NAS with a single-disk ZFS pool
(`big_pool`, 3.6 TB in a USB enclosure) and Home Assistant Supervised with
Zigbee2MQTT, Matter and Mosquitto alongside it.

Two problems were solved here on 2026-09-11.

## The pool stopped needing a reboot

After a power cut the enclosure comes back, but `zfs-import-cache.service` has
already run at boot and failed — it is a one-shot, and nothing retries it. The
pool then stays missing until someone reboots the host, which is why a reboot
looked like the cure. It was not: the import simply ran again.

The fix is an import triggered by the disk appearing rather than by boot:

- `/etc/systemd/system/zfs-import-big_pool.service` — imports by `/dev/disk/by-id`
  (device names change between reconnections; by-id does not), clears a
  suspended pool, mounts datasets.
- `/etc/udev/rules.d/99-zfs-import-big_pool.rules` — starts that unit when a
  partition labelled `big_pool` appears. Keyed on the **ZFS label**, not the
  enclosure's serial, so replacing the case or the cable changes nothing.

Power-cycling the enclosure now imports the pool on its own.

## Monitoring, outbound only

This host is behind NAT on a home network; the Prometheus that watches
everything else is in another datacentre and cannot reach it. Opening a port
would mean exposing a home NAS to the internet — a worse trade than losing
resolution. So the host reports on itself, over connections it opens:

- a heartbeat to an **Uptime Kuma push monitor** while healthy. Kuma alerts when
  the pings stop, which covers what a self-check can never report: the host
  being down, the network gone, or this script broken.
- a message to **ntfy** when something is wrong, carrying the detail.

Both matter. A checker that only sends alerts is silent when all is well and
silent when it is dead, and those two silences look identical.

### What it checks

- `big_pool` imported, ONLINE, error counters, capacity. The pool is a **single
  disk with no redundancy**: ZFS detects corruption it cannot repair, and says
  so only when asked.
- S.M.A.R.T. health of both disks.
- Root filesystem usage.
- Home Assistant answering on 8123, and the container count — this host is the
  home's automation hub, and containers stopping is as much an outage as the
  NAS disappearing.
- The state of the weekly borg backup, read from `/var/log/omv-backup.log`.

### Backups are reported, not alerted on

The borg section publishes four metrics and deliberately adds nothing to the
problem list that drives Kuma and ntfy:

| metric | meaning |
|---|---|
| `borg_metrics_up` | the log was readable and parsed |
| `borg_backup_last_result` | 1 if the most recent *finished* run succeeded |
| `borg_backup_last_success_timestamp_seconds` | end of the last successful run |
| `borg_backup_last_run_timestamp_seconds` | start of the most recent run |

A stale backup stays stale for days, and this script runs every five minutes —
putting it in the problem list would mean an ntfy message every five minutes
for a week. Prometheus decides when that becomes an alert, and Alertmanager
groups and rate-limits it. See `docker-monitoring/prometheus/rules/debian01.rules.yml`,
group `debian01_backups`.

Two details the parser has to get right, both learned from the real log:

- **Match `ERROR:` and nothing looser.** Every run, successful ones included,
  logs `Save of MBR failed!` — `omv-backup` cannot derive the root device from
  LVM. A `/failed/` match would mark every backup as a failure.
- **Compare the position of the last success against the last failure**, rather
  than reading only the newest run. A run takes about six minutes and the timer
  fires every five, so a backup in progress would otherwise look like a failure
  until it finished.

Why this exists: on 2026-09-11 the last successful backup turned out to be
2026-08-09. The 09-06 run had failed — it was writing into the mountpoint
directory on the root filesystem, because the ZFS pool had not been imported —
and cron's report went to root's mail, which nobody reads. A month with no
backups, and nothing anywhere said so.

### Installation

```bash
sudo install -m 755 host-health.sh /usr/local/bin/host-health.sh
sudo install -m 644 host-health.service host-health.timer /etc/systemd/system/

sudo tee /etc/default/host-health > /dev/null <<'CONF'
KUMA_PUSH_URL=https://uptime-kuma.srvx.cc/api/push/XXXXXXXX
NTFY_URL=https://ntfy.srvx.cc/<topic>
NTFY_TOKEN=<token>
CONF
sudo chmod 600 /etc/default/host-health

sudo systemctl daemon-reload
sudo systemctl enable --now host-health.timer
sudo systemctl start host-health.service    # run once immediately
journalctl -u host-health -n 20 --no-pager
```

The Kuma push URL comes from a **Push**-type monitor created in Uptime Kuma;
set its heartbeat interval to 10 minutes so a single missed run does not alert.
The credentials file is 600 because it holds the ntfy token.

### If node_exporter is installed later

The script also writes its metrics to
`/var/lib/node_exporter/textfile/host_health.prom`, so the same checks become
scrapeable the moment `prometheus-node-exporter` is installed with
`--collector.textfile.directory`. Nothing needs to change in the script.

## Prometheus agent

The host pushes its metrics rather than being scraped — see `agent.yml` for why.
Three things cost time when setting this up, all of them ownership and none of
them obvious from the error at first glance:

**The agent runs as 65534 (nobody).** Both the WAL volume and the password file
must be readable by that uid, and neither is by default:

```bash
docker run --rm -v prom-agent_agent-data:/data alpine chown -R 65534:65534 /data
docker run --rm -v "$PWD":/w alpine sh -c 'chown 65534 /w/rw_password && chmod 400 /w/rw_password'
```

Without the first, the container dies with `lock DB directory: permission
denied`. Without the second, it starts, scrapes happily, and fails every send
with `unable to read basic auth password` — a failure that looks like an auth
problem and is not.

**Port 9099, not the conventional 9091.** Something already listens on 9091 on
this host, on all interfaces. The agent's listener is loopback-only and exists
only so the process has somewhere to report its own state.

**The password file must have no trailing newline.** `printf`, not `echo`.

### Checking it works

```bash
docker logs prom-agent | tail                      # "Done replaying WAL" and no send errors
curl -s localhost:9099/api/v1/targets | head -c 300  # the local scrape target
```

From the Prometheus side, `count({host="debian01"})` should return a couple of
thousand series, and `Debian01MetricsMissing` should be gone.
