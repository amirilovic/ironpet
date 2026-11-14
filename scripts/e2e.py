#!/usr/bin/env python3
"""End-to-end checks for ironpet against real agent runs.

Relaunches /Applications/IronPet.app with --test-mode, drives it through its /test/* endpoints (the same
code paths as clicking in the UI), checks results on disk and in iTerm, then relaunches it normally.
Usage: python3 scripts/e2e.py [scenario ...]
With no arguments, runs every scenario except those in OPT_IN, which need extra setup (see below).
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
# IRONPET_APP and IRONPET_ROOT run a second copy of the app with its own port, token and threads, so a run does not
# disturb the installed app. Without them the scenarios drive /Applications/IronPet.app and ~/.ironpet.
APP = os.environ.get("IRONPET_APP", "/Applications/IronPet.app")
ROOT = os.environ.get("IRONPET_ROOT", f"{HOME}/.ironpet")
ISOLATED = "IRONPET_APP" in os.environ
WS = "/tmp/ironpet-e2e-ws"
results = []
SHOTS = os.environ.get("IRONPET_E2E_SHOTS", "/tmp/ironpet-e2e-shots")


def token():
    return open(f"{ROOT}/token").read().strip()


def call(method, path, body=None, timeout=10):
    port = open(f"{ROOT}/port").read().strip()
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method,
                                 headers={"X-Ironpet-Token": token(), "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=30).stdout.strip()


def wait_for(predicate, timeout, interval=0.5):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(interval)
    return last


def chat():
    return call("GET", "/test/chat")


def record(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}", flush=True)


def relaunch(test_mode, env=None):
    subprocess.run(["pkill", "-f", f"{APP}/Contents/MacOS/IronPet"])
    time.sleep(1.5)
    port_file = f"{ROOT}/port"
    if os.path.exists(port_file):
        os.remove(port_file)
    if ISOLATED:
        if not test_mode:
            return
        full = {**os.environ, "IRONPET_ROOT": ROOT, **(env or {})}
        # Command-line defaults hide the installed app's saved draft, attachments and open chat from this copy.
        fresh = ["-chatAttachments", "()", "-chatDraft", "", "-chatThread", ""]
        subprocess.Popen([f"{APP}/Contents/MacOS/IronPet", "--test-mode", *fresh], env=full, start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        args = ["open", "-n", APP] + (["--args", "--test-mode"] if test_mode else [])
        subprocess.run(args, check=True)
    wait_for(lambda: os.path.exists(port_file), 15)
    time.sleep(1.5)


def run_chat(prompt, backend="cursor", auto=False, workspace=WS, **extra):
    call("POST", "/test/chat", {"newChat": True, "backend": backend, "workspace": workspace, "auto": auto, "prompt": prompt, **extra})


def wait_approval_or_end(timeout=180):
    return wait_for(lambda: (lambda c: c if c["approvals"] or c["state"] in ("done", "failed") else None)(chat()), timeout)


def wait_end(timeout=180):
    return wait_for(lambda: (lambda c: c if c["state"] in ("done", "failed") and not c["approvals"] else None)(chat()), timeout)


def fresh_workspace():
    shutil.rmtree(WS, ignore_errors=True)
    os.makedirs(WS)


# Scenarios -------------------------------------------------------------------------------------

def approval_flow(name, backend, prompt, allow, expect_title, check_file, should_exist):
    fresh_workspace()
    run_chat(prompt, backend=backend)
    c = wait_approval_or_end()
    if not c or not c["approvals"]:
        return record(name, False, f"no approval card appeared (state={c and c['state']}, items={c and c['items'][-3:]})")
    title = c["approvals"][0]["title"]
    shot(f"approval-{backend}-{'allow' if allow else 'deny'}")
    call("POST", "/test/approve", {"allow": allow})
    # Further approvals may follow (e.g. a retry); deny anything after the one under test.
    end = wait_for(lambda: (lambda c: c if (c["state"] in ("done", "failed") and not c["approvals"]) or c["approvals"] else None)(chat()), 180)
    while end and end["approvals"]:
        call("POST", "/test/approve", {"allow": False})
        end = wait_end()
    exists = os.path.exists(os.path.join(WS, check_file))
    ok = expect_title.lower() in title.lower() and exists == should_exist and end and end["state"] == "done"
    record(name, ok, f"card='{title}' decision={'allow' if allow else 'deny'} file_exists={exists} state={end and end['state']}")


def assistant_text(c):
    return " ".join(i["text"] for i in c["items"] if i["kind"] == "assistant")


def proc_command(pid):
    return subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()


def proc_env(pid):
    return subprocess.run(["ps", "eww", "-p", str(pid)], capture_output=True, text=True).stdout


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def which(name):
    return subprocess.run(["zsh", "-lic", f"command -v {name}"], capture_output=True, text=True).stdout.strip().splitlines()[-1:] or [""]


def scenario_cursor():
    """S2, S3, S11: Cursor over `cursor-agent acp`: text, tool steps, approval cards."""
    fresh_workspace()
    open(os.path.join(WS, "hello.txt"), "w").write("hi from e2e\n")
    run_chat("Run the shell command `ls` and tell me the file names. Then reply with the single word pong.", "cursor")
    end = wait_end(150)
    tools = [i for i in end["items"] if i["kind"] == "tool"]
    pid = end["pid"]
    shot("cursor-turn")
    record("S2 Cursor: text streams and tool steps finish",
           end["state"] == "done" and "pong" in assistant_text(end).lower() and bool(tools) and all(t["ok"] == "yes" for t in tools),
           f"state={end['state']} tools={[(t['text'], t['ok']) for t in tools]} text={assistant_text(end)[:80]!r}")
    cmd = proc_command(pid) if pid else ""
    record("S2 Cursor: spawned `cursor-agent acp`", "cursor-agent" in cmd and cmd.endswith(" acp"), f"pid={pid} command={cmd!r}")

    sessions = [x for x in call("GET", "/status").get("sessions", []) if x["workspace"] == os.path.basename(WS)]
    record("S11 Chat run is not listed as an external session", not sessions, f"sessions={sessions}")

    # S3: a command Cursor does not allow-list asks first.
    approval_flow("S3 Cursor: shell card, Deny reaches the agent", "cursor",
                  "Run exactly this shell command: touch denied.txt . If it is denied, do not retry; just say it was denied.",
                  False, "command", "denied.txt", False)
    approval_flow("S3 Cursor: shell card, Allow runs it", "cursor",
                  "Run exactly this shell command: touch allowed.txt . Then reply OK.", True, "command", "allowed.txt", True)



def scenario_cursor_session():
    """S4, S5, S12, S14: Stop, session reuse, reopening a thread, and the model picker."""
    # S4 + S5: Stop cancels the turn, keeps the process, and the next message reuses process and session.
    fresh_workspace()
    run_chat("Write the numbers from 1 to 600, one per line, with no other text and no tools.", "cursor")
    running = wait_for(lambda: (lambda c: c if c["state"] == "running" and assistant_text(c) else None)(chat()), 90)
    before = running or chat()
    pid1, sid1 = before["pid"], before["sessionId"]
    call("POST", "/test/stop")
    time.sleep(1.5)
    after = chat()
    record("S4 Stop: turn ends, agent process stays alive",
           bool(running) and after["state"] == "idle" and alive(pid1) and after["pid"] == pid1,
           f"state={after['state']} pid={pid1} alive={alive(pid1)}")
    call("POST", "/test/chat", {"prompt": "Reply with the single word pong. No tools."})
    end2 = wait_end(120)
    record("S5 Second message uses the same process and session",
           end2["state"] == "done" and end2["pid"] == pid1 and end2["sessionId"] == sid1 and "pong" in assistant_text(end2).lower(),
           f"pid {pid1}->{end2['pid']} session {sid1}->{end2['sessionId']} state={end2['state']}")

    # S12: reopen the thread from history; session/load restores context.
    fresh_workspace()
    run_chat("Remember the code word BANANA42. Reply with just OK. No tools.", "cursor")
    first = wait_end(120)
    old_pid, sid = first["pid"], first["sessionId"]
    call("POST", "/test/show-chat", {"newChat": True})
    opened = call("POST", "/test/open-thread", {"id": sid})
    call("POST", "/test/chat", {"prompt": "What was the code word? Reply with the word only. No tools."})
    again = wait_end(120)
    shot("cursor-reopened")
    record("S12 Reopened thread continues through session/load",
           opened.get("sessionId") == sid and again["state"] == "done" and "banana42" in assistant_text(again).lower().split("what was the code word")[-1]
           and again["pid"] != old_pid and again["sessionId"] == sid,
           f"session={sid} -> {again['sessionId']} pid {old_pid}->{again['pid']} state={again['state']} text={assistant_text(again)[-80:]!r}")

    # S14: the picker lists the agent's models and a pick reaches the session.
    c = chat()
    models = c["models"]
    pick = next((m for m in models if m["name"] == "Auto"), models[-1] if models else None)
    run_chat("Reply with the single word pong. No tools.", "cursor", model=pick["id"] if pick else "")
    picked = wait_end(120)
    record("S14 Cursor: models come from the agent and a pick applies",
           len(models) > 1 and bool(pick) and picked["activeModel"] == pick["id"],
           f"models={len(models)} picked={pick and pick['id']} active={picked['activeModel']} state={picked['state']}")


def scenario_claude():
    """S6, S10 and approval cards for Claude Code over the bundled adapter."""
    fresh_workspace()
    run_chat("Reply with the single word pong. Do not use tools.", "claude")
    end = wait_end(150)
    pid = end["pid"]
    cmd = proc_command(pid) if pid else ""
    env = proc_env(pid) if pid else ""
    claude_path = which("claude")[0]
    record("S6 Claude Code: turn completes", end["state"] == "done" and "pong" in assistant_text(end).lower(),
           f"state={end['state']} text={assistant_text(end)[:60]!r} errors={[i['text'] for i in end['items'] if i['kind'] == 'error']}")
    record("S6 Claude Code: user's node runs the bundled claude.mjs with CLAUDE_CODE_EXECUTABLE set",
           "node" in cmd and "Resources/acp/claude.mjs" in cmd and f"CLAUDE_CODE_EXECUTABLE={claude_path}" in env,
           f"command={cmd!r} claude={claude_path}")
    models = chat()["models"]
    record("S14 Claude: models come from the agent", len(models) > 0, f"models={[m['id'] for m in models][:5]}")
    approval_flow("Claude Code: shell card, Allow reaches the agent", "claude",
                  "Run the shell command: touch claude-allowed.txt . Then reply OK.", True, "command", "claude-allowed.txt", True)
    # Not an edit tool: this Mac's Claude settings allow `Write(*)`, and Claude then never asks for a Write.
    approval_flow("Claude Code: shell card, Deny reaches the agent", "claude",
                  "Run the shell command: touch claude-denied.txt . If it is denied, do not retry; just say so.",
                  False, "command", "claude-denied.txt", False)


def scenario_codex():
    """S7: Codex through the adapter with CODEX_PATH set."""
    fresh_workspace()
    run_chat("Reply with the single word pong. Do not use tools.", "codex")
    end = wait_end(150)
    pid = end["pid"]
    codex_path = which("codex")[0]
    env = proc_env(pid) if pid else ""
    errors = [i["text"] for i in end["items"] if i["kind"] == "error"]
    record("S7 Codex: adapter runs with CODEX_PATH set to the user's codex and the session starts",
           bool(pid) and f"CODEX_PATH={codex_path}" in env and "codex.mjs" in proc_command(pid) and len(end["models"]) > 0,
           f"codex={codex_path} models={len(end['models'])} command={proc_command(pid)!r}")
    record("S7 Codex: turn answers",
           end["state"] == "done" and "pong" in assistant_text(end).lower(),
           f"state={end['state']} text={assistant_text(end)[:120]!r} errors={errors[-1:]}")


def scenario_agents():
    """S9: every installed agent that answers initialize is listed; Gemini and OpenCode complete a turn."""
    c = chat()
    ids = set(c["agents"])
    expected = {"cursor", "claude", "codex", "gemini", "opencode"}
    absent = {"pi", "goose", "github-copilot-cli", "kiro", "qwen-code", "kilo", "factory-droid"}
    record("S9 Picker lists installed agents and hides missing ones", expected <= ids and not (absent & ids), f"agents={sorted(ids)}")
    # OpenCode's default model needs a provider sign-in this Mac may not have; its free models do not.
    free_models = {"opencode": "opencode/big-pickle"}
    for agent in ("gemini", "opencode"):
        fresh_workspace()
        run_chat("Reply with the single word pong. Do not use tools.", agent, model=free_models.get(agent, ""))
        end = wait_end(150)
        record(f"S9 {agent}: completes a turn with no agent-specific code",
               end["state"] == "done" and "pong" in assistant_text(end).lower(),
               f"state={end['state']} text={assistant_text(end)[:60]!r} errors={[i['text'] for i in end['items'] if i['kind'] == 'error']}")


def scenario_asks():
    """Reports, per agent, whether it sends session/request_permission before a shell command (always passes; read the detail)."""
    for agent in ("cursor", "claude", "codex", "gemini", "opencode"):
        fresh_workspace()
        run_chat("Run exactly this shell command: touch asked.txt . If it is denied, do not retry; just say so.", agent,
                 model={"opencode": "opencode/big-pickle"}.get(agent, ""))
        c = wait_approval_or_end(240)
        asked = bool(c and c["approvals"])
        title = c["approvals"][0]["title"] if asked else ""
        if asked:
            call("POST", "/test/approve", {"allow": False})
        end = wait_end(240) if asked else c
        ran = os.path.exists(os.path.join(WS, "asked.txt"))
        errors = [i["text"] for i in (end or {"items": []})["items"] if i["kind"] == "error"]
        record(f"Asks before a shell command: {agent}", True,
               f"asked={asked} card='{title}' command_ran={ran} state={end and end['state']} errors={errors[-1:]}")


def scenario_runtime():
    """S6b: no usable Node and no Bun means the chat offers the Bun download, then runs on it."""
    claude = which("claude")[0]
    if not claude:
        return record("S6b Runtime download", False, "claude is not installed")
    bindir = f"/tmp/ironpet-e2e-bin"
    runtime = f"/tmp/ironpet-e2e-runtime"
    shutil.rmtree(bindir, ignore_errors=True)
    shutil.rmtree(runtime, ignore_errors=True)
    os.makedirs(bindir)
    os.symlink(os.path.realpath(claude), f"{bindir}/claude")
    relaunch(test_mode=True, env={"IRONPET_LOGIN_PATH": f"{bindir}:/usr/bin:/bin", "IRONPET_RUNTIME_DIR": runtime})
    fresh_workspace()
    run_chat("Reply with the single word pong. Do not use tools.", "claude")
    offered = wait_for(lambda: (lambda c: c if c["runtimeOffer"] or c["state"] == "done" else None)(chat()), 60)
    shot("runtime-offer")
    record("S6b Without Node 22 or Bun the chat offers the download", bool(offered) and offered["runtimeOffer"] == "Claude Code" and not os.path.exists(f"{runtime}/bun"),
           f"offer={offered and offered['runtimeOffer']!r}")
    call("POST", "/test/install-runtime")
    end = wait_for(lambda: (lambda c: c if c["state"] in ("done", "failed") and not c["runtimeOffer"] and not c["installingRuntime"] else None)(chat()), 300)
    cmd = proc_command(end["pid"]) if end and end["pid"] else ""
    record("S6b After allowing, Bun is downloaded and the turn runs on it",
           bool(end) and end["state"] == "done" and os.path.exists(f"{runtime}/bun") and f"{runtime}/bun" in cmd,
           f"state={end and end['state']} command={cmd!r}")
    relaunch(test_mode=True)


def scenario_auto():
    """S10: in Auto mode `ls` runs without a card and `rm -rf` still asks."""
    fresh_workspace()
    os.makedirs(os.path.join(WS, "junk"))
    run_chat("Run these two shell commands one at a time: first `ls`, then `rm -rf ./junk`. "
             "If a command is denied, do not retry; just say so.", "claude", auto=True)
    c = wait_approval_or_end()
    title = c["approvals"][0]["title"] if c and c["approvals"] else ""
    ran_ls = any(i["kind"] == "tool" and i["text"].startswith("Ran `ls") for i in (c or {"items": []})["items"])
    shot("auto-destructive-card")
    if title:
        call("POST", "/test/approve", {"allow": False})
    end = wait_end()
    ok = "destructive" in title.lower() and ran_ls and os.path.isdir(os.path.join(WS, "junk"))
    record("S10 Auto mode: ls runs without a card, rm -rf still asks", ok,
           f"card='{title}' ls_ran_first={ran_ls} junk_kept={os.path.isdir(os.path.join(WS, 'junk'))} state={end and end['state']}")


def scenario_picker():
    osa('tell application "Finder" to activate')
    time.sleep(1)
    c = call("POST", "/test/show-chat", {"newChat": True})
    shown = c["needsWorkspace"]
    call("POST", "/test/chat", {"prompt": "Reply with the single word OK."})
    blocked = chat()
    blocked_ok = blocked["needsWorkspace"] and not blocked["items"] and blocked["state"] == "idle"
    call("POST", "/test/chat", {"noProject": True, "prompt": "Reply with the single word OK. Do not use any tools."})
    end = wait_end(120)
    general_ok = end and end["state"] == "done" and end["workspace"].endswith("/.ironpet/scratch")
    record("Folder picker outside a coding app", shown and blocked_ok and general_ok,
           f"picker_shown={shown} send_blocked={blocked_ok} no_project_run={end and end['state']}")


def scenario_iterm_claude():
    fresh_workspace()
    session_id = osa(f'''
        tell application "iTerm2"
          set w to (create window with default profile)
          tell current session of w
            write text "cd {WS} && claude --permission-mode default 'Run the shell command: touch iterm-claude.txt'"
            return id
          end tell
        end tell''')
    if not session_id:
        return record("Claude Code in iTerm: needs input", False, "could not open iTerm window (Automation permission?)")
    # Default permission mode: the user's auto mode would approve `touch` without asking.
    found = None
    deadline = time.time() + 90
    while time.time() < deadline and not found:
        events = call("GET", "/test/attention")["events"]
        found = next((e for e in events if e["status"] == "Needs input" and session_id in e["iterm"]), None)
        time.sleep(1)
    record("Claude Code in iTerm: pet sees 'needs input'", bool(found),
           f"session={found and found['session']}" if found else "no Needs input event within 90s")
    if found:
        osa('tell application "Finder" to activate')
        time.sleep(1)
        call("POST", "/test/open-session", {"session": found["session"]})
        front = wait_for(lambda: (lambda f: f if "iTerm" in f else None)(
            osa('tell application "System Events" to get name of first process whose frontmost is true')), 4) \
            or osa('tell application "System Events" to get name of first process whose frontmost is true')
        current = osa('tell application "iTerm2" to tell current session of current window to return id')
        record("Jump from notification/session to the exact iTerm tab", current == session_id and "iTerm" in front,
               f"frontmost={front} current_session_matches={current == session_id}")
    tty = osa(f'''tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if id of s is "{session_id}" then return tty of s
              end repeat
            end repeat
          end repeat
        end tell''')
    if tty:
        subprocess.run(["pkill", "-t", tty.replace("/dev/", "")])
        time.sleep(1)
    osa(f'''tell application "iTerm2"
          repeat with w in windows
            if id of current session of w is "{session_id}" then close w
          end repeat
        end tell''')


def scenario_capture():
    osa('tell application "Finder" to activate')
    time.sleep(1)
    before = len(chat()["attachments"])
    r = call("POST", "/test/capture", {"region": False})
    if not r.get("permission"):
        return record("Screen capture of the front window", False, "SKIPPED: ironpet has no Screen Recording permission yet")
    c = wait_for(lambda: (lambda c: c if len(c["attachments"]) > before else None)(chat()), 15)
    path = c["attachments"][-1] if c else ""
    size = os.path.getsize(path) if path and os.path.exists(path) else 0
    record("Screen capture of the front window", size > 10_000, f"file={path} bytes={size}")


def status_sessions():
    return call("GET", "/status").get("sessions", [])


def scenario_summaries():
    fresh_workspace()
    name = os.path.basename(WS)
    env = {k: v for k, v in os.environ.items() if k != "IRONPET_RUN_ID"}
    subprocess.run(["cursor-agent", "-p", "--trust", "--force", "--output-format", "text",
                    "Create a file notes.md containing the word hi using your file editing tool. Then reply exactly: Created the notes file."],
                   cwd=WS, env=env, capture_output=True, timeout=180)
    s = wait_for(lambda: next((s for s in status_sessions()
                               if s["source"] == "cursor" and s["workspace"] == name and s["status"] == "Done" and s["summary"]), None), 20)
    record("Summary for a watched Cursor run", bool(s and "notes.md" in s["summary"]), f"summary='{s and s['summary']}'")

    subprocess.run(["claude", "-p", "--permission-mode", "acceptEdits",
                    "Create a file notes2.md containing the word hi. Then reply exactly: Wrote the second notes file."],
                   cwd=WS, env=env, capture_output=True, timeout=180)
    s = wait_for(lambda: next((s for s in status_sessions()
                               if s["source"] == "claude" and s["workspace"] == name and s["status"] == "Done" and s["summary"]), None), 20)
    ok = bool(s and "notes2.md" in s["summary"] and "second notes file" in s["summary"].lower())
    record("Summary for a watched Claude Code run", ok, f"summary='{s and s['summary']}'")


def scenario_notification_approval():
    fresh_workspace()
    run_chat("Run exactly this shell command: touch from-notification.txt . Then reply OK.")
    c = wait_approval_or_end()
    if not c or not c["approvals"]:
        return record("Allow from the notification button", False, "no approval appeared")
    r = call("POST", "/test/notification-action", {"allow": True})
    end = wait_end()
    exists = os.path.exists(os.path.join(WS, "from-notification.txt"))
    record("Allow from the notification button", r.get("ok") and exists and end["state"] == "done",
           f"card='{r.get('title')}' file_exists={exists} state={end and end['state']}")


def pr(number, ci, review=None):
    return {"number": number, "title": f"PR {number}", "url": f"https://test.example/o/r/pull/{number}", "isDraft": False,
            "repository": {"nameWithOwner": "o/r"}, "reviewDecision": review,
            "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": ci}}}]}}


def requested(number):
    return {"number": number, "title": f"Review {number}", "url": f"https://test.example/o/r/pull/{number}",
            "repository": {"nameWithOwner": "o/r"}, "author": {"login": "someone"}}


def scenario_github():
    host = f"test-{int(time.time())}.example"
    def data(prs, reqs):
        return {"viewer": {"pullRequests": {"nodes": prs}}, "search": {"nodes": reqs}}
    before = len(call("GET", "/test/signals")["notified"])
    seeded = call("POST", "/test/github-apply", {"host": host, "data": data([pr(1, "PENDING"), pr(2, "FAILURE")], [requested(10)])})
    ids = {s["id"] for s in seeded["signals"]}
    seed_ok = f"gh:{host}|o/r#2:ciFailed" in ids and len(seeded["notified"]) == before
    after = call("POST", "/test/github-apply", {"host": host, "data": data(
        [pr(1, "FAILURE", "APPROVED"), pr(2, "SUCCESS")], [requested(10), requested(11)])})
    new = set(after["notified"][before:])
    expected = {f"gh:{host}|o/r#1:ciFailed", f"gh:{host}|o/r#1:approved", f"gh:{host}|o/r#2:ciPassed", f"gh:{host}|o/r#11:reviewRequested"}
    ids = {s["id"] for s in after["signals"]}
    ok = seed_ok and new == expected and f"gh:{host}|o/r#2:ciFailed" not in ids
    record("GitHub: first poll silent, then CI/review changes alert", ok,
           f"seed_silent={seed_ok} notified={sorted(n.split(':')[-1] for n in new)}")

    real_before = len(call("GET", "/test/signals")["notified"])
    call("POST", "/test/github-poll")
    time.sleep(12)
    real_after = call("GET", "/test/signals")
    record("GitHub: real poll of your accounts runs without a notification flood",
           len(real_after["notified"]) - real_before <= 3,
           f"new_notifications={len(real_after['notified']) - real_before} open_alerts={len(real_after['signals'])}")


def scenario_mcp():
    """Uses the Langfuse MCP (signed in); the write is denied, so nothing is created."""
    fresh_workspace()
    run_chat("Use the langfuse MCP tool getHealth and report its status in one sentence. Do not use any other tools.")
    c = wait_approval_or_end(180)
    asked = [a["title"] for a in c["approvals"]]
    for _ in asked:
        call("POST", "/test/approve", {"allow": False})
    c = wait_end(120)
    reply = " ".join(i["text"] for i in c["items"] if i["kind"] == "assistant").lower()
    record("MCP: read-only tool runs without asking", not asked and "ok" in reply, f"cards={asked} reply='{reply[:80]}'")

    fresh_workspace()
    run_chat("Use the langfuse MCP tool createScoreConfig to create a score config named ironpet-e2e-test with dataType BOOLEAN. "
             "If it is denied, do not retry; just say so.")
    c = wait_approval_or_end(180)
    title = c["approvals"][0]["title"] if c and c["approvals"] else ""
    if title:
        call("POST", "/test/approve", {"allow": False})
    c = wait_end(120)
    record("MCP: write tool asks first and Deny blocks it", "createScoreConfig" in title and "langfuse" in title.lower(),
           f"card='{title}' state={c and c['state']}")


def scenario_sentry_mcp():
    """A chat in a brand-new folder can use the Sentry MCP signed in elsewhere (shared sign-in), read-only, no card."""
    fresh_workspace()
    run_chat("Call the Sentry MCP whoami tool and reply with just my Sentry user name or email, "
             "or NOT AVAILABLE if the tool is missing.")
    c = wait_approval_or_end(180)
    cards = [a["title"] for a in c["approvals"]]
    for _ in cards:
        call("POST", "/test/approve", {"allow": False})
    c = wait_end(120)
    reply = " ".join(i["text"] for i in c["items"] if i["kind"] == "assistant")
    record("Sentry MCP works in a new folder without asking", not cards and "@" in reply and "NOT AVAILABLE" not in reply,
           f"cards={cards} reply='{reply[:80]}'")


# Native UI (welcome window, Settings) -----------------------------------------------------------
# Driven through macOS accessibility (System Events), so the terminal needs Accessibility permission.
# These scenarios edit config.json and the hook files for real; the user's copies are restored afterwards.

CONFIG = f"{HOME}/.ironpet/config.json"
HOOK_FILES = {"cursor": f"{HOME}/.cursor/hooks.json", "claude": f"{HOME}/.claude/settings.json"}
DEFAULTS_DOMAIN = "dev.ironpet.app"


class PreservedUserState:
    """Snapshots config.json, both hook files and the setup flag; puts them back on exit."""

    def __enter__(self):
        self.files = {}
        for path in [CONFIG, *HOOK_FILES.values()]:
            self.files[path] = open(path, "rb").read() if os.path.exists(path) else None
        flag = subprocess.run(["defaults", "read", DEFAULTS_DOMAIN, "setupCompleted"], capture_output=True, text=True)
        self.setup_completed = flag.stdout.strip() if flag.returncode == 0 else None
        return self

    def __exit__(self, *exc):
        subprocess.run(["pkill", "-f", "IronPet.app/Contents/MacOS/IronPet"])
        time.sleep(1.5)
        for path, data in self.files.items():
            if data is None:
                if os.path.exists(path):
                    os.remove(path)
            else:
                with open(path, "wb") as f:
                    f.write(data)
        if self.setup_completed is None:
            subprocess.run(["defaults", "delete", DEFAULTS_DOMAIN, "setupCompleted"], capture_output=True)
        else:
            subprocess.run(["defaults", "write", DEFAULTS_DOMAIN, "setupCompleted", "-bool",
                            "true" if self.setup_completed == "1" else "false"])
        relaunch(test_mode=True)
        return False


def ax(window, action, role, name, prefix=False, by_id=False):
    """Finds the first element in `window` with this AX role and name (name prefix, or accessibility identifier with
    by_id) and acts on it. action: "click" | "value" | "focus" | "exists". Returns the AppleScript result as text,
    or "missing". Brings ironpet to the front and retries, since windows behind another app's Space are invisible."""
    if by_id:
        match = f'value of attribute "AXIdentifier" of e is "{name}"'
    else:
        match = f'name of e starts with "{name}"' if prefix else f'name of e is "{name}"'
    act = {"click": 'click e\n return "ok"', "value": "return (value of e) as text",
           "focus": 'set focused of e to true\n return "ok"', "exists": 'return "ok"'}[action]
    script = f"""
    tell application "System Events" to tell process "IronPet"
      if not (exists window "{window}") then return "missing"
      set allItems to entire contents of window "{window}"
      repeat with i from 1 to count of allItems
        set e to item i of allItems
        try
          if role of e is "{role}" and {match} then
            {act}
          end if
        end try
      end repeat
    end tell
    return "missing"
    """
    result = "missing"
    for _ in range(3):
        activate_app()
        result = osa(script)
        if result not in ("missing", ""):
            return result
        time.sleep(0.5)
    return result


def activate_app():
    """Windows in another Space (e.g. behind a full-screen app) are invisible to accessibility."""
    osa('tell application "System Events" to set frontmost of process "IronPet" to true')
    time.sleep(0.3)


def window_open(title):
    activate_app()
    return title in osa('tell application "System Events" to tell process "IronPet" to get name of every window')


def keystroke(key, *modifiers, to_app=True):
    """Types into ironpet (brought to the front first), or into whatever is frontmost with to_app=False."""
    if to_app:
        activate_app()
    using = f' using {{{", ".join(m + " down" for m in modifiers)}}}' if modifiers else ""
    osa(f'tell application "System Events" to keystroke "{key}"{using}')


def read_config():
    return json.load(open(CONFIG)) if os.path.exists(CONFIG) else {}


def hooks_installed(agent):
    path = HOOK_FILES[agent]
    return os.path.exists(path) and "/.ironpet/bin/ironpet-hook" in open(path).read()


def scenario_setup():
    with PreservedUserState():
        subprocess.run(["pkill", "-f", "IronPet.app/Contents/MacOS/IronPet"])
        time.sleep(1.5)
        os.remove(CONFIG) if os.path.exists(CONFIG) else None
        subprocess.run(["defaults", "delete", DEFAULTS_DOMAIN, "setupCompleted"], capture_output=True)
        before = {agent: open(path).read() if os.path.exists(path) else None for agent, path in HOOK_FILES.items()}
        relaunch(test_mode=True)

        shown = wait_for(lambda: window_open("Welcome to ironpet"), 10)
        unchanged = all((open(p).read() if os.path.exists(p) else None) == before[a] for a, p in HOOK_FILES.items())
        record("Setup: welcome window on first launch, nothing written yet", bool(shown) and not os.path.exists(CONFIG) and unchanged,
               f"window={bool(shown)} config_exists={os.path.exists(CONFIG)} hook_files_unchanged={unchanged}")
        if not shown:
            return

        ax("Welcome to ironpet", "focus", "AXTextField", "Name")
        keystroke("a", "command")
        keystroke("Testy")
        if ax("Welcome to ironpet", "value", "AXCheckBox", "Cursor", prefix=True) != "1":
            ax("Welcome to ironpet", "click", "AXCheckBox", "Cursor", prefix=True)
        if ax("Welcome to ironpet", "value", "AXCheckBox", "Claude Code", prefix=True) == "1":
            ax("Welcome to ironpet", "click", "AXCheckBox", "Claude Code", prefix=True)
        ax("Welcome to ironpet", "click", "AXButton", "setup.start", by_id=True)

        config = wait_for(lambda: read_config() or None, 5) or {}
        integrations = config.get("integrations", {})
        ok = (config.get("pet", {}).get("name") == "Testy" and integrations.get("cursorHooks") is True
              and integrations.get("claudeHooks") is False and hooks_installed("cursor") and not hooks_installed("claude")
              and not window_open("Welcome to ironpet"))
        record("Setup: Start applies choices (name, Cursor hooks on, Claude hooks off)", ok,
               f"name={config.get('pet', {}).get('name')} integrations={integrations} "
               f"cursor_hooks={hooks_installed('cursor')} claude_hooks={hooks_installed('claude')}")

        relaunch(test_mode=True)
        record("Setup: not shown again on the next launch", not wait_for(lambda: window_open("Welcome to ironpet"), 4))


def open_settings():
    activate_app()
    osa('tell application "System Events" to tell process "IronPet" to click menu item "Settings…" of menu 1 of menu bar item 2 of menu bar 1')
    return wait_for(lambda: window_open("ironpet Settings"), 5)


def scenario_settings():
    with PreservedUserState():
        if not open_settings():
            return record("Settings: window opens from the app menu", False)
        record("Settings: window opens from the app menu", True)
        win = "ironpet Settings"

        # Agent hooks toggle installs/removes only that agent's hooks.
        start = hooks_installed("claude")
        ax(win, "click", "AXCheckBox", "Watch Claude Code")
        flipped = wait_for(lambda: hooks_installed("claude") != start, 5)
        record("Settings: Watch Claude Code toggles its hooks and config",
               bool(flipped) and read_config().get("integrations", {}).get("claudeHooks") == (not start),
               f"before={start} after={hooks_installed('claude')}")
        ax(win, "click", "AXCheckBox", "Watch Claude Code")
        wait_for(lambda: hooks_installed("claude") == start, 5)

        # Record a new chat shortcut, then press it.
        ax(win, "click", "AXButton", "Open chat")
        time.sleep(0.5)
        keystroke("j", "control", "option", "command")
        saved = wait_for(lambda: read_config().get("hotkeys", {}).get("chat") == "ctrl+opt+cmd+j", 5)
        record("Settings: recording a shortcut saves it", bool(saved), f"chat={read_config().get('hotkeys', {}).get('chat')}")
        osa('tell application "System Events" to tell process "IronPet" to click button 1 of window "ironpet Settings"')  # close
        time.sleep(0.5)
        osa('tell application "Finder" to activate')
        time.sleep(0.5)
        keystroke("j", "control", "option", "command", to_app=False)
        opened = wait_for(lambda: chat()["visible"], 5)
        record("Settings: the new shortcut opens the chat", bool(opened))

        # Reminders tab writes to config.json.
        open_settings()
        osa(f'tell application "System Events" to tell process "IronPet" to click radio button 2 of tab group 1 of group 1 of window "{win}"')
        time.sleep(0.5)
        was = read_config().get("reminders", {}).get("paused", False)
        ax(win, "click", "AXCheckBox", "Pause all reminders")
        paused = wait_for(lambda: read_config().get("reminders", {}).get("paused") == (not was), 5)
        record("Settings: Pause all reminders saves to config.json", bool(paused))

        # Hand edits to config.json show up in the window.
        cfg = read_config()
        cfg.setdefault("pet", {})["name"] = "Handy"
        json.dump(cfg, open(CONFIG, "w"))
        osa(f'tell application "System Events" to tell process "IronPet" to click radio button 1 of tab group 1 of group 1 of window "{win}"')
        shown = wait_for(lambda: ax(win, "value", "AXTextField", "Name") == "Handy", 6)
        record("Settings: hand edits to config.json appear in the window", bool(shown))


MLX_PORT = 8000


def set_voice_config(**voice):
    config = read_config()
    config.setdefault("voice", {}).update(voice)
    json.dump(config, open(CONFIG, "w"), indent=2)
    time.sleep(2.6)  # the app re-reads config.json every 2 s


def speak(text, name):
    """A 16 kHz mono WAV of `text`, spoken by macOS."""
    os.makedirs(SHOTS, exist_ok=True)
    aiff, wav = f"{SHOTS}/{name}.aiff", f"{SHOTS}/{name}.wav"
    subprocess.run(["say", "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True)
    return wav


def voice_state():
    return chat()["voice"]


def shot(name):
    os.makedirs(SHOTS, exist_ok=True)
    c = chat()
    if c.get("windowId"):
        # By window id, so another app's window on top of the chat cannot end up in the picture.
        subprocess.run(["screencapture", "-x", "-o", "-l", str(c["windowId"]), f"{SHOTS}/{name}.png"])
        return
    x, y, w, h = c["frame"]
    subprocess.run(["screencapture", "-x", "-R", f"{int(x)},{int(y)},{int(w)},{int(h)}", f"{SHOTS}/{name}.png"])


def set_dark_mode(on):
    osa(f'tell application "System Events" to tell appearance preferences to set dark mode to {"true" if on else "false"}')
    time.sleep(1.5)


class SlowTranscriber:
    """An OpenAI-style server that waits before answering, so the transcribing state can be seen, and counts requests."""

    def __init__(self, port=8001, delay=4.0):
        import http.server
        import threading
        outer = self
        self.requests = 0
        self.delay = delay

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                outer.requests += 1
                time.sleep(outer.delay)
                body = b'{"text": "slow stub transcript"}'
                try:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except OSError:
                    pass  # the client cancelled

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


def scenario_voice():
    """Voice notes against a real local mlx-audio server (Parakeet), driven by a WAV file instead of the microphone."""
    server = None
    slow = None
    auto = subprocess.run(["defaults", "read", DEFAULTS_DOMAIN, "sendAfterDictation"], capture_output=True, text=True).stdout.strip()
    dark = osa('tell application "System Events" to tell appearance preferences to get dark mode') == "true"
    with PreservedUserState():
        try:
            relaunch(test_mode=True)
            wav = speak("Hello from the voice note test. Please summarise the readme.", "voice-note")
            local = {"enabled": True, "baseUrl": f"http://localhost:{MLX_PORT}/v1",
                     "model": "mlx-community/parakeet-tdt-0.6b-v3"}
            set_voice_config(enabled=False)
            record("Voice: off, the test endpoint refuses to record",
                   call("POST", "/test/voice/start", {"file": wav, "autoSend": False}).get("error") == "voice notes are off")

            # S6: nothing listens yet, so the transcription fails with an error that offers Retry.
            set_voice_config(**local)
            call("POST", "/test/show-chat", {"newChat": True})
            call("POST", "/test/voice/start", {"file": wav, "autoSend": False})
            wait_for(lambda: voice_state() == "recording", 5)
            time.sleep(1.5)
            call("POST", "/test/voice/stop")
            c = wait_for(lambda: (lambda c: c if c["voice"] == "idle" and c["items"] else None)(chat()), 20)
            errors = [i for i in (c or {"items": []})["items"] if i["kind"] == "error"]
            record("Voice: unreachable server shows an error with Retry", bool(errors) and c["voiceRetry"] and c["input"] == "",
                   errors[0]["text"] if errors else "no error item")

            server = subprocess.Popen(["uvx", "--from", "mlx-audio[server]", "mlx_audio.server", "--port", str(MLX_PORT)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

            def up():
                try:
                    urllib.request.urlopen(f"http://localhost:{MLX_PORT}/v1/models", timeout=2)
                    return True
                except urllib.error.HTTPError:
                    return True
                except Exception:
                    return False

            record("Voice: mlx-audio server started", bool(wait_for(up, 240, 2)))
            call("POST", "/test/voice/retry")
            c = wait_for(lambda: (lambda c: c if c["input"] else None)(chat()), 90)
            record("Voice: Retry re-sends the same recording and succeeds", bool(c) and "voice note" in c["input"].lower()
                   and not c["voiceRetry"], c["input"] if c else "no transcript")

            # S4: the transcript goes into the input and nothing is sent.
            call("POST", "/test/show-chat", {"newChat": True})
            call("POST", "/test/voice/start", {"file": wav, "autoSend": False})
            time.sleep(1.5)
            call("POST", "/test/voice/stop")
            c = wait_for(lambda: (lambda c: c if c["input"] else None)(chat()), 90)
            record("Voice: transcript lands in the input and is not sent",
                   bool(c) and "summar" in c["input"].lower() and not any(i["kind"] == "user" for i in c["items"]),
                   c["input"] if c else "no transcript")

            # S5: with auto-send on the transcript is sent as a chat message.
            fresh_workspace()
            call("POST", "/test/voice/start", {"file": wav, "newChat": True, "workspace": WS, "autoSend": True})
            time.sleep(1.5)
            call("POST", "/test/voice/stop")
            c = wait_for(lambda: (lambda c: c if any(i["kind"] == "user" for i in c["items"]) else None)(chat()), 90)
            sent = [i["text"] for i in c["items"] if i["kind"] == "user"] if c else []
            record("Voice: send automatically sends the transcript", bool(sent) and c["input"] == "", "; ".join(sent))
            call("POST", "/test/stop")
            call("POST", "/test/show-chat", {"newChat": True})

            # S11 and S12: the recording UI, with a server slow enough to catch the transcribing state.
            slow = SlowTranscriber()
            set_voice_config(baseUrl="http://127.0.0.1:8001/v1")
            for mode in ("light", "dark"):
                set_dark_mode(mode == "dark")
                call("POST", "/test/show-chat", {"newChat": True})
                call("POST", "/test/voice/start", {"file": wav, "autoSend": False})
                time.sleep(3.5)
                record(f"Voice: recording state ({mode})", voice_state() == "recording")
                shot(f"voice-recording-{mode}")
                call("POST", "/test/voice/stop")
                time.sleep(0.8)
                record(f"Voice: transcribing state ({mode})", voice_state() == "transcribing")
                shot(f"voice-transcribing-{mode}")
                c = wait_for(lambda: (lambda c: c if c["input"] else None)(chat()), 20)
                record(f"Voice: input returns with the transcript ({mode})",
                       bool(c) and c["voice"] == "idle" and c["input"] == "slow stub transcript")
                call("POST", "/test/show-chat", {"newChat": True})
                call("POST", "/test/stop")

            # Cancel while recording, then while transcribing: the input stays empty.
            set_dark_mode(False)
            call("POST", "/test/show-chat", {"newChat": True})
            before = slow.requests
            call("POST", "/test/voice/start", {"file": wav, "autoSend": False})
            time.sleep(1.2)
            call("POST", "/test/voice/cancel")
            time.sleep(1)
            c = chat()
            record("Voice: cancel while recording sends nothing",
                   c["voice"] == "idle" and c["input"] == "" and slow.requests == before)
            call("POST", "/test/voice/start", {"file": wav, "autoSend": False})
            time.sleep(1.2)
            call("POST", "/test/voice/stop")
            time.sleep(0.8)
            call("POST", "/test/voice/cancel")
            time.sleep(slow.delay + 1)
            c = chat()
            record("Voice: cancel while transcribing leaves the input empty", c["voice"] == "idle" and c["input"] == "")
        finally:
            # "Send after dictation" lives in the app's preferences, outside config.json: put the user's value back.
            subprocess.run(["defaults", "write", DEFAULTS_DOMAIN, "sendAfterDictation", "-bool", "false" if auto == "0" else "true"])
            if slow:
                slow.close()
            if server:
                server.terminate()
            set_dark_mode(dark)


def scenario_voice_key():
    """An API key typed in Settings → Voice goes to the Keychain and to no file under ~/.ironpet."""
    secret = "e2e-key-" + str(int(time.time()))
    service = ["security", "find-generic-password", "-s", "ironpet.voice"]
    if subprocess.run(service, capture_output=True).returncode == 0:
        return record("Voice key: Keychain item", False, "SKIPPED: an ironpet.voice key already exists; not overwriting it")
    with PreservedUserState():
        try:
            if not open_settings():
                return record("Voice key: Settings opens", False)
            win = "ironpet Settings"
            osa(f'tell application "System Events" to tell process "IronPet" to click radio button 4 of tab group 1 of group 1 of window "{win}"')
            time.sleep(1)
            ax(win, "focus", "AXTextField", "API key")
            keystroke(secret)
            keystroke("\r")
            time.sleep(1)
            stored = subprocess.run([*service, "-w"], capture_output=True, text=True).stdout.strip()
            record("Voice key: saved in the Keychain", stored == secret)
            time.sleep(2.5)
            hits = subprocess.run(["grep", "-rl", secret, f"{HOME}/.ironpet"], capture_output=True, text=True).stdout.strip()
            record("Voice key: not in any file under ~/.ironpet", hits == "", hits)
        finally:
            subprocess.run(["security", "delete-generic-password", "-s", "ironpet.voice"], capture_output=True)


SCENARIOS = {"cursor": scenario_cursor, "cursor-session": scenario_cursor_session, "claude": scenario_claude, "codex": scenario_codex, "agents": scenario_agents,
             "asks": scenario_asks, "runtime": scenario_runtime, "auto": scenario_auto, "picker": scenario_picker,
             "iterm": scenario_iterm_claude, "capture": scenario_capture, "summaries": scenario_summaries,
             "notification": scenario_notification_approval, "github": scenario_github, "mcp": scenario_mcp,
             "sentry": scenario_sentry_mcp, "setup": scenario_setup, "settings": scenario_settings,
             "voice": scenario_voice, "voice-key": scenario_voice_key}

# Need MCP servers signed in with cursor-agent: "mcp" a Langfuse MCP (its write is denied, so nothing is created),
# "sentry" a Sentry MCP. Run them by name, e.g. `python3 scripts/e2e.py mcp sentry`.
# "voice" starts a local mlx-audio server with `uvx` (needs the Parakeet model in the Hugging Face cache) and flips
# the system between light and dark mode for screenshots, saved to $IRONPET_E2E_SHOTS.
OPT_IN = {"mcp", "sentry", "voice", "voice-key", "runtime", "asks"}

if __name__ == "__main__":
    unknown = [name for name in sys.argv[1:] if name not in SCENARIOS]
    if unknown:
        sys.exit(f"Unknown scenario(s): {', '.join(unknown)}. Choose from: {', '.join(SCENARIOS)}")
    chosen = sys.argv[1:] or [name for name in SCENARIOS if name not in OPT_IN]
    relaunch(test_mode=True)
    try:
        for name in chosen:
            try:
                SCENARIOS[name]()
            except Exception as error:  # keep going so one broken scenario doesn't hide the rest
                record(name, False, f"error: {error}")
    finally:
        relaunch(test_mode=False)
    passed = sum(1 for _, ok, _ in results if ok)
    print(f"\n{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)
