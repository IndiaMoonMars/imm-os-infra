#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════
#  IMM-OS Stack Health Verification
#  Phase 0 Step 9 acceptance criteria validator
#
#  Usage:  ./scripts/verify-stack.sh
#  Run after: docker compose up -d && sleep 60
#
#  Exit 0 → ALL services healthy
#  Exit 1 → one or more services failed
# ════════════════════════════════════════════════════════════════════════════════

set -euo pipefail

PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}▶${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }

echo ""
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  IMM-OS Phase 0  —  Stack Health Check         ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo ""

# ── 1. Docker Compose ps ─────────────────────────────────────────────────────
info "Checking docker compose service states..."
COMPOSE_PS=$(docker compose ps --format json 2>/dev/null || echo "[]")

check_service_healthy() {
  local name="$1"
  local status
  status=$(docker inspect --format='{{.State.Health.Status}}' "imm-$name" 2>/dev/null || echo "missing")
  if [[ "$status" == "healthy" ]]; then
    pass "imm-$name → healthy"
  elif [[ "$status" == "missing" ]]; then
    fail "imm-$name → container not found"
  else
    fail "imm-$name → status: $status (expected: healthy)"
  fi
}

for svc in postgres influxdb mosquitto kafka zookeeper keycloak nginx; do
  check_service_healthy "$svc"
done

echo ""

# ── 2. PostgreSQL — accept connections ────────────────────────────────────────
info "PostgreSQL connection test..."
if docker exec imm-postgres pg_isready -U admin -d imm_db -q 2>/dev/null; then
  pass "PostgreSQL accepts connections on :5432"
else
  fail "PostgreSQL not accepting connections"
fi

echo ""

# ── 3. InfluxDB UI — :8086 ───────────────────────────────────────────────────
info "InfluxDB HTTP check..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8086/health 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
  pass "InfluxDB UI responds on :8086 (HTTP $HTTP_CODE)"
else
  fail "InfluxDB :8086 returned HTTP $HTTP_CODE (expected 200)"
fi

echo ""

# ── 4. Mosquitto MQTT — :1883 ─────────────────────────────────────────────────
info "Mosquitto MQTT check..."
if docker exec imm-mosquitto mosquitto_pub -h localhost -p 1883 -t "imm/health/check" -m "ping" 2>/dev/null; then
  pass "Mosquitto MQTT broker reachable on :1883"
else
  fail "Mosquitto not reachable on :1883"
fi

echo ""

# ── 5. Kafka — broker list ────────────────────────────────────────────────────
info "Kafka broker check..."
if docker exec imm-kafka kafka-topics --bootstrap-server localhost:9092 --list &>/dev/null; then
  pass "Kafka broker responding on :9092"
else
  fail "Kafka broker not responding on :9092"
fi

echo ""

# ── 6. Keycloak — /auth/health/ready ─────────────────────────────────────────
info "Keycloak health check..."
KC_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/auth/health/ready 2>/dev/null || echo "000")
if [[ "$KC_CODE" == "200" ]]; then
  pass "Keycloak /auth/health/ready → HTTP $KC_CODE"
else
  fail "Keycloak /auth/health/ready → HTTP $KC_CODE (expected 200)"
fi

echo ""

# ── 7. Nginx routing ──────────────────────────────────────────────────────────
info "Nginx reverse proxy routing..."

check_nginx_path() {
  local path="$1"
  local expected_min="$2"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost$path" 2>/dev/null || echo "000")
  if [[ "$code" -ge "$expected_min" && "$code" -lt 500 ]]; then
    pass "Nginx $path → HTTP $code"
  else
    fail "Nginx $path → HTTP $code (expected >= $expected_min and < 500)"
  fi
}

check_nginx_path "/"         200
check_nginx_path "/api/"     200
check_nginx_path "/openmct/" 200
check_nginx_path "/auth/"    200

echo ""

# ── 8. Sensor Simulator ───────────────────────────────────────────────────────
info "Sensor simulator check..."
SIM_STATUS=$(docker inspect --format='{{.State.Status}}' imm-sensor-sim 2>/dev/null || echo "missing")
if [[ "$SIM_STATUS" == "running" ]]; then
  pass "Sensor simulator is running (MQTT → imm/habitat/#)"
  warn "Simulated data is flowing. When real sensors arrive, disable this container."
else
  fail "Sensor simulator not running (status: $SIM_STATUS)"
fi

echo ""

# ── 9. Telemetry Worker ───────────────────────────────────────────────────────
info "Telemetry worker (MQTT→InfluxDB bridge) check..."
TW_STATUS=$(docker inspect --format='{{.State.Status}}' imm-telemetry-worker 2>/dev/null || echo "missing")
if [[ "$TW_STATUS" == "running" ]]; then
  pass "Telemetry worker is running"
else
  fail "Telemetry worker not running (status: $TW_STATUS)"
fi

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "  Results:  ${GREEN}$PASS passed${NC}  |  ${RED}$FAIL failed${NC}"
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo ""

if [[ "$FAIL" -eq 0 ]]; then
  echo -e "${GREEN}✅  Phase 0 Step 9 — ALL SERVICES HEALTHY${NC}"
  echo -e "    Stack is ready. Run for 24h to confirm stability."
  exit 0
else
  echo -e "${RED}❌  $FAIL service(s) failed health checks.${NC}"
  echo -e "    Check logs: docker compose logs <service-name>"
  exit 1
fi
