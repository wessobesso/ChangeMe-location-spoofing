#!/usr/bin/env python3
"""
Phase 2 harness (reverse channel):
  UITest listens on-device → Mac connects over USB link-local → SET Times Square → STOP
"""
from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import threading
import time
from datetime import datetime, timezone

TOKEN = os.urandom(16).hex()
PORT = 53271
PROJECT = "/Users/wessobesso/Documents/Projects/ChangeMe/ChangeMe.xcodeproj"
LOG = "/tmp/changeme-phase2-session.log"


def iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def discover_udid() -> str:
    text = subprocess.check_output(
        ["xcrun", "xctrace", "list", "devices"], stderr=subprocess.STDOUT, text=True
    )
    in_sim = False
    for line in text.splitlines():
        if "Simulators" in line:
            in_sim = True
            continue
        if in_sim:
            continue
        if "iPhone" in line and "(" in line:
            udid = line.rsplit("(", 1)[-1].rstrip(")").strip()
            if len(udid) > 20:
                return udid
    raise SystemExit("No physical iPhone found")


def discover_device_ip() -> str:
    arp = subprocess.check_output(["arp", "-a"], text=True, errors="replace")
    usb = []
    for m in re.finditer(r"\((\d+\.\d+\.\d+\.\d+)\) at .* on (en\d+|bridge\d+)", arp):
        ip, iface = m.group(1), m.group(2)
        if ip.startswith("169.254."):
            usb.append(ip)
    if usb:
        return usb[0]
    raise SystemExit("No USB link-local iPhone IP found in arp (need en14 peer)")


def recv_line(conn: socket.socket, buf: bytearray, timeout: float) -> dict | None:
    deadline = time.time() + timeout
    conn.settimeout(0.5)
    while time.time() < deadline:
        if b"\n" in buf:
            line, _, rest = buf.partition(b"\n")
            buf[:] = rest
            if line.strip():
                return json.loads(line.decode())
        try:
            chunk = conn.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            return None
        buf.extend(chunk)
    return None


def main() -> None:
    udid = discover_udid()
    host = discover_device_ip()
    print(f"[{iso()}] device_ip={host} port={PORT} udid={udid} token={TOKEN[:8]}…", flush=True)

    env = os.environ.copy()
    env["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    env.update(
        {
            "TEST_RUNNER_CHANGEME_PORT": str(PORT),
            "TEST_RUNNER_CHANGEME_TOKEN": TOKEN,
            "TEST_RUNNER_CHANGEME_LATITUDE": "43.6426",
            "TEST_RUNNER_CHANGEME_LONGITUDE": "-79.3871",
            "CHANGEME_PORT": str(PORT),
            "CHANGEME_TOKEN": TOKEN,
            "CHANGEME_LATITUDE": "43.6426",
            "CHANGEME_LONGITUDE": "-79.3871",
        }
    )
    cmd = [
        "xcodebuild",
        "test",
        "-project",
        PROJECT,
        "-scheme",
        "ChangeMeDevice",
        "-destination",
        f"platform=iOS,id={udid}",
        "-only-testing:ChangeMeDeviceUITests/LocationSessionUITests/testRunChangeMeLocationSession",
        "-allowProvisioningUpdates",
    ]
    print(f"[{iso()}] launching xcodebuild…", flush=True)
    logf = open(LOG, "w")
    proc = subprocess.Popen(cmd, env=env, stdout=logf, stderr=subprocess.STDOUT)
    print(f"[{iso()}] xcodebuild PID={proc.pid}", flush=True)
    start_pid = proc.pid

    # Wait for listener banner in log
    deadline = time.time() + 120
    while time.time() < deadline:
        text = open(LOG, errors="replace").read()
        if "ChangeMeDIAG listening port=" in text:
            print(f"[{iso()}] device listening detected", flush=True)
            break
        if proc.poll() is not None:
            raise SystemExit("xcodebuild exited before listener started")
        time.sleep(0.25)
    else:
        proc.terminate()
        raise SystemExit("Timed out waiting for device listener")

    # Connect Mac → iPhone
    conn = None
    last_err = None
    for _ in range(40):
        try:
            conn = socket.create_connection((host, PORT), timeout=3)
            break
        except OSError as e:
            last_err = e
            time.sleep(0.5)
    if conn is None:
        proc.terminate()
        raise SystemExit(f"Could not connect to {host}:{PORT}: {last_err}")
    print(f"[{iso()}] connected to device listener", flush=True)

    def send(msg: dict) -> None:
        payload = (json.dumps(msg) + "\n").encode()
        print(f"[{iso()}] >> {msg}", flush=True)
        conn.sendall(payload)

    buf = bytearray()
    send({"type": "HELLO", "token": TOKEN, "version": 1})

    t0 = time.time()
    ready = None
    while time.time() - t0 < 90:
        msg = recv_line(conn, buf, 5)
        print(f"[{iso()}] << {msg}", flush=True)
        if not msg:
            continue
        if msg.get("type") in {"READY", "APPLIED"}:
            ready = msg
            break
        if msg.get("type") == "ERROR":
            raise SystemExit(f"ERROR: {msg}")
    if not ready:
        raise SystemExit("No READY/APPLIED")

    first_injection = time.time() - t0
    print(f"[{iso()}] FIRST_INJECTION≈{first_injection:.1f}s after connect", flush=True)

    # Same-session update
    t_update = time.time()
    send(
        {
            "type": "SET",
            "token": TOKEN,
            "id": "times-square",
            "latitude": 40.7580,
            "longitude": -73.9855,
        }
    )
    applied = None
    while time.time() - t_update < 45:
        msg = recv_line(conn, buf, 5)
        print(f"[{iso()}] << {msg}", flush=True)
        if msg and msg.get("type") == "APPLIED" and msg.get("id") == "times-square":
            applied = msg
            break
        if msg and msg.get("type") == "ERROR":
            raise SystemExit(f"SET ERROR: {msg}")
    print(f"[{iso()}] times_square_applied={applied}", flush=True)
    if not applied:
        raise SystemExit("Times Square APPLIED not received")
    print(f"[{iso()}] UPDATE_LATENCY={time.time()-t_update:.1f}s", flush=True)
    print(f"[{iso()}] SAME_XCODEBUILD_PID={start_pid} still_running={proc.poll() is None}", flush=True)

    t_stop = time.time()
    send({"type": "STOP", "token": TOKEN})
    while time.time() - t_stop < 60:
        msg = recv_line(conn, buf, 5)
        print(f"[{iso()}] << {msg}", flush=True)
        if msg and msg.get("type") == "STOPPED":
            break
    try:
        proc.wait(timeout=90)
    except subprocess.TimeoutExpired:
        proc.terminate()
        proc.wait(timeout=20)
    print(f"[{iso()}] STOP_LATENCY={time.time()-t_stop:.1f}s exit={proc.returncode}", flush=True)
    print(f"[{iso()}] PHASE2_DONE", flush=True)
    conn.close()


if __name__ == "__main__":
    main()
