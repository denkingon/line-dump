"""mac/line_export.lua（Hammerspoon・v4）のテストを unittest から回す。

本体は mac/tests/test_line_export.lua（hs.* を偽物にして「偽の LINE」を動かす）。
Lua 5.4 が無い環境（Mac 標準など）ではスキップする。
"""
from __future__ import annotations

import shutil
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
LUA = shutil.which("lua5.4") or shutil.which("lua")


@unittest.skipUnless(LUA, "lua が無い（brew install lua で入る）")
class TestMacExport(unittest.TestCase):
    def test_line_export_lua(self):
        r = subprocess.run([LUA, str(REPO / "mac/tests/test_line_export.lua")],
                           capture_output=True, text=True, timeout=300)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(" 0 failed", r.stdout)


if __name__ == "__main__":
    unittest.main()
