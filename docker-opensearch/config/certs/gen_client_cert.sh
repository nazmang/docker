#!/bin/sh

openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr \
    -subj "/CN=client/OU=client/O=client/L=test/C=de"

openssl x509 -req \
    -in client.csr \
    -CA ca.pem \
    -CAkey ca.key \
    -CAcreateserial \
    -out client.crt \
    -days 365

openssl x509 -noout -in client.crt -subject
