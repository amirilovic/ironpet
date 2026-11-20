#!/usr/bin/env python3
"""Runtime check for the remote API against a --test-mode build with its own IRONPET_ROOT.

  swift build && python3 scripts/remote_check.py [shots-dir]

Pairs like a phone does (code, POST /v1/pair, Allow on the bubble through the test endpoint, poll), then lists tasks, accepts a
suggestion, opens the event socket and revokes the device. That part runs against the loopback listener, as a `tailscale serve`
front would reach it. Then it moves the listener to this Mac's Wi-Fi address and checks the HTTPS side: which sockets the app
listens on (never a wildcard address), that the certificate's SHA-256 is the `f` of the pairing link, and, when this Mac can reach
its own address, that pairing and `GET /v1/tasks` work over TLS with that certificate pinned and that another pin is refused.
It never touches ~/.ironpet or the installed app.
"""
import base64
import hashlib
import json
import os
import re
import socket
import ssl
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


def listeners(pid):
    """The local addresses of the TCP sockets the app listens on, as lsof reports them."""
    out = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], capture_output=True, text=True).stdout
    return sorted(line[1:] for line in out.splitlines() if line.startswith("n"))


def lan_address():
    for iface in ("en0", "en1"):
        out = subprocess.run(["ipconfig", "getifaddr", iface], capture_output=True, text=True).stdout.strip()
        if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", out):
            return out
    return None


def tls_request(ip, method, path, body=None, token=None, headers=None, pin=None):
    """One HTTPS request that accepts the server only when the SHA-256 of its certificate is `pin`. Returns (status, json)."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with socket.create_connection((ip, PORT), timeout=5) as raw, context.wrap_socket(raw) as tls:
        if hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest() != pin:
            raise ssl.SSLError("certificate does not match the pin")
        payload = json.dumps(body).encode() if body is not None else b""
        head = {"Host": ip, "Content-Type": "application/json", "Content-Length": str(len(payload)), "Connection": "close", **(headers or {})}
        if token:
            head["Authorization"] = f"Bearer {token}"
        tls.sendall((f"{method} {path} HTTP/1.1\r\n" + "".join(f"{k}: {v}\r\n" for k, v in head.items()) + "\r\n").encode() + payload)
        data = b""
        while chunk := tls.recv(65536):
            data += chunk
    status = int(data.split(b" ", 2)[1])
    return status, json.loads(data.split(b"\r\n\r\n", 1)[1] or b"{}")


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
FRONT = "https://mac.example.ts.net"
json.dump({"remote": {"enabled": True, "port": PORT, "address": FRONT}}, open(f"{ROOT}/config.json", "w"))
app = subprocess.Popen([BIN, "--test-mode"], env={**os.environ, "IRONPET_ROOT": ROOT})
try:
    wait(lambda: os.path.exists(f"{ROOT}/port") and os.path.exists(f"{ROOT}/token"), 30)
    check("remote API is listening", wait(lambda: control("GET", "/test/remote").get("running")))
    code = control("POST", "/test/remote/code")
    status, pair = remote("POST", "/v1/pair", {"code": code["code"], "device_name": "Check phone"})
    check("pair answers 202", status == 202, str(status))
    check("the front link has no certificate pin", code["link"] == f"ironpet://pair?u={FRONT}&c={code['code']}", code["link"])
    check("only loopback listens before an address is chosen", listeners(app.pid) and all(a.startswith("127.0.0.1:") for a in listeners(app.pid)), str(listeners(app.pid)))
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

    # The Wi-Fi address: HTTPS on it, plain HTTP on loopback, and nothing on a wildcard address.
    ip = lan_address()
    if ip is None:
        print("NOTE no en0 address on this Mac, the HTTPS part was skipped", flush=True)
    else:
        json.dump({"remote": {"enabled": True, "port": PORT, "address": ip}}, open(f"{ROOT}/config.json", "w"))
        moved = wait(lambda: control("GET", "/test/remote").get("address") == ip)
        check("the listener moves to the chosen address", bool(moved))
        code = control("POST", "/test/remote/code")
        check("the link pins the certificate", code["link"] == f"ironpet://pair?u=https://{ip}:{PORT}&c={code['code']}&f={code['fingerprint']}", code["link"])
        check("the served certificate is the one in the link", control("GET", "/test/remote").get("served_fingerprint") == code["fingerprint"])
        found = listeners(app.pid)
        check("nothing listens on a wildcard address", not any(a.startswith(("*:", "0.0.0.0:")) for a in found), str(found))
        check("the remote port listens on loopback and the chosen address", {f"127.0.0.1:{PORT}", f"{ip}:{PORT}"} <= set(found), str(found))
        port_file = open(f"{ROOT}/port").read().strip()
        check("the hook server is loopback only", f"127.0.0.1:{port_file}" in found and not any(a.endswith(f":{port_file}") and not a.startswith("127.0.0.1") for a in found), str(found))
        try:
            status, pair = tls_request(ip, "POST", "/v1/pair", {"code": code["code"], "device_name": "TLS phone"}, pin=code["fingerprint"])
        except OSError as e:
            print(f"NOTE this Mac cannot connect to its own address {ip} ({e}); the TLS round trip is covered by RemoteSecureListenerTests on loopback", flush=True)
        else:
            check("pair over TLS with the pin", status == 202, str(status))
            control("POST", "/test/automations/bubble", {"id": f"remote-pairing:{pair['pairing_id']}", "button": "Allow"})
            _, poll = tls_request(ip, "GET", f"/v1/pair/{pair['pairing_id']}", headers={"X-Pairing-Secret": pair["secret"]}, pin=code["fingerprint"])
            status, tasks = tls_request(ip, "GET", "/v1/tasks", token=poll.get("token"), pin=code["fingerprint"])
            check("GET /v1/tasks over TLS", status == 200 and "tasks" in tasks, str(status))
            try:
                tls_request(ip, "GET", "/v1/tasks", pin="0" * 64)
                check("another pin is refused", False)
            except ssl.SSLError:
                check("another pin is refused", True)
finally:
    app.terminate()
    try:
        app.wait(timeout=10)
    except subprocess.TimeoutExpired:
        app.kill()
print("FAILED: " + ", ".join(failures) if failures else "all passed")
sys.exit(1 if failures else 0)
