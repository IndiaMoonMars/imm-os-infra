# IMM OS Infrastructure
Terraform/Ansible scripts, Docker configs, K3s setup.

## First-time setup: secrets and MQTT TLS

All secrets live in **`imm-os-infra/.env`** (git-ignored; never commit it).
`docker compose` refuses to start while a required one is missing.

```sh
cd imm-os-infra

# 1. Create .env and fill every required secret with a random value.
#    Safe to re-run: values you already set are never changed.
./scripts/generate-secrets.sh             # add --webhook to also enable the sleep webhook

# 2. Create the MQTT TLS certificates. Add the MCC server's LAN IP / DNS name
#    so edge nodes can connect by it.
./mosquitto/gen-certs.sh 192.168.1.100

# 3. Start (or restart) the stack.
docker compose up -d
```

**On Windows**, use the PowerShell versions (no Git Bash needed) in PowerShell
from the `imm-os-infra` folder:

```powershell
cd imm-os-infra
.\scripts\generate-secrets.ps1              # add -Webhook for the sleep webhook
.\mosquitto\gen-certs.ps1 192.168.1.100     # your PC's IPv4 address from `ipconfig`
docker compose up -d
```

If PowerShell says "running scripts is disabled on this system", first run
`Set-ExecutionPolicy -Scope Process Bypass` (this only affects the current
window). `gen-certs.ps1` uses the OpenSSL that ships with Git for Windows. If
OpenSSL isn't installed, it generates the certificates in a temporary Docker
container instead (Docker Desktop must be running).

| Variable in `.env` | Used by | Required |
|---|---|---|
| `MQTT_EDGE_PASSWORD` | MQTT user `imm-edge` (RPi / Jetson) | yes |
| `MQTT_ECLSS_PASSWORD` | MQTT user `imm-eclss` (eclss-api) | yes |
| `MQTT_INGEST_PASSWORD` | MQTT user `imm-ingest` (bridge, telemetry worker) | yes |
| `MQTT_SIM_PASSWORD` | MQTT user `imm-sim` (sensor simulator) | yes |
| `IMM_EDGE_CLIENT_SECRET` | Keycloak client `imm-edge` (edge → HTTP APIs) | yes |
| `IMM_SERVICE_TOKEN` | internal service-to-service calls | set it (placeholder default) |
| `SLEEP_WEBHOOK_TOKEN` | Garmin/Fitbit sleep webhook | optional (empty = disabled) |

The broker builds its hashed password file from these on every start, so to
**change an MQTT password**: edit it in `.env`, run `docker compose up -d`, and
update the edge nodes. Which topics each MQTT user may use is in
`mosquitto/config/acl`.

### MQTT listeners
- **8883 (TLS)**: the only MQTT port published on the LAN; edge nodes use it.
- **1883 (plain)**: docker network only, for the stack's own services.

### Each edge node (RPi / Jetson)
1. Copy `mosquitto/certs/ca.crt` to `/etc/imm-os/mqtt-ca.crt` (not secret).
2. Copy `imm-os-edge/systemd/edge.env.example` to `/etc/imm-os/edge.env`,
   `chmod 600`, and set:
   - `MQTT_PASSWORD` = `MQTT_EDGE_PASSWORD` from `.env`
   - `IMM_EDGE_CLIENT_SECRET` = the same value as in `.env`
   - `MQTT_HOST` = a name or IP the certificate covers (from step 2 above)
3. Restart the IMM services: `sudo systemctl restart 'imm-*'`

`generate-secrets.sh` prints the two edge values at the end. Keep
`mosquitto/certs/ca.key` private: it is only needed to issue a new server
certificate (`./mosquitto/gen-certs.sh --force ...`), after which every edge node
needs the new `ca.crt`.

## Telemetry: simulated → real sensors

Edge drivers and the `sensor-sim` container publish the same readings on
`habitat/sensors/<sensor>/<zone>`, marked `"simulated": true/false`:

```
MQTT → mqtt-kafka-bridge → telemetry.raw → telemetry-validator → telemetry.validated
     → telemetry-processor (InfluxDB habitat_sensors + alerts) / realtime WS (OpenMCT)
```

- Rejected readings go to Kafka `telemetry.deadletter`; the reason is logged by
  `docker compose logs telemetry-validator`.
- As each real sensor comes online, stop simulating it: set
  `SIM_DISABLED_SENSORS=node-rpi-01:bme280` in `.env` and run
  `docker compose up -d sensor-sim`. The dashboard badge for that value turns
  from **SIM** to **LIVE**.
- Driver setup: `imm-os-edge/real-sensors/README.md`.
