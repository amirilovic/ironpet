#!/usr/bin/env python3
"""Runtime check for a chat with a very long transcript: idle CPU and responsiveness, then a 2,000 token stream.

Usage: long_transcript_check.py <IronPet.app> <thread.json>
Launches the app in test mode with its own IRONPET_ROOT, seeds the chat, leaves it idle for 30 s while sampling CPU
and the response time of GET /test/chat, then streams 2,000 tokens and reports the slowest response and the footprint.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

app, thread = sys.argv[1], sys.argv[2]
root = tempfile.mkdtemp(prefix="ironpet-long-")
env = {**os.environ, "IRONPET_ROOT": root}
proc = subprocess.Popen([f"{app}/Contents/MacOS/IronPet", "--test-mode", "-chatAttachments", "()", "-chatDraft", "", "-chatThread", ""],
                        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def call(method, path, body=None, timeout=60):
    port = open(f"{root}/port").read().strip()
    token = open(f"{root}/token").read().strip()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method,
                                 headers={"X-Ironpet-Token": token, "Content-Type": "application/json"})
    start = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return (json.loads(raw) if raw else {}), time.time() - start


def cpu_seconds():
    out = subprocess.run(["ps", "-o", "cputime=", "-p", str(proc.pid)], capture_output=True, text=True).stdout.strip()
    total = 0.0
    for part in (out or "0").split(":"):  # [[H:]MM:]SS.ss
        total = total * 60 + float(part)
    return total


def footprint():
    out = subprocess.run(["footprint", str(proc.pid)], capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if "Footprint" in l or "phys_footprint" in l][:2]


try:
    for _ in range(60):
        if os.path.exists(f"{root}/port"):
            break
        time.sleep(0.5)
    time.sleep(2)
    t = time.time()
    try:
        r, _ = call("POST", "/test/seed-transcript", {"file": thread}, timeout=120)
    except Exception as e:
        r = {"error": str(e)}
    print("seed:", r, f"returned after {time.time() - t:.1f}s")
    samples, worst = [], 0.0
    last_cpu, last_time = cpu_seconds(), time.time()
    for sec in range(30):
        time.sleep(1)
        try:
            _, dt = call("GET", "/test/chat", timeout=20)
        except Exception as e:
            dt = 20.0
        worst = max(worst, dt)
        now_cpu, now = cpu_seconds(), time.time()
        samples.append(100 * (now_cpu - last_cpu) / (now - last_time))  # CPU used in this window, in percent
        last_cpu, last_time = now_cpu, now
    after = samples[5:]
    print(f"S1 idle: avg cpu after 5 s {sum(after) / len(after):.1f}%, max {max(after):.1f}%, slowest response {worst:.2f}s")
    print("footprint idle:", footprint())
    call("POST", "/test/stream-reply", {"tokens": 2000}, timeout=30)
    worst = 0.0
    for _ in range(60):
        time.sleep(0.25)
        try:
            _, dt = call("GET", "/test/chat", timeout=20)
        except Exception:
            dt = 20.0
        worst = max(worst, dt)
    print(f"S2 streaming: slowest response {worst:.2f}s")
    print("footprint after stream:", footprint())
finally:
    proc.terminate()
    proc.wait()
    shutil.rmtree(root, ignore_errors=True)
