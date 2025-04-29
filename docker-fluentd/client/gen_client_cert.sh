#!/bin/sh

openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr \
    -subj "/CN=admin/OU=SSL/O=Test/L=Test/C=DE"

openssl x509 -req \
    -in client.csr \
    -CA ca.pem \
    -CAkey ca.key \
    -CAcreateserial \
    -out client.crt \
    -days 365
