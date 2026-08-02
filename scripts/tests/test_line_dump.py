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
[LINE] グループAのトーク履歴
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
        self.assertEqual(chat.name, "グループA")
        self.assertEqual(len(chat.messages), 2)
        self.assertEqual(
            chat.messages[0].text,
            '複数行の\nメッセージです\n彼は "OK" と言った',
        )
        self.assertEqual(chat.messages[1].text, "ふつうの行")

    def test_asymmetric_quote_not_swallowed(self):
        # 「"」で始まるだけの生メッセージが後続を飲み込まないこと
        text = (
            "[LINE] 田中とのトーク履歴\n保存日時：2026/07/14 10:00\n\n"
            "2026/07/12(日)\n"
            '10:00\t田中\t"あの件どうなった？\n'
            "10:01\t田中\t次のメッセージ\n"
            "10:02\t田中\tさらに次\n"
        )
        chat = parse_chat_text(text)
        self.assertEqual(len(chat.messages), 3)
        self.assertEqual(chat.messages[0].text, '"あの件どうなった？')
        self.assertEqual(chat.messages[1].text, "次のメッセージ")

    def test_date_variants(self):
        for date_line in ("2026/07/12(日)", "2026年7月12日(日)",
                          "2026/07/12 土曜日", "2026/07/12(Sat)",
                          "2026.07.12 Sunday"):
            text = f"{date_line}\n10:00\tA\thello\n"
            chat = parse_chat_text(text)
            self.assertEqual(len(chat.messages), 1, msg=date_line)
            self.assertEqual(chat.messages[0].ts, datetime(2026, 7, 12, 10, 0))

    def test_bare_date_in_body_is_not_date_switch(self):
        # 本文中の曜日なしの日付行は日付切替と誤認しない（継続行として残る）
        text = (
            "2026/07/12(日)\n"
            "10:00\t田中\t明日の予定:\n"
            "2026/07/13\n"
            "10:05\t田中\t了解\n"
        )
        chat = parse_chat_text(text)
        self.assertEqual(len(chat.messages), 2)
        self.assertEqual(chat.messages[0].text, "明日の予定:\n2026/07/13")
        self.assertEqual(chat.messages[1].ts, datetime(2026, 7, 12, 10, 5))

    def test_header_variants(self):
        # 1:1 / グループ / 英語（プレフィックスあり・なし）
        cases = [
            ("[LINE] 田中太郎とのトーク履歴", "田中太郎"),
            ("[LINE] 家族のトーク履歴", "家族"),
            ("[LINE] Chat history with Alice", "Alice"),
            ("Chat history in My Group", "My Group"),
        ]
        for header, expected in cases:
            text = f"{header}\n保存日時：2026/07/14 10:00\n\n2026/07/12(日)\n10:00\tA\thi\n"
            self.assertEqual(extract_chat_name(text), expected, msg=header)

    def test_fallback_name_from_filename(self):
        # 実際のエクスポートファイル名は「[LINE] ○○とのトーク.txt」（「履歴」なし）
        with tempfile.TemporaryDirectory() as tmp:
            for fname, expected in [
                ("[LINE] 山田花子とのトーク.txt", "山田花子"),
                ("[LINE] 家族のトーク.txt", "家族"),
                ("[LINE] 山田花子とのトーク (1).txt", "山田花子"),
                ("[LINE] 田中太郎とのトーク履歴.txt", "田中太郎"),
            ]:
                p = Path(tmp) / fname
                p.write_text("2026/07/12(日)\n10:00\tA\thi\n", encoding="utf-8")
                chat = parse_chat_file(p)
                self.assertEqual(chat.name, expected, msg=fname)

    def test_garbage_lines_counted(self):
        chat = parse_chat_text("ゴミヘッダ行\nさらにゴミ\n")
        self.assertEqual(chat.messages, [])
        self.assertGreaterEqual(chat.skipped_lines, 1)


MAC_SAMPLE = """\
2024.03.31 日曜日
18:04 H Village はじめまして！H Villageです。
友だち追加ありがとうございます
2024.04.03 水曜日
09:25 H Village 画像
"""


class TestMacFormat(unittest.TestCase):
    """Mac 版アプリの「トークを保存」形式（スペース区切り・ヘッダ無し）。"""

    def test_messages_parsed(self):
        chat = parse_chat_text(MAC_SAMPLE)
        self.assertEqual(len(chat.messages), 2)
        self.assertEqual(chat.messages[0].ts, datetime(2024, 3, 31, 18, 4))
        # 送信者と本文はスペースで分離できないため text にまとめて持つ
        self.assertEqual(
            chat.messages[0].text,
            "H Village はじめまして！H Villageです。\n友だち追加ありがとうございます",
        )
        self.assertEqual(chat.messages[1].ts, datetime(2024, 4, 3, 9, 25))

    def test_count_messages_both_formats(self):
        self.assertEqual(ingest.count_messages(ingest.content_lines(MAC_SAMPLE)), 2)
        self.assertEqual(ingest.count_messages(ingest.content_lines(IOS_SAMPLE)), 6)

    def test_am_pm_text_not_counted_as_message(self):
        # 英文中の「9:00 AM」は時が1桁なのでメッセージ行と誤検出しない
        from line_parser import is_message_line
        self.assertFalse(is_message_line("9:00 AM meeting starts"))
        self.assertTrue(is_message_line("09:00 Alice 会議です"))

    def test_mac_filenames(self):
        with tempfile.TemporaryDirectory() as tmp:
            for fname, expected in [
                ("[LINE]H Village.txt", "H Village"),
                ("[LINE] Chat with Berry.txt", "Berry"),
                ("[LINE]H Village 2.txt", "H Village"),
            ]:
                p = Path(tmp) / fname
                p.write_text(MAC_SAMPLE, encoding="utf-8")
                self.assertEqual(parse_chat_file(p).name, expected, msg=fname)


def _export(name: str, body: str, saved_at: str = "2026/07/14 10:00",
            group: bool = False) -> str:
    joint = "の" if group else "との"
    return f"[LINE] {name}{joint}トーク履歴\n保存日時：{saved_at}\n\n{body}"


def _msgs(n: int, start: int = 0) -> list[str]:
    """テスト用のメッセージ行を n 個生成する（10:00, 10:01, ...）。"""
    return [f"10:{i:02d}\t田中\tメッセージ{i}" for i in range(start, start + n)]


def _body(lines: list[str]) -> str:
    return "2026/07/12(日)\n" + "\n".join(lines) + "\n"


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
        p = self._incoming("[LINE] 田中太郎とのトーク.txt", text)
        rc, out, _ = _run(str(p))
        self.assertEqual(rc, 0)
        self.assertIn(
            "SUMMARY: updated=1 unchanged=0 skipped=0 errors=0 "
            "added_lines=2 added_messages=1", out)
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

    def test_stale_export_quietly_ignored(self):
        # 取り込み済みの先頭部分と一致する古いエクスポート → 警告なしで無視
        long_text = _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n10:01\t田中\t二通目\n")
        _run(str(self._incoming("a.txt", long_text)))
        p2 = self._incoming("b.txt", _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n"))
        rc, out, err = _run(str(p2))
        self.assertEqual(rc, 0)
        self.assertIn("unchanged=1", out)
        self.assertIn("旧版", out)
        self.assertEqual(err, "")
        self.assertEqual(
            (ingest.CHATS_DIR / "田中.txt").read_text(encoding="utf-8"), long_text)

    def test_shorter_diverging_export_is_skipped(self):
        # 先頭(アンカー)は一致するが途中から違い、かつ短い = 部分エクスポート等
        long_text = _export("田中", _body(_msgs(30)))
        _run(str(self._incoming("a.txt", long_text)))
        short_diverged = _export("田中", _body(_msgs(24) + ["10:24\t田中\t違う内容"]))
        rc, out, err = _run(str(self._incoming("b.txt", short_diverged)))
        self.assertEqual(rc, 0)
        self.assertIn("skipped=1", out)
        self.assertIn("短い", err)
        self.assertEqual(
            (ingest.CHATS_DIR / "田中.txt").read_text(encoding="utf-8"), long_text)

    def test_shorter_export_with_force_replaces(self):
        _run(str(self._incoming("a.txt", _export("田中", _body(_msgs(30))))))
        short_text = _export("田中", _body(_msgs(24) + ["10:24\t田中\t違う内容"]))
        p2 = self._incoming("b.txt", short_text)
        rc, out, _ = _run("--force", str(p2))
        self.assertIn("updated=1", out)
        self.assertEqual(
            (ingest.CHATS_DIR / "田中.txt").read_text(encoding="utf-8"), short_text)

    def test_rewritten_history_replaces_with_warning(self):
        # アンカーより後ろでの送信取消(途中の行が変わる) + 末尾に新着
        old_lines = _msgs(25)
        _run(str(self._incoming("a.txt", _export("田中", _body(old_lines)))))
        new_lines = list(old_lines)
        new_lines[22] = "10:22\t田中\tメッセージの送信を取り消しました"
        new_text = _export("田中", _body(new_lines + ["10:25\t田中\t新着"]))
        p2 = self._incoming("b.txt", new_text)
        rc, out, err = _run(str(p2))
        self.assertIn("updated=1", out)
        self.assertIn("履歴の途中", err)
        self.assertEqual(
            (ingest.CHATS_DIR / "田中.txt").read_text(encoding="utf-8"), new_text
        )

    def test_homonym_talks_get_separate_files(self):
        # 同じ表示名「田中」の 1:1 とグループ → 別ファイルに分かれ、履歴を奪い合わない
        one = _export("田中", "2026/07/12(日)\n10:00\t田中\t1:1のメッセージ\n")
        grp = _export("田中", "2026/07/12(日)\n11:00\t佐藤\tグループのメッセージ\n", group=True)
        _run(str(self._incoming("a.txt", one, mtime=1000)))
        rc, out, err = _run(str(self._incoming("b.txt", grp, mtime=2000)))
        self.assertIn("updated=1", out)
        self.assertIn("同名の別トーク", err)
        self.assertEqual(
            (ingest.CHATS_DIR / "田中.txt").read_text(encoding="utf-8"), one)
        self.assertEqual(
            (ingest.CHATS_DIR / "田中 (2).txt").read_text(encoding="utf-8"), grp)
        # それぞれの続きが正しいファイルに入る
        grp2 = _export("田中", (
            "2026/07/12(日)\n11:00\t佐藤\tグループのメッセージ\n11:05\t佐藤\t続き\n"
        ), group=True)
        rc, out, err = _run(str(self._incoming("c.txt", grp2, mtime=3000)))
        self.assertIn("updated=1", out)
        self.assertEqual(err, "")
        self.assertEqual(
            (ingest.CHATS_DIR / "田中 (2).txt").read_text(encoding="utf-8"), grp2)
        self.assertEqual(
            (ingest.CHATS_DIR / "田中.txt").read_text(encoding="utf-8"), one)

    def test_sanitize_collision_gets_separate_files(self):
        a = _export("A/B", "2026/07/12(日)\n10:00\tA\tスラッシュの方\n")
        b = _export("A:B", "2026/07/12(日)\n10:00\tB\tコロンの方\n")
        _run(str(self._incoming("a.txt", a, mtime=1000)))
        rc, out, err = _run(str(self._incoming("b.txt", b, mtime=2000)))
        self.assertIn("同名の別トーク", err)
        self.assertEqual(
            (ingest.CHATS_DIR / "A_B.txt").read_text(encoding="utf-8"), a)
        self.assertEqual(
            (ingest.CHATS_DIR / "A_B (2).txt").read_text(encoding="utf-8"), b)

    def test_empty_body_file_is_ignored(self):
        p1 = self._incoming("empty.txt", "")
        p2 = self._incoming("header_only.txt",
                            "[LINE] 空トークとのトーク履歴\n保存日時：2026/07/14 10:00\n\n")
        rc, out, err = _run(str(p1), str(p2))
        self.assertEqual(rc, 0)
        self.assertIn("skipped=2", out)
        self.assertIn("本文0行", err)
        self.assertFalse(ingest.CHATS_DIR.exists())

    def test_unreadable_file_does_not_stop_batch(self):
        bad = self.incoming / "bad.txt"
        bad.write_text(_export("壊", "2026/07/12(日)\n10:00\tA\thi\n"), encoding="utf-16")
        os.utime(bad, (1000, 1000))
        good = self._incoming("good.txt",
                              _export("田中", "2026/07/12(日)\n10:00\t田中\tおはよう\n"),
                              mtime=2000)
        rc, out, err = _run(str(bad), str(good))
        self.assertEqual(rc, 1)  # errors>0 の合図
        self.assertIn("errors=1", out)
        self.assertIn("updated=1", out)
        self.assertIn("error: ", err)
        self.assertTrue((ingest.CHATS_DIR / "田中.txt").exists())

    def test_multiple_files_same_chat_newest_wins(self):
        old = _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n")
        new = _export("田中", "2026/07/12(日)\n10:00\t田中\t一通目\n10:01\t田中\t二通目\n")
        # Drive の重複保存を想定: 「... (1).txt」が最新
        p_old = self._incoming("[LINE] 田中とのトーク.txt", old, mtime=1000)
        p_new = self._incoming("[LINE] 田中とのトーク (1).txt", new, mtime=2000)
        rc, out, _ = _run(str(p_new), str(p_old))  # 引数順に関係なく mtime 順
        self.assertIn("updated=2", out)
        self.assertEqual(
            (ingest.CHATS_DIR / "田中.txt").read_text(encoding="utf-8"), new
        )
        self.assertFalse((ingest.CHATS_DIR / "田中 (2).txt").exists())

    def test_headerless_file_uses_filename(self):
        text = "2026/07/12(日)\n10:00\t山田\thi\n"
        p = self._incoming("[LINE] 山田とのトーク (3).txt", text)
        _run(str(p))
        self.assertTrue((ingest.CHATS_DIR / "山田.txt").exists())

    def test_missing_file_counted_as_error(self):
        rc, out, err = _run(str(self.incoming / "nai.txt"))
        self.assertEqual(rc, 1)
        self.assertIn("errors=1", out)
        self.assertIn("error: ", err)

    def test_bom_input_handled(self):
        text = "﻿" + _export("田中", "2026/07/12(日)\n10:00\t田中\tおはよう\n")
        p = self._incoming("a.txt", text)
        rc, out, _ = _run(str(p))
        self.assertIn("updated=1", out)
        self.assertIn("added_messages=1", out)

    def test_mac_export_ingested(self):
        # Mac 版の書き出し（ヘッダ無し・スペース区切り）も取り込める
        p = self._incoming("[LINE]H Village.txt", MAC_SAMPLE)
        rc, out, _ = _run(str(p))
        self.assertEqual(rc, 0)
        self.assertIn("added_messages=2", out)
        dest = ingest.CHATS_DIR / "H Village.txt"
        self.assertEqual(dest.read_text(encoding="utf-8"), MAC_SAMPLE)
        # 追記された再エクスポート → 差分が正しく数えられる
        p2 = self._incoming("[LINE]H Village.txt",
                            MAC_SAMPLE + "10:00 H Village 新着です\n", mtime=9000)
        rc, out, err = _run(str(p2))
        self.assertIn("updated=1", out)
        self.assertIn("added_messages=1", out)
        self.assertEqual(err, "")


if __name__ == "__main__":
    unittest.main()
