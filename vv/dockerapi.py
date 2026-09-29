"""
Minimal Docker Engine API client over /var/run/docker.sock (stdlib only), for the V&V
runner's fault injection: stop/start/kill/restart containers, run commands in them,
and run the scratch containers of the restore drill.
"""
import http.client
import json
import os
import socket
import struct
import time
import urllib.parse
from typing import Dict, List, Optional

SOCKET = os.getenv("DOCKER_SOCKET", "/var/run/docker.sock")


class DockerError(RuntimeError):
    pass


class _Conn(http.client.HTTPConnection):
    def __init__(self, timeout: float):
        super().__init__("localhost", timeout=timeout)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(SOCKET)


def call(method: str, path: str, body=None, timeout: float = 60, raw: bool = False):
    conn = _Conn(timeout)
    try:
        data = None if body is None else json.dumps(body).encode()
        conn.request(method, path, body=data, headers={"Host": "docker", "Content-Type": "application/json"})
        r = conn.getresponse()
        out = r.read()
        if r.status >= 400:
            raise DockerError(f"{method} {path}: HTTP {r.status} {out[:300]!r}")
        if raw:
            return out
        return json.loads(out) if out and out[:1] in (b"{", b"[") else out
    finally:
        conn.close()


def containers(all_: bool = True) -> List[dict]:
    return call("GET", f"/containers/json?all={1 if all_ else 0}")


def find(name: str) -> Optional[dict]:
    for c in containers():
        if any(n.lstrip("/") == name for n in c.get("Names", [])):
            return c
    return None


def inspect(name: str) -> dict:
    return call("GET", f"/containers/{urllib.parse.quote(name)}/json")


def health(name: str) -> str:
    """healthy | unhealthy | starting | none | exited | paused ..."""
    st = inspect(name)["State"]
    if st.get("Status") != "running":
        return st.get("Status", "unknown")
    return (st.get("Health") or {}).get("Status", "none")


def stop(name: str, t: int = 10) -> None:
    call("POST", f"/containers/{urllib.parse.quote(name)}/stop?t={t}", timeout=t + 60)


def start(name: str) -> None:
    call("POST", f"/containers/{urllib.parse.quote(name)}/start")


def restart(name: str, t: int = 10) -> None:
    call("POST", f"/containers/{urllib.parse.quote(name)}/restart?t={t}", timeout=t + 60)


def kill(name: str, signal: str = "SIGKILL") -> None:
    call("POST", f"/containers/{urllib.parse.quote(name)}/kill?signal={signal}")


def remove(name: str) -> None:
    try:
        call("DELETE", f"/containers/{urllib.parse.quote(name)}?force=1&v=1")
    except DockerError:
        pass


def exec_run(name: str, cmd: List[str], env: Optional[List[str]] = None, timeout: float = 300):
    """Run cmd in a running container; returns (exit code, combined output)."""
    ex = call("POST", f"/containers/{urllib.parse.quote(name)}/exec",
              {"Cmd": cmd, "AttachStdout": True, "AttachStderr": True, "Env": env or []})
    raw = call("POST", f"/exec/{ex['Id']}/start", {"Detach": False, "Tty": False}, timeout=timeout, raw=True)
    out, i = [], 0
    while i + 8 <= len(raw):                       # multiplexed stream: 8-byte frame headers
        size = struct.unpack(">I", raw[i + 4:i + 8])[0]
        out.append(raw[i + 8:i + 8 + size])
        i += 8 + size
    code = call("GET", f"/exec/{ex['Id']}/json").get("ExitCode")
    return code, b"".join(out).decode("utf-8", "replace")


def run(name: str, image: str, env: Dict[str, str] = None, binds: List[str] = None, network: str = None,
        cmd: List[str] = None) -> None:
    """Create and start a scratch container (removed first if it exists)."""
    remove(name)
    body = {"Image": image, "Env": [f"{k}={v}" for k, v in (env or {}).items()],
            "HostConfig": {"Binds": binds or [], "NetworkMode": network or "bridge"},
            "Labels": {"imm.vv": "scratch"}}
    if cmd:
        body["Cmd"] = cmd
    call("POST", f"/containers/create?name={urllib.parse.quote(name)}", body)
    start(name)


def self_container() -> Optional[dict]:
    """This container (the V&V runner) as Docker sees it, or None outside Docker."""
    try:
        return inspect(socket.gethostname())
    except DockerError:
        return None


def wait_healthy(name: str, timeout: float) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        try:
            if health(name) in ("healthy", "none"):
                return True
        except DockerError:
            pass
        time.sleep(2)
    return False
