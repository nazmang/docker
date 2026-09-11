#!/usr/bin/env bash
#
# Health check for debian01 (OpenMediaVault 7 + Home Assistant Supervised),
# reporting outbound only.
#
# Why outbound: this host lives on 192.168.88.0/24 behind NAT, and the
# monitoring stack is in another datacentre. Nothing can scrape it. Opening a
# port to reach it would mean exposing a home NAS to the internet, which is a
# worse trade than losing some resolution. So the host reports on itself:
#
#   * a heartbeat to an Uptime Kuma push monitor while everything is healthy.
#     Kuma alerts when the pings STOP -- which covers the cases a check cannot
#     report itself: host down, network gone, this script broken.
#   * a message to ntfy when something is wrong, with the detail.
#
# The two are complementary on purpose. A checker that only sends alerts is
# silent both when all is well and when it is dead, and those look identical.
#
# Config: /etc/default/host-health   (KUMA_PUSH_URL, NTFY_URL, NTFY_TOKEN)

set -uo pipefail

CONF=/etc/default/host-health
[[ -r "$CONF" ]] && . "$CONF"

KUMA_PUSH_URL="${KUMA_PUSH_URL:-}"
NTFY_URL="${NTFY_URL:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
POOL="${ZFS_POOL:-big_pool}"
DISK_WARN_PCT="${DISK_WARN_PCT:-90}"
TEXTFILE="${TEXTFILE:-/var/lib/node_exporter/textfile/host_health.prom}"

problems=()
metrics=()

add_metric() { metrics+=("$1"); }

# --- ZFS -------------------------------------------------------------------
# The pool this host exists for. Not imported is the failure that started all
# of this: after a power cut the USB enclosure comes back, but the boot-time
# import has already run and failed, so the pool stays missing until someone
# notices. Now it is noticed in five minutes rather than in five days.
if zpool list -H -o name 2>/dev/null | grep -qx "$POOL"; then
    add_metric "zfs_pool_imported{pool=\"$POOL\"} 1"
    health=$(zpool list -H -o health "$POOL" 2>/dev/null)
    case "$health" in
        ONLINE)   add_metric "zfs_pool_healthy{pool=\"$POOL\"} 1" ;;
        *)        add_metric "zfs_pool_healthy{pool=\"$POOL\"} 0"
                  problems+=("пул $POOL в состоянии $health") ;;
    esac

    # Checksum and I/O errors accumulate silently on a single-disk pool: ZFS
    # detects corruption it cannot repair, and says so only if asked.
    errors=$(zpool status "$POOL" 2>/dev/null | awk '/^\s+'"$POOL"'\s/ {print $3+$4+$5}')
    errors=${errors:-0}
    add_metric "zfs_pool_errors{pool=\"$POOL\"} $errors"
    [[ "$errors" -gt 0 ]] && problems+=("пул $POOL: $errors ошибок чтения/записи/контрольных сумм")

    cap=$(zpool list -H -o capacity "$POOL" 2>/dev/null | tr -d '%')
    add_metric "zfs_pool_capacity_percent{pool=\"$POOL\"} ${cap:-0}"
    [[ "${cap:-0}" -ge "$DISK_WARN_PCT" ]] && problems+=("пул $POOL заполнен на ${cap}%")
else
    add_metric "zfs_pool_imported{pool=\"$POOL\"} 0"
    add_metric "zfs_pool_healthy{pool=\"$POOL\"} 0"
    problems+=("пул $POOL НЕ импортирован")
fi

# --- Диски и S.M.A.R.T. ----------------------------------------------------
for dev in /dev/sda /dev/sdb; do
    [[ -b "$dev" ]] || continue
    name=$(basename "$dev")
    if smart=$(smartctl -H "$dev" 2>/dev/null); then
        if grep -qiE "PASSED|OK" <<<"$smart"; then
            add_metric "smart_healthy{device=\"$name\"} 1"
        else
            add_metric "smart_healthy{device=\"$name\"} 0"
            problems+=("S.M.A.R.T. на $name сообщает о проблеме")
        fi
    fi
done

# --- Корневая файловая система ---------------------------------------------
root_pct=$(df --output=pcent / | tail -1 | tr -dc '0-9')
add_metric "root_filesystem_used_percent ${root_pct:-0}"
[[ "${root_pct:-0}" -ge "$DISK_WARN_PCT" ]] && problems+=("корневая ФС заполнена на ${root_pct}%")

# --- Home Assistant --------------------------------------------------------
# This host is also the home's automation hub; containers stopping is as much
# an outage as the NAS going away, and nothing else would report it.
if command -v docker >/dev/null 2>&1; then
    running=$(docker ps -q 2>/dev/null | wc -l)
    add_metric "docker_containers_running $running"
    if ! curl -sf -m 5 -o /dev/null http://127.0.0.1:8123/ 2>/dev/null; then
        add_metric "home_assistant_up 0"
        problems+=("Home Assistant не отвечает на 8123")
    else
        add_metric "home_assistant_up 1"
    fi
fi

add_metric "host_health_last_run_timestamp_seconds $(date +%s)"
add_metric "host_health_problems ${#problems[@]}"

# --- Публикация ------------------------------------------------------------
# For node_exporter, if it is installed. Harmless when it is not.
if [[ -d "$(dirname "$TEXTFILE")" ]]; then
    printf '%s\n' "${metrics[@]}" > "$TEXTFILE.tmp" && mv "$TEXTFILE.tmp" "$TEXTFILE"
fi

if [[ ${#problems[@]} -eq 0 ]]; then
    # Heartbeat only while healthy: a ping sent regardless of state would turn
    # Kuma into a liveness check for the script rather than for the host.
    [[ -n "$KUMA_PUSH_URL" ]] && curl -sf -m 10 -o /dev/null "${KUMA_PUSH_URL}?status=up&msg=OK" || true
    exit 0
fi

msg=$(printf '%s\n' "${problems[@]}")
[[ -n "$KUMA_PUSH_URL" ]] && curl -sf -m 10 -o /dev/null \
    --data-urlencode "msg=${msg//$'\n'/; }" "${KUMA_PUSH_URL}?status=down" || true

if [[ -n "$NTFY_URL" ]]; then
    curl -sf -m 10 -o /dev/null \
        ${NTFY_TOKEN:+-H "Authorization: Bearer $NTFY_TOKEN"} \
        -H "Title: debian01: ${#problems[@]} problem(s)" \
        -H "Priority: high" \
        -H "Tags: warning,floppy_disk" \
        -d "$msg" "$NTFY_URL" || true
fi

exit 1
