"""line_parser / make_digest のテスト。

実行:
    cd <repo root> && python3 -m unittest discover -s scripts/tests -v
"""
from __future__ import annotations

import io
import json
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import make_digest  # noqa: E402
from line_parser import parse_chat_file, parse_chat_text  # noqa: E402

IOS_SAMPLE = """\
[LINE] 田中太郎とのトーク履歴
保存日時：2026/07/14 10:00

2026/07/12(日)
10:21\t田中太郎\tおはよう
10:22\t自分\tおはよう！
今日どうする？
10:23\t田中太郎\t[スタンプ]
2026/07/13(月)
午後3:04\t田中太郎\t午後のメッセージ
午前12:05\t自分\t深夜のメッセージ
21:00\t☎ 通話時間 1:23
"""

QUOTED_SAMPLE = """\
[LINE] グループAとのトーク履歴
保存日時：2026/07/14 10:00

2026/07/12(日)
10:21\t佐藤\t"複数行の
メッセージです
彼は ""OK"" と言った"
10:22\t鈴木\tふつうの行
"""


class TestParser(unittest.TestCase):
    def test_ios_basic(self):
        chat = parse_chat_text(IOS_SAMPLE)
        self.assertEqual(chat.name, "田中太郎")
        self.assertEqual(len(chat.messages), 6)
        m = chat.messages[0]
        self.assertEqual(m.ts, datetime(2026, 7, 12, 10, 21))
        self.assertEqual(m.sender, "田中太郎")
        self.assertEqual(m.text, "おはよう")
        self.assertEqual(chat.skipped_lines, 0)

    def test_multiline_continuation(self):
        chat = parse_chat_text(IOS_SAMPLE)
        self.assertEqual(chat.messages[1].text, "おはよう！\n今日どうする？")

    def test_gozen_gogo(self):
        chat = parse_chat_text(IOS_SAMPLE)
        self.assertEqual(chat.messages[3].ts, datetime(2026, 7, 13, 15, 4))
        self.assertEqual(chat.messages[4].ts, datetime(2026, 7, 13, 0, 5))

    def test_system_message(self):
        chat = parse_chat_text(IOS_SAMPLE)
        sys_msg = chat.messages[5]
        self.assertIsNone(sys_msg.sender)
        self.assertEqual(sys_msg.text, "☎ 通話時間 1:23")

    def test_quoted_multiline(self):
        chat = parse_chat_text(QUOTED_SAMPLE)
        self.assertEqual(len(chat.messages), 2)
        self.assertEqual(
            chat.messages[0].text,
            '複数行の\nメッセージです\n彼は "OK" と言った',
        )
        self.assertEqual(chat.messages[1].text, "ふつうの行")

    def test_date_variants(self):
        for date_line in ("2026/07/12(日)", "2026.07.12", "2026年7月12日(日)",
                          "2026/07/12 土曜日", "2026/07/12(Sat)"):
            text = f"{date_line}\n10:00\tA\thello\n"
            chat = parse_chat_text(text)
            self.assertEqual(len(chat.messages), 1, msg=date_line)
            self.assertEqual(chat.messages[0].ts, datetime(2026, 7, 12, 10, 0))

    def test_english_header(self):
        text = "[LINE] Chat history with Alice\nSaved on: 2026/07/14\n\n2026/07/12(Sun)\n10:00\tAlice\thi\n"
        chat = parse_chat_text(text)
        self.assertEqual(chat.name, "Alice")
        self.assertEqual(len(chat.messages), 1)

    def test_fallback_name_from_filename(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "[LINE] 山田花子とのトーク履歴.txt"
            p.write_text("2026/07/12(日)\n10:00\t山田花子\thi\n", encoding="utf-8")
            chat = parse_chat_file(p)
            self.assertEqual(chat.name, "山田花子")

    def test_garbage_lines_counted(self):
        chat = parse_chat_text("ゴミヘッダ行\nさらにゴミ\n")
        self.assertEqual(chat.messages, [])
        self.assertGreaterEqual(chat.skipped_lines, 1)


def _write_raw(name: str, body: str) -> None:
    (make_digest.RAW_DIR / f"[LINE] {name}とのトーク履歴.txt").write_text(
        body, encoding="utf-8"
    )


def _run(*argv: str) -> str:
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = make_digest.main(list(argv))
    out = buf.getvalue()
    assert rc == 0, out
    return out


class TestDigest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self._orig = (make_digest.REPO_ROOT, make_digest.RAW_DIR,
                      make_digest.DAILY_DIR, make_digest.STATE_PATH)
        make_digest.REPO_ROOT = self.tmp
        make_digest.RAW_DIR = self.tmp / "raw"
        make_digest.DAILY_DIR = self.tmp / "daily"
        make_digest.STATE_PATH = self.tmp / "state" / "state.json"
        make_digest.RAW_DIR.mkdir()

    def tearDown(self):
        (make_digest.REPO_ROOT, make_digest.RAW_DIR,
         make_digest.DAILY_DIR, make_digest.STATE_PATH) = self._orig
        shutil.rmtree(self.tmp)

    def test_first_run_respects_first_days(self):
        _write_raw("田中", (
            "2026/07/01(水)\n10:00\t田中\t古いメッセージ\n"
            "2026/07/13(月)\n10:00\t田中\t新しいメッセージ\n"
        ))
        out = _run("--date", "2026-07-14", "--first-days", "3")
        self.assertIn("SUMMARY: total=1 chats=1", out)
        digest = (make_digest.DAILY_DIR / "2026-07-14.md").read_text(encoding="utf-8")
        self.assertIn("新しいメッセージ", digest)
        self.assertNotIn("古いメッセージ", digest)
        # 古いメッセージも「取り込み済み」として state に反映されている
        state = json.loads(make_digest.STATE_PATH.read_text(encoding="utf-8"))
        self.assertEqual(state["chats"]["田中"]["last_ts"], "2026-07-13T10:00")

    def test_incremental_no_duplicates(self):
        _write_raw("田中", "2026/07/13(月)\n10:00\t田中\t一通目\n")
        _run("--date", "2026-07-14")
        # 再エクスポート: 同じ内容 + 新着2件（うち1件は同一分内）
        _write_raw("田中", (
            "2026/07/13(月)\n10:00\t田中\t一通目\n10:00\t田中\t同じ分の新着\n"
            "2026/07/14(火)\n09:00\t田中\t翌日の新着\n"
        ))
        out = _run("--date", "2026-07-15")
        self.assertIn("SUMMARY: total=2 chats=1", out)
        digest = (make_digest.DAILY_DIR / "2026-07-15.md").read_text(encoding="utf-8")
        self.assertNotIn("一通目", digest)
        self.assertIn("同じ分の新着", digest)
        self.assertIn("翌日の新着", digest)

    def test_no_new_messages(self):
        _write_raw("田中", "2026/07/13(月)\n10:00\t田中\t一通目\n")
        _run("--date", "2026-07-14")
        out = _run("--date", "2026-07-15")
        self.assertIn("SUMMARY: total=0 chats=0 file=none", out)
        self.assertFalse((make_digest.DAILY_DIR / "2026-07-15.md").exists())

    def test_rerun_same_day_appends(self):
        _write_raw("田中", "2026/07/13(月)\n10:00\t田中\t一通目\n")
        _run("--date", "2026-07-14")
        _write_raw("田中", (
            "2026/07/13(月)\n10:00\t田中\t一通目\n"
            "2026/07/14(火)\n08:00\t田中\t二通目\n"
        ))
        _run("--date", "2026-07-14")
        digest = (make_digest.DAILY_DIR / "2026-07-14.md").read_text(encoding="utf-8")
        self.assertIn("一通目", digest)
        self.assertIn("追記", digest)
        self.assertIn("二通目", digest)
        # H1 見出しは1つだけ
        self.assertEqual(digest.count("# LINE ダイジェスト"), 1)

    def test_multiple_chats(self):
        _write_raw("田中", "2026/07/13(月)\n10:00\t田中\tこんにちは\n")
        _write_raw("グループB", "2026/07/13(月)\n11:00\t佐藤\tやあ\n")
        out = _run("--date", "2026-07-14")
        self.assertIn("SUMMARY: total=2 chats=2", out)
        digest = (make_digest.DAILY_DIR / "2026-07-14.md").read_text(encoding="utf-8")
        self.assertIn("## 田中", digest)
        self.assertIn("## グループB", digest)

    def test_duplicate_files_same_chat(self):
        # Drive の重複保存で同じトークの txt が2つある場合もダブらない
        _write_raw("田中", "2026/07/13(月)\n10:00\t田中\tこんにちは\n")
        (make_digest.RAW_DIR / "[LINE] 田中とのトーク履歴 (1).txt").write_text(
            "[LINE] 田中とのトーク履歴\n\n2026/07/13(月)\n10:00\t田中\tこんにちは\n",
            encoding="utf-8",
        )
        out = _run("--date", "2026-07-14")
        self.assertIn("SUMMARY: total=1 chats=1", out)

    def test_dry_run_writes_nothing(self):
        _write_raw("田中", "2026/07/13(月)\n10:00\t田中\tこんにちは\n")
        out = _run("--date", "2026-07-14", "--dry-run")
        self.assertIn("SUMMARY: total=1 chats=1", out)
        self.assertFalse(make_digest.STATE_PATH.exists())
        self.assertFalse((make_digest.DAILY_DIR / "2026-07-14.md").exists())

    def test_empty_raw_dir(self):
        out = _run("--date", "2026-07-14")
        self.assertIn("SUMMARY: total=0", out)


if __name__ == "__main__":
    unittest.main()
