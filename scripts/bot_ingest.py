"""Bot サーバーの /export JSON を bot/ 配下の txt アーカイブに追記する。

Bot 経由のメッセージは手動エクスポート（chats/）とは出所が違うので、
bot/<チャット名>.txt に分けて蓄積する。形式は LINE エクスポート互換
（日付行 + 「HH:MM\t送信者\t本文」）に揃える。

状態ファイル（コミット対象）:
  bot/.cursor      サーバー側イベントログの取り込み済み行数
  bot/.chats.json  チャットID → ファイル名の対応（同名チャットの衝突回避）

使い方:
    python3 scripts/bot_ingest.py <export.json>   # '-' で stdin

出力の最終行は機械可読サマリ:
    SUMMARY: chats=<更新チャット数> messages=<追記メッセージ数> cursor=<新カーソル>
"""
from __future__ import annotations

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


def load_cursor() -> int:
    if CURSOR_PATH.exists():
        try:
            return int(CURSOR_PATH.read_text().strip())
        except ValueError:
            return 0
    return 0


def load_chats_map() -> dict[str, str]:
    if CHATS_MAP_PATH.exists():
        return json.loads(CHATS_MAP_PATH.read_text(encoding="utf-8"))
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


def append_messages(path: Path, name: str, messages: list[dict]) -> int:
    """メッセージをアーカイブに追記する。戻り値は追記件数。"""
    BOT_DIR.mkdir(parents=True, exist_ok=True)
    is_new = not path.exists()
    current_date = last_date_in_file(path)
    lines: list[str] = []
    if is_new:
        lines.append(f"[LINE Bot] {name} のアーカイブ")
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
    with path.open("a", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return appended


def main(argv: list[str] | None = None) -> int:
    args = argv if argv is not None else sys.argv[1:]
    if len(args) != 1:
        print("usage: bot_ingest.py <export.json | ->", file=sys.stderr)
        return 2
    raw = sys.stdin.read() if args[0] == "-" else Path(args[0]).read_text(encoding="utf-8")
    try:
        data = json.loads(raw)
    except ValueError as e:
        print(f"error: JSONが読めません: {e}", file=sys.stderr)
        return 1

    chats_map = load_chats_map()
    total_msgs = 0
    updated_chats = 0
    for chat in data.get("chats", []):
        key, name = chat.get("key"), chat.get("name") or "unknown"
        if not key:
            continue
        if key not in chats_map:
            chats_map[key] = allocate_filename(name, chats_map)
        path = BOT_DIR / chats_map[key]
        n = append_messages(path, name, chat.get("messages", []))
        if n:
            updated_chats += 1
            total_msgs += n
            print(f"bot/{chats_map[key]}: +{n}件")

    cursor = int(data.get("next_cursor", load_cursor()))
    BOT_DIR.mkdir(parents=True, exist_ok=True)
    CURSOR_PATH.write_text(f"{cursor}\n")
    CHATS_MAP_PATH.write_text(
        json.dumps(chats_map, ensure_ascii=False, indent=1, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"SUMMARY: chats={updated_chats} messages={total_msgs} cursor={cursor}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
