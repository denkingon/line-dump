"""LINE エクスポート txt を chats/ の正本に取り込む。

LINE の「トーク履歴を送信」は毎回**全履歴**を出力するので、正本の更新は
「最新エクスポートで前のファイルを置き換える」が基本方針。過去の版はすべて
git 履歴に残るため、置き換えても失われるものはない。

安全ガード:
  - 新しいエクスポートが前回より**短い**場合（部分エクスポート・誤ファイル・
    LINE 側での履歴全削除など）は置き換えをスキップして警告（--force で強制）。
    ただし前回の先頭部分と完全一致する場合は「古いエクスポート」なので静かに無視。
  - **同名の別トーク**（同じ表示名の 1:1 とグループなど）は本文の先頭
    （アンカー行）で見分け、別トークなら「<名前> (2).txt」として別ファイルに保存。
  - 本文0行のファイルは正本を作らない（ダウンロード失敗・無関係ファイル対策）。
  - 読めないファイル（非UTF-8等）はそのファイルだけ error 扱いにして続行。

使い方:
    python3 scripts/ingest.py <export1.txt> [<export2.txt> ...]
    python3 scripts/ingest.py --force <export.txt>

複数ファイルは更新時刻の古い順に処理する（同じトークが複数あれば最新が勝つ）。

出力の最終行は機械可読サマリ（rc は errors>0 のとき 1）:
    SUMMARY: updated=<置き換え数> unchanged=<変化なし数> skipped=<スキップ数> \
errors=<読込失敗数> added_lines=<追加行数> added_messages=<追加メッセージ数>
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

# 同一トーク判定に使う本文先頭のアンカー行数。全履歴エクスポート同士なら
# 同じトークは先頭が一致し、別トークは最初の数行で必ず食い違う。
ANCHOR_LINES = 20


def warn(msg: str) -> None:
    print(f"warn: {msg}", file=sys.stderr)


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


def _same_talk(a: list[str], b: list[str]) -> bool:
    """本文の先頭アンカーが一致すれば同じトークとみなす。"""
    if not a or not b:
        return True
    n = min(len(a), len(b), ANCHOR_LINES)
    return a[:n] == b[:n]


def resolve_dest(name: str, new_body: list[str]) -> tuple[Path, list[str] | None, bool]:
    """トーク名と本文アンカーから正本ファイルを解決する。

    戻り値: (正本パス, 既存の本文 or None, 同名別トークとして新規割当てしたか)
    """
    base = safe_filename(name)
    pat = re.compile(rf"^{re.escape(base)}(?: \((\d+)\))?\.txt$")
    candidates = (
        [p for p in sorted(CHATS_DIR.iterdir()) if pat.match(p.name)]
        if CHATS_DIR.is_dir() else []
    )
    for dest in candidates:
        old_body = content_lines(dest.read_text(encoding="utf-8-sig"))
        if _same_talk(old_body, new_body):
            return dest, old_body, False
    if not candidates:
        return CHATS_DIR / f"{base}.txt", None, False
    used = {int(m.group(1)) for p in candidates
            if (m := pat.match(p.name)) and m.group(1)}
    n = 2
    while n in used:
        n += 1
    return CHATS_DIR / f"{base} ({n}).txt", None, True


def ingest_file(path: Path, force: bool) -> tuple[str, int, int]:
    """1ファイルを取り込む。戻り値は (結果, 追加行数, 追加メッセージ数)。

    結果は "updated" | "unchanged" | "skipped"。読込失敗は例外のまま上げる。
    """
    text = path.read_text(encoding="utf-8-sig")
    name = extract_chat_name(text, fallback=fallback_name_from_filename(path))
    new_body = content_lines(text)
    dest, old_body, is_homonym = resolve_dest(name, new_body)
    rel = dest.relative_to(REPO_ROOT)

    if old_body is None:
        if not new_body:
            warn(f"{path.name}: 本文0行のため無視（ダウンロード失敗や無関係なファイルの可能性）")
            return "skipped", 0, 0
        if is_homonym:
            warn(f"{path.name}: 同名の別トークを検出 → {rel} として保存")
        _write(dest, text)
        print(f"{rel}: 新規 ({len(new_body)}行)")
        return "updated", len(new_body), count_messages(new_body)

    if new_body == old_body:
        print(f"{rel}: 変化なし")
        return "unchanged", 0, 0

    if len(new_body) < len(old_body):
        if new_body == old_body[: len(new_body)]:
            # 取り込み済み内容の先頭部分と完全一致 = 古いエクスポート。静かに無視
            print(f"{rel}: 旧版（取り込み済み）")
            return "unchanged", 0, 0
        if not force:
            warn(
                f"{rel}: 新エクスポートが前回より短い "
                f"({len(old_body)}行 → {len(new_body)}行)。データ消失を防ぐため置き換えを"
                "スキップ。意図的なら --force を付けて再実行"
            )
            return "skipped", 0, 0

    if old_body != new_body[: len(old_body)]:
        warn(
            f"{rel}: 履歴の途中が前回と異なる（送信取消・削除の可能性）。"
            "最新版で置き換える（前の版は git 履歴に残る）"
        )

    added = len(new_body) - len(old_body)
    added_msgs = count_messages(new_body) - count_messages(old_body)
    _write(dest, text)
    print(f"{rel}: 置き換え ({added:+d}行)")
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

    # 古い順に処理 → 同じトークに複数ファイルがあっても最新が最後に勝つ
    paths = sorted(
        (Path(p) for p in args.files),
        key=lambda p: p.stat().st_mtime if p.is_file() else 0.0,
    )

    counts = {"updated": 0, "unchanged": 0, "skipped": 0, "errors": 0}
    added_lines = 0
    added_messages = 0
    for p in paths:
        try:
            result, lines, msgs = ingest_file(p, force=args.force)
        except Exception as e:  # 1ファイルの失敗でバッチ全体を止めない
            print(f"error: {p}: {e}", file=sys.stderr)
            counts["errors"] += 1
            continue
        counts[result] += 1
        added_lines += lines
        added_messages += msgs

    print(
        f"SUMMARY: updated={counts['updated']} unchanged={counts['unchanged']} "
        f"skipped={counts['skipped']} errors={counts['errors']} "
        f"added_lines={added_lines} added_messages={added_messages}"
    )
    return 1 if counts["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
