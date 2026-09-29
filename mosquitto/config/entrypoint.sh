#!/bin/sh
# Build Mosquitto's hashed password file from env vars, then start the broker.
# Runs on every container start, so changing a password = edit .env + restart.
set -eu

DATA_DIR="${MOSQUITTO_DATA_DIR:-/mosquitto/data}"
CONF="${MOSQUITTO_CONF:-/mosquitto/config/mosquitto.conf}"
CERT_SRC="${MOSQUITTO_CERT_DIR:-/mosquitto/certs}"
PASSWD="$DATA_DIR/passwd"
HEALTH_PW_FILE="$DATA_DIR/.health_pw"

need() {
    eval "val=\${$1:-}"
    if [ -z "$val" ]; then
        echo "mosquitto entrypoint: $1 is not set" >&2
        exit 1
    fi
}
for var in MQTT_EDGE_PASSWORD MQTT_ECLSS_PASSWORD MQTT_INGEST_PASSWORD MQTT_SIM_PASSWORD; do
    need "$var"
done

for f in ca.crt server.crt server.key; do
    if [ ! -f "$CERT_SRC/$f" ]; then
        echo "mosquitto entrypoint: $CERT_SRC/$f missing; run imm-os-infra/mosquitto/gen-certs.sh" >&2
        exit 1
    fi
done

umask 077
# TLS material: private copy the broker (running as mosquitto) can read
mkdir -p "$DATA_DIR/certs"
cp "$CERT_SRC/ca.crt" "$CERT_SRC/server.crt" "$CERT_SRC/server.key" "$DATA_DIR/certs/"

tmp="$PASSWD.tmp"
rm -f "$tmp"
touch "$tmp"
mosquitto_passwd -b "$tmp" imm-edge   "$MQTT_EDGE_PASSWORD"
mosquitto_passwd -b "$tmp" imm-eclss  "$MQTT_ECLSS_PASSWORD"
mosquitto_passwd -b "$tmp" imm-ingest "$MQTT_INGEST_PASSWORD"
mosquitto_passwd -b "$tmp" imm-sim    "$MQTT_SIM_PASSWORD"

# Random per-start password for the in-container healthcheck
health_pw="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mosquitto_passwd -b "$tmp" imm-health "$health_pw"
printf '%s' "$health_pw" > "$HEALTH_PW_FILE"

mv "$tmp" "$PASSWD"
# The broker drops to the mosquitto user when started as root
if id mosquitto >/dev/null 2>&1; then
    chown mosquitto "$PASSWD"
    chown -R mosquitto "$DATA_DIR/certs"
fi

exec mosquitto -c "$CONF"
