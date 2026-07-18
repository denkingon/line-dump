"""取得済みメッセージ JSON を txt アーカイブに追記する汎用取り込み。

入力はどの経路でも同じ形:
    {"next_cursor": <文字列or数値>,
     "chats": [{"key": "<一意なチャットID>", "name": "<表示名>",
                "messages": [{"ts": "2026-07-18T10:21", "sender": "田中", "text": "..."}]}]}

経路ごとに出力先ディレクトリを分ける:
  - LINE Bot   → bot/    (server/app.py の /export が入力。カーソルは行番号)
  - Slack      → slack/  (Routine が Slack MCP の読取結果から入力を組み立てる。
                          カーソルは Slack の message ts 文字列)

形式は LINE エクスポート互換（日付行 + 「HH:MM\t送信者\t本文」）。
sender が null の行はシステムメッセージ（タブ1つの2フィールド形式）。

状態ファイル（コミット対象、出力先ディレクトリ内）:
  .cursor      取り込み済みカーソル（意味は経路依存・そのまま保存して次回渡す）
  .chats.json  チャットID → ファイル名の対応（同名チャットの衝突回避）

使い方:
    python3 scripts/bot_ingest.py <export.json>          # bot/ へ（'-' で stdin）
    python3 scripts/bot_ingest.py --dir slack <in.json>  # slack/ へ

出力の最終行は機械可読サマリ:
    SUMMARY: chats=<更新チャット数> messages=<追記メッセージ数> cursor=<新カーソル>
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ingest import safe_filename  # noqa: E402
from line_parser import _DATE_LINE  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
BOT_DIR = REPO_ROOT / "bot"
CURSOR_PATH = BOT_DIR / ".cursor"
CHATS_MAP_PATH = BOT_DIR / ".chats.json"

WEEKDAYS_JA = ["月", "火", "水", "木", "金", "土", "日"]


def load_cursor(path: Path) -> str:
    if path.exists():
        return path.read_text(encoding="utf-8").strip()
    return "0"


def load_chats_map(path: Path) -> dict[str, str]:
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {}


def allocate_filename(name: str, chats_map: dict[str, str]) -> str:
    """チャット名からファイル名を割り当てる。同名の別チャットは (2) 等を付ける。"""
    used = set(chats_map.values())
    base = safe_filename(name)
    candidate = f"{base}.txt"
    n = 2
    while candidate in used:
        candidate = f"{base} ({n}).txt"
        n += 1
    return candidate


def last_date_in_file(path: Path) -> str | None:
    """既存アーカイブの最後の日付行（YYYY/MM/DD 部分）を返す。"""
    if not path.exists():
        return None
    for line in reversed(path.read_text(encoding="utf-8").splitlines()):
        m = _DATE_LINE.match(line)
        if m:
            return f"{int(m.group(1)):04d}/{int(m.group(2)):02d}/{int(m.group(3)):02d}"
    return None


def date_line(dt: datetime) -> str:
    return f"{dt:%Y/%m/%d}({WEEKDAYS_JA[dt.weekday()]})"


def append_messages(path: Path, name: str, messages: list[dict],
                    label: str = "LINE Bot") -> int:
    """メッセージをアーカイブに追記する。戻り値は追記件数。"""
    is_new = not path.exists()
    current_date = last_date_in_file(path)
    lines: list[str] = []
    if is_new:
        lines.append(f"[{label}] {name} のアーカイブ")
    appended = 0
    for msg in sorted(messages, key=lambda m: m.get("ts", "")):
        try:
            ts = datetime.strptime(msg["ts"], "%Y-%m-%dT%H:%M")
        except (ValueError, KeyError):
            continue
        day = f"{ts:%Y/%m/%d}"
        if day != current_date:
            current_date = day
            lines.append(date_line(ts))
        sender = msg.get("sender")
        text = msg.get("text", "")
        if sender is None:
            lines.append(f"{ts:%H:%M}\t{text}")
        else:
            lines.append(f"{ts:%H:%M}\t{sender}\t{text}")
        appended += 1
    if appended == 0:
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return appended


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("source", help="取り込む JSON（'-' で stdin）")
    ap.add_argument("--dir", dest="out_dir", default=None,
                    help="REPO_ROOT からの出力先ディレクトリ名（既定: bot）")
    ap.add_argument("--label", default="LINE Bot",
                    help="新規ファイルのヘッダに入れる経路名（既定: LINE Bot）")
    args = ap.parse_args(argv)

    if args.out_dir:
        target_dir = REPO_ROOT / args.out_dir
        cursor_path = target_dir / ".cursor"
        chats_map_path = target_dir / ".chats.json"
    else:
        target_dir, cursor_path, chats_map_path = BOT_DIR, CURSOR_PATH, CHATS_MAP_PATH

    raw = sys.stdin.read() if args.source == "-" else Path(args.source).read_text(encoding="utf-8")
    try:
        data = json.loads(raw)
    except ValueError as e:
        print(f"error: JSONが読めません: {e}", file=sys.stderr)
        return 1

    chats_map = load_chats_map(chats_map_path)
    total_msgs = 0
    updated_chats = 0
    for chat in data.get("chats", []):
        key, name = chat.get("key"), chat.get("name") or "unknown"
        if not key:
            continue
        if key not in chats_map:
            chats_map[key] = allocate_filename(name, chats_map)
        path = target_dir / chats_map[key]
        n = append_messages(path, name, chat.get("messages", []), label=args.label)
        if n:
            updated_chats += 1
            total_msgs += n
            print(f"{target_dir.name}/{chats_map[key]}: +{n}件")

    cursor = str(data.get("next_cursor", "")) or load_cursor(cursor_path)
    target_dir.mkdir(parents=True, exist_ok=True)
    cursor_path.write_text(f"{cursor}\n", encoding="utf-8")
    chats_map_path.write_text(
        json.dumps(chats_map, ensure_ascii=False, indent=1, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"SUMMARY: chats={updated_chats} messages={total_msgs} cursor={cursor}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
