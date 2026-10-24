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

# 前の回の積み直しがぶつかって途中で止まっていたら取り消す（そのままだと main に
# 戻れず、取り込みも自動更新もずっと止まる）
in_rebase() { [ -d "$(git rev-parse --git-dir)/rebase-merge" ] || [ -d "$(git rev-parse --git-dir)/rebase-apply" ]; }
if in_rebase; then
  git rebase --abort >>"$LOG" 2>&1 && log "warn: 途中で止まっていた積み直しを取り消した"
fi

# main 以外のブランチでは取り込みも push もしない（push origin main は
# 手元の main を送るだけなので、別ブランチの commit は届かないのに
# 「push 完了」と出てしまう）
BRANCH="$(git symbolic-ref --short -q HEAD)"
if [ "$BRANCH" != "main" ]; then
  log "error: main 以外のブランチ（${BRANCH:-detached}）では取り込み・push しない"
  exit 1
fi

# GitHub のリポジトリが公開でも取り込んで push する（2026-10-24、持ち主が
# 「公開のままでいい。非公開には後でする」と決めた）。公開中は止めたい時だけ
# LINE_DUMP_ALLOW_PUBLIC=0 にする。その時は認証なしで問い合わせ、見えたら（200）
# 公開なので止め、確かめられない時も念のため止める。生 txt はそのまま残るので、
# 非公開にすれば次の回でまとめて取り込む
REMOTE="$(git remote get-url origin 2>/dev/null)"
case "$REMOTE" in
  *github.com[:/]*)
    if [ "${LINE_DUMP_ALLOW_PUBLIC:-1}" != "1" ]; then
      SLUG="${REMOTE#*github.com[:/]}"; SLUG="${SLUG%/}"; SLUG="${SLUG%.git}"
      CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://api.github.com/repos/$SLUG" 2>/dev/null)"
      if [ "$CODE" = "200" ]; then
        log "error: GitHub の $SLUG が公開になっているので、取り込みも push もしない（LINE_DUMP_ALLOW_PUBLIC=0 の指定）"
        log "  GitHub → $SLUG → Settings → General → Danger Zone → Change visibility → Make private。非公開にすれば次の回で取り込む"
        exit 1
      elif [ "$CODE" != "404" ]; then
        log "error: GitHub の $SLUG が公開か非公開か確かめられない（HTTP ${CODE:-応答なし}）ので、念のため取り込みも push もしない"
        exit 1
      fi
    fi
    ;;
esac

# 他の端末やクラウド側の更新を先に取り込む（ローカル変更は保持）
if ! git pull --rebase --autostash origin main >>"$LOG" 2>&1; then
  if in_rebase; then
    # 手元の commit が GitHub の版とぶつかった。積み直しを取り消し、commit も push も
    # しない（途中の状態で commit すると main に戻れなくなる）
    git rebase --abort >>"$LOG" 2>&1
    log "error: 手元の commit が GitHub の版とぶつかったので取り込みをやめた（commit も push もしない）"
    exit 1
  fi
  log "warn: pull に失敗（続行）"
fi
# 手元の変更を戻す所でぶつかった印（<<<<<<<）が残っていたら、公開リポジトリに送らない
CONFLICTS="$(git diff --name-only --diff-filter=U)"
if [ -n "$CONFLICTS" ]; then
  log "error: 手元の変更と GitHub の版がぶつかった（commit も push もしない）"
  printf '%s\n' "$CONFLICTS" | while IFS= read -r f; do log "  $f"; done
  exit 1
fi

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
