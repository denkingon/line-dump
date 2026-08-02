# Mac 完全自動化のセットアップ（書き出しから push まで無人）

毎朝、Mac が自分で LINE を開いてトークを txt に書き出し、このリポジトリに
push するようにする。**設定後はこちらの操作はゼロ**。

```
毎日 07:00  Hammerspoon
  → LINE を開く → 検索してトークを開く → ⋮ → トークを保存
  → Linetxt フォルダに [LINE]<トーク名>.txt
  → mac/sync.sh: ingest.py で chats/ に取り込み → commit → push
  → GitHub の line-dump が最新に（Cowork / Claude からいつでも読める）
```

## 前提

- Mac 版 LINE がログイン済み
- 実行時刻に Mac が起動・ログイン状態（スリープ中は動かない）
- [Hammerspoon](https://www.hammerspoon.org/) 導入済み（`brew install --cask hammerspoon`）

## 手順

### 1. リポジトリを Mac に clone

```bash
git clone https://github.com/denkingon/line-dump.git ~/Document/line-dump
```

### 2. 書き出すトークを指定

`~/Document/line-dump/mac/line_export.lua` を開き、`TARGETS` に対象を書く。
型は 1:1・グループなら `full`、公式アカウントなら `official`。

```lua
local TARGETS = {
  { "家族",       "full" },
  { "ゼミ",       "full" },
  { "○○公式",    "official" },
}
```

保存先（`OUT_DIR`）は既定で既存の Dropbox アーカイブ
`~/Library/CloudStorage/Dropbox-SFC-CNS/Ryo Murata/Backups/Linetxt` を指している。
過去の書き出しもそこに溜まっているので、変えない方が履歴が分断されない。

### 3. Hammerspoon に読み込ませる

Hammerspoon コンソールで1行実行（`~/.hammerspoon/` はこちらから書けないため）:

```lua
io.open(os.getenv("HOME").."/.hammerspoon/init.lua","a"):write('\ndofile(os.getenv("HOME").."/Document/line-dump/mac/line_export.lua")\n')
```

メニューバーの金槌アイコン → **Reload Config** →
コンソールに `[LINE-export] 読込完了` が出れば稼働。

### 4. 手動テスト

集中モードを ON にして（通知バナーがクリックを奪うため）、`⌘⌥⌃L` を押す。
LINE が自動で動き、最後に「LINE書き出し OK:n NG:0 / push済」と出れば成功。

GitHub の `chats/` にファイルが増えていることを確認する。

## 注意点（LINE 側の仕様なので回避できない）

- **画面に読み込まれている分だけが保存される。** 古い履歴まで欲しいトークは、
  初回だけ手動でトーク内を上にスクロールして読み込ませてから実行する
  （長く使っているトークは初回で数年分入ることが多い）
- 実行中は Mac を触らない。通知が出るとクリックが弾かれる
- LINE をフルスクリーンにしない（別 Space になり操作できない）

## うまくいかないとき

| 症状 | 原因 | 対処 |
|---|---|---|
| クリックが `"通知センター"` エラー | 通知バナーが最前面（画面には写らない） | 集中モード ON |
| スクリーンショットが真っ暗 | LINE がフルスクリーン | 最大化ウィンドウに戻す |
| 「トークを保存」でなく別項目が押される | メニュー型が違う | `TARGETS` の型を `official` / `full` で入れ替える |
| 座標がズレた（LINE アップデート後など） | UI 配置が変わった | `⌘⌥⌃K` で測り直し、`line_export.lua` の較正値を更新 |
| push できない | 認証切れ | `cd ~/Document/line-dump && git push` を手で叩いて確認 |

ログは `~/Document/line-dump/mac/sync.log`。取り込み結果（SUMMARY 行）も残る。

## 取り込みだけやり直したいとき

書き出し済みの txt を入れ直すだけなら Hammerspoon 不要:

```bash
bash ~/Document/line-dump/mac/sync.sh
```
