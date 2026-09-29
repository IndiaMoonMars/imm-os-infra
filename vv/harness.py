"""
V&V harness: a test node that publishes like a real edge node, and clients for the
health monitor, the backend, InfluxDB and Postgres.

The test node (VV_NODE, zone VV_ZONE, EVA crew VV_CREW) publishes real (not simulated)
readings over MQTT with the edge credentials, so the health monitor treats it exactly
like hardware: its alarms count, they change the mission mode. Every reading carries a
sequence number, and every one the broker acknowledged (QoS 1 PUBACK) is recorded, so
the end-to-end integrity check can prove each one reached InfluxDB exactly, whatever
was injected in between.
"""
import json
import math
import os
import random
import threading
import time
import uuid
from typing import Callable, Dict, List, Optional

import httpx
import paho.mqtt.client as mqtt

VV_NODE = os.getenv("VV_NODE", "vv-node-01")
VV_ZONE = os.getenv("VV_ZONE", "vv-zone-a")
VV_CREW = os.getenv("VV_CREW", "vv-crew-01")
HEALTH_URL = os.getenv("VV_HEALTH_URL", "http://health-monitor:8011")
BACKEND_URL = os.getenv("VV_BACKEND_URL", "http://backend:8000")


def now() -> float:
    return round(time.time(), 3)


def wait_until(pred: Callable[[], object], timeout: float, every: float = 1.0):
    """Poll pred() until it returns something truthy; returns (value, seconds waited) or (None, timeout)."""
    t0 = time.time()
    while True:
        try:
            v = pred()
        except Exception:             # a service we just broke on purpose: keep polling
            v = None
        if v:
            return v, time.time() - t0
        if time.time() - t0 >= timeout:
            return None, time.time() - t0
        time.sleep(every)


# ── the test node ──────────────────────────────────────────────────
class Stream:
    """One periodic reading: topic, current values, optional ramps toward targets."""

    def __init__(self, name: str, topic: str, base: dict, period: float = 1.0, stored: bool = True,
                 noise: Optional[Dict[str, float]] = None):
        self.name, self.topic, self.period, self.stored = name, topic, period, stored
        self.noise = noise or {}       # like a real sensor: a perfectly constant value is "stuck"
        self.values = {k: v for k, v in base.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
        self.static = {k: v for k, v in base.items() if k not in self.values}
        self.targets: Dict[str, tuple] = {}         # metric → (target, max change per second)
        self.enabled = True
        self.extra: dict = {}                       # merged into the next readings (q, qf, ...)
        self.run = uuid.uuid4().hex[:12]
        self.seq = 0
        self.next_at = 0.0

    def ramp(self, **targets):
        """ramp(co2_ppm=(6000, 1500)): move toward 6000 at up to 1500 per second."""
        for k, (target, rate) in targets.items():
            self.targets[k] = (float(target), float(rate))

    def set(self, **values):
        for k, v in values.items():
            self.values[k] = float(v)
            self.targets.pop(k, None)

    def settled(self) -> bool:
        return not self.targets

    def _step(self, dt: float):
        for k, (target, rate) in list(self.targets.items()):
            cur = self.values.get(k, target)
            step = rate * dt
            if abs(target - cur) <= step:
                self.values[k] = target
                del self.targets[k]
            else:
                self.values[k] = cur + math.copysign(step, target - cur)


class Publisher(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.streams: Dict[str, Stream] = {}
        self.lock = threading.Lock()
        self.pending: Dict[int, dict] = {}          # mid → reading, until PUBACK
        self.confirmed: List[dict] = []             # broker-acknowledged readings
        self.early: set = set()                     # mids acknowledged before publish() returned
        self.ignore: set = set()                    # mids of messages not checked for integrity
        self.sent = 0
        self.stop_flag = threading.Event()
        c = mqtt.Client(client_id=f"imm-vv-{uuid.uuid4().hex[:8]}", clean_session=True)
        if os.getenv("MQTT_USERNAME"):
            c.username_pw_set(os.getenv("MQTT_USERNAME"), os.getenv("MQTT_PASSWORD"))
        if os.getenv("MQTT_TLS_CA"):
            c.tls_set(ca_certs=os.getenv("MQTT_TLS_CA"))
        c.max_queued_messages_set(0)                # queue everything while the broker is away
        c.max_inflight_messages_set(100)
        c.on_publish = self._on_publish
        c.reconnect_delay_set(1, 5)
        self.client = c

    def connect(self):
        self.client.connect_async(os.getenv("MQTT_HOST", "mosquitto"), int(os.getenv("MQTT_PORT", "1883")), 30)
        self.client.loop_start()
        ok, _ = wait_until(self.client.is_connected, 20, 0.2)
        if not ok:
            raise RuntimeError("V&V could not connect to the MQTT broker (edge credentials?)")
        self.start()

    def _on_publish(self, client, userdata, mid):
        # paho calls this holding its own message lock: never wait here for anything that
        # is held while calling client.publish()
        with self.lock:
            r = self.pending.pop(mid, None)
            if r is not None:
                self.confirmed.append(r)
            elif mid in self.ignore:
                self.ignore.discard(mid)
            else:
                self.early.add(mid)                 # acked before publish() returned

    def add(self, s: Stream) -> Stream:
        with self.lock:
            self.streams[s.name] = s
        return s

    def __getitem__(self, name) -> Stream:
        return self.streams[name]

    def reading(self, s: Stream, ts: float, **over) -> dict:
        s.seq += 1
        vals = {k: round(v + (random.gauss(0, s.noise[k]) if s.noise.get(k) else 0.0), 3) for k, v in s.values.items()}
        body = {**s.static, **vals, **s.extra, **over, "timestamp": ts, "seq": s.seq, "run": s.run}
        return body

    def _track(self, mid: int, record: Optional[dict]):
        with self.lock:
            self.sent += 1
            if mid in self.early:                   # already acknowledged
                self.early.discard(mid)
                if record is not None:
                    self.confirmed.append(record)
            elif record is not None:
                self.pending[mid] = record
            else:
                self.ignore.add(mid)

    def publish(self, s: Stream, body: dict, record: bool = True):
        info = self.client.publish(s.topic, json.dumps(body), qos=1)     # not under self.lock (see _on_publish)
        self._track(info.mid, {"stream": s.name, **body} if record and s.stored else None)

    def publish_raw(self, topic: str, body: dict, qos: int = 1):
        info = self.client.publish(topic, json.dumps(body), qos=qos)
        if qos:
            self._track(info.mid, None)

    def run(self):
        last = time.time()
        while not self.stop_flag.is_set():
            t = time.time()
            dt, last = t - last, t
            with self.lock:
                streams = list(self.streams.values())
            for s in streams:
                s._step(dt)
                if not s.enabled or t < s.next_at:
                    continue
                s.next_at = t + s.period
                self.publish(s, self.reading(s, now()))
            time.sleep(0.05)

    def close(self):
        self.stop_flag.set()
        time.sleep(0.5)
        wait_until(lambda: not self.pending, 15, 0.5)
        self.client.loop_stop()
        self.client.disconnect()


def build_node(pub: Publisher) -> Publisher:
    """The test node's habitat streams (1 Hz) and its EVA crew member's suit (off until the EVA tests)."""
    n, z = VV_NODE, VV_ZONE
    base = {"node_id": n, "zone": z, "simulated": False}
    pub.add(Stream("bme280", f"habitat/sensors/bme280/{z}", {**base, "sensor": "bme280", "temp": 22.0, "hum": 45.0, "pres": 1008.0},
                   noise={"temp": 0.02, "hum": 0.1, "pres": 0.05}))
    pub.add(Stream("scd40", f"habitat/sensors/scd40/{z}", {**base, "sensor": "scd40", "co2_ppm": 700.0, "temp": 22.4, "hum": 44.0},
                   noise={"co2_ppm": 4.0, "temp": 0.03, "hum": 0.15}))
    pub.add(Stream("o2", f"habitat/sensors/o2/{z}", {**base, "sensor": "o2", "o2_pct": 20.9, "calibrated": 1},
                   noise={"o2_pct": 0.01}))
    pub.add(Stream("sysmon", f"habitat/sensors/sysmon/{z}", {
        **base, "sensor": "sysmon", "cpu_temp": 52.0, "cpu_load": 20.0, "mem_pct": 40.0, "disk_pct": 30.0,
        "undervolt": 0, "svc_failed": 0, "svc_restarts": 0}, period=5.0, noise={"cpu_temp": 0.3, "cpu_load": 2.0}))
    c = VV_CREW
    vit = pub.add(Stream("vitals", f"habitat/eva/biosensors/{c}", {
        "node_id": n, "crew_id": c, "sensor": "eva_biosensor", "simulated": False,
        "hr_bpm": 92.0, "spo2_pct": 97.0, "skin_temp_c": 33.5}, noise={"hr_bpm": 1.0, "skin_temp_c": 0.05}))
    pos = pub.add(Stream("position", f"habitat/eva/position/{c}", {
        "crew_id": c, "mode": "uwb", "x_m": 12.0, "y_m": 4.0, "quality": 0.9}, stored=False))
    vit.enabled = pos.enabled = False
    return pub


# ── clients ────────────────────────────────────────────────────────
class Api:
    def __init__(self):
        self.h = {"X-IMM-Service-Token": os.environ["IMM_SERVICE_TOKEN"]}
        self.c = httpx.Client(timeout=10)

    def health(self, path: str, method: str = "GET", **kw):
        r = self.c.request(method, HEALTH_URL + "/api/health" + path, headers=self.h, **kw)
        r.raise_for_status()
        return r.json()

    def backend(self, path: str):
        return self.c.get(BACKEND_URL + path, headers=self.h)

    def summary(self) -> dict:
        return self.health("/summary")

    def alarm(self, key: str) -> Optional[dict]:
        return next((a for a in self.health("/alarms")["alarms"] if a["key"] == key), None)

    def alarms(self, contains: str = "") -> List[dict]:
        return [a for a in self.health("/alarms")["alarms"] if contains in a["key"]]

    def stream(self, sensor: str, node: str = VV_NODE) -> Optional[dict]:
        for s in self.health("/streams")["streams"]:
            if f"{node}|{sensor}|" in s["key"] or (s.get("node") == node and s.get("sensor") == sensor):
                return s
        return None

    def measurement(self, name: str) -> Optional[dict]:
        return next((m for m in self.health("/measurements")["measurements"]
                     if m["measurement"] == name and m["node_id"] == VV_NODE and m["zone"] == VV_ZONE), None)

    def subsystem(self, sid: str) -> Optional[dict]:
        return next((s for s in self.summary()["subsystems"] if s["id"] == sid), None)

    def crew(self, crew: str = VV_CREW) -> Optional[dict]:
        return next((c for c in self.health("/eva")["crews"] if c["crew_id"] == crew), None)


def influx_client():
    from influxdb_client import InfluxDBClient
    return InfluxDBClient(url=os.getenv("INFLUX_URL", "http://influxdb:8086"),
                          token=os.getenv("INFLUX_TOKEN", ""), org=os.getenv("INFLUX_ORG", "imm_org"), timeout=30000)


def stored_points(start: float, node: str = VV_NODE) -> Dict[tuple, float]:
    """(sensor, metric, epoch ms) → value for every stored point of the node since start."""
    q = f'''from(bucket: "habitat_sensors")
      |> range(start: {int(start) - 1}, stop: {int(time.time()) + 120})
      |> filter(fn: (r) => r.node_id == "{node}" and r._field == "value")
      |> keep(columns: ["_time", "_value", "_measurement", "metric"])'''
    out = {}
    with influx_client() as c:
        for table in c.query_api().query(q):
            for rec in table.records:
                ms = int(round(rec.get_time().timestamp() * 1000))
                out[(rec.values["_measurement"], rec.values["metric"], ms)] = rec.get_value()
    return out


def delete_node_points(start: float, node: str = VV_NODE) -> None:
    from datetime import datetime, timezone
    with influx_client() as c:
        c.delete_api().delete(datetime.fromtimestamp(start - 7200, timezone.utc), datetime.now(timezone.utc),
                              f'node_id="{node}"', bucket="habitat_sensors", org=os.getenv("INFLUX_ORG", "imm_org"))


async def pg_fetch(sql: str, *args):
    import asyncpg
    c = await asyncpg.connect(user=os.getenv("POSTGRES_USER", "admin"), password=os.getenv("POSTGRES_PASSWORD", ""),
                              database=os.getenv("POSTGRES_DB", "imm_db"), host=os.getenv("POSTGRES_HOST", "postgres"),
                              timeout=10)
    try:
        return await c.fetch(sql, *args)
    finally:
        await c.close()
