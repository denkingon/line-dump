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
    extract_chat_name,
    fallback_name_from_filename,
    is_message_line,
    snapshot_key,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
CHATS_DIR = REPO_ROOT / "chats"

_UNSAFE_FILENAME = re.compile(r'[\\/:*?"<>|\x00-\x1f]')

# 同一トーク判定に使う本文先頭のアンカー行数。全履歴エクスポート同士なら
# 同じトークは先頭が一致し、別トークは最初の数行で必ず食い違う。
ANCHOR_LINES = 20

# 先頭が欠けたスナップショット同士をつなぐときに、重なりとみなす最小行数。
# 短すぎると別トークの定型あいさつ等で誤接合しうるので、時刻付きの行が
# 数行そろって一致することを要求する。
OVERLAP_LINES = 8


def warn(msg: str) -> None:
    print(f"warn: {msg}", file=sys.stderr)


def safe_filename(name: str) -> str:
    name = _UNSAFE_FILENAME.sub("_", name).strip().strip(".")
    return name or "unknown"


def split_header(text: str) -> tuple[str, list[str]]:
    """(ヘッダ, 本文行) に分ける。本文は最初の日付行から。

    「保存日時：...」はエクスポートのたびに変わるので、新旧比較は本文行
    だけで行う。改行コード差もここで吸収する。Mac 版はヘッダを持たない。
    """
    lines = [ln.rstrip("\r") for ln in text.splitlines()]
    for i, ln in enumerate(lines):
        if _DATE_LINE.match(ln):
            header = "\n".join(lines[:i]) + "\n" if i else ""
            return header, lines[i:]
    return text, []


def content_lines(text: str) -> list[str]:
    """ヘッダを除いた本文行を返す。"""
    return split_header(text)[1]


def count_messages(lines: list[str]) -> int:
    """メッセージ行（時刻で始まる行）の数を数える。スマホ版/Mac版の両形式。"""
    return sum(1 for ln in lines if is_message_line(ln))


def _find_block(hay: list[str], needle: list[str]) -> int:
    """hay の中で needle と完全一致する最初の位置。無ければ -1。"""
    n = len(needle)
    if n == 0 or n > len(hay):
        return -1
    first = needle[0]
    for i in range(len(hay) - n + 1):
        if hay[i] == first and hay[i:i + n] == needle:
            return i
    return -1


def merge_bodies(old: list[str], new: list[str]) -> list[str] | None:
    """同じトークの2つのスナップショットを結合する。無関係なら None。

    Mac 版の書き出しは「画面に読み込まれている範囲」しか出ないため、
    先頭が欠けた（途中から始まる）スナップショットが普通に発生する。
    重なりを見つけて連結し、履歴を落とさずに新着だけを足す。

    重なりは「一方の端が他方の中に現れるか」で探す。切り詰められた
    スナップショットも先頭に日付行を持つため、先頭同士の比較では
    合致しないことがある（実際にこれで別トーク扱いになる不具合が出た）。
    """
    if not old:
        return new
    if not new:
        return old
    if old == new:
        return old

    # どちらかがもう一方を完全に含む
    if len(new) >= len(old) and _find_block(new, old) >= 0:
        return new          # new の方が前にも後ろにも広い
    if len(old) >= len(new) and _find_block(old, new) >= 0:
        return old          # new は取り込み済みの一部

    k = OVERLAP_LINES
    if len(old) < k or len(new) < k:
        return None         # 短すぎて重なりを信頼できない

    # old の末尾が new の途中にある = new は old の続き（先頭が欠けていてよい）
    j = _find_block(new, old[-k:])
    if j >= 0:
        return old + new[j + k:]

    # new の末尾が old の先頭に重なる = new はより前まで遡れている
    j = _find_block(old, new[-k:])
    if j >= 0:
        overlap = j + k
        if len(new) >= overlap and new[-overlap:] == old[:overlap]:
            return new[:-overlap] + old

    return None


def _same_talk(a: list[str], b: list[str]) -> bool:
    """同じトークのスナップショット同士かを判定する。

    先頭アンカーが一致するか、どちらかがもう一方の続き（重なりあり）なら同一。
    """
    if not a or not b:
        return True
    n = min(len(a), len(b), ANCHOR_LINES)
    if a[:n] == b[:n]:
        return True
    return merge_bodies(a, b) is not None


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

    if old_body == new_body[: len(old_body)]:
        pass  # 素直な追記（末尾に増えただけ）。下の共通処理で置き換える
    else:
        # 先頭が欠けたスナップショット同士でも履歴を落とさないよう結合を試みる
        merged = merge_bodies(old_body, new_body)
        if merged is not None:
            if merged == old_body:
                print(f"{rel}: 旧版（取り込み済み）")
                return "unchanged", 0, 0
            added = len(merged) - len(old_body)
            added_msgs = count_messages(merged) - count_messages(old_body)
            # ヘッダは既存の正本のものを優先（Mac 版は元々ヘッダを持たない）
            old_header, _ = split_header(dest.read_text(encoding="utf-8-sig"))
            new_header, _ = split_header(text)
            _write(dest, (old_header or new_header) + "\n".join(merged) + "\n")
            print(f"{rel}: 結合 ({added:+d}行)")
            return "updated", added, added_msgs

        if len(new_body) < len(old_body):
            if not force:
                warn(
                    f"{rel}: 新エクスポートが前回より短く、重なりも見つからない "
                    f"({len(old_body)}行 → {len(new_body)}行)。データ消失を防ぐため"
                    "置き換えをスキップ。意図的なら --force を付けて再実行"
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

    # 古い順に処理 → 同じトークに複数ファイル（日ごとのスナップショット）が
    # あっても最新が最後に勝つ。ファイル名の日付を優先し、無ければ更新日時。
    paths = sorted((Path(p) for p in args.files), key=snapshot_key)

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
