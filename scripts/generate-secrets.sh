#!/bin/sh
# Fill imm-os-infra/.env with strong random values for the required secrets.
#
#   ./scripts/generate-secrets.sh            # create/complete .env
#   ./scripts/generate-secrets.sh --webhook  # also set SLEEP_WEBHOOK_TOKEN
#
# - Creates .env from .env.example if it doesn't exist.
# - Only fills a secret that is missing, empty or still the example
#   placeholder; values you already set are never changed, so re-running is safe.
# - Prints the values each edge node needs in /etc/imm-os/edge.env.
set -eu
cd "$(dirname "$0")/.."

SECRETS="IMM_SERVICE_TOKEN IMM_EDGE_CLIENT_SECRET MQTT_EDGE_PASSWORD MQTT_ECLSS_PASSWORD MQTT_INGEST_PASSWORD MQTT_SIM_PASSWORD"
if [ "${1:-}" = "--webhook" ]; then SECRETS="$SECRETS SLEEP_WEBHOOK_TOKEN"; fi

if [ ! -f .env ]; then
    cp .env.example .env
    echo "Created .env from .env.example"
fi
chmod 600 .env

current() { grep -E "^$1=" .env | tail -n 1 | cut -d= -f2- || true; }

for var in $SECRETS; do
    val="$(current "$var")"
    case "$val" in
        ""|change-me*|changeme*|your-*) ;;          # empty or placeholder → generate
        *) echo "kept      $var"; continue ;;
    esac
    new="$(openssl rand -hex 32)"
    if grep -qE "^$var=" .env; then
        tmp=".env.tmp.$$"
        awk -v k="$var" -v v="$new" 'BEGIN{FS=OFS="="} $1==k{print k "=" v; next} {print}' .env > "$tmp"
        mv "$tmp" .env
        chmod 600 .env
    else
        printf '%s=%s\n' "$var" "$new" >> .env
    fi
    echo "generated $var"
done

cat <<MSG

Done. Values for /etc/imm-os/edge.env on each edge node:
  IMM_EDGE_CLIENT_SECRET=$(current IMM_EDGE_CLIENT_SECRET)
  MQTT_PASSWORD=$(current MQTT_EDGE_PASSWORD)

Restart the stack to apply: docker compose up -d
(Keycloak reads IMM_EDGE_CLIENT_SECRET only when it first imports the realm.)
MSG
