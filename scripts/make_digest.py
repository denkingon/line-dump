"""raw/*.txt の LINE トーク履歴から日次ダイジェストを生成する。

LINE のエクスポートは毎回「全履歴」なので、state/state.json に取り込み済み
位置を記録し、前回以降の新着メッセージだけを daily/YYYY-MM-DD.md に書き出す。

使い方:
    python3 scripts/make_digest.py                # 今日(JST)のダイジェストを生成
    python3 scripts/make_digest.py --dry-run      # 書き込まずに新着件数だけ確認
    python3 scripts/make_digest.py --date 2026-07-14 --first-days 3

差分検出の仕組み:
  - チャットごとに last_ts（取り込み済みの最終メッセージ時刻）を持つ
  - LINE の時刻は分精度で同一分に複数メッセージが並ぶため、last_ts の
    直近 48h(COMPARE_WINDOW)は メッセージのハッシュ集合(seen)とも突き合わせる
  - seen には直近 72h(SEEN_RETENTION)分のハッシュだけ保持し、肥大化を防ぐ
  - 初めて見るチャットは直近 --first-days 日分だけ取り込む
    （全履歴が初回ダイジェストに丸ごと載るのを防ぐ）

出力の最終行は機械可読なサマリ:
    SUMMARY: total=<新着件数> chats=<新着のあったトーク数> file=<出力パス>
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from line_parser import ChatLog, Message, parse_chat_file  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = REPO_ROOT / "raw"
DAILY_DIR = REPO_ROOT / "daily"
STATE_PATH = REPO_ROOT / "state" / "state.json"

JST = timezone(timedelta(hours=9))
COMPARE_WINDOW = timedelta(hours=48)   # last_ts からこの範囲はハッシュで重複判定
SEEN_RETENTION = timedelta(hours=72)   # seen ハッシュの保持期間
TS_FORMAT = "%Y-%m-%dT%H:%M"
WEEKDAYS_JA = ["月", "火", "水", "木", "金", "土", "日"]


def msg_key(msg: Message) -> str:
    raw = f"{msg.ts.strftime(TS_FORMAT)}|{msg.sender or ''}|{msg.text}"
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]


def load_state() -> dict:
    if STATE_PATH.exists():
        return json.loads(STATE_PATH.read_text(encoding="utf-8"))
    return {"version": 1, "chats": {}}


def save_state(state: dict) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(
        json.dumps(state, ensure_ascii=False, indent=1, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def collect_chats() -> dict[str, ChatLog]:
    """raw/*.txt をパースし、トーク名でマージ(重複ファイル対策)して返す。"""
    chats: dict[str, ChatLog] = {}
    for path in sorted(RAW_DIR.glob("*.txt")):
        log = parse_chat_file(path)
        if log.skipped_lines:
            print(f"warn: {path.name}: 解釈できない行が {log.skipped_lines} 行", file=sys.stderr)
        if log.name in chats:
            chats[log.name].messages.extend(log.messages)
            chats[log.name].skipped_lines += log.skipped_lines
        else:
            chats[log.name] = log
    # 同一トークの重複ファイルをハッシュで dedupe し、時系列に整列
    for log in chats.values():
        uniq: dict[str, Message] = {}
        for m in log.messages:
            uniq.setdefault(msg_key(m), m)
        log.messages = sorted(uniq.values(), key=lambda m: m.ts)
    return chats


def find_new_messages(
    log: ChatLog, chat_state: dict | None, first_baseline: datetime
) -> list[Message]:
    """state と突き合わせて未取り込みのメッセージを返す。"""
    if not log.messages:
        return []
    if chat_state is None:
        # 初回: 直近 first_days 分だけを新着扱いにする
        return [m for m in log.messages if m.ts >= first_baseline]
    last_ts = datetime.strptime(chat_state["last_ts"], TS_FORMAT)
    window_start = last_ts - COMPARE_WINDOW
    seen = set(chat_state.get("seen", []))
    return [
        m for m in log.messages
        if m.ts >= window_start and msg_key(m) not in seen
    ]


def updated_chat_state(log: ChatLog, chat_state: dict | None, now: datetime) -> dict:
    """取り込み後のチャット state を作る。last_ts は決して巻き戻さない。"""
    max_ts = max(m.ts for m in log.messages)
    if chat_state is not None:
        prev = datetime.strptime(chat_state["last_ts"], TS_FORMAT)
        max_ts = max(max_ts, prev)
    keep_from = max_ts - SEEN_RETENTION
    seen = sorted(msg_key(m) for m in log.messages if m.ts >= keep_from)
    return {
        "last_ts": max_ts.strftime(TS_FORMAT),
        "seen": seen,
        "updated_at": now.strftime(TS_FORMAT),
    }


def format_message(msg: Message) -> str:
    sender = msg.sender if msg.sender is not None else "(システム)"
    text = msg.text.replace("\n", "\n  ")  # 複数行はインデントして続ける
    return f"- **{msg.ts:%H:%M}** {sender}: {text}"


def build_digest(
    digest_date: date, new_by_chat: dict[str, list[Message]], now: datetime
) -> str:
    total = sum(len(v) for v in new_by_chat.values())
    wd = WEEKDAYS_JA[digest_date.weekday()]
    lines = [
        f"# LINE ダイジェスト — {digest_date.isoformat()} ({wd})",
        "",
        f"新着 **{total}件** / {len(new_by_chat)}トーク（{now:%Y-%m-%d %H:%M} 取り込み）",
    ]
    for chat_name in sorted(new_by_chat, key=lambda n: new_by_chat[n][-1].ts, reverse=True):
        msgs = new_by_chat[chat_name]
        lines += ["", f"## {chat_name} — {len(msgs)}件"]
        current_day: date | None = None
        for m in msgs:
            if m.ts.date() != current_day:
                current_day = m.ts.date()
                wd = WEEKDAYS_JA[current_day.weekday()]
                lines += ["", f"### {current_day:%Y/%m/%d} ({wd})", ""]
            lines.append(format_message(m))
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--date", help="ダイジェストの日付 YYYY-MM-DD（既定: 今日 JST）")
    ap.add_argument("--first-days", type=int, default=3,
                    help="初めて見るトークで遡って取り込む日数（既定: 3）")
    ap.add_argument("--dry-run", action="store_true",
                    help="state もダイジェストも書き込まない")
    args = ap.parse_args(argv)

    now = datetime.now(JST).replace(tzinfo=None)
    digest_date = date.fromisoformat(args.date) if args.date else now.date()
    first_baseline = datetime.combine(
        digest_date - timedelta(days=args.first_days), datetime.min.time()
    )

    chats = collect_chats()
    if not chats:
        print("raw/ に txt がありません")
        print("SUMMARY: total=0 chats=0 file=none")
        return 0

    state = load_state()
    new_by_chat: dict[str, list[Message]] = {}
    for name, log in sorted(chats.items()):
        if not log.messages:
            continue
        chat_state = state["chats"].get(name)
        new = find_new_messages(log, chat_state, first_baseline)
        if new:
            new_by_chat[name] = new
        state["chats"][name] = updated_chat_state(log, chat_state, now)
        print(f"{name}: 全{len(log.messages)}件 / 新着{len(new)}件")

    total = sum(len(v) for v in new_by_chat.values())
    out_path = DAILY_DIR / f"{digest_date.isoformat()}.md"

    if total == 0:
        if not args.dry_run:
            save_state(state)
        print("SUMMARY: total=0 chats=0 file=none")
        return 0

    digest = build_digest(digest_date, new_by_chat, now)
    if not args.dry_run:
        DAILY_DIR.mkdir(parents=True, exist_ok=True)
        if out_path.exists():
            # 同じ日に2回実行した場合は追記にする
            existing = out_path.read_text(encoding="utf-8")
            body = digest.split("\n", 1)[1].lstrip("\n")  # 追記側の H1 は落とす
            digest = f"{existing}\n---\n\n## 追記（{now:%H:%M}）\n\n{body}"
        out_path.write_text(digest, encoding="utf-8")
        save_state(state)

    rel = out_path.relative_to(REPO_ROOT)
    print(f"SUMMARY: total={total} chats={len(new_by_chat)} file={rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
