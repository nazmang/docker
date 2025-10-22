#!/bin/sh
openssl req -new -x509 -sha256 -key ca.key -out ca.pem -days 3650 -subj "/C=US/ST=State/L=City/O=MyOrg/OU=IT/CN=opensearch-root-ca"
openssl genrsa -out node.key 4096
openssl req -new -key node.key -out node.csr -subj "/C=US/ST=State/L=City/O=MyOrg/OU=IT/CN=opensearch-node"
openssl x509 -req -in node.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out node.pem -days 3650 -sha256
