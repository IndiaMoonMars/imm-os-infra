#!/bin/sh
# Restore IMM-OS data from a backup (disaster recovery). REPLACES the live data.
#
#   scripts/restore.sh postgres [backup file] [--yes]    default: newest backups/postgres/imm_db-*.dump
#   scripts/restore.sh influx   [backup file] [--yes]    default: newest backups/influx/influx-*.tar.gz
#
# 1. picks the backup and checks its checksum
# 2. takes a safety backup of the current data (if the database is up)
# 3. stops the services that write to that database
# 4. restores (Postgres: pg_restore --clean; InfluxDB: influx restore --full)
# 5. compares row counts with the ones recorded at backup time (Postgres)
# 6. starts everything again (docker compose up -d)
#
# To practise without touching live data use the DR drill instead: scripts/dr-drill.sh
set -eu
cd "$(dirname "$0")/.."
KIND=${1:?usage: scripts/restore.sh postgres|influx [backup file] [--yes]}
shift
FILE=""; YES=0
for a in "$@"; do case "$a" in --yes) YES=1 ;; *) FILE=$a ;; esac; done
DIR=$(grep -E '^BACKUP_DIR=' .env 2>/dev/null | tail -n 1 | cut -d= -f2- || true)
DIR=${DIR:-./backups}

case "$KIND" in
    postgres) PATTERN='imm_db-*.dump'; DB=postgres
              WRITERS="keycloak eclss-api eva-api inventory-api comms-api scheduling-api medical-api psych-api mission-assistant auto-control ai-processor health-monitor telemetry-ingest backup-postgres" ;;
    influx)   PATTERN='influx-*.tar.gz'; DB=influxdb
              WRITERS="telemetry-processor telemetry-worker backup-influx" ;;
    *) echo "unknown kind $KIND (postgres or influx)" >&2; exit 2 ;;
esac
if [ -z "$FILE" ]; then
    FILE=$(ls -1t "$DIR/$KIND"/$PATTERN 2>/dev/null | head -n 1 || true)
fi
[ -n "$FILE" ] && [ -f "$FILE" ] || { echo "no $KIND backup found (looked in $DIR/$KIND)" >&2; exit 1; }
if [ -f "$FILE.sha256" ]; then
    (cd "$(dirname "$FILE")" && sha256sum -c "$(basename "$FILE").sha256" >/dev/null) || { echo "checksum MISMATCH: $FILE is damaged" >&2; exit 1; }
    echo "checksum ok: $FILE"
else
    echo "warning: no checksum file for $FILE"
fi

echo
echo "This REPLACES the live $KIND data with $(basename "$FILE")"
echo "(taken $(date -r "$FILE" '+%Y-%m-%d %H:%M')). Services stopped meanwhile: $WRITERS"
if [ $YES -ne 1 ]; then
    printf 'Type RESTORE to continue: '
    read -r answer
    [ "$answer" = "RESTORE" ] || { echo "cancelled"; exit 1; }
fi

echo "safety backup of the current data ..."
docker compose exec -T "backup-$KIND" /bin/sh /scripts/backup.sh "$KIND" once \
    || echo "  (no safety backup: the database or the backup container is down; continuing)"

echo "stopping writers ..."
# shellcheck disable=SC2086
docker compose stop $WRITERS >/dev/null 2>&1 || true
docker compose up -d "$DB" >/dev/null
docker compose cp "$FILE" "$DB:/tmp/imm-restore" >/dev/null

if [ "$KIND" = postgres ]; then
    docker compose exec -T postgres sh -c 'until pg_isready -U "$POSTGRES_USER" -q; do sleep 1; done;
        pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner /tmp/imm-restore; rc=$?;
        rm -f /tmp/imm-restore; exit $rc' || echo "  pg_restore reported errors (often harmless 'does not exist' notes on a fresh database)"
    if [ -f "$FILE.counts-after" ]; then
        docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -F " " -c "
            SELECT table_name, (xpath(\$\$/row/c/text()\$\$, query_to_xml(format(\$\$SELECT count(*) AS c FROM %I.%I\$\$,
                table_schema, table_name), false, true, \$\$\$\$)))[1]::text
            FROM information_schema.tables WHERE table_schema = \$\$public\$\$ AND table_type = \$\$BASE TABLE\$\$ ORDER BY 1"' \
            > /tmp/imm-restore-counts.$$ || true
        bad=$(awk 'NR == FNR {want[$1] = $2; next} ($1 in want) && want[$1] != $2 {n++} END {print n + 0}' \
            "$FILE.counts-after" /tmp/imm-restore-counts.$$)
        rm -f /tmp/imm-restore-counts.$$
        echo "row counts: $bad table(s) differ from the backup's record (0 expected; small differences = rows written during the dump)"
    fi
else
    docker compose exec -T influxdb sh -c 'rm -rf /tmp/imm-r && mkdir /tmp/imm-r && tar xzf /tmp/imm-restore -C /tmp/imm-r &&
        INFLUX_TOKEN="$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN" influx restore --full /tmp/imm-r/*; rc=$?;
        rm -rf /tmp/imm-r /tmp/imm-restore; exit $rc'
fi

echo "starting everything ..."
docker compose up -d >/dev/null
echo "done. Check: docker compose ps   and the IMM-OS alarm panel."
