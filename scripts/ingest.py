"""LINE エクスポート txt を chats/ の正本に取り込む。

LINE の「トーク履歴を送信」は毎回**全履歴**を出力するので、正本の更新は
「最新エクスポートで前のファイルを置き換える」が基本方針。過去の版はすべて
git 履歴に残るため、置き換えても失われるものはない。

ただし新しいエクスポートが前回より**短い**場合（部分エクスポート・誤った
ファイル・LINE 側での履歴全削除など）は、データ消失を防ぐため置き換えを
スキップして警告する。意図的な場合は --force で強制置き換え。

使い方:
    python3 scripts/ingest.py <export1.txt> [<export2.txt> ...]
    python3 scripts/ingest.py --force <export.txt>

複数ファイルは更新時刻の古い順に処理する（同じトークが複数あれば最新が勝つ）。

出力の最終行は機械可読サマリ:
    SUMMARY: updated=<置き換え数> unchanged=<変化なし数> skipped=<スキップ数> \
added_lines=<追加行数> added_messages=<追加メッセージ数>
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from line_parser import (  # noqa: E402
    _DATE_LINE,
    _TIME_LINE,
    extract_chat_name,
    fallback_name_from_filename,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
CHATS_DIR = REPO_ROOT / "chats"

_UNSAFE_FILENAME = re.compile(r'[\\/:*?"<>|\x00-\x1f]')


def safe_filename(name: str) -> str:
    name = _UNSAFE_FILENAME.sub("_", name).strip().strip(".")
    return name or "unknown"


def content_lines(text: str) -> list[str]:
    """ヘッダ（最初の日付行より前）を除いた本文行を返す。

    「保存日時：...」はエクスポートのたびに変わるので、新旧比較はこの
    本文行だけで行う。改行コード差も吸収する。
    """
    lines = [ln.rstrip("\r") for ln in text.splitlines()]
    for i, ln in enumerate(lines):
        if _DATE_LINE.match(ln):
            return lines[i:]
    return []


def count_messages(lines: list[str]) -> int:
    """メッセージ行（時刻で始まる行）の数を数える。"""
    return sum(1 for ln in lines if _TIME_LINE.match(ln))


def ingest_file(path: Path, force: bool) -> tuple[str, int, int]:
    """1ファイルを取り込む。戻り値は (結果, 追加行数, 追加メッセージ数)。

    結果は "updated" | "unchanged" | "skipped"。
    """
    text = path.read_text(encoding="utf-8-sig")
    name = extract_chat_name(text, fallback=fallback_name_from_filename(path))
    dest = CHATS_DIR / f"{safe_filename(name)}.txt"
    new_body = content_lines(text)

    if not dest.exists():
        _write(dest, text)
        n = len(new_body)
        print(f"{dest.relative_to(REPO_ROOT)}: 新規 ({n}行)")
        return "updated", n, count_messages(new_body)

    old_body = content_lines(dest.read_text(encoding="utf-8-sig"))

    if new_body == old_body:
        print(f"{dest.relative_to(REPO_ROOT)}: 変化なし")
        return "unchanged", 0, 0

    added = len(new_body) - len(old_body)
    added_msgs = count_messages(new_body) - count_messages(old_body)

    if len(new_body) < len(old_body) and not force:
        print(
            f"warn: {dest.relative_to(REPO_ROOT)}: 新エクスポートが前回より短い "
            f"({len(old_body)}行 → {len(new_body)}行)。データ消失を防ぐため置き換えを"
            "スキップ。意図的なら --force を付けて再実行",
            file=sys.stderr,
        )
        return "skipped", 0, 0

    if old_body != new_body[: len(old_body)]:
        print(
            f"warn: {dest.relative_to(REPO_ROOT)}: 履歴の途中が前回と異なる"
            "（送信取消・削除の可能性）。最新版で置き換える（前の版は git 履歴に残る）",
            file=sys.stderr,
        )

    _write(dest, text)
    print(f"{dest.relative_to(REPO_ROOT)}: 置き換え ({added:+d}行)")
    return "updated", added, added_msgs


def _write(dest: Path, text: str) -> None:
    CHATS_DIR.mkdir(parents=True, exist_ok=True)
    dest.write_text(text, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="+", help="取り込む LINE エクスポート txt")
    ap.add_argument("--force", action="store_true",
                    help="新エクスポートが前回より短くても置き換える")
    args = ap.parse_args(argv)

    paths = [Path(p) for p in args.files]
    for p in paths:
        if not p.is_file():
            print(f"error: ファイルがありません: {p}", file=sys.stderr)
            return 1
    # 古い順に処理 → 同じトークに複数ファイルがあっても最新が最後に勝つ
    paths.sort(key=lambda p: p.stat().st_mtime)

    counts = {"updated": 0, "unchanged": 0, "skipped": 0}
    added_lines = 0
    added_messages = 0
    for p in paths:
        result, lines, msgs = ingest_file(p, force=args.force)
        counts[result] += 1
        added_lines += lines
        added_messages += msgs

    print(
        f"SUMMARY: updated={counts['updated']} unchanged={counts['unchanged']} "
        f"skipped={counts['skipped']} added_lines={added_lines} "
        f"added_messages={added_messages}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
