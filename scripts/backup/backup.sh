#!/bin/sh
# IMM-OS scheduled backups. Runs inside the backup-postgres / backup-influx containers
# (docker-compose.yml), writing to /backups (the host folder BACKUP_DIR, default ./backups).
#
#   backup.sh postgres|influx          loop: back up now if one is due, then every BACKUP_INTERVAL_H
#   backup.sh postgres|influx once     one backup now (the DR drill and restore scripts use this)
#   backup.sh postgres|influx check    container healthcheck: fails when the last good backup is too old
#
# Each backup is checked before it counts: a Postgres dump must list with pg_restore, an
# Influx backup must have its manifest. Row/point counts are recorded next to it so a
# restore can be verified (scripts/dr-drill). A failure is reported to the health monitor
# (caution alarm) and retried in 15 min. The newest BACKUP_KEEP_MIN backups are always
# kept; older ones go after BACKUP_KEEP_DAYS.
set -u
KIND=${1:?usage: backup.sh postgres|influx [once|check]}
MODE=${2:-loop}
DIR=/backups/$KIND
INTERVAL_H=${BACKUP_INTERVAL_H:-6}
KEEP_DAYS=${BACKUP_KEEP_DAYS:-14}
KEEP_MIN=${BACKUP_KEEP_MIN:-4}
RETRY_S=900
mkdir -p "$DIR"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [backup-$KIND] $*"; }

report() {  # severity message   (the message must not contain double quotes)
    [ -n "${IMM_SERVICE_TOKEN:-}" ] || return 0
    wget -q -O /dev/null -T 10 \
        --header "Content-Type: application/json" --header "X-IMM-Service-Token: $IMM_SERVICE_TOKEN" \
        --post-data "{\"key\":\"backup.$KIND\",\"severity\":\"$1\",\"category\":\"pipeline\",\"source\":\"backup-$KIND\",\"message\":\"$2\",\"hold_s\":$((RETRY_S + 300))}" \
        "${HEALTH_EVENTS_URL:-http://health-monitor:8011/api/health/events}" 2>/dev/null || true
}

age_min() {  # minutes since the file was modified, or a large number
    [ -f "$1" ] || { echo 999999; return; }
    echo $(( ($(date +%s) - $(stat -c %Y "$1")) / 60 ))
}

pg_counts() {  # exact row count of every table
    psql -h "$PGHOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -F ' ' -v ON_ERROR_STOP=1 -c "
        SELECT table_name, (xpath('/row/c/text()', query_to_xml(
            format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text
        FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1"
}

backup_postgres() {
    export PGPASSWORD="$POSTGRES_PASSWORD" PGHOST="${PGHOST:-postgres}"
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    f="$DIR/imm_db-$ts.dump"
    pg_counts > "$f.counts-before" || return 1
    pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -Z 6 -f "$f.part" || return 1
    pg_counts > "$f.counts-after" || return 1
    pg_restore --list "$f.part" > /dev/null || { log "dump does not read back"; return 1; }
    mv "$f.part" "$f"
    (cd "$DIR" && sha256sum "$(basename "$f")" > "$(basename "$f").sha256")
    log "ok: $(basename "$f") ($(du -h "$f" | cut -f1), $(wc -l < "$f.counts-after") tables)"
}

influx_points() {  # points in habitat_sensors between two RFC3339 times
    influx query --raw "from(bucket: \"habitat_sensors\") |> range(start: $1, stop: $2)
        |> filter(fn: (r) => r._field == \"value\") |> group() |> count()" 2>/dev/null |
        awk -F, '{sub(/\r$/, "")} /^#/ || NF < 2 {next} !c {for (i = 1; i <= NF; i++) if ($i == "_value") c = i; next} {print $c; exit}'
}

backup_influx() {
    export INFLUX_HOST="${INFLUX_HOST:-http://influxdb:8086}"     # INFLUX_TOKEN from the environment
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    d="$DIR/influx-$ts"
    # a closed window in the past, so later writes don't change it; the DR drill compares against it
    stop=$(date -u -d "@$(( $(date +%s) - 600 ))" +%Y-%m-%dT%H:%M:%SZ)
    start=$(date -u -d "@$(( $(date +%s) - 86400 ))" +%Y-%m-%dT%H:%M:%SZ)
    rm -rf "$d.part"
    influx backup "$d.part" > /dev/null || return 1
    ls "$d.part"/*.manifest > /dev/null 2>&1 || { log "backup has no manifest"; return 1; }
    points=$(influx_points "$start" "$stop")
    mv "$d.part" "$d"
    tar -C "$DIR" -czf "$d.tar.gz.part" "influx-$ts" && rm -rf "$d" && mv "$d.tar.gz.part" "$d.tar.gz" || return 1
    printf 'start %s\nstop %s\npoints %s\n' "$start" "$stop" "${points:-0}" > "$d.tar.gz.counts"
    (cd "$DIR" && sha256sum "influx-$ts.tar.gz" > "influx-$ts.tar.gz.sha256")
    log "ok: influx-$ts.tar.gz ($(du -h "$d.tar.gz" | cut -f1), ${points:-0} sensor points in the last day)"
}

prune() {
    # newest first; keep KEEP_MIN whatever their age, delete the rest once older than KEEP_DAYS
    ls -1t "$DIR" | grep -E '\.(dump|tar\.gz)$' | tail -n +$((KEEP_MIN + 1)) | while read -r b; do
        if [ -n "$(find "$DIR/$b" -mtime +"$KEEP_DAYS" 2>/dev/null)" ]; then
            log "pruning $b"
            rm -f "$DIR/$b" "$DIR/$b".*
        fi
    done
    rm -rf "$DIR"/*.part
}

run_once() {
    if "backup_$KIND"; then
        date -u +%Y-%m-%dT%H:%M:%SZ > "$DIR/last-success"
        prune
        return 0
    fi
    log "FAILED"
    report caution "$KIND backup failed; retrying in $((RETRY_S / 60)) min (see: docker compose logs backup-$KIND)"
    return 1
}

case "$MODE" in
    once)
        run_once; exit $? ;;
    check)
        # healthy if the last good backup is younger than two intervals (+30 min slack),
        # or the container started less than 30 min ago and is still making its first one
        limit=$((INTERVAL_H * 120 + 30))
        [ "$(age_min "$DIR/last-success")" -lt "$limit" ] && exit 0
        [ "$(age_min /tmp/started)" -lt 30 ] && exit 0
        echo "last good $KIND backup: $(cat "$DIR/last-success" 2>/dev/null || echo never)"; exit 1 ;;
    loop)
        touch /tmp/started
        log "every ${INTERVAL_H} h into $DIR (keep ${KEEP_DAYS} days, at least ${KEEP_MIN})"
        sleep "${BACKUP_START_DELAY_S:-60}"          # let the database come up first
        while true; do
            due=$((INTERVAL_H * 60 - $(age_min "$DIR/last-success")))
            if [ "$due" -gt 0 ]; then
                sleep $((due * 60 < 3600 ? due * 60 : 3600))
                continue
            fi
            run_once || sleep "$RETRY_S"
        done ;;
    *)
        echo "unknown mode $MODE" >&2; exit 2 ;;
esac
