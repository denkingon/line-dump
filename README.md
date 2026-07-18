# LINE Dump

LINE のトーク履歴（txt）を毎日 Cowork / Claude に届けるパイプライン。
届くのは要約ではなく **txt ファイルそのもの**。トークごとに1ファイル、常に最新の全履歴。

## 全体の流れ

取り込み経路は3つ。すべて毎朝 07:00 JST の Claude Routine が処理する。

```
【経路3: Slack 自分宛DM（完全自動・メモの取り込み口）】
Slack の自分宛 DM に書く ─→ Slack API で新着取得
                     ↓ bot_ingest.py --dir slack
              slack/Slackメモ.txt に追記

【経路2: 手動エクスポート（LINEの1:1トークも取れる唯一の方法）】
iPhone: LINE → トーク履歴を送信 → Google ドライブ「LINE-exports」
                     ↓ ingest.py
              chats/<トーク名>.txt を最新版で置き換え

【経路1: LINE Bot（任意・グループの完全自動化）】
LINE グループ ─→ webhook ─→ Fly.io「line-dump-bot」が蓄積
                     ↓ /export → bot_ingest.py
              bot/<チャット名>.txt に追記

              ↓ いずれも（毎朝 07:00 JST の Routine）
       git commit & push + 更新があればプッシュ通知
```

`slack/`・`chats/`・`bot/` が成果物。Cowork / Claude のセッションからも、
clone したローカルからも常に読める。Bot のセットアップは `docs/setup-line-bot.md` 参照。

## 更新ルール（ingest.py）

LINE の「トーク履歴を送信」は毎回**全履歴**を出力する。だから基本方針は
「**最新エクスポートで前のファイルを置き換える**」— 差分管理は git がやる。

| 新しいエクスポートが… | 動作 |
|---|---|
| 前回より増えているだけ | 置き換え（通常ケース） |
| 本文が同一（保存日時だけ違う） | 何もしない（コミットを汚さない） |
| 取り込み済み内容の先頭部分と一致（古いエクスポート） | 静かに無視 |
| 途中が変わっている（送信取消・削除） | 置き換え + 警告。前の版は git 履歴に残る |
| 前回より**短い**（部分エクスポート等） | **スキップ + 警告**（データ消失ガード）。意図的なら `--force` |
| 本文の**先頭から**違う（同名の別トーク） | `<名前> (2).txt` として**別ファイルに保存** + 警告 |
| 本文が0行（空・壊れたファイル） | 無視 + 警告 |
| 読めない（非UTF-8等） | そのファイルだけ error にして続行（rc=1） |

同一トークかどうかは本文の先頭20行（アンカー）で判定する。LINE のエクスポートは
毎回全履歴なので、同じトークなら先頭が一致し、別トークなら先頭から食い違う。

## 経路の使い分け

LINE には「他人との 1:1 トークを自動で外部に出す」公式 API が存在しない。
Bot（Messaging API）が見えるのは **Bot が参加しているグループ** と
**Bot 宛のメッセージ** だけ。Slack には普通に API がある。そこで:

| 取りたいもの | 経路 |
|---|---|
| 自分用メモ（いちばん手軽） | **Slack の自分宛 DM に書くだけ** → 毎朝自動で `slack/` に追記（経路3・稼働中） |
| 友だちとの 1:1 トーク | 手動エクスポート → Drive（経路2・稼働中）。毎回全履歴なのでサボっても抜けない |
| グループのトーク | 手動エクスポート（経路2）。完全自動にしたければ Bot をグループに招待（経路1・任意） |
| Bot 参加前のグループ履歴 | 手動エクスポートで補完（経路2） |

経路1（LINE Bot）は実装済みだがデプロイは任意（`docs/setup-line-bot.md`）。
グループに Bot を入れることが必須なので、使うかどうかは好みで。

## ディレクトリ構造

```
line-dump/
├── scripts/
│   ├── ingest.py         手動エクスポート txt → chats/ 正本の更新
│   ├── bot_ingest.py     Bot /export JSON → bot/ アーカイブへ追記
│   ├── line_parser.py    LINE txt の構造化（トーク名抽出・行判定に使用）
│   └── tests/            unittest（34件）
├── server/               LINE Bot webhook サーバー（Fly.io・標準ライブラリのみ）
│   ├── app.py            署名検証 + イベント蓄積 + /export API
│   ├── fly.toml          Fly.io 設定（app: line-dump-bot）
│   └── Dockerfile
├── chats/                手動エクスポートの正本 txt（トークごと・常に全履歴）
├── slack/                Slack 自分宛DM の自動アーカイブ txt
├── bot/                  LINE Bot の自動アーカイブ txt（Bot利用時のみ）
├── config.json           Drive フォルダ ID・Slack DM ID・Bot 設定
└── docs/
    ├── setup-iphone.md   手動エクスポートの手順
    └── setup-line-bot.md Bot（完全自動）のセットアップ手順
```

## コマンド

```bash
# 手動エクスポートの取り込み（Routine が毎朝実行するのと同じもの）
python3 scripts/ingest.py <エクスポート.txt> [...]

# 前回より短いエクスポートで強制置き換え
python3 scripts/ingest.py --force <エクスポート.txt>

# Bot 新着の取り込み（Routine が毎朝実行するのと同じもの）
curl -s -H "Authorization: Bearer <EXPORT_TOKEN>" \
  "https://line-dump-bot.fly.dev/export?since=$(cat bot/.cursor 2>/dev/null || echo 0)" \
  | python3 scripts/bot_ingest.py -

# テスト
python3 -m unittest discover -s scripts/tests -v
```

出力の最終行は機械可読サマリ:

```
ingest.py:     SUMMARY: updated=... unchanged=... skipped=... errors=... added_lines=... added_messages=...  （errors>0 なら rc=1）
bot_ingest.py: SUMMARY: chats=... messages=... cursor=...
```

## 日次 Routine（自動実行）の中身

Claude Code Remote の Routine が毎朝 07:00 JST（22:00 UTC）にセッションへ発火する。
やることは上の「全体の流れ」の 1〜4。障害時は同じ手順を手動セッションで
なぞれば復旧できる。

- Drive フォルダ: `LINE-exports`（ID は `config.json` 参照）
- フォルダ内の**全 txt** を一時ディレクトリに取得し、`ingest.py` 経由でのみ
  `chats/` を更新する（古い重複エクスポートは「旧版」として静かに無視される
  ので Drive の掃除は不要）
- Bot サーバーには `bot/.cursor` 以降の新着だけを問い合わせる。サーバーが
  未デプロイ・停止中なら静かにスキップ
- 更新ゼロの日は通知なしで静かに終了

## プライバシー

このリポジトリには **LINE のトーク内容がそのまま** 入る（chats/ と bot/）。
`config.json` には Bot の /export 用トークンも含まれる。
必ず private リポジトリのまま運用すること。公開・共有は厳禁。
グループに Bot を入れる際は、記録されることを他のメンバーに伝えること。
