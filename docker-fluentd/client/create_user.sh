#!/bin/bash
set -euo pipefail


if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo ".env file not found!"
  exit 1
fi

curl -s -X PUT -k "${OPENSEARCH_URL}/_plugins/_security/api/roles/${FLUENTD_ROLE}" \
  -H 'Content-Type: application/json' \
  --cert "${CLIENT_CERT}" \
  --key "${CLIENT_KEY}" \
  --cacert "${CA_CERT}" \
  -d "{
  \"cluster_permissions\": [
    \"cluster_monitor\"
  ],
  \"index_permissions\": [
    {
      \"index_patterns\": [\"fluentd-*\"),
      \"allowed_actions\": [
        \"write\",
        \"create_index\",
        \"index\"
      ]
    }
  ]
}"

echo "✅ Role '${FLUENTD_ROLE}' created or updated successfully."

curl -s -X PUT -k "${OPENSEARCH_URL}/_plugins/_security/api/internalusers/${FLUENTD_USERNAME}" \
  -H 'Content-Type: application/json' \
  --cert "${CLIENT_CERT}" \
  --key "${CLIENT_KEY}" \
  --cacert "${CA_CERT}" \
  -d "{
  \"password\": \"${FLUENTD_PASSWORD}\",
  \"backend_roles\": [],
  \"attributes\": {},
  \"roles\": [\"${FLUENTD_ROLE}\"]
}"

echo "✅ User '${FLUENTD_USERNAME}' created or updated successfully."
