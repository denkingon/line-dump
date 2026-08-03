# LINE Dump

LINE のトーク履歴（txt）を毎日 Cowork / Claude に届けるパイプライン。
届くのは要約ではなく **txt ファイルそのもの**。トークごとに1ファイル、常に最新の全履歴。

## 全体の流れ

取り込み経路は4つ。**経路0（Mac 自動）だけで LINE は完全無人**になる。

```
【経路0: Mac 自動書き出し ★本命・操作ゼロ】
毎日 07:00  Hammerspoon が Mac 版 LINE を操作
  → ⋮ →「トークを保存」→ [LINE]<トーク名>.txt
  → mac/sync.sh: ingest.py → commit → push
              chats/<トーク名>.txt が最新に

【経路3: Slack 自分宛DM（完全自動・メモの取り込み口）】
Slack の自分宛 DM に書く ─→ Slack API で新着取得
                     ↓ bot_ingest.py --dir slack
              slack/Slackメモ.txt に追記

【経路2: 手動エクスポート（Mac が使えないときの保険）】
iPhone: LINE → トーク履歴を送信 → Google ドライブ「LINE-exports」
                     ↓ ingest.py
              chats/<トーク名>.txt を最新版で置き換え

【経路1: LINE Bot（任意・グループのリアルタイム取り込み）】
LINE グループ ─→ webhook ─→ Fly.io「line-dump-bot」が蓄積
                     ↓ /export → bot_ingest.py
              bot/<チャット名>.txt に追記

  経路1〜3 は毎朝 07:00 JST の Claude Routine が処理し、
  経路0 は Mac 側で完結して直接 push する
```

`chats/`・`slack/`・`bot/` が成果物。Cowork / Claude のセッションからも、
clone したローカルからも常に読める。

- Mac 自動化: `docs/setup-mac-auto.md` ★おすすめ
- Slack: 自分宛 DM に書くだけ（設定済み）
- iPhone 手動: `docs/setup-iphone.md`
- LINE Bot: `docs/setup-line-bot.md`

## LINE の書き出し形式は2種類ある

同じ「トーク履歴」でも出力が違う。どちらも取り込めるようにしてある。

| | 日付行 | メッセージ行 | ヘッダ |
|---|---|---|---|
| **スマホ版**（トーク履歴を送信） | `2026/07/12(日)` | `10:21<TAB>送信者<TAB>本文` | あり |
| **Mac 版**（トークを保存） | `2024.03.31 日曜日` | `18:04 送信者 本文`（スペース） | なし |

Mac 版は送信者と本文がスペース区切りで機械的に分離できないため、送信者名まで
分けたい場合は `line-chat-export` スキルの `normalize_line.py` を使うこと。
このリポジトリは txt を原文のまま保持するのが役目なので、分離はしていない。

## 更新ルール（ingest.py）

LINE の「トーク履歴を送信」は毎回**全履歴**を出力する。だから基本方針は
「**最新エクスポートで前のファイルを置き換える**」— 差分管理は git がやる。

| 新しいエクスポートが… | 動作 |
|---|---|
| 前回より増えているだけ | 置き換え（通常ケース） |
| 本文が同一 | 何もしない（コミットを汚さない） |
| 取り込み済みの一部（古いエクスポート） | 静かに無視 |
| **先頭が欠けている**（スクロール不足のスナップショット） | **重なりを見つけて結合**。古い履歴を保ったまま末尾の新着だけ追加 |
| **前より前まで遡れている**（上にスクロールした） | 前方の履歴を足して結合 |
| 途中が変わっている（送信取消・削除） | 置き換え + 警告。前の版は git 履歴に残る |
| 短い上に重なりも無い | **スキップ + 警告**（データ消失ガード）。意図的なら `--force` |
| 本文がまったく別（同名の別トーク） | `<名前> (2).txt` として**別ファイルに保存** + 警告 |
| 本文が0行（空・壊れたファイル） | 無視 + 警告 |
| 読めない（非UTF-8等） | そのファイルだけ error にして続行（rc=1） |

**なぜ結合が要るか**: Mac 版の書き出しは「画面に読み込まれている範囲」しか
出ないため、日によって先頭が欠けたスナップショットが普通に出てくる。単純に
置き換えると古い履歴が消え、別トーク扱いにするとファイルが増え続ける。
そこで一方の端がもう一方の中に現れるか（8行以上の一致）で重なりを探し、
足りない分だけを継ぎ足す。同じものを何度渡しても結果は変わらない（冪等）。

複数のスナップショットを一度に渡した場合は、**ファイル名の日付**
（`_20260803`）→ 更新日時 の順で古い方から処理する。クラウド同期や
コピーで更新日時が狂っても、名前の日付があれば順序を間違えない。

## 経路の使い分け

| 取りたいもの | 経路 |
|---|---|
| **LINE のトーク全般（1:1 もグループも）** | **経路0: Mac 自動書き出し**。Mac の GUI 操作なら 1:1 も取れる。設定後は操作ゼロ |
| 自分用メモ | 経路3: Slack の自分宛 DM に書くだけ → 毎朝 `slack/` に追記 |
| Mac が使えない期間の補完 | 経路2: iPhone から手動エクスポート → Drive |
| グループをリアルタイムで | 経路1: LINE Bot（任意）。招待が必要な代わりに即時 |

**なぜ Mac の画面操作なのか**: LINE にはトーク履歴を取得する API が無く、
Messaging API も Bot 宛の新規メッセージしか見えない。アプリの
「⋮ →トークを保存」だけが唯一の出口なので、そこを自動化するのが本筋になる。

**Mac 自動化の限界**（LINE 側の仕様で回避できない）:
- 実行時刻に Mac が起動・ログイン状態である必要がある
- **画面に読み込まれている分だけ**が保存される。古い履歴が欲しいトークは
  初回だけ手動で上にスクロールして読み込ませる

## ディレクトリ構造

```
line-dump/
├── scripts/
│   ├── ingest.py         書き出し txt → chats/ 正本の更新（スマホ版/Mac版 両対応）
│   ├── bot_ingest.py     JSON → bot/ ・ slack/ アーカイブへ追記
│   ├── line_parser.py    LINE txt の構造化（トーク名抽出・行判定に使用）
│   └── tests/            unittest（45件）
├── mac/                  Mac 側の自動書き出し（経路0）
│   ├── line_export.lua   Hammerspoon: 毎日 LINE を操作して書き出す
│   └── sync.sh           書き出した txt を取り込んで commit & push
├── server/               LINE Bot webhook サーバー（Fly.io・標準ライブラリのみ）
│   ├── app.py            署名検証 + イベント蓄積 + /export API
│   ├── fly.toml          Fly.io 設定（app: line-dump-bot）
│   └── Dockerfile
├── chats/                LINE トークの正本 txt（トークごと・常に全履歴）
├── slack/                Slack 自分宛DM の自動アーカイブ txt
├── bot/                  LINE Bot の自動アーカイブ txt（Bot利用時のみ）
├── config.json           Drive フォルダ ID・Slack DM ID・Bot 設定
└── docs/
    ├── setup-mac-auto.md Mac 完全自動化（★おすすめ）
    ├── setup-iphone.md   iPhone からの手動エクスポート
    └── setup-line-bot.md LINE Bot のセットアップ
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
