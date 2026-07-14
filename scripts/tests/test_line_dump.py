"""line_parser / ingest のテスト。

実行:
    cd <repo root> && python3 -m unittest discover -s scripts/tests -v
"""
from __future__ import annotations

import io
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import ingest  # noqa: E402
from line_parser import extract_chat_name, parse_chat_file, parse_chat_text  # noqa: E402

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

    def test_extract_chat_name(self):
        self.assertEqual(extract_chat_name(IOS_SAMPLE), "田中太郎")
        self.assertEqual(extract_chat_name("ヘッダなし本文\n", fallback="fb"), "fb")

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


def _export(name: str, body: str, saved_at: str = "2026/07/14 10:00") -> str:
    return f"[LINE] {name}とのトーク履歴\n保存日時：{saved_at}\n\n{body}"


def _run(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc = ingest.main(list(argv))
    return rc, out.getvalue(), err.getvalue()


class TestIngest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self._orig = (ingest.REPO_ROOT, ingest.CHATS_DIR)
        ingest.REPO_ROOT = self.tmp
        ingest.CHATS_DIR = self.tmp / "chats"
        self.incoming = self.tmp / "incoming"
        self.incoming.mkdir()

    def tearDown(self):
        ingest.REPO_ROOT, ingest.CHATS_DIR = self._orig
        shutil.rmtree(self.tmp)

    def _incoming(self, filename: str, text: str, mtime: float | None = None) -> Path:
        p = self.incoming / filename
        p.write_text(text, encoding="utf-8")
        if mtime is not None:
            os.utime(p, (mtime, mtime))
        return p

    def test_new_chat_creates_canonical_file(self):
        text = _export("田中太郎", "2026/07/12(日)\n10:00\t田中太郎\tおはよう\n")
        p = self._incoming("[LINE] 田中太郎とのトーク履歴.txt", text)
        rc, out, _ = _run(str(p))
        self.assertEqual(rc, 0)
        self.assertIn("SUMMARY: updated=1 unchanged=0 skipped=0 added_lines=2 added_messages=1", out)
        dest = ingest.CHATS_DIR / "田中太郎.txt"
        self.assertEqual(dest.read_text(encoding="utf-8"), text)

    def test_identical_body_different_header_is_unchanged(self):
        body = "2026/07/12(日)\n10:00\t田中\tおはよう\n"
        p1 = self._incoming("a.txt", _export("田中", body, "2026/07/14 10:00"))
        _run(str(p1))
        # 保存日時だけ違う再エクスポート → 変化なし扱い(コミット汚れを防ぐ)
        p2 = self._incoming("b.txt", _export("田中", body, "2026/07/15 09:00"))
        rc, out, _ = _run(str(p2))
        self.assertEqual(rc, 0)
        self.assertIn("unchanged=1", out)
        self.assertIn("updated=0", out)

    def test_superset_replaces(self):
        p1 = self._incoming("a.txt", _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n"))
        _run(str(p1))
        new_text = _export("田中", (
            "2026/07/12(日)\n10:00\t田中\t一通目\n10:00\t田中\t同じ分の新着\n"
            "2026/07/13(月)\n09:00\t田中\t翌日の新着\n"
        ), "2026/07/15 09:00")
        p2 = self._incoming("b.txt", new_text)
        rc, out, err = _run(str(p2))
        self.assertIn("updated=1", out)
        self.assertIn("added_lines=3 added_messages=2", out)
        self.assertEqual(err, "")  # 素直な追記なので警告なし
        dest = ingest.CHATS_DIR / "田中.txt"
        self.assertEqual(dest.read_text(encoding="utf-8"), new_text)

    def test_shorter_export_is_skipped(self):
        long_text = _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n10:01\t田中\t二通目\n")
        p1 = self._incoming("a.txt", long_text)
        _run(str(p1))
        p2 = self._incoming("b.txt", _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n"))
        rc, out, err = _run(str(p2))
        self.assertEqual(rc, 0)
        self.assertIn("skipped=1", out)
        self.assertIn("短い", err)
        dest = ingest.CHATS_DIR / "田中.txt"
        self.assertEqual(dest.read_text(encoding="utf-8"), long_text)

    def test_shorter_export_with_force_replaces(self):
        p1 = self._incoming("a.txt", _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n10:01\t田中\t二通目\n"))
        _run(str(p1))
        short_text = _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n")
        p2 = self._incoming("b.txt", short_text)
        rc, out, _ = _run("--force", str(p2))
        self.assertIn("updated=1", out)
        dest = ingest.CHATS_DIR / "田中.txt"
        self.assertEqual(dest.read_text(encoding="utf-8"), short_text)

    def test_rewritten_history_replaces_with_warning(self):
        p1 = self._incoming("a.txt", _export("田中", "2026/07/12(日)\n10:00\t田中\t消される予定\n10:01\t田中\t残る\n"))
        _run(str(p1))
        new_text = _export("田中", (
            "2026/07/12(日)\n10:00\t田中\tメッセージの送信を取り消しました\n"
            "10:01\t田中\t残る\n10:02\t田中\t新着\n"
        ))
        p2 = self._incoming("b.txt", new_text)
        rc, out, err = _run(str(p2))
        self.assertIn("updated=1", out)
        self.assertIn("履歴の途中", err)
        self.assertEqual(
            (ingest.CHATS_DIR / "田中.txt").read_text(encoding="utf-8"), new_text
        )

    def test_multiple_files_same_chat_newest_wins(self):
        old = _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n")
        new = _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n10:01\t田中\t二通目\n")
        # Drive の重複保存を想定: 「... (1).txt」が最新
        p_old = self._incoming("[LINE] 田中とのトーク履歴.txt", old, mtime=1000)
        p_new = self._incoming("[LINE] 田中とのトーク履歴 (1).txt", new, mtime=2000)
        rc, out, _ = _run(str(p_new), str(p_old))  # 引数順に関係なく mtime 順
        self.assertIn("updated=2", out)
        self.assertEqual(
            (ingest.CHATS_DIR / "田中.txt").read_text(encoding="utf-8"), new
        )

    def test_unsafe_chat_name_sanitized(self):
        text = _export("A/B:C", "2026/07/12(日)\n10:00\tA\thi\n")
        p = self._incoming("x.txt", text)
        _run(str(p))
        self.assertTrue((ingest.CHATS_DIR / "A_B_C.txt").exists())

    def test_headerless_file_uses_filename(self):
        text = "2026/07/12(日)\n10:00\t山田\thi\n"
        p = self._incoming("[LINE] 山田とのトーク履歴 (3).txt", text)
        _run(str(p))
        self.assertTrue((ingest.CHATS_DIR / "山田.txt").exists())

    def test_missing_file_errors(self):
        rc, _, err = _run(str(self.incoming / "nai.txt"))
        self.assertEqual(rc, 1)
        self.assertIn("ファイルがありません", err)

    def test_bom_input_handled(self):
        text = "﻿" + _export("田中", "2026/07/12(日)\n10:00\t田中\tおはよう\n")
        p = self._incoming("a.txt", text)
        rc, out, _ = _run(str(p))
        self.assertIn("updated=1", out)
        self.assertIn("added_messages=1", out)


if __name__ == "__main__":
    unittest.main()
