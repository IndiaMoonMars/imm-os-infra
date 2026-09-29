#!/usr/bin/env python3
"""
IMM-OS mission readiness test: end-to-end V&V with deliberate fault injection.

Runs against the live MCC stack (docker compose) and proves, requirement by
requirement (imm-os-docs/vv-plan.md), that faults are detected and alarmed, that the
system degrades safely, that it recovers by itself, and that no data is lost:

  detection    sensor loss, out-of-range data, rate glitches, cross-check failures,
               sequence gaps, late (backfilled) data
  alarms       limits, escalation, acknowledgement, clearing, no alarm flooding,
               unverified data, persistence across a health-monitor restart
  degraded     sensor failover, loss of critical monitoring, edge component SAFE mode,
               node loss
  EVA          loss of signal (LOS_WARN → LOS → CONTINGENCY), partial loss, recovery
               with backfill
  recovery     crashed worker, hung worker (watchdog + autoheal), MQTT bridge, broker,
               Kafka, InfluxDB and Postgres outages
  integrity    every reading the broker accepted is in InfluxDB, once, with its value
  DR           backups fresh and restorable (restore drill into scratch containers)

It injects faults with a real test node (vv-node-01, crew vv-crew-01) publishing as an
edge node, and through the Docker API (stop, kill, SIGSTOP). Every injected fault is
undone in a finally block, and the test node is decommissioned at the end.

  docker compose --profile vv run --rm vv                         # everything (~30 min)
  docker compose --profile vv run --rm vv python -u /vv/mission_readiness.py --quick
  ... --only VV-ALM-01,VV-EVA-01      ... --list

Writes vv/reports/mission-readiness-<UTC time>.md and .json; exit code 0 = GO.
Run it when the habitat is not on a live mission: its alarms are real alarms.
"""
import argparse
import asyncio
import json
import os
import sys
import time
import traceback
from datetime import datetime, timezone
from typing import Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dockerapi as dk  # noqa: E402
import dr_drill  # noqa: E402
from harness import (VV_CREW, VV_NODE, VV_ZONE, Api, Publisher, build_node, delete_node_points,  # noqa: E402
                     now, pg_fetch, stored_points, wait_until)

REPORTS = os.getenv("VV_REPORTS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "reports"))
NODE_SUB = f"atmosphere:{VV_NODE}/{VV_ZONE}"
CO2_KEY = f"limit.co2.{VV_NODE}.{VV_ZONE}"


class Fail(AssertionError):
    pass


def check(cond, msg: str):
    if not cond:
        raise Fail(msg)


# ── test registry ──────────────────────────────────────────────────
TESTS: List[dict] = []


def test(rid: str, title: str, requirement: str, critical: bool = True, slow: bool = False, disruptive: bool = False):
    def deco(fn):
        TESTS.append({"id": rid, "title": title, "requirement": requirement, "critical": critical,
                      "slow": slow, "disruptive": disruptive, "fn": fn})
        return fn
    return deco


class Ctx:
    def __init__(self):
        self.api = Api()
        self.pub = build_node(Publisher())
        self.t_start = time.time()
        self.names: Dict[str, str] = {}
        self.evidence: List[str] = []

    def container(self, service: str) -> str:
        """compose service → container name (imm-<service> by default)."""
        if service not in self.names:
            for c in dk.containers():
                if c.get("Labels", {}).get("com.docker.compose.service") == service:
                    self.names[service] = c["Names"][0].lstrip("/")
                    break
            else:
                raise Fail(f"no container for service {service}")
        return self.names[service]

    def note(self, msg: str):
        self.evidence.append(msg)
        print(f"      · {msg}", flush=True)

    def flowing(self, sensor: str = "scd40", within: float = 10) -> bool:
        """Live readings of the test node are arriving at the health monitor."""
        s = self.api.stream(sensor)
        return bool(s and s.get("status") in ("ok", "suspect") and s.get("age_s") is not None and s["age_s"] < within)

    def wait_flowing(self, timeout: float = 120) -> float:
        ok, t = wait_until(lambda: self.flowing(), timeout, 2)
        check(ok, f"telemetry from {VV_NODE} did not flow again within {timeout:.0f} s")
        return t

    def settle_alarm_gone(self, key: str, timeout: float = 60):
        """Wait until the alarm is inactive, and acknowledge it so it closes."""
        def gone():
            a = self.api.alarm(key)
            if a is None:
                return True
            if a["state"] != "active":
                if not a["acked"]:
                    self.api.health(f"/alarms/{a['id']}/ack", "POST")
                return self.api.alarm(key) is None
            return False
        ok, _ = wait_until(gone, timeout, 2)
        return ok


def alarm_active(ctx: Ctx, key: str, severity: Optional[str] = None):
    def pred():
        a = ctx.api.alarm(key)
        if a and a["state"] == "active" and (severity is None or a["severity"] == severity):
            return a
        return None
    return pred


# ══ preflight ═══════════════════════════════════════════════════════
@test("VV-PRE-01", "MCC stack healthy", "Every MCC container with a healthcheck reports healthy before the test.")
def pre_stack(ctx: Ctx):
    bad = []
    for c in dk.containers(all_=False):
        svc = c.get("Labels", {}).get("com.docker.compose.service")
        if not svc or svc == "vv" or c.get("Labels", {}).get("imm.vv"):
            continue
        st = c.get("Status", "")
        if "(unhealthy)" in st or "(health: starting)" in st:
            bad.append(f"{svc}: {st}")
    check(not bad, "not healthy: " + "; ".join(bad))
    ctx.note(f"{len(dk.containers(all_=False))} containers running, none unhealthy")


@test("VV-PRE-02", "Test node reporting, no alarms in nominal conditions",
      "A healthy node's nominal readings are accepted as good and raise no alarm (no false alarms).")
def pre_nominal(ctx: Ctx):
    _, t = wait_until(lambda: all(ctx.flowing(s) for s in ("bme280", "scd40", "o2")), 60, 2)
    check(all(ctx.flowing(s) for s in ("bme280", "scd40", "o2")), f"{VV_NODE} streams not ok")
    time.sleep(15)
    mine = [a["key"] for a in ctx.api.alarms(VV_NODE)]
    check(not mine, f"alarms on nominal data: {mine}")
    sub = ctx.api.subsystem(NODE_SUB)
    check(sub and sub["status"] == "GO", f"{NODE_SUB} is {sub and sub['status']}")
    ctx.note(f"streams ok after {t:.0f} s; {NODE_SUB} GO; 0 alarms")


# ══ alarms ══════════════════════════════════════════════════════════
@test("VV-ALM-01", "CO₂ warning raised, acknowledged, cleared",
      "CO₂ above 5000 ppm raises one WARNING within 15 s; the operator can acknowledge it; "
      "it clears when CO₂ returns below the limit minus the deadband, and closes.")
def alm_co2(ctx: Ctx):
    scd, o2 = ctx.pub["scd40"], ctx.pub["o2"]
    t0 = time.time()
    scd.ramp(co2_ppm=(6000, 1500))          # a fast but physical rise (rate limit 5000 ppm/s)
    o2.ramp(o2_pct=(20.3, 0.5))
    a, _ = wait_until(alarm_active(ctx, CO2_KEY, "warning"), 30, 1)
    check(a, "no CO₂ WARNING alarm")
    lat = time.time() - t0
    check(lat <= 15 + 4, f"raised after {lat:.0f} s (> 15 s)")
    ctx.note(f"WARNING after {lat:.1f} s: {a['message']}")
    sub = ctx.api.subsystem(NODE_SUB)
    check(sub and sub["status"] != "GO", "atmosphere subsystem still GO")
    check(ctx.api.summary()["mode"] in ("DEGRADED", "EMERGENCY"), "mission mode not DEGRADED")
    acked = ctx.api.health(f"/alarms/{a['id']}/ack", "POST")["alarm"]
    check(acked["acked"] and acked["acked_by"], "acknowledge failed")
    scd.ramp(co2_ppm=(700, 1500))
    o2.ramp(o2_pct=(20.9, 0.5))
    ok, t = wait_until(lambda: ctx.api.alarm(CO2_KEY) is None, 60, 1)
    check(ok, "acknowledged alarm did not close after CO₂ returned to normal")
    ctx.note(f"cleared and closed {t:.0f} s after CO₂ fell (off-delay 10 s)")
    ctx.alarm_id = a["id"]


@test("VV-ALM-02", "Escalation to EMERGENCY", "CO₂ above 20000 ppm escalates to EMERGENCY, sets the mission mode "
      "EMERGENCY and the atmosphere subsystem NO-GO; escalation requires a new acknowledgement.")
def alm_escalate(ctx: Ctx):
    scd, o2 = ctx.pub["scd40"], ctx.pub["o2"]
    try:
        scd.ramp(co2_ppm=(6000, 2000))
        o2.ramp(o2_pct=(20.3, 0.5))
        a, _ = wait_until(alarm_active(ctx, CO2_KEY, "warning"), 30, 1)
        check(a, "no WARNING first")
        ctx.api.health(f"/alarms/{a['id']}/ack", "POST")
        scd.ramp(co2_ppm=(24000, 2500))
        o2.ramp(o2_pct=(18.3, 0.5))           # O₂ falls as CO₂ rises (consistent, no cross-check fault)
        e, t = wait_until(alarm_active(ctx, CO2_KEY, "emergency"), 40, 1)
        check(e, "no escalation to EMERGENCY")
        check(not e["acked"], "escalated alarm kept the old acknowledgement")
        check(e["id"] == a["id"], "escalation created a new alarm instead of escalating the open one")
        s = ctx.api.summary()
        check(s["mode"] == "EMERGENCY", f"mode {s['mode']}")
        check(ctx.api.subsystem(NODE_SUB)["status"] == "NO_GO", "atmosphere not NO-GO")
        ctx.note(f"EMERGENCY {t:.0f} s after the rise started; mode EMERGENCY; {NODE_SUB} NO-GO; ack reset")
    finally:
        scd.ramp(co2_ppm=(700, 3000))
        o2.ramp(o2_pct=(20.9, 1))
        ctx.settle_alarm_gone(CO2_KEY, 90)
        for a in ctx.api.alarms(f"limit.o2.{VV_NODE}"):
            ctx.settle_alarm_gone(a["key"], 60)


@test("VV-ALM-03", "No alarm flooding", "A condition that persists is one alarm (one database row), not one per reading.")
def alm_flood(ctx: Ctx):
    def closed_rows():                          # the monitor persists through a queue: allow it a moment
        r = asyncio.run(pg_fetch("SELECT id, raise_count, state FROM alarms WHERE alarm_key = $1 AND raised_at > to_timestamp($2)",
                                 CO2_KEY, ctx.t_start))
        return r if r and all(x["state"] == "closed" for x in r) else None
    wait_until(closed_rows, 15, 1)
    rows = asyncio.run(pg_fetch("SELECT id, raise_count, state FROM alarms WHERE alarm_key = $1 AND raised_at > to_timestamp($2)",
                                CO2_KEY, ctx.t_start))
    events = asyncio.run(pg_fetch("SELECT event FROM alarm_events WHERE alarm_key = $1 AND at > to_timestamp($2) ORDER BY at, id",
                                  CO2_KEY, ctx.t_start))
    kinds = [r["event"] for r in events]
    check(len(rows) == 2, f"{len(rows)} alarm rows for 2 episodes (expected 2)")
    check(all(r["state"] == "closed" for r in rows), "an episode is not closed in the database")
    check(kinds.count("raised") == 2 and "escalated" in kinds and kinds.count("acked") >= 3,
          f"event trail {kinds}")
    ctx.note(f"{len(rows)} rows for ~{int(time.time() - ctx.t_start)} s of readings; trail: {' → '.join(kinds)}")


@test("VV-ALM-04", "Suspect data: alarm marked UNVERIFIED, capped at WARNING",
      "A limit breach on data the sensor itself marks suspect raises an UNVERIFIED alarm no higher than WARNING.")
def alm_unverified(ctx: Ctx):
    scd = ctx.pub["scd40"]
    try:
        scd.extra = {"q": "suspect", "qf": ["uncalibrated"]}
        scd.ramp(co2_ppm=(25000, 2500))
        ctx.pub["o2"].ramp(o2_pct=(18.3, 0.5))
        a, _ = wait_until(alarm_active(ctx, CO2_KEY), 40, 1)
        check(a, "no alarm on suspect data")
        time.sleep(8)
        a = ctx.api.alarm(CO2_KEY)
        check(a["severity"] == "warning" and a["unverified"], f"{a['severity']} unverified={a['unverified']}")
        check(ctx.api.summary()["mode"] != "EMERGENCY", "suspect data drove the mode to EMERGENCY")
        ctx.note(f"{a['severity']} UNVERIFIED: {a['message'][:90]}")
    finally:
        scd.extra = {}
        scd.ramp(co2_ppm=(700, 3000))
        ctx.pub["o2"].ramp(o2_pct=(20.9, 1))
        ctx.settle_alarm_gone(CO2_KEY, 90)
        for a in ctx.api.alarms(f"limit.o2.{VV_NODE}"):
            ctx.settle_alarm_gone(a["key"], 60)


# ══ detection ═══════════════════════════════════════════════════════
@test("VV-DET-01", "Out-of-range reading rejected", "A physically impossible reading (BME280 500 °C) is dead-lettered "
      "with a reason, never stored, and counted against the sensor.")
def det_range(ctx: Ctx):
    s = ctx.pub["bme280"]
    before = (ctx.api.stream("bme280") or {}).get("invalid_5min", 0)
    ts = now()
    body = {**s.static, "temp": 500.0, "hum": 45.0, "pres": 1008.0, "timestamp": ts}    # no seq: not a lost reading
    ctx.pub.publish(s, body, record=False)
    ok, t = wait_until(lambda: (ctx.api.stream("bme280") or {}).get("invalid_5min", 0) > before, 20, 1)
    check(ok, "rejection not seen by the health monitor")
    time.sleep(3)
    pts = stored_points(ts - 1)
    check(not [k for k, v in pts.items() if k[:2] == ("bme280", "temp") and v >= 400], "the 500 °C reading was stored")
    ctx.note(f"dead-lettered; health monitor counted it after {t:.0f} s; not in InfluxDB")


@test("VV-DET-02", "Rate-of-change glitch flagged", "A jump faster than the sensor's physical rate (BME280 +15 °C in 1 s) "
      "marks the stream suspect with reason 'rate'.")
def det_rate(ctx: Ctx):
    s = ctx.pub["bme280"]
    try:
        s.set(temp=37.0)
        ok, t = wait_until(lambda: "rate" in " ".join((ctx.api.stream("bme280") or {}).get("reasons", [])), 15, 1)
        check(ok, f"no rate flag: {ctx.api.stream('bme280')}")
        ctx.note(f"stream flagged after {t:.0f} s: {ctx.api.stream('bme280').get('reasons')}")
    finally:
        s.ramp(temp=(22.0, 2.0))


@test("VV-DET-03", "Cross-check between redundant sensors", "BME280 and SCD40 humidity that imply dew points more than "
      "3 °C apart for over a minute raise a cross-check alarm on the pair.")
def det_cross(ctx: Ctx):
    s = ctx.pub["bme280"]
    key = f"sensor.{VV_NODE}.bme280.{VV_ZONE}.cross.dew_point"
    try:
        s.ramp(hum=(80.0, 10.0))
        a, t = wait_until(alarm_active(ctx, key), 100, 1)       # on-delay 60 s: a door opening is not a fault
        check(a, "no cross-check alarm")
        ctx.note(f"{a['severity']} after {t:.0f} s: {a['message'][:100]}")
    finally:
        s.ramp(hum=(45.0, 10.0))
        ctx.settle_alarm_gone(key, 60)


@test("VV-DET-04", "Lost readings detected from sequence numbers",
      "Readings missing from a stream (sequence gap) are counted as lost and reported.", critical=False)
def det_gap(ctx: Ctx):
    s = ctx.pub["o2"]
    before = ((ctx.api.stream("o2") or {}).get("integrity") or {}).get("lost", 0)
    s.seq += 5                                             # the node "loses" 5 readings
    ok, t = wait_until(lambda: ((ctx.api.stream("o2") or {}).get("integrity") or {}).get("lost", 0) >= before + 5, 15, 1)
    check(ok, f"gap not detected: {(ctx.api.stream('o2') or {}).get('integrity')}")
    ctx.note(f"5 lost readings counted after {t:.0f} s")


@test("VV-DET-05", "Late (backfilled) data stored at its time, no alarm",
      "Readings replayed after an outage are stored at their original time, marked delayed, and raise no live alarm.")
def det_backfill(ctx: Ctx):
    s = ctx.pub["scd40"]
    t_old = now() - 1800
    for i in range(20):                               # 20 s of a node's backlog from 30 min ago, CO₂ 9000
        ctx.pub.publish(s, ctx.pub.reading(s, round(t_old + i, 3), co2_ppm=9000.0, delayed=True))
    time.sleep(12)
    check(ctx.api.alarm(CO2_KEY) is None, "backfilled data raised a live CO₂ alarm")
    pts = stored_points(t_old - 5)
    old = [v for (sensor, metric, ms), v in pts.items() if sensor == "scd40" and metric == "co2_ppm" and ms < (t_old + 60) * 1000]
    check(len(old) == 20 and all(v == 9000.0 for v in old), f"{len(old)} backfilled points stored at their time (expected 20)")
    ctx.note("20 backfilled readings stored at their original time; no alarm")


# ══ degraded modes ══════════════════════════════════════════════════
@test("VV-RED-01", "Failover to a redundant sensor", "When the primary temperature sensor (BME280) stops, temperature "
      "is served by the SCD40 within 30 s; the measurement is DEGRADED, not lost.")
def red_failover(ctx: Ctx):
    s = ctx.pub["bme280"]
    try:
        s.enabled = False
        m, t = wait_until(lambda: (lambda m: m if m and m.get("source_sensor") == "scd40" else None)(
            ctx.api.measurement("temperature")), 45, 1)
        check(m, f"no failover: {ctx.api.measurement('temperature')}")
        check(m["status"] == "DEGRADED", f"status {m['status']}")
        check(ctx.api.subsystem(NODE_SUB)["status"] != "NO_GO", "loss of a non-critical primary made the atmosphere NO-GO")
        ctx.note(f"temperature from {m['source_sensor']} after {t:.0f} s ({m['status']}: {m.get('reason')})")
    finally:
        s.enabled = True
    m, t = wait_until(lambda: (lambda m: m if m and m["status"] == "NOMINAL" and m.get("source_sensor") == "bme280" else None)(
        ctx.api.measurement("temperature")), 45, 1)
    check(m, "did not return to the primary sensor")
    ctx.note(f"back on the BME280 {t:.0f} s after it returned")


@test("VV-RED-02", "Loss of critical monitoring", "When the only CO₂ sensor stops, CO₂ monitoring is LOST within 40 s: "
      "WARNING 'use a portable monitor' and the atmosphere subsystem NO-GO; recovery clears it.")
def red_critical(ctx: Ctx):
    s = ctx.pub["scd40"]
    key = f"monitoring.co2.{VV_NODE}.{VV_ZONE}"
    try:
        s.enabled = False
        a, t = wait_until(alarm_active(ctx, key, "warning"), 60, 1)
        check(a, "no loss-of-monitoring alarm")
        check(ctx.api.subsystem(NODE_SUB)["status"] == "NO_GO", "atmosphere not NO-GO")
        ctx.note(f"WARNING after {t:.0f} s: {a['message'][:90]}; {NODE_SUB} NO-GO")
    finally:
        s.enabled = True
    check(ctx.settle_alarm_gone(key, 90), "loss-of-monitoring alarm did not clear after the sensor returned")
    ok, t = wait_until(lambda: ctx.api.subsystem(NODE_SUB)["status"] == "GO", 60, 2)
    check(ok, "atmosphere not GO again")


@test("VV-EDGE-01", "Edge component in SAFE mode", "An edge component reporting SAFE (e.g. the climate controller "
      "after an actuator fault) raises a WARNING and marks its node DEGRADED; NOMINAL clears it.")
def edge_safe(ctx: Ctx):
    topic = f"habitat/health/{VV_NODE}/eclss_pid"
    key = f"component.{VV_NODE}/eclss_pid.state"
    try:
        ctx.pub.publish_raw(topic, {"node_id": VV_NODE, "component": "eclss_pid", "state": "SAFE",
                                    "reason": "V&V: heater relay stuck, outputs off", "timestamp": now(), "interval_s": 30})
        a, t = wait_until(alarm_active(ctx, key, "warning"), 20, 1)
        check(a, "no alarm for the SAFE component")
        sub = ctx.api.subsystem(f"node:{VV_NODE}")
        check(sub and sub["status"] == "DEGRADED", f"node subsystem {sub and sub['status']}")
        ctx.note(f"WARNING after {t:.0f} s; node DEGRADED: {sub['reasons']}")
    finally:
        ctx.pub.publish_raw(topic, {"node_id": VV_NODE, "component": "eclss_pid", "state": "NOMINAL",
                                    "reason": "", "timestamp": now(), "interval_s": 30})
    check(ctx.settle_alarm_gone(key, 30), "SAFE alarm did not clear on NOMINAL")


# ══ EVA ═════════════════════════════════════════════════════════════
def eva_state(ctx: Ctx, state: str):
    return lambda: (lambda c: c if c and c["state"] == state else None)(ctx.api.crew())


@test("VV-EVA-01", "EVA partial loss (vitals)", "With position still arriving, suit vitals missing for the partial-loss "
      "time raise a CAUTION.")
def eva_partial(ctx: Ctx):
    vit, pos = ctx.pub["vitals"], ctx.pub["position"]
    vit.enabled = pos.enabled = True
    ctx.api.health(f"/eva/{VV_CREW}/arm", "POST")
    both = lambda: (lambda c: c if c and c["state"] == "NOMINAL" and (c.get("vitals_age_s") or 99) < 3        # noqa: E731
                    and (c.get("position_age_s") or 99) < 3 else None)(ctx.api.crew())
    ok, _ = wait_until(both, 30, 1)
    check(ok, f"crew not NOMINAL with vitals and position flowing: {ctx.api.crew()}")
    thr = ctx.api.health("/eva")["thresholds"]
    key = f"eva.vitals_lost.{VV_CREW}"
    try:
        vit.enabled = False
        t0 = time.time()
        a, _ = wait_until(alarm_active(ctx, key, "caution"), thr["partial_s"] + 15, 1)
        check(a, "no partial-loss alarm")
        ctx.note(f"CAUTION {time.time() - t0:.0f} s after vitals stopped (threshold {thr['partial_s']:.0f} s)")
    finally:
        vit.enabled = True
    check(ctx.settle_alarm_gone(key, 30), "partial-loss alarm did not clear")


@test("VV-EVA-02", "EVA loss of signal: LOS_WARN → LOS → CONTINGENCY", "With all suit telemetry lost, the crew member goes "
      "LOS_WARN (caution), LOS (warning) and CONTINGENCY (emergency, mode EMERGENCY, EVA NO-GO) at the configured times "
      "(±5 s), with the last known position and a search radius.", slow=True)
def eva_los(ctx: Ctx):
    vit, pos = ctx.pub["vitals"], ctx.pub["position"]
    thr = ctx.api.health("/eva")["thresholds"]
    key = f"eva.los.{VV_CREW}"
    vit.enabled = pos.enabled = False
    t0 = time.time()
    marks = {}
    for state, sev, limit in (("LOS_WARN", "caution", thr["warn_s"]), ("LOS", "warning", thr["los_s"]),
                              ("CONTINGENCY", "emergency", thr["contingency_s"])):
        c, _ = wait_until(eva_state(ctx, state), limit + 20 - (time.time() - t0), 0.5)
        check(c, f"never reached {state}: {ctx.api.crew()}")
        marks[state] = time.time() - t0
        check(abs(marks[state] - limit) <= 5 + 1.5, f"{state} after {marks[state]:.1f} s (configured {limit:.0f} s)")
        a, _ = wait_until(alarm_active(ctx, key, sev), 8, 0.5)
        check(a, f"no {sev} alarm in {state}")
    c = ctx.api.crew()
    check(c.get("last_position") and c.get("search_radius_m"), "no last position / search radius")
    check(ctx.api.summary()["mode"] == "EMERGENCY", "mode not EMERGENCY in CONTINGENCY")
    check(ctx.api.subsystem("eva")["status"] == "NO_GO", "EVA not NO-GO")
    ctx.note("; ".join(f"{k} {v:.1f} s" for k, v in marks.items())
             + f"; search radius {c['search_radius_m']:.0f} m around {c['last_position'].get('x_m')}, {c['last_position'].get('y_m')}")
    ctx.los_at = t0


@test("VV-EVA-03", "EVA recovery with suit backfill", "When contact returns the crew member is NOMINAL again, the LOS "
      "alarm clears, and the suit's stored-and-forwarded readings for the outage are accepted as delayed data.", slow=True)
def eva_recover(ctx: Ctx):
    vit, pos = ctx.pub["vitals"], ctx.pub["position"]
    t_lost = getattr(ctx, "los_at", time.time() - 60)
    # the suit replays what it logged during the outage (1 Hz here), then goes live
    t = t_lost + 1
    n = 0
    while t < time.time() - 1:
        ctx.pub.publish(vit, ctx.pub.reading(vit, round(t, 3), delayed=True))
        t += 1
        n += 1
    vit.enabled = pos.enabled = True
    c, dt = wait_until(eva_state(ctx, "NOMINAL"), 20, 0.5)
    check(c, "crew did not return to NOMINAL")
    check(ctx.settle_alarm_gone(f"eva.los.{VV_CREW}", 30), "LOS alarm did not clear")
    out, _ = wait_until(lambda: (lambda o: o[-1] if o and o[-1].get("backfilled") else None)(
        (ctx.api.crew() or {}).get("outages")), 15, 1)
    check(out, f"outage not recorded with its backfill: {(ctx.api.crew() or {}).get('outages')}")
    ctx.note(f"NOMINAL {dt:.1f} s after contact; outage of {out.get('duration_s', 0):.0f} s recorded, "
             f"{out['backfilled']} of {n} backfilled suit readings accounted to it")
    vit.enabled = pos.enabled = False
    ctx.api.health(f"/eva/{VV_CREW}/disarm", "POST")


# ══ recovery (pipeline faults) ══════════════════════════════════════
@test("VV-REC-01", "Crashed worker restarted", "A pipeline worker that crashes (telemetry-validator exits) is restarted "
      "automatically and telemetry flows again within 90 s.", disruptive=True)
def rec_crash(ctx: Ctx):
    name = ctx.container("telemetry-validator")
    started = dk.inspect(name)["State"]["StartedAt"]
    dk.exec_run(name, ["python", "-c", "import os, signal; os.kill(1, signal.SIGINT)"])
    ok, t = wait_until(lambda: dk.inspect(name)["State"]["StartedAt"] != started, 60, 1)
    check(ok, "container not restarted within 60 s")
    ctx.note(f"exited and restarted (restart policy) after {t:.0f} s")
    t = ctx.wait_flowing(90)
    ctx.note(f"telemetry flowing again {t:.0f} s later")


@test("VV-REC-02", "Hung worker detected by the watchdog and restarted by autoheal", "A pipeline worker that hangs "
      "(telemetry-processor frozen) is marked unhealthy by its heartbeat healthcheck and restarted by autoheal within "
      "4 min, reported as an advisory; its backlog is then stored.", slow=True, disruptive=True)
def rec_hang(ctx: Ctx):
    name = ctx.container("telemetry-processor")
    started = dk.inspect(name)["State"]["StartedAt"]
    dk.kill(name, "SIGSTOP")
    try:
        ok, t = wait_until(lambda: dk.inspect(name)["State"]["StartedAt"] != started, 240, 3)
        check(ok, f"not restarted (health: {dk.health(name)})")
        ctx.note(f"frozen → unhealthy → restarted by autoheal after {t:.0f} s")
    finally:
        try:
            dk.kill(name, "SIGCONT")
        except dk.DockerError:
            pass
    a, _ = wait_until(lambda: [x for x in ctx.api.alarms("autoheal") if name in x["key"]], 30, 2)
    check(a, "autoheal restart not reported to the health monitor")
    ctx.note(f"reported: {a[0]['message'][:90]}")
    check(dk.wait_healthy(name, 120), "processor not healthy after the restart")


def outage(ctx: Ctx, service: str, seconds: float, note: str):
    name = ctx.container(service)
    dk.stop(name, t=10)
    ctx.note(f"{service} stopped for {seconds:.0f} s ({note})")
    try:
        time.sleep(seconds)
    finally:
        dk.start(name)
    check(dk.wait_healthy(name, 180), f"{service} not healthy after restart")


@test("VV-REC-03", "MQTT→Kafka bridge outage without data loss", "Readings published while the bridge is down are queued "
      "by the broker (persistent session) and delivered when it returns.", disruptive=True)
def rec_bridge(ctx: Ctx):
    outage(ctx, "mqtt-kafka-bridge", 20, "broker queues for its persistent session")
    ctx.note(f"telemetry flowing {ctx.wait_flowing(90):.0f} s after restart (loss checked in VV-INT-01)")


@test("VV-REC-04", "MQTT broker restart", "A broker restart loses no acknowledged reading: publishers resend, "
      "the bridge's queued messages survive (persistence).", disruptive=True)
def rec_broker(ctx: Ctx):
    name = ctx.container("mosquitto")
    dk.restart(name, t=10)
    check(dk.wait_healthy(name, 120), "broker not healthy")
    ctx.note(f"broker restarted; telemetry flowing {ctx.wait_flowing(120):.0f} s later")


@test("VV-REC-05", "Kafka outage without data loss", "Readings arriving while Kafka is down are held by the bridge's "
      "producer and delivered when Kafka returns; the pipeline resumes by itself.", disruptive=True, slow=True)
def rec_kafka(ctx: Ctx):
    outage(ctx, "kafka", 30, "the bridge's producer buffers")
    ctx.note(f"telemetry flowing {ctx.wait_flowing(180):.0f} s after Kafka returned")


@test("VV-REC-06", "InfluxDB outage: no mock data, no loss", "While InfluxDB is down the dashboards get 503 (never made-up "
      "numbers) and the processor holds its batch; when it returns every reading is stored.", disruptive=True)
def rec_influx(ctx: Ctx):
    name = ctx.container("influxdb")
    dk.stop(name, t=10)
    try:
        time.sleep(5)
        code = ctx.api.backend("/api/telemetry/latest").status_code
        check(code == 503, f"/api/telemetry/latest answered {code} with InfluxDB down (mock data?)")
        ctx.note("InfluxDB down: /api/telemetry/latest → 503")
        time.sleep(25)
    finally:
        dk.start(name)
    check(dk.wait_healthy(name, 120), "InfluxDB not healthy")
    ok, t = wait_until(lambda: ctx.api.backend("/api/telemetry/latest").status_code == 200, 60, 2)
    check(ok, "/latest not back")
    ctx.note(f"/latest 200 again {t:.0f} s after restart")


@test("VV-REC-07", "Postgres outage: alarms keep working, then persist", "With Postgres down the health monitor keeps "
      "raising alarms from memory, queues their records, and writes them when Postgres returns.", disruptive=True)
def rec_postgres(ctx: Ctx):
    name = ctx.container("postgres")
    topic = f"habitat/health/{VV_NODE}/vv_probe"
    key = f"component.{VV_NODE}/vv_probe.state"
    dk.stop(name, t=10)
    try:
        ctx.pub.publish_raw(topic, {"node_id": VV_NODE, "component": "vv_probe", "state": "FAULT",
                                    "reason": "V&V: raised during a database outage", "timestamp": now()})
        a, t = wait_until(alarm_active(ctx, key), 20, 1)
        check(a, "no alarm while Postgres is down")
        ctx.note(f"alarm raised {t:.0f} s after the fault with Postgres down")
        time.sleep(10)
    finally:
        dk.start(name)
    check(dk.wait_healthy(name, 120), "Postgres not healthy")
    rows, t = wait_until(lambda: asyncio.run(pg_fetch("SELECT id FROM alarms WHERE alarm_key = $1 AND state <> 'closed'", key)), 90, 3)
    check(rows, "queued alarm not written after Postgres returned")
    ctx.note(f"written to Postgres {t:.0f} s after it returned")
    ctx.probe_key = key


@test("VV-ALM-05", "Alarms survive a health-monitor restart", "Open alarms (with their id and acknowledgement) and the "
      "stream registry are restored after the health monitor restarts.", disruptive=True)
def alm_restart(ctx: Ctx):
    key = getattr(ctx, "probe_key", f"component.{VV_NODE}/vv_probe.state")
    a = ctx.api.alarm(key)
    check(a, "probe alarm not open")
    ctx.api.health(f"/alarms/{a['id']}/ack", "POST")
    name = ctx.container("health-monitor")
    dk.restart(name, t=10)
    check(dk.wait_healthy(name, 180), "health monitor not healthy")
    b, t = wait_until(lambda: ctx.api.alarm(key), 60, 2)
    check(b and b["id"] == a["id"] and b["acked"], f"after restart: {b}")
    ctx.note(f"alarm {a['id']} restored acknowledged {t:.0f} s after restart")
    ctx.pub.publish_raw(f"habitat/health/{VV_NODE}/vv_probe", {"node_id": VV_NODE, "component": "vv_probe",
                                                               "state": "NOMINAL", "timestamp": now()})
    ctx.settle_alarm_gone(key, 60)


# ══ integrity ═══════════════════════════════════════════════════════
@test("VV-INT-01", "End-to-end data integrity", "Every reading the broker acknowledged during the whole test, through "
      "every injected outage, is in InfluxDB exactly once, at its own time, with its exact value.")
def int_all(ctx: Ctx):
    cutoff = time.time()                                       # the node keeps publishing: check what was sent before now
    time.sleep(20)                                             # ... after giving it time to drain
    ok, _ = wait_until(lambda: not ctx.pub.pending, 30, 1)
    pts = stored_points(ctx.t_start - 3600)
    missing, wrong, total = [], [], 0
    for r in ctx.pub.confirmed:
        if r["timestamp"] >= cutoff and not r.get("delayed"):
            continue
        s = ctx.pub.streams[r["stream"]]
        sensor = s.static.get("sensor")
        ms = int(round(r["timestamp"] * 1000))
        for metric in s.values:
            if metric in ("seq",):
                continue
            total += 1
            v = pts.get((sensor, metric, ms))
            if v is None:
                missing.append(f"{sensor}.{metric}@{ms} seq {r['seq']}")
            elif abs(v - float(r[metric])) > 1e-6:
                wrong.append(f"{sensor}.{metric}@{ms}: stored {v}, sent {r[metric]}")
    unconfirmed = len(ctx.pub.pending)
    check(not missing and not wrong, f"{len(missing)} missing, {len(wrong)} wrong of {total}: {(missing + wrong)[:5]}")
    ctx.note(f"{len(ctx.pub.confirmed)} readings / {total} values, all stored exactly"
             + (f"; {unconfirmed} never acknowledged by the broker (not counted)" if unconfirmed else ""))


@test("VV-INT-02", "Replayed data does not duplicate", "Re-sending already stored readings (a node replaying its "
      "backlog a second time, minutes later) leaves exactly one copy of each, at its own time.")
def int_replay(ctx: Ctx):
    cutoff = time.time() - 60                      # older than a minute: the case the old clamp got wrong
    rs = [r for r in ctx.pub.confirmed if r["stream"] == "o2" and r["timestamp"] < cutoff][-20:]
    check(len(rs) == 20, "not enough older o2 readings")
    t_first = rs[0]["timestamp"]
    s = ctx.pub["o2"]
    for r in rs:
        body = {k: v for k, v in r.items() if k != "stream"}
        body["delayed"] = True
        ctx.pub.publish(s, body, record=False)
    time.sleep(15)
    # the stored o2 points since t_first must be exactly the readings sent once
    stored = sorted(ms for (sensor, metric, ms) in stored_points(t_first - 1) if sensor == "o2" and metric == "o2_pct"
                    and ms >= int(round(t_first * 1000)))
    sent = sorted({int(round(r["timestamp"] * 1000)) for r in ctx.pub.confirmed
                   if r["stream"] == "o2" and r["timestamp"] >= t_first})
    extra = sorted(set(stored) - set(sent))
    check(not extra and len(stored) == len(set(stored)), f"{len(extra)} extra point(s) after the replay, e.g. {extra[:3]}")
    ctx.note(f"20 readings replayed {time.time() - t_first:.0f} s after they were taken: no duplicates "
             f"({len(stored)} points = readings sent)")


# ══ backup and disaster recovery ════════════════════════════════════
@test("VV-DR-01", "Backups fresh and intact", "The newest Postgres and InfluxDB backups are younger than two backup "
      "intervals and match their checksums.")
def dr_fresh(ctx: Ctx):
    for kind in ("postgres", "influx"):
        ok, msg = dr_drill.fresh_backup(kind)
        check(ok, f"backup {kind} failed: {msg}")
    r = dr_drill.check_backups()
    for d in r["details"]:
        ctx.note(d)
    check(r["ok"], "; ".join(r["details"]))


@test("VV-DR-02", "Postgres restore drill", "The newest Postgres dump restores into an empty server with every table's "
      "rows; restore time (RTO) recorded.", slow=True)
def dr_pg(ctx: Ctx):
    r = dr_drill.restore_postgres()
    for d in r["details"]:
        ctx.note(d)
    check(r["ok"], "; ".join(r["details"]))


@test("VV-DR-03", "InfluxDB restore drill", "The newest InfluxDB backup restores into an empty server with every sensor "
      "point of the recorded window; RTO recorded.", slow=True)
def dr_influx(ctx: Ctx):
    r = dr_drill.restore_influx()
    for d in r["details"]:
        ctx.note(d)
    check(r["ok"], "; ".join(r["details"]))


# ══ runner ══════════════════════════════════════════════════════════
def cleanup(ctx: Ctx):
    print("\nCleaning up the test node ...", flush=True)
    for s in ctx.pub.streams.values():
        s.enabled = False
    try:
        ctx.api.health(f"/eva/{VV_CREW}/disarm", "POST")
    except Exception:
        pass
    ctx.pub.close()
    try:
        r = ctx.api.health(f"/nodes/{VV_NODE}/forget", "POST")
        print(f"  {VV_NODE} decommissioned, {r['alarms_closed']} alarm(s) closed")
        for a in ctx.api.alarms(VV_CREW):
            ctx.api.health(f"/alarms/{a['id']}/ack", "POST")
    except Exception as exc:
        print(f"  could not decommission {VV_NODE}: {exc}")
    if os.getenv("VV_KEEP_DATA") != "1":
        try:
            delete_node_points(ctx.t_start)
            print(f"  test readings of {VV_NODE} deleted from InfluxDB (alarm history kept in Postgres)")
        except Exception as exc:
            print(f"  could not delete test readings: {exc}")
    for c in dk.containers():
        if c.get("Labels", {}).get("imm.vv") == "scratch":
            dk.remove(c["Id"])
    # anything a failed test left stopped or frozen
    for svc in ("telemetry-processor", "telemetry-validator", "mqtt-kafka-bridge", "kafka", "influxdb", "postgres",
                "mosquitto", "health-monitor"):
        try:
            name = ctx.container(svc)
            st = dk.inspect(name)["State"]
            if st.get("Status") == "exited":
                dk.start(name)
                print(f"  restarted {name}")
            elif st.get("Status") == "running":
                dk.kill(name, "SIGCONT")
        except Exception:
            pass


def report(results: List[dict], started: float, args) -> str:
    os.makedirs(REPORTS, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    crit_fail = [r for r in results if r["result"] == "FAIL" and r["critical"]]
    verdict = "GO" if not crit_fail and any(r["result"] == "PASS" for r in results) else "NO-GO"
    lines = [f"# IMM-OS mission readiness test: {verdict}", "",
             f"- Run: {datetime.fromtimestamp(started, timezone.utc):%Y-%m-%d %H:%M} UTC, "
             f"{(time.time() - started) / 60:.1f} min, mode {'quick' if args.quick else 'full'}",
             f"- Result: {sum(r['result'] == 'PASS' for r in results)} passed, "
             f"{sum(r['result'] == 'FAIL' for r in results)} failed "
             f"({len(crit_fail)} critical), {sum(r['result'] == 'SKIP' for r in results)} skipped",
             f"- Test node: {VV_NODE} / {VV_ZONE}, EVA crew {VV_CREW} (decommissioned afterwards)", "",
             "| ID | Test | Result | Time | Evidence |", "|---|---|---|---|---|"]
    for r in results:
        ev = "<br>".join(x.replace("|", "\\|") for x in r["evidence"]) or (r.get("error") or "").replace("|", "\\|")
        if r["result"] == "FAIL" and r.get("error"):
            ev = f"**{r['error']}**" + ("<br>" + ev if r["evidence"] else "")
        lines.append(f"| {r['id']}{'' if r['critical'] else ' (minor)'} | {r['title']} | "
                     f"{'✅ PASS' if r['result'] == 'PASS' else '❌ FAIL' if r['result'] == 'FAIL' else '⏭ SKIP'} | "
                     f"{r['seconds']:.0f} s | {ev} |")
    lines += ["", "## Requirements", ""] + [f"- **{r['id']}** {r['requirement']}" for r in results]
    md = "\n".join(lines) + "\n"
    base = os.path.join(REPORTS, f"mission-readiness-{stamp}")
    open(base + ".md", "w").write(md)
    json.dump({"verdict": verdict, "started": started, "results": results}, open(base + ".json", "w"), indent=1, default=str)
    print(f"\n{'=' * 70}\n  MISSION READINESS: {verdict}\n  report: {base}.md\n{'=' * 70}")
    return verdict


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true", help="skip the slow tests (EVA contingency wait, hang, Kafka, restore drills)")
    ap.add_argument("--no-disruptive", action="store_true", help="do not stop or kill any MCC container")
    ap.add_argument("--only", help="comma-separated test IDs")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()
    if args.list:
        for t in TESTS:
            print(f"{t['id']:10} {'slow ' if t['slow'] else '     '}{'disruptive ' if t['disruptive'] else '           '}{t['title']}")
        return 0
    only = set(args.only.split(",")) if args.only else None
    started = time.time()
    ctx = Ctx()
    print(f"IMM-OS mission readiness test: test node {VV_NODE}, crew {VV_CREW}", flush=True)
    try:                                       # leftovers of an aborted earlier run
        ctx.api.health(f"/nodes/{VV_NODE}/forget", "POST")
        ctx.api.health(f"/eva/{VV_CREW}/disarm", "POST")
    except Exception:
        pass
    ctx.pub.connect()
    results = []
    try:
        for t in TESTS:
            skip = ((only and t["id"] not in only and not t["id"].startswith("VV-PRE"))
                    or (args.quick and t["slow"]) or (args.no_disruptive and t["disruptive"]))
            r = {k: t[k] for k in ("id", "title", "requirement", "critical")}
            r.update(result="SKIP", seconds=0.0, evidence=[])
            if skip:
                results.append(r)
                continue
            print(f"\n▶ {t['id']}  {t['title']}", flush=True)
            ctx.evidence = []
            t0 = time.time()
            try:
                t["fn"](ctx)
                r["result"] = "PASS"
            except Fail as exc:
                r["result"], r["error"] = "FAIL", str(exc)
            except Exception as exc:
                r["result"], r["error"] = "FAIL", f"{type(exc).__name__}: {exc}"
                traceback.print_exc()
            r["seconds"], r["evidence"] = round(time.time() - t0, 1), list(ctx.evidence)
            print(f"  {'PASS' if r['result'] == 'PASS' else 'FAIL: ' + r.get('error', '')}  ({r['seconds']:.0f} s)", flush=True)
            results.append(r)
            if t["id"] == "VV-PRE-01" and r["result"] == "FAIL":
                print("Stack not healthy: stopping here.")
                break
    finally:
        cleanup(ctx)
    return 0 if report(results, started, args) == "GO" else 1


if __name__ == "__main__":
    sys.exit(main())
