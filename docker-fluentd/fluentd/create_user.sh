#!/bin/bash
# One-off bootstrap of the OpenSearch role and user fluentd writes with. Run by
# hand, not part of the image. Credentials come from the environment -- never
# put them in this file: until 2026-09-29 the fluentd password sat here as a
# literal in a public repository (found by gitleaks), and admin:admin was
# hardcoded although the admin password had long been changed.
#
#   OS_URL=https://<host>:9200 OS_ADMIN_PASSWORD=... OS_FLUENTD_PASSWORD=... ./create_user.sh
#
# To rotate only the fluentd password afterwards, PATCH the user instead of
# re-running this (keeps the role mapping):
#   PATCH $OS_URL/_plugins/_security/api/internalusers/fluentd
#   [{"op":"replace","path":"/password","value":"<new>"}]
set -euo pipefail
: "${OS_URL:?set OS_URL, e.g. https://opensearch.example:9200}"
: "${OS_ADMIN_PASSWORD:?set OS_ADMIN_PASSWORD}"
: "${OS_FLUENTD_PASSWORD:?set OS_FLUENTD_PASSWORD}"
OS_ADMIN_USER="${OS_ADMIN_USER:-admin}"

# Credentials and body reach curl through file descriptors, not argv, so
# neither the admin password nor the fluentd password shows up in ps.
os_put() {
  curl -sSk -X PUT "$OS_URL$1" -H 'Content-Type: application/json' \
    -K <(printf 'user = "%s:%s"\n' "$OS_ADMIN_USER" "$OS_ADMIN_PASSWORD") \
    --data-binary @<(printf '%s' "$2")
  echo
}

os_put "/_plugins/_security/api/roles/fluentd_writer" '{
  "cluster_permissions": ["cluster_monitor"],
  "index_permissions": [
    {
      "index_patterns": ["fluentd-*"],
      "allowed_actions": ["write", "create_index", "index"]
    }
  ]
}'

os_put "/_plugins/_security/api/internalusers/fluentd" "$(printf '{
  "password": "%s",
  "backend_roles": [],
  "attributes": {},
  "opendistro_security_roles": ["fluentd_writer"]
}' "$OS_FLUENTD_PASSWORD")"
