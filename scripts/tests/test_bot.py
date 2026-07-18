"""server/app.py（純粋関数部分）と bot_ingest のテスト。"""
from __future__ import annotations

import io
import json
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO / "server"))

import app  # noqa: E402  (server/app.py)
import bot_ingest  # noqa: E402


class DummyNames:
    def chat_name(self, source):
        return {"group": "家族", "room": "複数人", "user": "自分"}[source["type"]]

    def sender_name(self, source):
        return "田中"


class TestServerPure(unittest.TestCase):
    def test_verify_signature(self):
        import base64
        import hashlib
        import hmac
        body = b'{"events":[]}'
        secret = "secret123"
        sig = base64.b64encode(
            hmac.new(secret.encode(), body, hashlib.sha256).digest()
        ).decode()
        self.assertTrue(app.verify_signature(secret, body, sig))
        self.assertFalse(app.verify_signature(secret, body, "invalid"))
        self.assertFalse(app.verify_signature(secret, b"tampered", sig))
        self.assertFalse(app.verify_signature(secret, body, ""))

    def test_message_text_placeholders(self):
        self.assertEqual(app.message_text({"type": "text", "text": "hi"}), "hi")
        self.assertEqual(app.message_text({"type": "sticker"}), "[スタンプ]")
        self.assertEqual(
            app.message_text({"type": "file", "fileName": "a.pdf"}), "[ファイル] a.pdf")
        self.assertEqual(
            app.message_text({"type": "location", "address": "東京"}), "[位置情報] 東京")

    def test_event_to_message(self):
        names = DummyNames()
        # 2026-07-18 10:21 JST (01:21 UTC) の ms epoch
        ev = {
            "type": "message", "timestamp": 1784337660000,
            "source": {"type": "group", "groupId": "g1", "userId": "u1"},
            "message": {"type": "text", "text": "おはよう"},
        }
        key, name, msg = app.event_to_message(ev, names)
        self.assertEqual(key, "group:g1")
        self.assertEqual(name, "家族")
        self.assertEqual(msg["sender"], "田中")
        self.assertEqual(msg["text"], "おはよう")
        self.assertEqual(msg["ts"], "2026-07-18T10:21")

        join = {"type": "join", "timestamp": 1784337660000,
                "source": {"type": "group", "groupId": "g1"}}
        _, _, jmsg = app.event_to_message(join, names)
        self.assertIsNone(jmsg["sender"])
        self.assertIn("アーカイブ開始", jmsg["text"])

        self.assertIsNone(app.event_to_message(
            {"type": "follow", "timestamp": 0, "source": {"type": "user", "userId": "u"}},
            names))

    def test_build_export_cursor_and_dedup(self):
        tmp = Path(tempfile.mkdtemp())
        orig = app.EVENTS_PATH
        app.EVENTS_PATH = tmp / "events.jsonl"
        try:
            ev = {
                "type": "message", "timestamp": 1784337660000,
                "webhookEventId": "W1",
                "source": {"type": "group", "groupId": "g1", "userId": "u1"},
                "message": {"type": "text", "text": "一通目"},
            }
            ev2 = dict(ev, webhookEventId="W2",
                       message={"type": "text", "text": "二通目"})
            with app.EVENTS_PATH.open("w", encoding="utf-8") as f:
                f.write(json.dumps({"recv": "r", "event": ev}) + "\n")
                f.write(json.dumps({"recv": "r", "event": ev}) + "\n")   # 再配送
                f.write(json.dumps({"recv": "r", "event": ev2}) + "\n")
            out = app.build_export(0, DummyNames())
            self.assertEqual(out["next_cursor"], 3)
            msgs = out["chats"][0]["messages"]
            self.assertEqual([m["text"] for m in msgs], ["一通目", "二通目"])
            # カーソル以降だけ
            out2 = app.build_export(2, DummyNames())
            self.assertEqual(out2["next_cursor"], 3)
            self.assertEqual(len(out2["chats"][0]["messages"]), 1)
            # 末尾まで読んだ後は空
            out3 = app.build_export(3, DummyNames())
            self.assertEqual(out3["next_cursor"], 3)
            self.assertEqual(out3["chats"], [])
        finally:
            app.EVENTS_PATH = orig
            shutil.rmtree(tmp)


def _run(payload: dict) -> str:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False,
                                     encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
        path = f.name
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = bot_ingest.main([path])
    Path(path).unlink()
    assert rc == 0, buf.getvalue()
    return buf.getvalue()


class TestBotIngest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self._orig = (bot_ingest.REPO_ROOT, bot_ingest.BOT_DIR,
                      bot_ingest.CURSOR_PATH, bot_ingest.CHATS_MAP_PATH)
        bot_ingest.REPO_ROOT = self.tmp
        bot_ingest.BOT_DIR = self.tmp / "bot"
        bot_ingest.CURSOR_PATH = self.tmp / "bot" / ".cursor"
        bot_ingest.CHATS_MAP_PATH = self.tmp / "bot" / ".chats.json"

    def tearDown(self):
        (bot_ingest.REPO_ROOT, bot_ingest.BOT_DIR,
         bot_ingest.CURSOR_PATH, bot_ingest.CHATS_MAP_PATH) = self._orig
        shutil.rmtree(self.tmp)

    def test_new_chat_archive(self):
        out = _run({
            "next_cursor": 5,
            "chats": [{"key": "group:g1", "name": "家族", "messages": [
                {"ts": "2026-07-18T10:21", "sender": "田中", "text": "おはよう"},
                {"ts": "2026-07-18T10:22", "sender": None, "text": "（メンバーが参加しました）"},
                {"ts": "2026-07-19T09:00", "sender": "母", "text": "翌日の分"},
            ]}],
        })
        self.assertIn("SUMMARY: chats=1 messages=3 cursor=5", out)
        content = (bot_ingest.BOT_DIR / "家族.txt").read_text(encoding="utf-8")
        self.assertEqual(content, (
            "[LINE Bot] 家族 のアーカイブ\n"
            "2026/07/18(土)\n"
            "10:21\t田中\tおはよう\n"
            "10:22\t（メンバーが参加しました）\n"
            "2026/07/19(日)\n"
            "09:00\t母\t翌日の分\n"
        ))
        self.assertEqual((bot_ingest.CURSOR_PATH).read_text().strip(), "5")

    def test_append_same_day_no_duplicate_date_line(self):
        _run({"next_cursor": 1, "chats": [{"key": "group:g1", "name": "家族", "messages": [
            {"ts": "2026-07-18T10:21", "sender": "田中", "text": "一通目"}]}]})
        out = _run({"next_cursor": 2, "chats": [{"key": "group:g1", "name": "家族", "messages": [
            {"ts": "2026-07-18T11:00", "sender": "田中", "text": "二通目"}]}]})
        self.assertIn("messages=1", out)
        content = (bot_ingest.BOT_DIR / "家族.txt").read_text(encoding="utf-8")
        self.assertEqual(content.count("2026/07/18(土)"), 1)
        self.assertIn("11:00\t田中\t二通目", content)

    def test_homonym_chats_separate_files(self):
        _run({"next_cursor": 1, "chats": [
            {"key": "group:g1", "name": "田中",
             "messages": [{"ts": "2026-07-18T10:00", "sender": "田中", "text": "グループ"}]},
            {"key": "user:u1", "name": "田中",
             "messages": [{"ts": "2026-07-18T10:01", "sender": "田中", "text": "1:1"}]},
        ]})
        self.assertTrue((bot_ingest.BOT_DIR / "田中.txt").exists())
        self.assertTrue((bot_ingest.BOT_DIR / "田中 (2).txt").exists())
        # 2回目以降も同じファイルに追記される
        _run({"next_cursor": 2, "chats": [
            {"key": "user:u1", "name": "田中",
             "messages": [{"ts": "2026-07-18T10:05", "sender": "田中", "text": "続き"}]},
        ]})
        self.assertIn("続き", (bot_ingest.BOT_DIR / "田中 (2).txt").read_text(encoding="utf-8"))

    def test_empty_export_only_updates_cursor(self):
        out = _run({"next_cursor": 42, "chats": []})
        self.assertIn("SUMMARY: chats=0 messages=0 cursor=42", out)
        self.assertEqual((bot_ingest.CURSOR_PATH).read_text().strip(), "42")

    def test_slack_dir_and_label(self):
        # --dir slack: 別ディレクトリ・独自カーソル(Slackのts文字列)・独自ヘッダ
        payload = {
            "next_cursor": "1771626089.297989",
            "chats": [{"key": "slack:D083CBP73KK", "name": "Slackメモ", "messages": [
                {"ts": "2026-07-18T12:00", "sender": "村田", "text": "メモ1"}]}],
        }
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False,
                                         encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False)
            path = f.name
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = bot_ingest.main(["--dir", "slack", "--label", "Slack", path])
        Path(path).unlink()
        self.assertEqual(rc, 0)
        out = buf.getvalue()
        self.assertIn("SUMMARY: chats=1 messages=1 cursor=1771626089.297989", out)
        slack_dir = bot_ingest.REPO_ROOT / "slack"
        content = (slack_dir / "Slackメモ.txt").read_text(encoding="utf-8")
        self.assertTrue(content.startswith("[Slack] Slackメモ のアーカイブ\n"))
        self.assertIn("12:00\t村田\tメモ1", content)
        self.assertEqual((slack_dir / ".cursor").read_text().strip(),
                         "1771626089.297989")
        # bot/ 側の状態には触れない
        self.assertFalse(bot_ingest.CURSOR_PATH.exists())


if __name__ == "__main__":
    unittest.main()
