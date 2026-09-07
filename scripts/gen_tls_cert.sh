#!/usr/bin/env bash
#
# Generate a self-signed TLS certificate for the collaboration host.
#
# Everything in this stack used to travel as plain HTTP, which meant WebDAV
# Basic-auth credentials and document contents crossed the corporate network in
# cleartext. The proxy in docker-compose.nextcloud.yml now terminates TLS, and
# it needs a certificate.
#
# A self-signed certificate is fine for a lab, but NOT for production: every
# client has to be told to trust it, and nothing then distinguishes it from an
# attacker's. For a real deployment, replace deploy/tls/{fullchain,privkey}.pem
# with a certificate issued by your corporate CA for the same address, and
# distribute that CA to clients through your normal channels.
#
# The SANs matter: clients connect by IP, and a certificate with only a CN and
# no IP SAN is rejected outright by modern TLS stacks.
#
# Usage: scripts/gen_tls_cert.sh [--host 10.0.7.10] [--dns office.lightoffice.internal] [--force]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLS_DIR="$ROOT/deploy/tls"
HOST="10.0.7.10"
DNS="office.lightoffice.internal"
DAYS=825          # the maximum most clients accept for a server certificate
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --dns) DNS="$2"; shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

mkdir -p "$TLS_DIR"
if [ -s "$TLS_DIR/fullchain.pem" ] && [ "$FORCE" -eq 0 ]; then
  echo "certificate already present at $TLS_DIR/fullchain.pem (use --force to replace)"
  openssl x509 -in "$TLS_DIR/fullchain.pem" -noout -subject -dates -ext subjectAltName
  exit 0
fi

cat > "$TLS_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $HOST
O = LightOffice
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @san
[san]
IP.1 = $HOST
DNS.1 = $DNS
DNS.2 = localhost
IP.2 = 127.0.0.1
EOF

umask 077
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TLS_DIR/privkey.pem" \
  -out "$TLS_DIR/fullchain.pem" \
  -days "$DAYS" -sha256 -config "$TLS_DIR/openssl.cnf" 2>/dev/null
chmod 600 "$TLS_DIR/privkey.pem"
chmod 644 "$TLS_DIR/fullchain.pem"

echo "wrote $TLS_DIR/fullchain.pem and privkey.pem"
openssl x509 -in "$TLS_DIR/fullchain.pem" -noout -subject -dates -ext subjectAltName
echo
echo "Self-signed: clients must be told to trust it. Replace with a corporate-CA"
echo "certificate for the same address before a production rollout."
