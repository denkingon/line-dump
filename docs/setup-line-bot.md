# LINE Bot（完全自動取り込み）のセットアップ

グループのメッセージをリアルタイムで自動アーカイブする仕組み。
一度設定すれば、以降は**何もしなくても** Bot が参加しているトークの内容が
毎朝 `bot/` 配下の txt に追記されていく。

## できること / できないこと

| | |
|---|---|
| ✅ Bot を招待した**グループ**の全メッセージ | 参加した時点から自動記録 |
| ✅ **Bot との 1:1 トーク** | 自分用メモの自動取り込み口として最適 |
| ❌ 友だちとの 1:1 トーク | LINE の仕様上、Bot からは見えない → 従来どおり手動エクスポート（Drive 経由） |
| ❌ Bot 参加**以前**の履歴 | 手動エクスポートで補完（chats/ に入る） |

## 1. LINE Developers でチャネルを作る（無料・10分）

1. https://developers.line.biz/console/ にログイン（普段の LINE アカウントで OK）
2. プロバイダーを作成（名前は何でも。例: `line-dump`）
3. **Messaging API チャネル**を作成
   （現行フローでは LINE 公式アカウントが同時に作られる。名前例: `アーカイブ係`）
4. 控える値は2つ:
   - **チャネルシークレット** — 「チャネル基本設定」タブ
   - **チャネルアクセストークン（長期）** — 「Messaging API 設定」タブで発行
5. [LINE Official Account Manager](https://manager.line.biz/) → 設定 → 応答設定:
   - 応答メッセージ: **オフ**（Bot に勝手に返信させない）
   - あいさつメッセージ: **オフ**（任意）
   - Webhook: **オン**
6. 同じく設定 → アカウント設定 → 「グループ・複数人トークへの参加を許可する」を **オン**

## 2. Fly.io にサーバーをデプロイ（5分）

```bash
cd server
fly launch --no-deploy --name line-dump-bot --region nrt --copy-config
fly volumes create line_bot_data --region nrt --size 1
fly secrets set \
  LINE_CHANNEL_SECRET=<チャネルシークレット> \
  LINE_CHANNEL_ACCESS_TOKEN=<チャネルアクセストークン> \
  EXPORT_TOKEN=<config.json の bot.export_token と同じ値>
fly deploy
```

確認:

```bash
curl https://line-dump-bot.fly.dev/health          # → ok
```

## 3. Webhook を接続

1. LINE Developers → Messaging API 設定 → Webhook URL に
   `https://line-dump-bot.fly.dev/webhook` を設定
2. 「検証」ボタン → 成功を確認
3. 「Webhook の利用」を **オン**

## 4. 使い始める

- **グループを記録したい**: そのグループに Bot（公式アカウント）を招待するだけ。
  以降のメッセージが自動で記録される
- **自分用メモ**: Bot と 1:1 のトークを開いて、そこに書くだけ。
  書いたものが翌朝 `bot/<自分の表示名>.txt` に入る

毎朝 07:00 の Routine がサーバーからまとめて取得し、`bot/` に追記 → push →
新着があればプッシュ通知する。

## 動作確認（手動）

```bash
# サーバーに溜まっているイベントを取得してみる
curl -s -H "Authorization: Bearer <EXPORT_TOKEN>" \
  "https://line-dump-bot.fly.dev/export?since=0" | python3 -m json.tool
```

## 仕組みとファイル

```
LINE → webhook → Fly.io line-dump-bot
                 /data/events.jsonl に追記（生イベント・永続ボリューム）
                 /data/names.json   表示名キャッシュ
      ↓ 毎朝 07:00 JST（Routine）
GET /export?since=<bot/.cursor> → scripts/bot_ingest.py
      → bot/<チャット名>.txt に追記（LINE エクスポート互換形式）
      → bot/.cursor / bot/.chats.json 更新 → commit & push
```

- 画像・スタンプ等は `[写真]` `[スタンプ]` として記録（本文のみ対象）
- 同名のチャットは `<名前> (2).txt` のように自動で別ファイルになる
- webhook の再配送（重複イベント）は取得時に除外される

## トラブルシュート

| 症状 | 確認 |
|---|---|
| Webhook 検証が失敗 | `fly logs` で署名エラーの有無。LINE_CHANNEL_SECRET の値を再確認 |
| メッセージが記録されない | Bot がグループに参加しているか。`curl .../export?since=0` に出るか |
| 送信者名が「メンバーxxxx」になる | 一時的な API 失敗。名前が取れた時点からキャッシュされ改善する |
| /export が 401 | EXPORT_TOKEN と config.json の bot.export_token の不一致 |
