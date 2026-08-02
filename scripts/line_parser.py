"""LINE トーク履歴 txt のパーサ。

iPhone / Android の「トーク履歴を送信」で出力される txt を構造化する。
日本語・英語エクスポートの両方に対応。標準ライブラリのみ使用。

想定フォーマット（iOS 日本語の例）:

    [LINE] 田中太郎とのトーク履歴
    保存日時：2026/07/14 10:00

    2026/07/12(日)
    10:21\t田中太郎\tおはよう
    10:22\t自分\tおはよう！
    10:23\t田中太郎\t"複数行の
    メッセージ"
    10:30\t☎ 通話時間 1:23

- 日付行で日が切り替わり、以降の時刻行がその日のメッセージになる
- タブ区切りが2フィールドしかない行はシステムメッセージ（sender=None）
- 時刻行にも日付行にも一致しない行は直前メッセージの続き（改行含むメッセージ）
- Android 形式の「"..."」による複数行クオートも解釈する
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path


@dataclass
class Message:
    ts: datetime  # 分精度（LINE の txt に秒は無い）
    sender: str | None  # None はシステムメッセージ（通話ログ・退出通知など）
    text: str


@dataclass
class ChatLog:
    name: str
    messages: list[Message] = field(default_factory=list)
    skipped_lines: int = 0  # 解釈できなかった行数（フォーマット崩れの検知用）


# ヘッダからトーク名を抜くパターン（上から順に試す）
# 1:1 は「○○とのトーク履歴」、グループは「○○のトーク履歴」（「との」なし）。
# 英語版は「Chat history with ○○」(1:1) /「Chat history in ○○」(グループ)で、
# 「[LINE] 」プレフィックスが付かない変種もある。
_HEADER_NAME_PATTERNS = [
    re.compile(r"^\[LINE\]\s*(.+?)(?:との|の)?トーク履歴\s*$"),
    re.compile(r"^(?:\[LINE\]\s*)?Chat history (?:with|in) (.+?)\s*$", re.IGNORECASE),
    re.compile(r"^(.+?)(?:との|の)?トーク履歴\s*$"),
]

_SAVED_AT = re.compile(r"^(?:保存日時|Saved on)\s*[:：]")

# 日付行: 「2026/07/12(日)」「2026.07.12 土曜日」「2026年7月12日(日)」など。
# 実際のエクスポートの日付行は日英とも必ず曜日付きなので、曜日を必須にして
# メッセージ本文中の裸の日付（「2026/07/12」だけの行）を誤認しないようにする。
_DATE_LINE = re.compile(
    r"^(\d{4})[/.年](\d{1,2})[/.月](\d{1,2})日?\s*"
    r"(?:\([^)]*\)|[月火水木金土日]曜日|,?\s*(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[A-Za-z]*)\s*$"
)

# 時刻行の先頭（スマホ版エクスポート・タブ区切り）: 「10:21」「午後3:04」「10:21 AM」
_TIME_LINE = re.compile(
    r"^(?:(午前|午後)\s*)?(\d{1,2}):(\d{2})(?:\s*(AM|PM))?\t(.*)$",
    re.IGNORECASE,
)

# 時刻行（Mac版アプリの「トークを保存」）: 「18:04 送信者 本文」
# タブが無く半角スペース区切り。時は必ず2桁ゼロ埋めなので、そこを固定して
# 本文中の「9:00 AM」のような表記をメッセージ行と誤検出しないようにする。
# 送信者と本文はスペースでは機械的に分離できないため、まとめて扱う。
_TIME_LINE_MAC = re.compile(r"^([01]\d|2[0-3]):([0-5]\d) (\S.*)$")


def is_message_line(line: str) -> bool:
    """スマホ版・Mac版どちらの形式でもメッセージ開始行なら True。"""
    return bool(_TIME_LINE.match(line) or _TIME_LINE_MAC.match(line))


def _to_hour24(hour: int, ampm: str | None) -> int:
    """午前/午後/AM/PM 付きの時を24時間制に変換する。"""
    if ampm is None:
        return hour
    ampm = ampm.upper()
    if ampm in ("午後", "PM"):
        return 12 if hour == 12 else hour + 12
    # 午前 / AM
    return 0 if hour == 12 else hour


def parse_chat_text(text: str, fallback_name: str = "unknown") -> ChatLog:
    """LINE エクスポート txt 全文をパースして ChatLog を返す。"""
    chat = ChatLog(name=fallback_name)
    current_date: date | None = None
    in_quote = False  # Android 形式の "..." 複数行メッセージの内側にいるか

    lines = text.splitlines()
    for i, raw_line in enumerate(lines):
        line = raw_line.rstrip("\r")

        # ── 複数行クオートの継続 ──
        if in_quote and chat.messages:
            # 「"」で始まるだけの生メッセージ（クオートではない）を誤って
            # 飲み込まないよう、時刻行/日付行が来たらクオートを打ち切って
            # その行を通常処理に流す（テキストはそのまま確定）。
            if _TIME_LINE.match(line) or _DATE_LINE.match(line):
                in_quote = False
            else:
                msg = chat.messages[-1]
                msg.text += "\n" + line
                if line.endswith('"'):
                    in_quote = False
                    msg.text = _strip_quotes(msg.text)
                continue

        # ── 日付行 ──
        m = _DATE_LINE.match(line)
        if m:
            try:
                current_date = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
            except ValueError:
                chat.skipped_lines += 1
            continue

        # ── 時刻行（メッセージ本体）──
        m = _TIME_LINE.match(line)
        if m and current_date is not None:
            ampm_pre, hh, mm, ampm_post, rest = m.groups()
            try:
                hour = _to_hour24(int(hh), ampm_pre or ampm_post)
                ts = datetime(
                    current_date.year, current_date.month, current_date.day,
                    hour, int(mm),
                )
            except ValueError:
                chat.skipped_lines += 1
                continue

            parts = rest.split("\t", 1)
            if len(parts) == 2:
                sender: str | None = parts[0] or None
                body = parts[1]
            else:
                sender = None  # 通話ログ・グループ退出などのシステム行
                body = parts[0]

            # Android 形式: 複数行メッセージは "..." で囲われる
            if body.startswith('"') and not (len(body) >= 2 and body.endswith('"')):
                in_quote = True

            chat.messages.append(Message(ts=ts, sender=sender, text=body))
            continue

        # ── 時刻行（Mac版アプリ形式）──
        m = _TIME_LINE_MAC.match(line)
        if m and current_date is not None:
            hh, mm, rest = m.groups()
            ts = datetime(
                current_date.year, current_date.month, current_date.day,
                int(hh), int(mm),
            )
            # Mac版は「送信者 本文」がスペース区切りで分離できないため、
            # sender は立てずに丸ごと text に持つ（詳細な分離が必要な場合は
            # line-chat-export スキルの normalize_line.py を使うこと）。
            chat.messages.append(Message(ts=ts, sender=None, text=rest))
            continue

        # ── ヘッダ行（最初のメッセージより前のみ）──
        if not chat.messages and current_date is None:
            if not line.strip() or _SAVED_AT.match(line):
                continue
            for pat in _HEADER_NAME_PATTERNS:
                m = pat.match(line)
                if m:
                    chat.name = m.group(1).strip()
                    break
            else:
                chat.skipped_lines += 1
            continue

        # ── 直前メッセージの続き（改行を含むメッセージ）──
        if chat.messages:
            if line.strip() or chat.messages[-1].text:
                chat.messages[-1].text += "\n" + line
        elif line.strip():
            chat.skipped_lines += 1

    # 末尾の後処理: クオートが閉じないまま終わった場合も外側の " を剥がす
    if in_quote and chat.messages:
        chat.messages[-1].text = _strip_quotes(chat.messages[-1].text)

    # メッセージ末尾の余分な空行を除去
    for msg in chat.messages:
        msg.text = msg.text.rstrip("\n")

    return chat


def _strip_quotes(text: str) -> str:
    """囲みクオートを剥がし、エスケープされた "" を " に戻す。"""
    if text.startswith('"') and text.endswith('"') and len(text) >= 2:
        text = text[1:-1]
    return text.replace('""', '"')


def extract_chat_name(text: str, fallback: str = "unknown") -> str:
    """ヘッダ行からトーク名を抜く。最初の日付行より前だけを見る。"""
    for line in text.splitlines()[:10]:
        line = line.rstrip("\r")
        if _DATE_LINE.match(line):
            break
        for pat in _HEADER_NAME_PATTERNS:
            m = pat.match(line)
            if m:
                return m.group(1).strip()
    return fallback


def fallback_name_from_filename(path: Path) -> str:
    """ファイル名からトーク名の代替を作る（Drive の重複サフィックスも除去）。

    実際のエクスポートのファイル名は「[LINE] ○○とのトーク.txt」(1:1) /
    「[LINE] ○○のトーク.txt」(グループ)で、ヘッダ行と違い「履歴」は付かない。
    Mac 版アプリは「[LINE]○○.txt」「[LINE] Chat with ○○.txt」の2系統。
    どの形式でも剥がせるようにしておく。
    """
    name = re.sub(r"^\[LINE\]\s*", "", path.stem)
    name = re.sub(r"^Chat with\s+", "", name, flags=re.IGNORECASE)  # Mac 版英語表示
    name = re.sub(r"\s*\(\d+\)$", "", name)  # 「... (1)」など Drive の重複保存
    name = re.sub(r"\s+\d+$", "", name)      # 「... 2」など macOS の重複保存
    name = re.sub(r"(?:との|の)?トーク(?:履歴)?$", "", name).strip()
    return name or path.stem


def parse_chat_file(path: Path) -> ChatLog:
    """txt ファイルをパースする。トーク名が取れない場合はファイル名を使う。"""
    text = path.read_text(encoding="utf-8-sig")
    return parse_chat_text(text, fallback_name=fallback_name_from_filename(path))
