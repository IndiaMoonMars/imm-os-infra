# Mission readiness test (V&V with fault injection)

`mission_readiness.py` checks the running MCC stack end to end. It deliberately breaks
things and verifies that:
- the faults are detected and alarmed;
- the system degrades safely and recovers by itself;
- no data is lost.

Each test verifies one requirement of the V&V plan (imm-os-docs `vv-plan.md`). The result
is a GO / NO-GO report.

```powershell
# on the MCC PC, in imm-os-infra (the stack must be up)
.\scripts\mission-readiness.ps1                  # everything, ~30 min
.\scripts\mission-readiness.ps1 --quick          # skip the slow tests, ~12 min
.\scripts\mission-readiness.ps1 --no-disruptive  # never stop or kill an MCC container
.\scripts\mission-readiness.ps1 --only VV-EVA-02,VV-REC-05
.\scripts\mission-readiness.ps1 --list
.\scripts\dr-drill.ps1                           # only the backup restore drill
```

(Linux: `scripts/mission-readiness.sh`, `scripts/dr-drill.sh`.)

The report is written to `vv/reports/mission-readiness-<UTC time>.md` (and `.json`).
The exit code is 0 for GO.

## What it does to the system

- **Test node.** It adds a test node, `vv-node-01` (zone `vv-zone-a`, EVA crew
  `vv-crew-01`), which publishes over MQTT with the edge credentials, exactly like a
  Raspberry Pi. Its data is **real, not simulated**, so its alarms are real alarms: they
  change the mission mode and appear on every console. **Run it before a mission or in a
  planned test window, not during live operations.**
- **Container faults.** It injects faults through the Docker API:
  - it crashes the validator;
  - it freezes the processor (SIGSTOP), which the watchdog plus autoheal must fix;
  - it stops and restarts the MQTT bridge, the broker, Kafka, InfluxDB and Postgres;
  - it restarts the health monitor.

  Each fault is undone in a `finally` block, and at the end it restarts anything left
  stopped.
- **Scratch containers.** The restore drill uses scratch containers (`imm-vv-dr-*`) and
  never touches live data.
- **Cleanup.** At the end it decommissions the test node (its alarms close; the history
  stays in Postgres) and deletes the test node's readings from InfluxDB. Set
  `VV_KEEP_DATA=1` to keep them.

## Tests

| ID | What is verified |
|---|---|
| VV-PRE-01/02 | stack healthy; nominal data raises no alarm |
| VV-ALM-01 | CO₂ > 5000 ppm → one WARNING within 15 s, ack, clear, close |
| VV-ALM-02 | CO₂ > 20000 ppm → escalation to EMERGENCY, mode EMERGENCY, atmosphere NO-GO, new ack needed |
| VV-ALM-03 | no alarm flooding: one database row per episode, full event trail |
| VV-ALM-04 | suspect data → UNVERIFIED alarm, capped at WARNING |
| VV-ALM-05 | open alarms (id, ack) survive a health-monitor restart |
| VV-DET-01..05 | out-of-range rejected; rate glitch; dew-point cross-check; sequence gaps; backfill stored at its time without alarm |
| VV-RED-01/02 | failover to the redundant temperature sensor; loss of critical CO₂ monitoring → NO-GO |
| VV-EDGE-01 | edge component in SAFE mode → WARNING, node DEGRADED |
| VV-EVA-01..03 | partial loss; LOS_WARN → LOS → CONTINGENCY at the configured times; recovery with suit backfill |
| VV-REC-01..07 | crash, hang (watchdog + autoheal), bridge / broker / Kafka / InfluxDB / Postgres outages |
| VV-INT-01/02 | every reading the broker accepted is stored once, at its time, with its value; replays don't duplicate |
| VV-DR-01..03 | backups fresh and intact; Postgres and InfluxDB restore drills with RTO |

A **critical** failure makes the verdict NO-GO. VV-DET-04 is informational.
