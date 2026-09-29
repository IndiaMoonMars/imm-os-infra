#!/bin/sh
# Create a private CA and a TLS server certificate for the IMM-OS MQTT broker.
#
#   ./mosquitto/gen-certs.sh [extra-name ...]
#
# The certificate is valid for imm.local, mosquitto and localhost plus any
# extra DNS names or IP addresses you pass, e.g. the MCC server's LAN IP:
#   ./mosquitto/gen-certs.sh 192.168.1.100 mcc.habitat.lan
# Edge nodes must connect using one of these names (MQTT_HOST).
#
# Output (mosquitto/certs/, git-ignored):
#   ca.crt      copy to every edge node (MQTT_TLS_CA); not secret
#   ca.key      keep private: needed only to issue new server certs
#   server.crt  / server.key   used by the broker
# Re-run with --force to replace an existing CA and certificate.
set -eu
cd "$(dirname "$0")"
OUT=certs
FORCE=0
if [ "${1:-}" = "--force" ]; then FORCE=1; shift; fi

if [ -f "$OUT/server.crt" ] && [ "$FORCE" -ne 1 ]; then
    echo "$OUT/server.crt already exists; use --force to replace it" >&2
    exit 1
fi
mkdir -p "$OUT"
chmod 700 "$OUT"

san="DNS:imm.local,DNS:mosquitto,DNS:localhost,IP:127.0.0.1"
for name in "$@"; do
    case "$name" in
        *[!0-9.]*) san="$san,DNS:$name" ;;   # contains a non-digit/dot → hostname
        *)         san="$san,IP:$name" ;;
    esac
done

umask 077
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "$OUT/ca.key" -out "$OUT/ca.crt" \
    -subj "/O=India Moon Mars/CN=IMM-OS MQTT CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout "$OUT/server.key" -out "$OUT/server.csr" \
    -subj "/O=India Moon Mars/CN=imm.local" 2>/dev/null

printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$san" > "$OUT/server.ext"
openssl x509 -req -in "$OUT/server.csr" -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" \
    -CAcreateserial -out "$OUT/server.crt" -days 825 -sha256 -extfile "$OUT/server.ext" 2>/dev/null
rm -f "$OUT/server.csr" "$OUT/server.ext" "$OUT/ca.srl"
chmod 644 "$OUT/ca.crt" "$OUT/server.crt"

echo "Created $OUT/ca.crt, $OUT/server.crt, $OUT/server.key (names: $san)"
echo "Copy $OUT/ca.crt to each edge node as /etc/imm-os/mqtt-ca.crt"
