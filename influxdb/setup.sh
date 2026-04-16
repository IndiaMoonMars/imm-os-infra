#!/usr/bin/env bash
# IMM-OS InfluxDB Setup Script
# Creates required buckets for the telemetry processor

if [ -z "$INFLUX_TOKEN" ]; then
  echo "Error: INFLUX_TOKEN is not set."
  exit 1
fi

INFLUX_URL="http://localhost:8086"
INFLUX_ORG="imm_org"

echo "Waiting for InfluxDB to start..."
until influx ping -c "$INFLUX_URL"; do
  sleep 2
done

echo "InfluxDB is up. Setting up buckets..."

# Create habitat_sensors bucket (90 days retention = 2160 hours)
influx bucket create \
  -n habitat_sensors \
  -o "$INFLUX_ORG" \
  -r 2160h \
  -t "$INFLUX_TOKEN" \
  -c "$INFLUX_URL" \
  || echo "Bucket habitat_sensors might already exist"

# Create habitat_alerts bucket (30 days retention = 720 hours)
influx bucket create \
  -n habitat_alerts \
  -o "$INFLUX_ORG" \
  -r 720h \
  -t "$INFLUX_TOKEN" \
  -c "$INFLUX_URL" \
  || echo "Bucket habitat_alerts might already exist"

echo "InfluxDB setup complete."
