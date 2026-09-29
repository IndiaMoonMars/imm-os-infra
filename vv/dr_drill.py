"""
Disaster-recovery drill: prove the backups restore, without touching production.

  1. (optional) take a fresh backup now, in the backup containers (scripts/backup/backup.sh once)
  2. start scratch Postgres / InfluxDB containers (same images) on the stack's network
  3. restore the newest Postgres dump and InfluxDB backup into them
  4. verify: every table's row count lies between the counts recorded just before and
     just after the dump; the InfluxDB sensor points in the recorded window match
  5. report the restore time (RTO) and the age of the backup (RPO), remove the scratch containers

Standalone:  docker compose --profile vv run --rm vv python -u /vv/dr_drill.py
"""
import asyncio
import glob
import hashlib
import os
import secrets
import sys
import time
from typing import Dict, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dockerapi as dk  # noqa: E402

BACKUPS = os.getenv("VV_BACKUPS", "/backups")
INTERVAL_H = float(os.getenv("BACKUP_INTERVAL_H", "6"))
PG_IMAGE = os.getenv("VV_PG_IMAGE", "postgres:15-alpine")
INFLUX_IMAGE = os.getenv("VV_INFLUX_IMAGE", "influxdb:2.7-alpine")
PG_NAME, INFLUX_NAME = "imm-vv-dr-postgres", "imm-vv-dr-influx"


def newest(kind: str, pattern: str) -> Optional[str]:
    files = sorted(glob.glob(os.path.join(BACKUPS, kind, pattern)), key=os.path.getmtime)
    return files[-1] if files else None


def sha_ok(path: str) -> bool:
    try:
        want = open(path + ".sha256").read().split()[0]
    except OSError:
        return False
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest() == want


def read_counts(path: str) -> Dict[str, int]:
    out = {}
    for line in open(path):
        parts = line.split()
        if len(parts) == 2:
            out[parts[0]] = int(parts[1])
    return out


def container_for(kind: str) -> Optional[str]:
    for c in dk.containers(all_=False):
        if c.get("Labels", {}).get("com.docker.compose.service") == f"backup-{kind}":
            return c["Names"][0].lstrip("/")
    return None


def fresh_backup(kind: str) -> Tuple[bool, str]:
    name = container_for(kind)
    if not name:
        return False, f"backup-{kind} container not running"
    code, out = dk.exec_run(name, ["/bin/sh", "/scripts/backup.sh", kind, "once"], timeout=900)
    return code == 0, out.strip().splitlines()[-1] if out.strip() else f"exit {code}"


def check_backups() -> dict:
    """Newest backups exist, are fresh enough and match their checksums."""
    res = {"ok": True, "details": []}
    for kind, pattern in (("postgres", "imm_db-*.dump"), ("influx", "influx-*.tar.gz")):
        f = newest(kind, pattern)
        if not f:
            res["ok"] = False
            res["details"].append(f"{kind}: no backup in {BACKUPS}/{kind}")
            continue
        age_h = (time.time() - os.path.getmtime(f)) / 3600
        fresh = age_h <= 2 * INTERVAL_H + 0.5
        good = sha_ok(f)
        res["ok"] &= fresh and good
        res["details"].append(f"{kind}: {os.path.basename(f)}, {age_h:.1f} h old, "
                              f"{os.path.getsize(f) / 1e6:.1f} MB, checksum {'ok' if good else 'MISMATCH'}"
                              + ("" if fresh else f" (older than {2 * INTERVAL_H:.0f} h)"))
    return res


def _env():
    me = dk.self_container()
    if me is None:
        raise RuntimeError("the DR drill runs inside the vv container (docker compose --profile vv run --rm vv ...)")
    network = next(iter(me["NetworkSettings"]["Networks"]))
    src = next((m["Source"] for m in me["Mounts"] if m["Destination"] == BACKUPS), None)
    if not src:
        raise RuntimeError(f"{BACKUPS} is not a mounted folder")
    return network, src


def restore_postgres() -> dict:
    import asyncpg
    dump = newest("postgres", "imm_db-*.dump")
    if not dump:
        return {"ok": False, "details": ["no Postgres dump"]}
    before, after = read_counts(dump + ".counts-before"), read_counts(dump + ".counts-after")
    network, src = _env()
    pw = secrets.token_hex(12)
    t0 = time.time()
    try:
        dk.run(PG_NAME, PG_IMAGE, env={"POSTGRES_PASSWORD": pw, "POSTGRES_DB": "imm_db"},
               binds=[f"{src}:/backups:ro"], network=network)
        ready = False
        for _ in range(90):                       # TCP answers only once init has finished
            code, _ = dk.exec_run(PG_NAME, ["pg_isready", "-h", "127.0.0.1", "-U", "postgres"])
            if code == 0:
                ready = True
                break
            time.sleep(1)
        if not ready:
            return {"ok": False, "details": ["scratch Postgres did not start"]}
        rel = os.path.relpath(dump, BACKUPS)
        code, out = dk.exec_run(PG_NAME, ["pg_restore", "-h", "127.0.0.1", "-U", "postgres", "-d", "imm_db",
                                          "--no-owner", "--no-privileges", f"/backups/{rel}"], timeout=1800)
        if code != 0:
            return {"ok": False, "details": [f"pg_restore failed ({code}): {out[-400:]}"]}

        async def counts():
            c = await asyncpg.connect(host=PG_NAME, user="postgres", password=pw, database="imm_db", timeout=10)
            try:
                rows = await c.fetch("""
                    SELECT table_name, (xpath('/row/c/text()', query_to_xml(
                        format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text AS n
                    FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'""")
                return {r["table_name"]: int(r["n"]) for r in rows}
            finally:
                await c.close()
        got = asyncio.run(counts())
        rto = time.time() - t0
        bad = []
        for table, b in before.items():
            a = after.get(table, b)
            n = got.get(table)
            if n is None or not (min(a, b) <= n <= max(a, b)):
                bad.append(f"{table}: restored {n}, expected {b}..{a}")
        rows = sum(got.values())
        details = [f"{os.path.basename(dump)}: {len(got)} tables, {rows} rows restored in {rto:.0f} s",
                   f"backup age (RPO now) {(time.time() - os.path.getmtime(dump)) / 60:.0f} min"]
        details += bad[:10]
        return {"ok": not bad and len(got) >= len(before), "details": details, "rto_s": round(rto, 1), "rows": rows}
    finally:
        dk.remove(PG_NAME)


def restore_influx() -> dict:
    from influxdb_client import InfluxDBClient
    tarball = newest("influx", "influx-*.tar.gz")
    if not tarball:
        return {"ok": False, "details": ["no InfluxDB backup"]}
    meta = dict(line.split(None, 1) for line in open(tarball + ".counts").read().strip().splitlines())
    expect = int(meta.get("points", "0").strip() or 0)
    network, src = _env()
    token = secrets.token_hex(24)
    t0 = time.time()
    try:
        dk.run(INFLUX_NAME, INFLUX_IMAGE, network=network, binds=[f"{src}:/backups:ro"], env={
            "DOCKER_INFLUXDB_INIT_MODE": "setup", "DOCKER_INFLUXDB_INIT_USERNAME": "vv-drill",
            "DOCKER_INFLUXDB_INIT_PASSWORD": secrets.token_hex(12), "DOCKER_INFLUXDB_INIT_ORG": "vv-drill",
            "DOCKER_INFLUXDB_INIT_BUCKET": "vv-drill", "DOCKER_INFLUXDB_INIT_ADMIN_TOKEN": token})
        env = [f"INFLUX_TOKEN={token}", "INFLUX_HOST=http://127.0.0.1:8086"]
        ready = False
        for _ in range(90):
            code, _ = dk.exec_run(INFLUX_NAME, ["influx", "bucket", "list", "--name", "vv-drill"], env=env)
            if code == 0:
                ready = True
                break
            time.sleep(1)
        if not ready:
            return {"ok": False, "details": ["scratch InfluxDB did not start"]}
        rel = os.path.relpath(tarball, BACKUPS)
        folder = os.path.basename(tarball)[:-len(".tar.gz")]
        code, out = dk.exec_run(INFLUX_NAME, ["sh", "-c", f"tar xzf /backups/{rel} -C /tmp && influx restore --full /tmp/{folder}"],
                                env=env, timeout=1800)
        if code != 0:
            return {"ok": False, "details": [f"influx restore failed ({code}): {out[-400:]}"]}
        # a full restore brings back the production tokens: query with the real one
        got = None
        for _ in range(30):
            try:
                with InfluxDBClient(url=f"http://{INFLUX_NAME}:8086", token=os.getenv("INFLUX_TOKEN", ""),
                                    org=os.getenv("INFLUX_ORG", "imm_org"), timeout=30000) as c:
                    q = f'''from(bucket: "habitat_sensors") |> range(start: {meta["start"].strip()}, stop: {meta["stop"].strip()})
                            |> filter(fn: (r) => r._field == "value") |> group() |> count()'''
                    tables = c.query_api().query(q)
                    got = sum(r.get_value() for t in tables for r in t.records)
                    break
            except Exception:
                time.sleep(2)
        rto = time.time() - t0
        ok = got is not None and got == expect
        return {"ok": ok, "rto_s": round(rto, 1), "points": got, "details": [
            f"{os.path.basename(tarball)}: restored in {rto:.0f} s; {got} sensor points in "
            f"{meta['start'].strip()}..{meta['stop'].strip()} (backup recorded {expect})"]}
    finally:
        dk.remove(INFLUX_NAME)


def main() -> int:
    for kind in ("postgres", "influx"):
        ok, msg = fresh_backup(kind)
        print(f"fresh {kind} backup: {'ok' if ok else 'FAILED'}: {msg}")
    results = {"backups": check_backups(), "postgres": restore_postgres(), "influx": restore_influx()}
    for name, r in results.items():
        print(f"{'PASS' if r['ok'] else 'FAIL'}  {name}")
        for d in r["details"]:
            print("      " + d)
    return 0 if all(r["ok"] for r in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
