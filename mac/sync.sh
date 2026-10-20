#!/bin/bash
# Mac 側の同期スクリプト。
#
# Hammerspoon が LINE を書き出した直後に呼ばれ、書き出した txt を
# line-dump リポジトリの chats/ に取り込んで push する。
# これで「LINE を開く → txt になって GitHub に載る」までが無人で完結する。
#
# 単体でも実行できる（書き出し済みの txt を取り込み直したいとき）:
#   bash ~/Document/line-dump/mac/sync.sh
# macOS 標準の /bin/bash は 3.2 なので、bash4 専用機能（mapfile 等）は使わない
set -o pipefail

# ─── 環境に合わせて書き換える ───
REPO="${LINE_DUMP_REPO:-$HOME/Document/line-dump}"
# LINE の生 txt が溜まっているフォルダ（Hammerspoon の保存先と同じにする）
RAW_DIR="${LINE_DUMP_RAW_DIR:-$HOME/Library/CloudStorage/Dropbox-SFC-CNS/Ryo Murata/Backups/Linetxt}"

PY="${LINE_DUMP_PYTHON:-/usr/bin/python3}"
LOG="$REPO/mac/sync.log"

# 画面には必ず出し、ログファイルは書ける時だけ追記する
# （リポジトリが無い等の初期エラーでもメッセージが消えないように）
log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line"
  [ -d "$(dirname "$LOG")" ] && printf '%s\n' "$line" >>"$LOG"
  return 0
}

if [ ! -d "$REPO/.git" ]; then
  log "error: リポジトリが無い: $REPO"
  log "  git clone https://github.com/denkingon/line-dump.git \"$REPO\" で用意する"
  exit 1
fi
if [ ! -d "$RAW_DIR" ]; then
  log "error: 生txtのフォルダが無い: $RAW_DIR"
  exit 1
fi

cd "$REPO" || exit 1
mkdir -p "$(dirname "$LOG")"

# main 以外のブランチでは取り込みも push もしない（push origin main は
# 手元の main を送るだけなので、別ブランチの commit は届かないのに
# 「push 完了」と出てしまう）
BRANCH="$(git symbolic-ref --short -q HEAD)"
if [ "$BRANCH" != "main" ]; then
  log "error: main 以外のブランチ（${BRANCH:-detached}）では取り込み・push しない"
  exit 1
fi

# 他の端末やクラウド側の更新を先に取り込む（ローカル変更は保持）
git pull --rebase --autostash origin main >>"$LOG" 2>&1 || log "warn: pull に失敗（続行）"

# 生 txt を集める。ファイル名に空白が入るので -print0 で受ける
FILES=()
while IFS= read -r -d '' f; do
  FILES+=("$f")
done < <(find "$RAW_DIR" -maxdepth 2 -name '*.txt' -print0 2>/dev/null)

if [ "${#FILES[@]}" -eq 0 ]; then
  log "取り込む txt が無い: $RAW_DIR"
  exit 0
fi

# 取り込み。警告(stderr)も画面とログの両方に残したいので一旦まとめて受ける
OUT="$(mktemp "${TMPDIR:-/tmp}/line-dump-ingest.XXXXXX")"
"$PY" "$REPO/scripts/ingest.py" "${FILES[@]}" >"$OUT" 2>&1
RC=$?
cat "$OUT" >>"$LOG"
SUMMARY="$(grep '^SUMMARY:' "$OUT" | tail -1)"
grep '^warn:\|^error:' "$OUT" | while IFS= read -r w; do log "$w"; done
rm -f "$OUT"

log "${SUMMARY:-SUMMARY 行が取れませんでした (rc=$RC)}"
[ "$RC" -ne 0 ] && log "warn: 読めなかったファイルがあります（上の error 行を確認）"

if [ -z "$(git status --porcelain)" ]; then
  log "変更なし（push不要）"
  exit 0
fi

git add -A
# 画像が紛れ込んでいたら commit も push もしない。このリポジトリは公開で、
# 撮影画像にはトーク画面が写っている（line_export.lua はリポジトリの外に
# 置くが、古い版や手違いで入った時の歯止め）。
# 一覧は NUL 区切りで取る（日本語名は通常の出力だと "..." で囲まれて末尾が
# 拡張子にならず、見逃すため）
IMAGES="$(git diff --cached --name-only -z | tr '\0' '\n' |
  grep -iE '\.(png|jpe?g|heic|heif|gif|tiff?|webp|bmp|mov|mp4)$')"
if [ -n "$IMAGES" ]; then
  git reset -q
  log "error: 画像ファイルが commit に入りそうになったので中止（push していない）"
  printf '%s\n' "$IMAGES" | while IFS= read -r f; do log "  $f"; done
  exit 1
fi
git commit -q -m "mac: LINE書き出しを取り込み ($(date '+%Y-%m-%d %H:%M'))

$SUMMARY" >>"$LOG" 2>&1

for delay in 0 2 4 8 16; do
  [ "$delay" -gt 0 ] && sleep "$delay"
  if git push origin main >>"$LOG" 2>&1; then
    log "push 完了"
    exit 0
  fi
  log "warn: push 失敗（${delay}s 後に再試行）"
done

log "error: push に失敗。ネットワークか認証を確認する"
exit 1
