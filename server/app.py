"""LINE Bot webhook サーバー（Fly.io 用・標準ライブラリのみ）。

役割は2つだけ:
  1. POST /webhook  — LINE Messaging API の webhook を受け、署名検証して
                      イベントを /data/events.jsonl に追記する（即 200 を返す）
  2. GET  /export   — 蓄積イベントをカーソル以降ぶん、送信者名・チャット名を
                      解決した JSON で返す（Bearer トークン認証）

環境変数:
  LINE_CHANNEL_SECRET        署名検証用（LINE Developers のチャネル基本設定）
  LINE_CHANNEL_ACCESS_TOKEN  名前解決 API 用（長期チャネルアクセストークン）
  EXPORT_TOKEN               /export の Bearer トークン
  DATA_DIR                   永続化先（既定 /data）
  PORT / BIND_HOST           待ち受け（既定 8080 / 0.0.0.0）

/export のレスポンス:
  {"next_cursor": <int>,
   "chats": [{"key": "group:xxx", "name": "家族",
              "messages": [{"ts": "2026-07-18T10:21", "sender": "田中", "text": "..."}]}]}

ts は JST・分精度。sender が null の行はシステムメッセージ。
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

CHANNEL_SECRET = os.environ.get("LINE_CHANNEL_SECRET", "")
ACCESS_TOKEN = os.environ.get("LINE_CHANNEL_ACCESS_TOKEN", "")
EXPORT_TOKEN = os.environ.get("EXPORT_TOKEN", "")
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
EVENTS_PATH = DATA_DIR / "events.jsonl"
NAMES_PATH = DATA_DIR / "names.json"

JST = timezone(timedelta(hours=9))

# message.type → 本文プレースホルダ（text 以外）
MEDIA_PLACEHOLDER = {
    "sticker": "[スタンプ]",
    "image": "[写真]",
    "video": "[動画]",
    "audio": "[ボイスメッセージ]",
    "file": "[ファイル]",
    "location": "[位置情報]",
}


def verify_signature(secret: str, body: bytes, signature: str) -> bool:
    digest = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).digest()
    return hmac.compare_digest(base64.b64encode(digest).decode("ascii"), signature or "")


def _api_get(path: str) -> dict | None:
    req = urllib.request.Request(
        f"https://api.line.me{path}",
        headers={"Authorization": f"Bearer {ACCESS_TOKEN}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError):
        return None


class NameCache:
    """表示名・チャット名の解決（LINE API + 永続キャッシュ）。"""

    def __init__(self) -> None:
        self._names: dict[str, str] = {}
        if NAMES_PATH.exists():
            try:
                self._names = json.loads(NAMES_PATH.read_text(encoding="utf-8"))
            except ValueError:
                self._names = {}

    def _save(self) -> None:
        NAMES_PATH.parent.mkdir(parents=True, exist_ok=True)
        NAMES_PATH.write_text(
            json.dumps(self._names, ensure_ascii=False, indent=1), encoding="utf-8"
        )

    def _get(self, cache_key: str, path: str, field: str, fallback: str) -> str:
        if cache_key in self._names:
            return self._names[cache_key]
        data = _api_get(path)
        name = (data or {}).get(field) or fallback
        if data is not None:
            self._names[cache_key] = name
            self._save()
        return name

    def chat_name(self, source: dict) -> str:
        stype = source.get("type")
        if stype == "group":
            gid = source["groupId"]
            return self._get(f"chat:{gid}", f"/v2/bot/group/{gid}/summary",
                             "groupName", f"グループ{gid[:8]}")
        if stype == "room":
            rid = source["roomId"]
            return f"複数人トーク{rid[:8]}"  # room に名前 API は無い
        uid = source.get("userId", "")
        return self._get(f"chat:{uid}", f"/v2/bot/profile/{uid}",
                         "displayName", f"ユーザー{uid[:8]}")

    def sender_name(self, source: dict) -> str:
        stype = source.get("type")
        uid = source.get("userId", "")
        if not uid:
            return "不明"
        if stype == "group":
            gid = source["groupId"]
            return self._get(f"user:{uid}", f"/v2/bot/group/{gid}/member/{uid}",
                             "displayName", f"メンバー{uid[:8]}")
        if stype == "room":
            rid = source["roomId"]
            return self._get(f"user:{uid}", f"/v2/bot/room/{rid}/member/{uid}",
                             "displayName", f"メンバー{uid[:8]}")
        return self._get(f"user:{uid}", f"/v2/bot/profile/{uid}",
                         "displayName", f"ユーザー{uid[:8]}")


def chat_key(source: dict) -> str:
    stype = source.get("type")
    if stype == "group":
        return f"group:{source['groupId']}"
    if stype == "room":
        return f"room:{source['roomId']}"
    return f"user:{source.get('userId', '?')}"


def message_text(message: dict) -> str:
    mtype = message.get("type")
    if mtype == "text":
        return message.get("text", "")
    if mtype == "file" and message.get("fileName"):
        return f"[ファイル] {message['fileName']}"
    if mtype == "location":
        where = message.get("address") or message.get("title") or ""
        return f"[位置情報] {where}".rstrip()
    return MEDIA_PLACEHOLDER.get(mtype, f"[{mtype}]")


def event_to_message(event: dict, names: NameCache) -> tuple[str, str, dict] | None:
    """イベント1件を (chat_key, chat_name, message) に変換。対象外は None。"""
    etype = event.get("type")
    source = event.get("source") or {}
    if etype not in ("message", "join", "memberJoined", "memberLeft", "unsend"):
        return None
    if etype != "join" and source.get("type") not in ("group", "room", "user"):
        return None
    ts = datetime.fromtimestamp(event.get("timestamp", 0) / 1000, tz=JST)
    msg: dict = {"ts": ts.strftime("%Y-%m-%dT%H:%M")}
    if etype == "message":
        msg["sender"] = names.sender_name(source)
        msg["text"] = message_text(event.get("message") or {})
    elif etype == "join":
        msg["sender"] = None
        msg["text"] = "（Botが参加 — ここからアーカイブ開始）"
    elif etype == "memberJoined":
        msg["sender"] = None
        msg["text"] = "（メンバーが参加しました）"
    elif etype == "memberLeft":
        msg["sender"] = None
        msg["text"] = "（メンバーが退出しました）"
    else:  # unsend
        msg["sender"] = None
        msg["text"] = "（メッセージの送信取消がありました）"
    return chat_key(source), names.chat_name(source), msg


def build_export(since: int, names: NameCache) -> dict:
    """events.jsonl の since 行目以降を chats 形式にまとめる。"""
    chats: dict[str, dict] = {}
    line_no = 0
    seen_event_ids: set[str] = set()
    if EVENTS_PATH.exists():
        with EVENTS_PATH.open(encoding="utf-8") as f:
            for line_no, line in enumerate(f, start=1):
                if line_no <= since or not line.strip():
                    continue
                try:
                    event = json.loads(line)["event"]
                except (ValueError, KeyError):
                    continue
                eid = event.get("webhookEventId")
                if eid and eid in seen_event_ids:  # 再配送の重複を除外
                    continue
                if eid:
                    seen_event_ids.add(eid)
                converted = event_to_message(event, names)
                if converted is None:
                    continue
                key, name, msg = converted
                chat = chats.setdefault(key, {"key": key, "name": name, "messages": []})
                chat["messages"].append(msg)
    return {"next_cursor": max(line_no, since), "chats": list(chats.values())}


class Handler(BaseHTTPRequestHandler):
    server_version = "line-dump-bot"

    def _respond(self, code: int, body: bytes = b"", ctype: str = "text/plain") -> None:
        self.send_response(code)
        self.send_header("Content-Type", f"{ctype}; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        url = urlparse(self.path)
        if url.path == "/health":
            self._respond(200, b"ok")
            return
        if url.path == "/export":
            auth = self.headers.get("Authorization", "")
            if not EXPORT_TOKEN or auth != f"Bearer {EXPORT_TOKEN}":
                self._respond(401, b"unauthorized")
                return
            try:
                since = int((parse_qs(url.query).get("since") or ["0"])[0])
            except ValueError:
                since = 0
            payload = build_export(since, self.server.names)  # type: ignore[attr-defined]
            self._respond(200, json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                          "application/json")
            return
        self._respond(404, b"not found")

    def do_POST(self) -> None:  # noqa: N802
        if urlparse(self.path).path != "/webhook":
            self._respond(404, b"not found")
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        if not verify_signature(CHANNEL_SECRET, body, self.headers.get("X-Line-Signature", "")):
            self._respond(403, b"bad signature")
            return
        try:
            events = json.loads(body.decode("utf-8")).get("events", [])
        except ValueError:
            self._respond(400, b"bad json")
            return
        if events:
            DATA_DIR.mkdir(parents=True, exist_ok=True)
            received = datetime.now(JST).strftime("%Y-%m-%dT%H:%M:%S")
            with EVENTS_PATH.open("a", encoding="utf-8") as f:
                for event in events:
                    f.write(json.dumps({"recv": received, "event": event},
                                       ensure_ascii=False) + "\n")
        self._respond(200, b"OK")

    def log_message(self, fmt: str, *args) -> None:  # アクセスログは stdout に1行
        print(f"{self.address_string()} {fmt % args}", flush=True)


def main() -> int:
    if not CHANNEL_SECRET or not EXPORT_TOKEN:
        print("warning: LINE_CHANNEL_SECRET / EXPORT_TOKEN が未設定", file=sys.stderr)
    host = os.environ.get("BIND_HOST", "0.0.0.0")
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer((host, port), Handler)
    server.names = NameCache()  # type: ignore[attr-defined]
    print(f"line-dump-bot listening on {host}:{port}, data={DATA_DIR}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
