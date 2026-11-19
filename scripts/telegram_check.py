#!/usr/bin/env python3
"""Runtime check for the Telegram connection against scripts/fake_telegram.py, with an isolated ironpet.

  swift build && python3 scripts/telegram_check.py [shots-dir]

Covers the setup, pairing, form and error scenarios. The chat round trip needs a real agent, so it is covered by
TelegramTests and by a manual check with a real bot.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = tempfile.mkdtemp(prefix="ironpet-tg-")
SHOTS = sys.argv[1] if len(sys.argv) > 1 else ROOT
PORT = 18099
BIN = os.path.join(os.path.dirname(__file__), "..", ".build", "debug", "IronPet")
failures = []


def call(method, path, body=None):
    port = open(f"{ROOT}/port").read().strip()
    token = open(f"{ROOT}/token").read().strip()
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode() if body is not None else None,
                                 method=method, headers={"X-Ironpet-Token": token, "Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=10).read() or b"{}")


def fake(method, path, body=None):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", data=json.dumps(body).encode() if body is not None else None, method=method)
    return json.loads(urllib.request.urlopen(req, timeout=10).read())


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


server = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(__file__), "fake_telegram.py"), str(PORT)])
app = subprocess.Popen([BIN, "--test-mode"], env={**os.environ, "IRONPET_ROOT": ROOT, "IRONPET_TELEGRAM_API": f"http://127.0.0.1:{PORT}"})
try:
    wait(lambda: os.path.exists(f"{ROOT}/port") and os.path.exists(f"{ROOT}/token"), 30)
    time.sleep(1)
    # S1
    check("S1 token saved", call("POST", "/test/telegram/token", {"token": "111:SECRETTOKEN"}).get("ok"))
    call("POST", "/test/telegram/test")
    result = wait(lambda: call("GET", "/test/telegram")["test"] not in ("", "running") and call("GET", "/test/telegram")["test"])
    check("S1 Test shows the bot username", result == "@ghost_fake_bot", str(result))
    config = open(f"{ROOT}/config.json").read() if os.path.exists(f"{ROOT}/config.json") else ""
    check("S1 token is not in config.json", "SECRETTOKEN" not in config)
    call("POST", "/test/show-settings", {"tab": "integrations", "snapshot": f"{SHOTS}/integrations-setup.png"})
    # S2
    call("POST", "/test/telegram/enable", {"enabled": True})
    check("S2 polling starts", wait(lambda: call("GET", "/test/telegram")["status"].startswith("polling")))
    fake("POST", "/_push", {"from": 10, "name": "Ann", "username": "ann", "text": "/start"})
    check("S2 pairing request appears", wait(lambda: [p["id"] for p in call("GET", "/test/telegram")["pending"]] == [10]))
    call("POST", "/test/show-settings", {"tab": "integrations", "snapshot": f"{SHOTS}/integrations-pending.png"})
    call("POST", "/test/telegram/allow", {"id": 10})
    check("S2 Allow adds the user", [u["id"] for u in call("GET", "/test/telegram")["users"]] == [10])
    fake("POST", "/_push", {"from": 11, "name": "Bob", "text": "/start"})
    time.sleep(2)
    check("S2 a second stranger is ignored", call("GET", "/test/telegram")["pending"] == [])
    texts = [m["text"] for m in fake("GET", "/_sent")["sent"] if m["chat"] == 11]
    check("S2 the stranger gets no reply", texts == [], str(texts))
    # S7 at runtime: a stranger's text never reaches the chat.
    fake("POST", "/_push", {"from": 12, "name": "Eve", "text": "hello agent"})
    time.sleep(2)
    check("S7 stranger text stays out of the chat", call("GET", "/test/chat")["items"] == [])
    # S10 and S11 at runtime: replies only, so no agent turn starts.
    fake("POST", "/_push", {"from": 10, "document": {"file_id": "big", "file_name": "huge.zip", "file_size": 25 * 1048576}})
    big = wait(lambda: [m["text"] for m in fake("GET", "/_sent")["sent"] if "20 MB" in m["text"]])
    check("S10 oversized file gets a size reply", bool(big), str(big))
    fake("POST", "/_file", {"file_id": "v1", "path": "voice/file_0.oga", "content": "OggS"})
    fake("POST", "/_push", {"from": 10, "voice": {"file_id": "v1", "file_size": 4}})
    off = wait(lambda: [m["text"] for m in fake("GET", "/_sent")["sent"] if "Settings → Voice" in m["text"]])
    check("S11 voice message with voice notes off gets an error reply", bool(off), str(off))
    check("S10/S11 nothing reached the chat", call("GET", "/test/chat")["items"] == [])
    # Forms: S1 (shown), S2 (answered from Telegram), S3 (answered on the Mac).
    def options(*names):
        return [{"const": n, "title": n.upper()} for n in names]
    def form(message):
        return {"mode": "form", "message": message, "requestedSchema": {"type": "object", "required": ["question_0"], "properties": {
            "question_0": {"type": "string", "title": "Runner", "oneOf": options("a", "b")},
            "question_1": {"type": "string", "title": "Mode", "oneOf": options("x", "y")},
            "question_2": {"type": "string", "title": "Size", "oneOf": options("s", "m")}}}}
    def sent_after(count):
        return fake("GET", "/_sent")["sent"][count:]
    before = len(fake("GET", "/_sent")["sent"])
    check("form opens", call("POST", "/test/form", form("Form one")).get("ok"))
    shown = wait(lambda: len(sent_after(before)) >= 4 and sent_after(before))
    check("S1 header and one message per question", bool(shown) and shown[0]["text"].startswith("Form one"), str(shown))
    if shown:
        questions = shown[1:4]
        buttons = [[b for row in m["reply_markup"]["inline_keyboard"] for b in row] for m in questions]
        check("S1 one button per option", [len(b) for b in buttons] == [2, 3, 3], str([len(b) for b in buttons]))
        check("S1 callback data under 64 bytes", all(len(b["callback_data"].encode()) <= 64 for row in buttons for b in row))
        for message, row in zip(questions, buttons):
            fake("POST", "/_tap", {"from": 10, "data": row[0]["callback_data"], "message_id": message["message_id"]})
        state = wait(lambda: call("GET", "/test/form").get("reply"))
        check("S2 the agent gets an accept with the choices", bool(state) and state["action"] == "accept"
              and state["content"] == {"question_0": "a", "question_1": "x", "question_2": "s"}, str(state))
        check("S2 the Mac shows the answered record", call("GET", "/test/form").get("record", {}).get("answers") == ["A", "X", "S"])
        edits = wait(lambda: len(fake("GET", "/_edits")["edits"]) >= 4 and fake("GET", "/_edits")["edits"])
        check("S2 the Telegram messages show the answers", bool(edits) and any("Answer: A" in e["text"] for e in edits), str(edits))
    before = len(fake("GET", "/_sent")["sent"])
    edits_before = len(fake("GET", "/_edits")["edits"])
    call("POST", "/test/form", form("Form two"))
    shown = wait(lambda: len(sent_after(before)) >= 4 and sent_after(before))
    call("POST", "/test/form/answer", {"skip": True})
    closed = wait(lambda: len(fake("GET", "/_edits")["edits"]) - edits_before >= 4 and fake("GET", "/_edits")["edits"][edits_before:])
    check("S3 Mac answer closes every Telegram message", bool(closed) and all(e["text"].endswith("Skipped on the Mac.") and not e.get("reply_markup") for e in closed), str(closed))
    if shown:
        row = shown[1]["reply_markup"]["inline_keyboard"][0][0]
        answers_before = len(fake("GET", "/_edits")["answers"])
        fake("POST", "/_tap", {"from": 10, "data": row["callback_data"], "message_id": shown[1]["message_id"]})
        late = wait(lambda: len(fake("GET", "/_edits")["answers"]) > answers_before and fake("GET", "/_edits")["answers"][-1])
        check("S3 a late tap is refused", late == "This form is no longer open.", str(late))
    # S6
    fake("POST", "/_mode", {"mode": "401"})
    status = wait(lambda: call("GET", "/test/telegram")["status"].startswith("error") and call("GET", "/test/telegram")["status"])
    check("S6 invalid token shows in the status", bool(status), str(status))
    call("POST", "/test/show-settings", {"tab": "integrations", "snapshot": f"{SHOTS}/integrations-error.png"})
    check("S6 the app still answers", "state" in call("GET", "/test/chat"))
    fake("POST", "/_mode", {"mode": "409"})
    status = wait(lambda: "409" in call("GET", "/test/telegram")["status"] and call("GET", "/test/telegram")["status"], 30)
    check("S6 409 shows in the status", bool(status), str(status))
    check("S6 no bubbles piled up", call("GET", "/test/telegram")["pending"] == [])
finally:
    app.terminate()
    server.terminate()
print("FAILED:" if failures else "all passed", failures)
sys.exit(1 if failures else 0)
