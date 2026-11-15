#!/usr/bin/env python3
"""A local stand-in for the Telegram Bot API, for running ironpet with --test-mode.

  python3 scripts/fake_telegram.py [port]
  IRONPET_TELEGRAM_API=http://127.0.0.1:<port> /path/to/IronPet --test-mode

Bot API calls go to /bot<token>/<method>. The control endpoints start with an underscore:
  POST /_push   {"from": 10, "name": "Ann", "username": "ann", "text": "hi"}  queue a message from a user
                add "document": {"file_id": "d1", "file_name": "a.pdf", "file_size": 123} or "voice": {...} or
                "photo": [{...}] for uploads, "caption": "..." for a caption
  POST /_tap    {"from": 10, "data": "a:<uuid>:1", "message_id": 101}              queue a tap on an inline button
  POST /_file   {"file_id": "d1", "path": "documents/a.pdf", "content": "text"}    register a downloadable file
  GET  /_edits                                                                      editMessageText and answerCallbackQuery calls
  GET  /_sent                                                                 sendMessage calls so far
  POST /_mode   {"mode": "ok" | "401" | "409"}                                 make every Bot API call fail
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

lock = threading.Lock()
updates = []
sent = []
actions = []
edits = []
answers = []
files = {}
state = {"mode": "ok", "next_id": 100}


def reply(handler, payload, status=200):
    body = json.dumps(payload).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        if self.path == "/_sent":
            with lock:
                return reply(self, {"sent": sent, "typing": len(actions)})
        if self.path == "/_edits":
            with lock:
                return reply(self, {"edits": edits, "answers": answers})
        if "/file/bot" in self.path:
            path = self.path.split("/file/bot", 1)[1].split("/", 1)[1]
            with lock:
                entry = next((f for f in files.values() if f["path"] == path), None)
            if not entry:
                return reply(self, {"ok": False}, 404)
            body = entry["content"].encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        reply(self, {"ok": False}, 404)

    def do_POST(self):
        data = self.body()
        if self.path == "/_push":
            with lock:
                state["next_id"] += 1
                updates.append({"update_id": state["next_id"], "message": {
                    "message_id": state["next_id"],
                    "from": {"id": data["from"], "is_bot": False, "first_name": data.get("name", "Ann"),
                             "username": data.get("username")},
                    "chat": {"id": data["from"], "type": "private"}}})
                message = updates[-1]["message"]
                for key in ("text", "caption", "document", "voice", "photo"):
                    if key in data:
                        message[key] = data[key]
            return reply(self, {"ok": True})
        if self.path == "/_tap":
            with lock:
                state["next_id"] += 1
                updates.append({"update_id": state["next_id"], "callback_query": {
                    "id": f"cb{state['next_id']}", "data": data["data"],
                    "from": {"id": data["from"], "is_bot": False, "first_name": "Ann"},
                    "message": {"message_id": data.get("message_id", 1), "chat": {"id": data["from"], "type": "private"}}}})
            return reply(self, {"ok": True})
        if self.path == "/_file":
            with lock:
                files[data["file_id"]] = {"path": data["path"], "content": data.get("content", "")}
            return reply(self, {"ok": True})
        if self.path == "/_mode":
            state["mode"] = data["mode"]
            return reply(self, {"ok": True})
        method = self.path.rsplit("/", 1)[-1]
        if state["mode"] != "ok":
            code = int(state["mode"])
            return reply(self, {"ok": False, "error_code": code, "description": "Unauthorized" if code == 401 else "Conflict"}, code)
        if method == "getMe":
            return reply(self, {"ok": True, "result": {"id": 1, "is_bot": True, "first_name": "Ghost", "username": "ghost_fake_bot"}})
        if method == "getUpdates":
            offset = data.get("offset", 0)
            deadline = time.time() + min(data.get("timeout", 0), 3)
            while True:
                with lock:
                    if offset == -1:
                        result = updates[-1:]
                    else:
                        result = [u for u in updates if u["update_id"] >= offset]
                if result or time.time() >= deadline:
                    return reply(self, {"ok": True, "result": result})
                time.sleep(0.1)
        if method == "sendMessage":
            with lock:
                state["next_id"] += 1
                sent.append({"chat": data["chat_id"], "text": data["text"], "parse_mode": data.get("parse_mode"),
                             "reply_markup": data.get("reply_markup"), "message_id": state["next_id"]})
                message_id = state["next_id"]
            return reply(self, {"ok": True, "result": {"message_id": message_id, "chat": {"id": data["chat_id"], "type": "private"}}})
        if method == "editMessageText":
            with lock:
                edits.append({"chat": data["chat_id"], "message_id": data["message_id"], "text": data["text"]})
            return reply(self, {"ok": True, "result": {"message_id": data["message_id"], "chat": {"id": data["chat_id"], "type": "private"}}})
        if method == "answerCallbackQuery":
            with lock:
                answers.append(data.get("text", ""))
            return reply(self, {"ok": True, "result": True})
        if method == "getFile":
            with lock:
                entry = files.get(data["file_id"])
            if not entry:
                return reply(self, {"ok": False, "error_code": 400, "description": "Bad Request: file is too big"}, 400)
            return reply(self, {"ok": True, "result": {"file_id": data["file_id"], "file_path": entry["path"], "file_size": len(entry["content"])}})
        if method == "sendChatAction":
            with lock:
                actions.append(data["chat_id"])
            return reply(self, {"ok": True, "result": True})
        reply(self, {"ok": False, "error_code": 404, "description": "Not Found"}, 404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18099
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
