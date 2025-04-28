#!/bin/bash
curl -X PUT -ku admin:admin "https://opensearch.comintern.local:9200/_plugins/_security/api/roles/fluentd_writer" -H 'Content-Type: application/json' -d '{
  "cluster_permissions": [
    "cluster_monitor"
  ],
  "index_permissions": [
    {
      "index_patterns": ["fluentd-*"],
      "allowed_actions": [
        "write",
        "create_index",
        "index"
      ]
    }
  ]
}'

curl -X PUT -ku admin:admin "https://opensearch.comintern.local:9200/_plugins/_security/api/internalusers/fluentd" -H 'Content-Type: application/json' -d '{
  "password": "PQVqUX71cC941OHDRPpGFrqIpQ",
  "backend_roles": [],
  "attributes": {},
  "roles": ["fluentd_writer"]
}'
