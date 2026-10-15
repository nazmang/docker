#!/bin/sh
# Thin-pool fill for node_exporter's textfile collector on pve01.
#
# Proxmox (and so Zabbix "Proxmox VE by HTTP") reports only the data part of
# an LVM-thin pool. When the metadata part fills up first the pool goes
# read-only for every disk in it — Proxmox CSI volumes and the VM root disks
# alike. This writes both percentages for rules/lvm.rules.yml.
#
# Install as root on pve01:
#   install -m 755 lvm-thin-textfile.sh /usr/local/sbin/
#   echo '*/5 * * * * root /usr/local/sbin/lvm-thin-textfile.sh' > /etc/cron.d/lvm-thin-textfile
# Output: /var/lib/prometheus/node-exporter/lvm_thin.prom (Debian default dir).
set -eu
dir=/var/lib/prometheus/node-exporter
tmp=$(mktemp "$dir/.lvm_thin.XXXXXX")
{
  echo "# HELP pve_lvm_thin_data_percent Data space used in an LVM thin pool."
  echo "# TYPE pve_lvm_thin_data_percent gauge"
  echo "# HELP pve_lvm_thin_metadata_percent Metadata space used in an LVM thin pool."
  echo "# TYPE pve_lvm_thin_metadata_percent gauge"
  lvs --noheadings --nosuffix --separator ' ' -S 'segtype=thin-pool' \
      -o vg_name,lv_name,data_percent,metadata_percent |
    while read -r vg lv data meta; do
      echo "pve_lvm_thin_data_percent{vg=\"$vg\",pool=\"$lv\"} $data"
      echo "pve_lvm_thin_metadata_percent{vg=\"$vg\",pool=\"$lv\"} $meta"
    done
} > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$dir/lvm_thin.prom"   # atomic: node_exporter never reads half a file
