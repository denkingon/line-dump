"""mac/sync.sh のテスト（取り込み → commit → push と、画像の歯止め）。

一時ディレクトリに「origin（bare）」と「Mac の clone」を作り、本物の sync.sh を
走らせる。git と bash があれば Linux でも macOS でも動く。
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent

MAC_EXPORT = """\
2026.10.20 火曜日
10:00 田中 おはよう
10:01 自分 おはよう！
10:02 田中 今日どうする？
10:03 自分 昼に行こう
10:04 田中 了解
10:05 自分 じゃあまた
10:06 田中 またね
10:07 自分 👍
"""


@unittest.skipUnless(shutil.which("git") and shutil.which("bash"), "git と bash が要る")
class TestSyncSh(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.origin = self.tmp / "origin.git"
        self.work = self.tmp / "work"
        self.raw = self.tmp / "raw"
        self.env = dict(os.environ,
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com",
                        LINE_DUMP_REPO=str(self.work), LINE_DUMP_RAW_DIR=str(self.raw),
                        LINE_DUMP_PYTHON=shutil.which("python3") or "python3")
        self.git("init", "-q", "--bare", "-b", "main", str(self.origin), cwd=self.tmp)
        self.work.mkdir()
        for rel in ("scripts/ingest.py", "scripts/line_parser.py", "mac/sync.sh", ".gitignore"):
            dst = self.work / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(REPO / rel, dst)
        (self.work / "chats").mkdir()
        (self.work / "chats/.gitkeep").write_text("")
        self.git("init", "-q", "-b", "main")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "init")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "origin", "main")
        self.raw.mkdir()
        (self.raw / "[LINE]田中_20261020.txt").write_text(MAC_EXPORT, encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, *args, cwd=None):
        return subprocess.run(["git", *args], cwd=cwd or self.work, env=self.env,
                              check=True, capture_output=True, text=True).stdout

    def sync(self):
        return subprocess.run(["bash", str(self.work / "mac/sync.sh")], cwd=self.tmp,
                              env=self.env, capture_output=True, text=True, timeout=120)

    def origin_log(self):
        return self.git("--git-dir", str(self.origin), "log", "--oneline", "main", cwd=self.tmp)

    def test_ingests_commits_and_pushes(self):
        r = self.sync()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("push 完了", r.stdout)
        self.assertIn("LINE書き出しを取り込み", self.origin_log())
        self.assertTrue((self.work / "chats/田中.txt").exists())

    def test_refuses_to_push_images(self):
        shot = self.work / "mac/debug/20261020-070312_Berry_トーク確認.png"
        shot.parent.mkdir(parents=True)
        shot.write_bytes(b"\x89PNG\r\n\x1a\n")
        (self.work / "mac/stray.jpg").write_bytes(b"\x89PNG\r\n\x1a\n")
        before = self.origin_log()
        r = self.sync()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("画像ファイル", r.stdout)
        self.assertIn("mac/stray.jpg", r.stdout)
        self.assertEqual(self.origin_log(), before, "何も push していない")
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "", "index も元に戻した")
        self.assertNotIn("debug", r.stdout, "mac/debug/ は .gitignore で最初から入らない")


if __name__ == "__main__":
    unittest.main()
