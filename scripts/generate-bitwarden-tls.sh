#!/usr/bin/env bash
set -euo pipefail

# Generates a self-signed cert for the Bitwarden SDK server and applies it as
# a TLS Secret + a CA ConfigMap that the ClusterSecretStore references.
# Re-run to rotate. Files are written to a tmpdir and removed at exit.

NAMESPACE=external-secrets
SVC=bitwarden-sdk-server
CN="${SVC}.${NAMESPACE}.svc"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/tls.key" -out "$tmp/tls.crt" \
  -subj "/CN=${CN}" \
  -addext "subjectAltName=DNS:${CN},DNS:${CN}.cluster.local,DNS:${SVC}"

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

kubectl -n "$NAMESPACE" create secret tls bitwarden-sdk-server-tls \
  --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create configmap bitwarden-sdk-server-ca \
  --from-file=ca.crt="$tmp/tls.crt" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "TLS secret and CA configmap applied in namespace ${NAMESPACE}."
