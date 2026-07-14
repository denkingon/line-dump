# LINE Dump

LINE のトーク履歴（txt）を毎日 Claude（Cowork）に届けるパイプライン。

## 全体の流れ

```
┌─ iPhone ────────────────────────────────────────────────┐
│ LINE → トーク履歴を送信 → Google ドライブ「LINE-exports」 │  ← 唯一の手動ステップ
└──────────────────────────────────────────────────────────┘
                     ↓  毎朝 07:00 JST（Claude Routine が自動発火）
┌─ Claude セッション ──────────────────────────────────────┐
│ 1. Drive の LINE-exports から txt を取得 → raw/ に保存    │
│ 2. python3 scripts/make_digest.py                         │
│    → 前回以降の新着だけを daily/YYYY-MM-DD.md に抽出      │
│ 3. git commit & push                                      │
│ 4. 新着があればプッシュ通知（件数と要点）                 │
└──────────────────────────────────────────────────────────┘
```

セッションは claude.ai / Cowork アプリから開けるので、毎朝そこに
「昨日の LINE の新着ダイジェスト」が届いている状態になる。

## なぜエクスポートだけ手動なのか

LINE にはトーク履歴を自動で外部に出す API が存在しない。公式の出口は
「トーク履歴を送信」で txt を共有することだけ。そこでこの設計にしている：

- **手動なのは「Drive に保存」だけ**。毎日でも週1でもいい。
- エクスポートは毎回**全履歴**が入るので、サボっても抜け漏れは起きない。
  `state/state.json` が取り込み済み位置を覚えていて、差分だけがダイジェストに載る。

## ディレクトリ構造

```
line-dump/
├── scripts/
│   ├── line_parser.py    LINE txt → 構造化（iOS/Android・日英対応）
│   ├── make_digest.py    差分検出 + daily/YYYY-MM-DD.md 生成
│   └── tests/            unittest（17件）
├── raw/                  Drive から取得した txt の原本（トークごとに最新版）
├── daily/                日次ダイジェスト（Cowork への「送信物」）
├── state/state.json      チャットごとの取り込み済み位置（差分検出用）
├── config.json           Drive フォルダ ID などの設定
└── docs/setup-iphone.md  iPhone 側のエクスポート手順
```

## コマンド

```bash
# ダイジェスト生成（Routine が毎朝実行するのと同じもの）
python3 scripts/make_digest.py

# 書き込まずに新着件数だけ確認
python3 scripts/make_digest.py --dry-run

# テスト
python3 -m unittest discover -s scripts/tests -v
```

出力の最終行は機械可読サマリ:
`SUMMARY: total=<新着件数> chats=<トーク数> file=<出力パス>`

## 差分検出の仕組み

- LINE の txt は分精度・秒なし。チャットごとに `last_ts`（最終取り込み時刻）を持ち、
  直近 48h は メッセージ内容の SHA-1 ハッシュ集合（`seen`）とも突き合わせるので、
  同じ分に増えたメッセージも取りこぼさない。
- `seen` は直近 72h 分だけ保持し、state.json の肥大化を防ぐ。
- 初めて見るトークは直近 3 日分だけ取り込む（`--first-days` で変更可）。
  全履歴が初回ダイジェストに丸ごと載るのを防ぐため。
- メッセージの削除・送信取消で履歴が変わっても壊れない（ハッシュ照合のため）。

## 日次 Routine（自動実行）の中身

Claude Code Remote の Routine が毎朝 07:00 JST（22:00 UTC）にこのリポジトリの
セッションへ発火する。セッションがやることは上の「全体の流れ」の 1〜4。
障害時は同じ手順を手動セッションでなぞれば復旧できる。

- Drive フォルダ: `LINE-exports`（ID は `config.json` 参照）
- 同名 txt が Drive に複数あっても、タイトルごとに最新版だけを取り込む
- 新着ゼロの日は通知なしで静かに終了

## プライバシー

このリポジトリには **LINE のトーク内容がそのまま** 入る（raw/ と daily/）。
必ず private リポジトリのまま運用すること。公開・共有は厳禁。
