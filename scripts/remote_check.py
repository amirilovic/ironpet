#!/usr/bin/env python3
"""Runtime check for the remote API against a --test-mode build with its own IRONPET_ROOT.

  swift build && python3 scripts/remote_check.py [shots-dir]

Pairs like a phone does (code, POST /v1/pair, Allow on the bubble through the test endpoint, poll), then lists tasks, accepts a
suggestion, opens the event socket and revokes the device. It never touches ~/.ironpet or the installed app.
"""
import base64
import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = tempfile.mkdtemp(prefix="ironpet-remote-")
SHOTS = sys.argv[1] if len(sys.argv) > 1 else ROOT
PORT = 47391
BIN = os.path.join(os.path.dirname(__file__), "..", ".build", "debug", "IronPet")
failures = []


def control(method, path, body=None):
    port = open(f"{ROOT}/port").read().strip()
    token = open(f"{ROOT}/token").read().strip()
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode() if body is not None else None,
                                 method=method, headers={"X-Ironpet-Token": token, "Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=10).read() or b"{}")


def remote(method, path, body=None, token=None, headers=None):
    h = {"Content-Type": "application/json", **(headers or {})}
    if token:
        h["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", data=json.dumps(body).encode() if body is not None else None, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def wait(predicate, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(0.3)
    return None


def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL"), name, detail, flush=True)
    if not ok:
        failures.append(name)


def frames(sock, count, timeout=5):  # returns early with what arrived when the socket goes quiet
    """Reads `count` unfragmented text frames from a server that does not mask."""
    sock.settimeout(timeout)
    out = []
    buf = b""
    while len(out) < count:
        while len(buf) < 2:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                return out
            if not chunk:
                return out
            buf += chunk
        opcode, length, offset = buf[0] & 0x0F, buf[1] & 0x7F, 2
        if length == 126:
            while len(buf) < 4:
                buf += sock.recv(4096)
            length, offset = int.from_bytes(buf[2:4], "big"), 4
        while len(buf) < offset + length:
            buf += sock.recv(4096)
        payload, buf = buf[offset:offset + length], buf[offset + length:]
        if opcode == 1:
            out.append(json.loads(payload))
    return out


def open_socket(token, since=None):
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    path = "/v1/events" + (f"?since={since}" if since is not None else "")
    s.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(1)
    return s, head.split(b"\r\n")[0].decode()


os.makedirs(ROOT, exist_ok=True)
json.dump({"remote": {"enabled": True, "port": PORT, "baseUrl": "https://mac.example.ts.net"}}, open(f"{ROOT}/config.json", "w"))
app = subprocess.Popen([BIN, "--test-mode"], env={**os.environ, "IRONPET_ROOT": ROOT})
try:
    wait(lambda: os.path.exists(f"{ROOT}/port") and os.path.exists(f"{ROOT}/token"), 30)
    check("remote API is listening", wait(lambda: control("GET", "/test/remote").get("running")))
    code = control("POST", "/test/remote/code")
    status, pair = remote("POST", "/v1/pair", {"code": code["code"], "device_name": "Check phone"})
    check("pair answers 202", status == 202, str(status))
    check("fingerprint matches the key", hashlib.sha256(base64.b64decode(pair.get("public_key", ""))).hexdigest() == code["fingerprint"])
    status, poll = remote("GET", f"/v1/pair/{pair['pairing_id']}", headers={"X-Pairing-Secret": pair["secret"]})
    check("poll is pending before Allow", poll.get("status") == "pending")
    pressed = control("POST", "/test/automations/bubble", {"id": f"remote-pairing:{pair['pairing_id']}", "button": "Allow"})
    check("Allow pressed on the bubble", pressed.get("ok"))
    status, poll = remote("GET", f"/v1/pair/{pair['pairing_id']}", headers={"X-Pairing-Secret": pair["secret"]})
    token = poll.get("token")
    check("poll returns the token", poll.get("status") == "allowed" and bool(token))
    check("no token without auth", remote("GET", "/v1/tasks")[0] == 401)
    control("POST", "/test/tasks/suggest", {"summary": "# Sync\n\n## Action items\n- [ ] Call the plumber (owner: Me)\n", "meeting": f"{ROOT}/meeting"})
    status, tasks = remote("GET", "/v1/tasks", token=token)
    check("GET /v1/tasks", status == 200 and "tasks" in tasks, str(status))
    status, sugg = remote("GET", "/v1/suggestions", token=token)
    items = sugg.get("suggestions", [])
    check("a suggestion is listed", status == 200 and len(items) > 0, str(sugg)[:200])
    if items:
        status, task = remote("POST", f"/v1/suggestions/{items[0]['id']}/accept", {}, token=token)
        check("accept makes a task", status == 200 and task.get("title"), str(task)[:200])
        status, detail = remote("GET", f"/v1/tasks/{task['id']}", token=token)
        by = [e["by"] for e in detail.get("history", [])]
        check("history names the device", any(b.startswith("remote:") for b in by), str(by))
    sock, line = open_socket(token)
    check("event socket upgrades", "101" in line, line)
    first = frames(sock, 1)
    check("socket says hello", first and first[0].get("kind") == "hello", str(first))
    remote("POST", "/v1/tasks", {"title": "From the check"}, token=token)
    try:
        seen = frames(sock, 3, timeout=3)
    except socket.timeout:
        seen = []
    check("socket carries tasks.changed", any(f.get("kind") == "tasks.changed" for f in seen), str(seen))
    # The window snapshot needs Screen Recording, which a headless run may lack, so a missing file is reported but does not fail the run.
    control("POST", "/test/remote/code")
    control("POST", "/test/show-settings", {"tab": "devices", "snapshot": f"{SHOTS}/devices.png"})
    time.sleep(1)
    print("NOTE devices.png written" if os.path.exists(f"{SHOTS}/devices.png") else "NOTE devices.png not written (no window server image); use --render-previews", flush=True)
    status, _ = remote("DELETE", "/v1/devices/me", token=token)
    check("revoke", status == 200)
    check("revoked token gets 401", remote("GET", "/v1/tasks", token=token)[0] == 401)
finally:
    app.terminate()
    try:
        app.wait(timeout=10)
    except subprocess.TimeoutExpired:
        app.kill()
print("FAILED: " + ", ".join(failures) if failures else "all passed")
sys.exit(1 if failures else 0)
