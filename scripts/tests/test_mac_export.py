"""mac/line_export.lua（Hammerspoon・v4）のテストを unittest から回す。

本体は mac/tests/test_line_export.lua（hs.* を偽物にして「偽の LINE」を動かす）。
Hammerspoon と同じ Lua 5.4 が無い環境（Mac 標準など）ではスキップする。
"""
from __future__ import annotations

import shutil
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent


def _lua54() -> str | None:
    for name in ("lua5.4", "lua"):
        exe = shutil.which(name)
        if not exe:
            continue
        try:
            v = subprocess.run([exe, "-e", "io.write(_VERSION)"], capture_output=True,
                               text=True, timeout=10).stdout
        except OSError:
            continue
        if v.strip() == "Lua 5.4":
            return exe
    return None


LUA = _lua54()


@unittest.skipUnless(LUA, "Lua 5.4 が無い（brew install lua で入る）")
class TestMacExport(unittest.TestCase):
    def test_line_export_lua(self):
        r = subprocess.run([LUA, str(REPO / "mac/tests/test_line_export.lua")],
                           capture_output=True, text=True, timeout=600)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(" 0 failed", r.stdout)


if __name__ == "__main__":
    unittest.main()
