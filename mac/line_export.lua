-- =====================================================================
-- LINE 自動エクスポート v4.1 → line-dump リポジトリへ push（Hammerspoon）
--
--   毎日 RUN_AT 以降の離席中に、TARGETS のトークを Mac 版 LINE から
--   書き出し、mac/sync.sh を呼んでリポジトリに取り込み・push する。
--
--   固定座標は使わず、画面を撮って OCR で文字を読み、見つけた所を押す。
--   各段で画面を読み直して確かめてから次へ進み、違えばその段で止める。
--     1. 窓      LINE のメイン窓を前面に。窓が無ければ open -b（Escape は使わない）
--     2. トーク  左の一覧に名前がそのまま見えていればその行を押す。見えなければ
--                検索欄に名前を入れ、出てきた行を押す
--                → ヘッダ（検索欄と同じ高さ）を OCR してトーク名を確認
--                （LINE が AX で教える検索欄の位置は、フルスクリーンか窓かで画面と
--                ずれるので、毎回その場で検索欄の文字を OCR して画面の位置に直す）
--     3. メニュー ⋮（窓右端−24, ヘッダのトーク名と同じ高さ）を押す
--                → OCR で「トークを保存」を探して押す（型指定・較正は不要）
--     4. 保存    保存シートを AX で待つ → →キー＋「_YYYYMMDD」→ 保存 →（置き換え）
--                保存先は既定のまま。保存後に OUT_DIR へ移す
--     5. 確認    OUT_DIR に今日付きのファイルがあれば OK
--   失敗したら撮影画像を DEBUG_DIR に残し、heartbeat に段と画像パスを書く。
--   人がマウスやキーボードを触ったら、その場で全体を止める。
--
--   OCR は mac/ocr.applescript（macOS 標準の Vision）。Hammerspoon に
--   「画面収録」の許可が要る（docs/setup-mac-auto.md）。
--
--   使い方（Hammerspoon のコンソールに打つ。結果もコンソールに出る）:
--     __LINE_EXPORT.help()          この一覧
--     __LINE_EXPORT.status()        今の状態と、自動実行が走らない理由
--     __LINE_EXPORT.check("Berry")  1件を保存ダイアログで保存名を確かめるところまで試す（保存しない）
--     __LINE_EXPORT.one("Berry")    1件だけ本当に書き出して push
--     __LINE_EXPORT.diag()          画面の読み取り診断（⌘⌥⌃K と同じ。何も押さない）
--     __LINE_EXPORT.names()         トーク名の一覧（⌘⌥⌃J と同じ。TARGETS に貼れる形式）
--     __LINE_EXPORT.update()        今すぐ最新の版にする（ふだんは30分ごとの自動更新に任せてよい）
--   ホットキー: 全件を今すぐ ⌘⌥⌃L / 診断 ⌘⌥⌃K / トーク名一覧 ⌘⌥⌃J（⇧ 版でも可）
--   status / check / one / diag の出力の画面の文字は伏せ字にする（TARGETS の名前と
--   LINE の決まった表示以外は「■n字」）。そのまま貼って共有しても会話の中身は出ない
--   （names はトーク名の一覧を出す。会話の中身は出さない）。
--   止めたいとき: マウスを動かすかキーを押す
-- =====================================================================
local M = {}

-- ===================== 設定（ここだけ書き換える）=====================
local HOME    = os.getenv("HOME")
local REPO    = os.getenv("LINE_DUMP_REPO") or (HOME .. "/Document/line-dump")
local OUT_DIR = os.getenv("LINE_DUMP_RAW_DIR") or (HOME ..
  "/Library/CloudStorage/Dropbox-SFC-CNS/Ryo Murata/Backups/Linetxt")

-- 書き出す対象（トーク名だけ。v3 までの "full"/"official" の型指定は不要）。
--
-- 一覧に名前がそのまま見えていればその行を、見えなければ検索欄に入れて
-- 絞り込んだ行を、画面に出た名前と照合してから開く。照合は絵文字・空白・
-- グループのメンバー数を無視する。一覧からは完全一致の行だけを開く。検索では
-- 完全一致の行があればそれを開き、無い時だけ部分一致の行を余分な字が少ない順に
-- 3つまで開く。開いたらヘッダで確かめ、保存名は完全一致を求める（違えば保存せず次へ）
-- （別トークを書き出さないため）。名前は LINE の表示どおりに書くのが確実（⌘⌥⌃J で一覧）。
local TARGETS = {
  "オーチュー/小林央忠",
  "3日後 ハートランド",
  "かにっこにー",
  "山脇開生",
  "Berry",
  "パプリカ",
  "p Koyo",
  "H Village",
  "np 雄太",
  "il 石川ありがとう",
  "いりべひでなり",
  "村田研",
  "mP-廣瀬舞",
}

local RUN_AT = "07:00"

-- ▼ 画面の読み方（論理座標 pt）。左の一覧とトーク欄の境目は毎回
--   一覧の AX のセルから割り出すので、窓の大きさが変わっても測り直しは要らない。
local L = {
  MENU_FROM_RIGHT = 24,   -- ⋮ は窓右端から 24pt 左・ヘッダのトーク名と同じ高さ
  -- ⋮ でメニューが出なかった時の再試行（1回だけ）。左へ大きくずらすと
  -- 隣の通話ボタンに当たりうるので、ずらし幅は小さくしておく。
  MENU_RETRY_DX   = -6,
  MENU_RETRY_DY   = 6,
  HEADER_H        = 130,  -- 窓の上端からこの高さまでをヘッダとみなす
  HEADER_DY       = 16,   -- ヘッダのトーク名は検索欄と同じ高さ（±この幅）にある
  MENU_W          = 360,  -- ⋮ から左へこの幅・下へ MENU_H をメニューの範囲とみなす
  MENU_H          = 520,
  -- LINE が AX で教える位置と画面に写る位置のずれは毎回測る（窓の出し方で
  -- 変わる）。この幅より大きいずれは測り違いとみなす
  SHIFT_MAX       = 80,
  -- 今のトーク名を集める時に読む一覧のページ数の上限（1ページ＝一覧の高さ分）
  NAME_PAGES      = 15,
}
-- ▲

-- ===================== 実装 ==========================================
local LINE_BUNDLE = "jp.naver.line.mac"
local OCR_SCRIPT  = REPO .. "/mac/ocr.applescript"
-- 撮影画像と診断（伏せ字）は Dropbox の Backups/line-dump-debug に置く（非公開。
-- トーク画面が写るので公開リポジトリには入れない）。失敗をこちらで見て直すための置き場。
local DEBUG_DIR   = os.getenv("LINE_DUMP_DEBUG_DIR") or
                    ((OUT_DIR:match("^(.*)/[^/]+$") or HOME) .. "/line-dump-debug")
local DEBUG_SHOW  = "Dropbox の " .. (DEBUG_DIR:match("([^/]+/[^/]+)$") or "line-dump-debug")   -- heartbeat に書く形
local DEBUG_KEEP_DAYS = 7
local RUN_LIMIT_MIN   = 20    -- 1回の実行の上限（固まっても Hammerspoon を返す）
-- 実行中は AX の応答待ちを2秒にし、終わったらこの値に戻す（0 = macOS の既定）。
-- init.lua で hs.window.timeout(…) を設定しているなら同じ値にする。
local AX_TIMEOUT_AFTER = 0
local TMP = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")   -- 撮影の一時置き場
local SAVE_LABELS = { "トークを保存", "Save chat" }   -- ⋮ メニューの項目名
-- ⋮ メニューの他の項目。これが新しく見えたら「メニューは開いた」とみなす
local MENU_HINTS  = { "通知オフ", "通知オン", "トーク履歴を削除", "退会", "ブロック",
                      "非表示", "Notifications off", "Notifications on",
                      "Delete chat history", "Leave", "Block", "Hide" }

local function log(s) print(os.date("%H:%M:%S ") .. "[line-dump] " .. s) end

-- 使う拡張は読み込み時に読んでおく（Hammerspoon は初めて触った時に読み込むので、
-- 実行の途中で読み込みに時間を取られないように）
for _, ext in ipairs({ "axuielement", "eventtap", "pasteboard", "application", "screen", "mouse",
                       "geometry", "caffeinate", "camera", "host", "fs", "timer", "alert" }) do
  local _ = hs[ext]
end

-- このファイル自身と版。版は中身から作るので、直した版が入ると変わる
-- （heartbeat と診断ファイルに書く。新しい版が入った日は失敗分をやり直す）
local SELF = ((debug.getinfo(1, "S") or {}).source or ""):match("^@(.+)$") or (REPO .. "/mac/line_export.lua")
local function readAll(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("a"); f:close(); return s
end
-- 自動更新で読み込み直した時は、読み込んだ中身をそのまま受け取る（版を正しく作るため）
local LOADED_SRC = _G.__LINE_EXPORT_SRC or readAll(SELF) or ""
_G.__LINE_EXPORT_SRC = nil
local function checksum(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end
local VERSION   = "v4.1-" .. checksum(LOADED_SRC)
local LOADED_AT = os.date("%Y-%m-%d %H:%M")
local function now() return hs.timer.secondsSinceEpoch() end
local function wait(sec) hs.timer.usleep(math.floor(sec * 1000000)) end
local function sh(s)                              -- シェル用の引用
  local q = tostring(s):gsub("'", "'\\''")
  return "'" .. q .. "'"
end
-- 時間で区切って待つ（AX が固まって1回の確認が長引いても上限を守る）
-- 想定外のエラー文（Lua のファイルパス入り）からホームのパスを ~ にする
local function tidy(s)
  s = tostring(s)
  local i, j = s:find(HOME, 1, true)
  while i do
    s = s:sub(1, i - 1) .. "~" .. s:sub(j + 1)
    i, j = s:find(HOME, i + 1, true)
  end
  return s
end

local function waitFor(fn, timeout, step)
  step = step or 0.25
  local limit = now() + timeout
  while true do
    local v = fn()
    if v then return v end
    if now() >= limit then return nil end
    wait(step)
  end
end

-- ---------- 実行中の見張り ----------
-- 人が戻ってきたら止める。自分の操作の後に人の入力があれば、HID の
-- 無操作時間が「自分の最後の操作からの時間」より短くなる（自分の操作で
-- 無操作時間が戻る場合も戻らない場合も成り立つ）。マウスが自分の置いた
-- 位置から動いていても止める。止めたら LINE を前に出し直さない。
local RUN = nil   -- 実行中だけ { deadline, lastSynth, mouse, pid, app }

local function stop(reason) error({ abort = reason }, 0) end
local function blocked(reason) error({ blocked = reason }, 0) end

-- HID の無操作時間（秒）と、それが細かい値か。hs.host.idleTime() は
-- 約1.07秒（2^30 ns）刻みの切り捨てなので、ioreg でナノ秒の値を読む。
-- 読めない時だけ hs.host.idleTime() に戻る（その時は刻みの分の余裕を見る）。
local function idleSeconds()
  local out = hs.execute("/usr/sbin/ioreg -c IOHIDSystem | /usr/bin/awk '/HIDIdleTime/ {print $NF; exit}'")
  local ns = tonumber((out or ""):match("^%s*(%d+)"))
  if ns then return ns / 1e9, true end
  return (hs.host.idleTime() or 0) * 1.073741824, false
end

local function guard()
  if not RUN then return end
  local t = now()
  if t > RUN.deadline then stop("時間切れ（" .. RUN_LIMIT_MIN .. "分）") end
  local idle, fine = idleSeconds()
  local since = t - RUN.lastSynth
  if idle + (fine and 0.25 or 1.33) < since then
    -- 止めた理由を数字で残す（人が触っていないのに止まる時の手がかり）
    log(string.format("見張り: 最後の自動操作から %.2f 秒なのに、無操作時間が %.2f 秒（%s）",
      since, idle, fine and "ioreg" or "idleTime"))
    stop("人の操作を検知")
  end
  if RUN.mouse then
    local p = hs.mouse.absolutePosition()
    local dx, dy = p.x - RUN.mouse.x, p.y - RUN.mouse.y
    if math.abs(dx) > 3 or math.abs(dy) > 3 then
      log(string.format("見張り: 自動操作の後にマウスが (%.0f, %.0f) 動いた", dx, dy))
      stop("マウスが動いた")
    end
  end
end
local function synthesized()
  if not RUN then return end
  RUN.lastSynth = now()
  RUN.mouse = hs.mouse.absolutePosition()
end

-- LINE が前面か。クリック・キー入力の前に必ず確かめる（他のアプリを操作しない）。
-- hs.application.frontmostApplication() は処理の途中では更新されない（実行を
-- 始めた時の前面のまま）ので、LINE 自身に AX で尋ねる（AXFrontmost）。
local function lineFront(app)
  app = app or (RUN and RUN.app)
  if not app then return false end
  local ok, v = pcall(function() return app:isFrontmost() end)
  return ok and v == true
end

-- その位置の一番上にあるのが LINE か（通知バナーや他の窓が重なっていないか）
local function hitsLine(x, y)
  if not (RUN and RUN.pid) then return true end
  local ok, el = pcall(hs.axuielement.systemElementAtPosition, x, y)
  if not ok or not el then return true end      -- 判定できない時は前面確認に任せる
  local ok2, pid = pcall(function() return el:pid() end)
  return not ok2 or pid == nil or pid == RUN.pid
end

-- 今キー入力を受けるアプリの名前（ログ用）。AX に尋ねるので処理の途中でも今の値
local function frontAppName()
  local ok, n = pcall(function()
    local a = hs.axuielement.systemWideElement():attributeValue("AXFocusedApplication")
    return a and a:attributeValue("AXTitle")
  end)
  return ok and n and tostring(n) or "不明"
end

-- LINE が前面か確かめ、違えば1回だけ前に出し直す（通知などで一瞬前面が
-- 外れることがある）。それでも違えば押さない・打たない。
local function ensureFront()
  if lineFront() then return true end
  local other = frontAppName()
  if RUN and RUN.app then
    pcall(function() RUN.app:activate(true) end); wait(0.6)
    guard()                                       -- 待っている間の人の操作を見逃さない
    if lineFront() then
      log("warn: LINE が前面に無かった（前面: " .. other .. "）ので前に出し直した")
      return true
    end
  end
  log("LINE が前面に来ない（前面: " .. other .. "）")
  return false
end

local FRONT_LOST = "LINE が前面に来ない（前に出し直しても別のアプリが前にある）"

local function clickAt(x, y)
  guard()
  if not ensureFront() then blocked(FRONT_LOST) end
  if not hitsLine(x, y) then blocked("押す所に LINE 以外の物が重なっている") end
  hs.eventtap.leftClick(hs.geometry.point(x, y))
  synthesized(); wait(0.3)
end
local function key(mods, k)
  guard()
  if not ensureFront() then blocked(FRONT_LOST) end
  hs.eventtap.keyStroke(mods, k)
  synthesized()
end

-- ---------- 文字の照合 ----------
-- OCR と TARGETS を同じ物差しで比べるための正規化。
-- 空白・絵文字・記号類を落とし、全角英数を半角・小文字にそろえ、
-- OCR が取り違えやすい長音/ダッシュ類と「卜/ト」を同一視する。
local function skipped(c)
  return c <= 0x20 or c == 0x7F or c == 0xA0 or c == 0x3000
      or (c >= 0x200B and c <= 0x200F) or c == 0xFEFF or c == 0x20E3
      or (c >= 0xFE00 and c <= 0xFE0F)                 -- 異体字セレクタ
      or (c >= 0x2190 and c <= 0x21FF)                 -- 矢印
      or (c >= 0x2300 and c <= 0x23FF)                 -- ⌚⏰ など
      or (c >= 0x25A0 and c <= 0x27BF)                 -- ▶︎■●☀♡✨ など
      or (c >= 0x2B00 and c <= 0x2BFF)                 -- ⭐ など
      or (c >= 0x1F000 and c <= 0x1FAFF)               -- 絵文字本体
      or (c >= 0xE0000 and c <= 0xE007F)               -- タグ文字
end
local DASH = { [0x30FC]=true, [0x4E00]=true, [0xFF70]=true, [0x2010]=true,
               [0x2011]=true, [0x2012]=true, [0x2013]=true, [0x2014]=true,
               [0x2015]=true, [0x2212]=true }
local function norm(s)
  s = tostring(s or "")
  local ok, r = pcall(function()
    local out = {}
    for _, c in utf8.codes(s) do
      if not skipped(c) then
        if c >= 0xFF01 and c <= 0xFF5E then c = c - 0xFEE0 end   -- 全角→半角
        if DASH[c] then c = 0x2D                                 -- ー一－— → -
        elseif c == 0x535C then c = 0x30C8                       -- 卜 → ト
        elseif c >= 0x41 and c <= 0x5A then c = c + 32 end       -- A-Z → a-z
        out[#out + 1] = utf8.char(c)
      end
    end
    return table.concat(out)
  end)
  if ok then return r end
  return (s:gsub("%s+", ""))                       -- 壊れた UTF-8 は空白だけ落とす
end

-- 末尾のグループのメンバー数「（82）」を除く。OCR が閉じ括弧を落とす・「]」に
-- 読むことがあり、ヘッダではメンバー数の後ろのアイコンを字として読むことも
-- ある（実機:「（82）→ ビ」）ので、メンバー数の後ろの3字までは一緒に落とす。
local function countless(n)
  local from, last, stop_ = 1, nil, nil
  while true do
    local a, b = n:find("%(%d+[%)%]]?", from)
    if not a then break end
    last, stop_, from = a, b, b + 1
  end
  if last and (utf8.len(n:sub(stop_ + 1)) or 99) <= 3 then return n:sub(1, last - 1) end
  return n
end

-- 照合の強さ: 3=完全一致 2=前方一致 1=部分一致 0=不一致。
-- グループのメンバー数は無視し、「…」で切れた名前は前半で照合する。
local function score(tn, s)
  if tn == "" or s == "" then return 0 end
  local core = countless(s)
  if core == tn or s == tn then return 3 end
  if core:sub(1, #tn) == tn then return 2 end
  if s:find(tn, 1, true) then return 1 end
  local cut = core:match("^(.-)%.%.%.$") or core:match("^(.-)…$")
  if cut and (utf8.len(cut) or 0) >= 3 and tn:sub(1, #cut) == cut then return 1 end
  return 0
end

-- 保存名とトーク名の照合用。ファイル名では / が _ や : に化けるので記号も落とす。
-- 保存名とトーク名の照合用。名前欄の値は OCR でなく LINE が付けた正確な文字
-- なので、norm() の OCR 向けの読み替え（ー・一・ダッシュ → -、卜 → ト）も記号の
-- 削除もしない（「村田研一」「村田研ー」「(Berry)」を「村田研」「Berry」と別に扱う）。
-- 落とすのは空白・絵文字だけ。全角英数は半角・小文字にそろえ、ファイル名で化ける
-- / : _ だけを同じ字とみなす。
local function loose(s)
  local ok, r = pcall(function()
    local out = {}
    for _, c in utf8.codes(tostring(s or "")) do
      if not skipped(c) then
        if c >= 0xFF01 and c <= 0xFF5E then c = c - 0xFEE0 end   -- 全角→半角
        if c >= 0x41 and c <= 0x5A then c = c + 32 end           -- A-Z → a-z
        if c == 0x2F or c == 0x3A then c = 0x5F end              -- / : → _
        out[#out + 1] = utf8.char(c)
      end
    end
    return table.concat(out)
  end)
  if ok then return r end
  return (tostring(s or ""):gsub("%s+", ""))
end

local function isLabel(n, labels)
  for _, lab in ipairs(labels) do
    local ln = norm(lab)
    if n == ln then return true end
    if n:sub(1, #ln) == ln and (utf8.len(n) or 99) - utf8.len(ln) <= 2 then return true end
  end
  return false
end
local function isSaveLabel(n) return isLabel(n, SAVE_LABELS) end

local function targetName(t) return type(t) == "table" and t[1] or t end

-- ---------- 伏せ字 ----------
-- コンソール・ログ・診断ファイルに出す画面の文字は伏せ字にする（貼って共有
-- しても、会話の中身や他のトーク名が出ないように）。そのまま
-- 出すのは TARGETS の名前と LINE の決まった表示（メニュー項目など）だけ。
-- それ以外は「■n字」。数字だけのもの（時刻など）は「［数字］」。
local UI_WORDS = { "LINE", "検索", "トーク", "友だち", "ホーム", "通話", "すべて",
                   "グループ", "メッセージ", "公式アカウント", "オープンチャット",
                   "Search", "Chats", "Friends", "Messages", "Groups", "All" }
local function masked(s)
  s = tostring(s or "")
  local n = norm(s)
  if n == "" then return "（空）" end
  for _, t in ipairs(TARGETS) do
    local name = targetName(t)
    local tn = norm(name)
    local sc = score(tn, n)
    if sc == 3 then return "〈" .. name .. "〉" end
    -- 前方一致は、後ろの字数だけ出す（「かにっこにー3」→〈かにっこにー〉＋1字）
    local extra = (utf8.len(n) or 99) - (utf8.len(tn) or 0)
    if sc == 2 and extra <= 6 then return "〈" .. name .. "〉＋" .. extra .. "字" end
  end
  -- 決まった表示は、読めた文字ではなく決まった文言で出す（後ろに付いた字は字数だけ）
  for _, labs in ipairs({ SAVE_LABELS, MENU_HINTS, UI_WORDS }) do
    for _, lab in ipairs(labs) do
      local ln = norm(lab)
      if n == ln then return lab end
      if labs ~= UI_WORDS and isLabel(n, { lab }) then
        return lab .. "＋" .. ((utf8.len(n) or 0) - (utf8.len(ln) or 0)) .. "字"
      end
    end
  end
  if s:match("^[%d%p%s]+$") then return "［数字］" end
  return "■" .. (utf8.len(s) or #s) .. "字"
end

-- ---------- 撮影と OCR ----------
local function pngSize(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local head = f:read(24); f:close()
  if not head or #head < 24 or head:sub(2, 4) ~= "PNG" then return nil end
  local function u32(i)
    local a, b, c, d = head:byte(i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

-- 撮影。既定は LINE の窓単体（-l）: 通知バナーや他のアプリが重なっていても
-- LINE だけが写る。screenRect を渡すと画面のその矩形（-R）を撮る: ⋮ の
-- メニューが別窓として出る場合でも写るので、メニューを読む時はこちら。
local function capture(win, tag, screenRect)
  local path = TMP .. "/line_export_" .. tag .. ".png"
  os.remove(path)
  local r, pw, ph
  if screenRect then
    r = { x = math.floor(screenRect.x), y = math.floor(screenRect.y),
          w = math.ceil(screenRect.w), h = math.ceil(screenRect.h) }
    hs.execute(string.format("/usr/sbin/screencapture -x -R %d,%d,%d,%d %s",
      r.x, r.y, r.w, r.h, sh(path)))
    pw, ph = pngSize(path)
  end
  if not pw and win then
    r = win:frame()
    hs.execute(string.format("/usr/sbin/screencapture -x -o -l %d %s", win:id() or 0, sh(path)))
    pw, ph = pngSize(path)
    if not pw then
      local ok, img = pcall(function() return win:snapshot() end)
      if ok and img then img:saveToFile(path) end
      pw, ph = pngSize(path)
    end
  end
  if not pw then return nil end
  return { path = path, rect = r, sx = pw / r.w, sy = ph / r.h }
end

-- 画像を OCR し、各文字列の中心を画面の論理座標に直して返す。
-- OCR 自体が動かない時は nil と理由を返す（「文字が無い」と区別するため）。
local function ocr(cap)
  if not cap then return nil, "画面を撮れない（画面収録の許可を確認）" end
  local out, ok = hs.execute("/usr/bin/osascript " .. sh(OCR_SCRIPT) .. " " .. sh(cap.path) .. " 2>&1")
  if not ok then
    return nil, "OCR が動かない: " .. (out or ""):gsub("%s+", " "):sub(1, 200)
  end
  local items = {}
  for line in (out or ""):gmatch("[^\r\n]+") do
    local s, cx, cy, w, h = line:match("^(.-)\t([%-%d%.]+)\t([%-%d%.]+)\t([%-%d%.]+)\t([%-%d%.]+)%s*$")
    if s and s ~= "" then
      items[#items + 1] = {
        text = s, n = norm(s),
        x = cap.rect.x + tonumber(cx) / cap.sx, y = cap.rect.y + tonumber(cy) / cap.sy,
        w = tonumber(w) / cap.sx, h = tonumber(h) / cap.sy,
      }
    end
  end
  return items
end

local function screenOf(win)
  return (win and win:screen() or hs.screen.primaryScreen()):frame()
end

-- 画面収録が許可されているか（未許可だと壁紙しか写らず、全段で見失う）
local function screenRecordingOK()
  if not hs.screenRecordingState then return true end
  local ok, st = pcall(hs.screenRecordingState, false)
  return not (ok and st == false)
end

-- ---------- デバッグ画像 ----------
local function safeName(s) return (tostring(s):gsub("[/:%c\\]", "_")) end

-- 撮影を DEBUG_DIR に残す。戻り値は heartbeat に書く形と、実際のパス。
-- Retina の PNG は数 MB あるので、sips で縮めた JPEG にする（できなければ PNG のまま）。
local function keepDebug(name, stage, cap, win)
  -- 撮影が無ければ LINE の窓だけを撮る（前面の他のアプリや通知は写さない。窓が無ければ撮らない）
  if not cap then cap = capture(win, "fail") end
  if not cap then return nil end
  hs.fs.mkdir(DEBUG_DIR)
  local base = os.date("%Y%m%d-%H%M%S") .. "_" .. safeName(name) .. "_" .. safeName(stage)
  local jpg = DEBUG_DIR .. "/" .. base .. ".jpg"
  hs.execute("/usr/bin/sips -s format jpeg -s formatOptions 70 -Z 2000 " .. sh(cap.path) ..
             " --out " .. sh(jpg) .. " >/dev/null 2>&1")
  if (hs.fs.attributes(jpg, "size") or 0) > 0 then return DEBUG_SHOW .. "/" .. base .. ".jpg", jpg end
  local png = DEBUG_DIR .. "/" .. base .. ".png"
  local src, dst = io.open(cap.path, "rb"), io.open(png, "wb")
  if not (src and dst) then
    if src then src:close() end
    if dst then dst:close() end
    return nil
  end
  dst:write(src:read("a")); src:close(); dst:close()
  return DEBUG_SHOW .. "/" .. base .. ".png", png
end

local function pruneDebug()
  if hs.fs.attributes(DEBUG_DIR, "mode") ~= "directory" then return end
  local limit = os.time() - DEBUG_KEEP_DAYS * 86400
  -- Dropbox のフォルダは一覧が取れないことがある（その時は消さずに続ける）
  pcall(function()
    for f in hs.fs.dir(DEBUG_DIR) do
      local p = DEBUG_DIR .. "/" .. f
      if (f:match("%.png$") or f:match("%.jpg$") or f:match("_report%.txt$"))
         and (hs.fs.attributes(p, "modification") or limit) < limit then
        os.remove(p)
      end
    end
  end)
end

-- 読めた文字を、画面のどこにあったか（領域）と伏せ字で並べる（診断用）
local function regionOf(it, ff, paneX)
  if not ff then return "?" end
  if it.x >= ff.x - 4 and it.x <= ff.x + ff.w + 4 and it.y >= ff.y - 4 and it.y <= ff.y + ff.h + 4 then
    return "検索欄"
  end
  if paneX and it.x < paneX then return it.y > ff.y + ff.h and "一覧" or "一覧の上" end
  if math.abs(it.y - (ff.y + ff.h / 2)) <= L.HEADER_DY then return "ヘッダ行" end
  return it.y < ff.y and "上端" or "トーク欄"
end
local function layoutLines(items, ff, paneX, perRegion)
  perRegion = perRegion or 25
  local sorted = {}
  for _, it in ipairs(items or {}) do sorted[#sorted + 1] = it end
  table.sort(sorted, function(a, b) if a.y ~= b.y then return a.y < b.y end; return a.x < b.x end)
  local out, count, order = {}, {}, {}
  for _, it in ipairs(sorted) do
    local r = regionOf(it, ff, paneX)
    if not count[r] then count[r] = 0; order[#order + 1] = r end
    count[r] = count[r] + 1
    if count[r] <= perRegion then
      out[#out + 1] = string.format("[%s] x=%.0f y=%.0f %s", r, it.x, it.y, masked(it.text))
    end
  end
  for _, r in ipairs(order) do
    if count[r] > perRegion then out[#out + 1] = string.format("[%s] ほか %d 件", r, count[r] - perRegion) end
  end
  return out
end

-- 段の失敗を返す。その時点の画面を DEBUG_DIR に残す。
-- msg は heartbeat（公開リポジトリ）に載る決まった文言だけにする。画面由来の
-- もの（ヘッダに見えた名前・保存名など）は detail に分け、伏せ字にしてから
-- 渡す（コンソールと、Dropbox の診断ファイル latest.txt に出る）。
-- 画面の撮影があれば読み直して、伏せ字の並び（layout）も付ける（診断ファイル用）。
local function fail(ctx, stage, msg, cap, detail)
  local layout
  if cap and ctx.ff then
    local items = ocr(cap)
    if items then layout = layoutLines(items, ctx.ff, ctx.paneX) end
  end
  local img, imgPath = keepDebug(ctx.name, stage, cap, ctx.win)
  return nil, { stage = stage, msg = msg, detail = detail, layout = layout,
                img = img, imgPath = imgPath }
end

-- 段ごとの経過（check / one でコンソールに出す。画面の文字は伏せ字で渡す）
local function note(ctx, stage, text)
  if ctx.trace then ctx.trace[#ctx.trace + 1] = { stage = stage, text = text } end
end

-- ---------- AX ----------
local function attr(el, name)
  local ok, v = pcall(function() return el:attributeValue(name) end)
  if ok then return v end
end
local function role(el)  return attr(el, "AXRole") end
local function title(el) return tostring(attr(el, "AXTitle") or "") end
local function axFrame(el)
  local p, s = attr(el, "AXPosition"), attr(el, "AXSize")
  if p and s then return { x = p.x, y = p.y, w = s.w, h = s.h } end
  local f = attr(el, "AXFrame")
  if f and f.x then return f end
end
-- performAction は失敗しても例外を出さず、nil/false を返す
local function press(el)
  guard()
  local ok, r = pcall(function() return el:performAction("AXPress") end)
  return ok and r ~= nil and r ~= false
end

-- 幅優先で探す。チャット欄は要素数が多いので、見る数に上限を設ける。
-- prune(el) が true の要素の中には入らない。
local function bfs(root, pred, budget, prune)
  if not root then return nil end
  local q, head = { root }, 1
  while q[head] and head <= (budget or 3000) do
    local el = q[head]; head = head + 1
    if pred(el) then return el end
    if not (prune and prune(el)) then
      for _, c in ipairs(attr(el, "AXChildren") or {}) do q[#q + 1] = c end
    end
  end
  return nil
end
local function bfsAll(root, pred, budget, prune)
  local found = {}
  bfs(root, function(e) if pred(e) then found[#found + 1] = e end; return false end, budget, prune)
  return found
end

-- トークリストの検索欄: 窓の上の方にある一番左の AXTextField。
-- 下のメッセージ入力欄・トーク内検索の欄・保存シートの名前欄と取り違えない。
local function searchField(win)
  local f = win:frame()
  local bestEl, bestF
  for _, e in ipairs(bfsAll(hs.axuielement.windowElement(win),
      function(e) return role(e) == "AXTextField" end, 2500,
      function(e) return role(e) == "AXSheet" end)) do
    local r = axFrame(e)
    if r and r.y + r.h / 2 < f.y + f.h * 0.4 and (not bestF or r.x < bestF.x) then
      bestEl, bestF = e, r
    end
  end
  return bestEl, bestF
end

-- 検索欄を持つ窓＝メイン窓。トークを別窓で開いていると focusedWindow が
-- そちらになることがあるので、全窓から探す。
-- keepMinimized なら最小化された窓は戻さない（診断は画面に何も出さない）。
local function findMain(app, keepMinimized)
  local best, bestArea
  for _, w in ipairs(app:allWindows() or {}) do
    if w:isMinimized() and not keepMinimized then
      guard()                                     -- 実行中なら、人が戻っていれば戻さない
      w:unminimize(); wait(0.5)
    end
    if not w:isMinimized() and w:isVisible() and searchField(w) then
      local f = w:frame()
      if not best or f.w * f.h > bestArea then best, bestArea = w, f.w * f.h end
    end
  end
  return best
end

-- ボタンを題名で探す。prefix なら前方一致（「置き換える」「置き換え」の両方に合う）
local function findButton(root, names, prefix)
  return bfs(root, function(e)
    if role(e) ~= "AXButton" then return false end
    local t = title(e)
    for _, n in ipairs(names) do
      if t == n or (prefix and t:sub(1, #n) == n) then return true end
    end
    return false
  end, 800)
end

-- 保存シート: 窓の子の AXSheet か、ダイアログ窓のうち、「キャンセル」と
-- 「保存」（または [LINE] で始まる名前欄）を持つもの。LINE の設定画面や
-- 別の確認ダイアログは保存シートとみなさない（触らない）。
local function isSaveSheet(el)
  if not findButton(el, { "キャンセル", "Cancel" }) then return false end
  if findButton(el, { "保存", "Save" }) then return true end
  return bfs(el, function(e)
    return role(e) == "AXTextField" and tostring(attr(e, "AXValue") or ""):match("^%[LINE%]") ~= nil
  end, 600) ~= nil
end
local function findSheet(app)
  local axapp = hs.axuielement.applicationElement(app)
  for _, w in ipairs(attr(axapp, "AXWindows") or {}) do
    local sr = attr(w, "AXSubrole")
    if (role(w) == "AXSheet" or sr == "AXDialog" or sr == "AXSystemDialog") and isSaveSheet(w) then
      return w
    end
    for _, c in ipairs(attr(w, "AXChildren") or {}) do
      if role(c) == "AXSheet" and isSaveSheet(c) then return c end
    end
  end
  return nil
end

-- 保存シートを閉じる。上書き確認などの内側のシートが出ていればそちらから。
local function cancelSheet(app)
  for _ = 1, 3 do
    local sheet = findSheet(app)
    if not sheet then return true end
    local inner
    for _, c in ipairs(attr(sheet, "AXChildren") or {}) do
      inner = inner or bfs(c, function(e) return role(e) == "AXSheet" end, 400)
    end
    local b = findButton(inner or sheet, { "キャンセル", "Cancel" })
    if not (b and press(b)) then return false end
    wait(0.6)
  end
  return findSheet(app) == nil
end

-- 文字列を貼り付けで入力する。キー入力だと日本語入力が ON のとき崩れるため。
-- landed() で入ったのを確かめてから元のクリップボードに戻す（戻すのが早いと
-- 元の中身の方が貼られてしまう）。一時的な中身はクリップボード履歴アプリに
-- 残らないよう Transient/Concealed の印を付ける。
-- 制約: 戻せるのは先頭の1項目だけ（複数ファイルのコピーなどは1つになる）。
local function pasteText(s, landed)
  local saved
  if hs.pasteboard.readAllData then
    local ok, d = pcall(hs.pasteboard.readAllData); if ok then saved = d end
  end
  local okw = hs.pasteboard.writeAllData and pcall(hs.pasteboard.writeAllData, {
    ["public.utf8-plain-text"] = s,
    ["org.nspasteboard.TransientType"] = "", ["org.nspasteboard.ConcealedType"] = "",
  })
  if not okw then hs.pasteboard.setContents(s) end
  wait(0.1)
  local ok, err = pcall(key, {"cmd"}, "v")
  if ok then
    if landed then waitFor(landed, 2, 0.1) else wait(0.6) end
  end
  if saved and next(saved) then pcall(hs.pasteboard.writeAllData, saved)
  else hs.pasteboard.clearContents() end
  if not ok then error(err, 0) end
end

-- ---------- 1. 窓 ----------
local function ensureWindow(app)
  for _ = 1, 3 do
    guard()
    app:activate(true); wait(0.8)
    guard()                                       -- 待つ間に人が戻ったら、窓を動かさない
    local win = findMain(app)
    guard()                                       -- 窓を探す間（AX をたどる・最小化を戻す）も同じ
    if win then
      local sf, f = screenOf(win), win:frame()
      if math.abs(f.w - sf.w) > 40 or math.abs(f.h - sf.h) > 40 then
        win:setFrame(sf, 0); wait(0.6)            -- 広い方が名前が切れずに読める
        guard()
      end
      -- メイン窓を最前面・キー窓にする（別窓で開いたトークにキー入力が行かないように）
      win:focus(); wait(0.4)
      local fw = app:focusedWindow()
      if lineFront(app) and (fw == nil or fw:id() == win:id()) then return win end
    end
    -- 窓が無い・見えない・検索欄が読めない・前面に来ない → Dock クリック相当で開き直す。
    -- hs.application.open / activate では窓が戻らない（実測）。Escape は使わない
    -- （LINE は Escape で窓やトークを閉じる。10/14 の連鎖失敗の元凶）。
    guard()
    hs.execute("/usr/bin/open -b " .. LINE_BUNDLE); wait(2)
  end
  return nil
end

-- ---------- AX の位置と画面のずれ ----------
-- LINE が AX で教える検索欄・一覧のセルの位置は、窓の出し方によって画面に
-- 写る位置とずれる（2026-10-23 の実機: フルスクリーンで、検索欄が見た目より
-- 30pt 下にあると報告された。窓表示ではずれないこともある）。押す位置と OCR は
-- 画面の位置で考えるので、毎回その場で検索欄に入っている文字（空なら「検索」の
-- 表示、それも読めなければ一覧のセルの名前）を OCR で探し、AX の位置との差
-- （dy）を測ってから AX の位置に足す。測れない時は同じ窓の形で前に測った値、
-- それも無ければ 0（ずれ無し）とみなす。横（x）はずれていなかった。
local SHIFT                                     -- 前に測った値 { memo, dy, how }
local PLACEHOLDERS = { "検索", "Search" }
local function shifted(r, dy)
  return { x = r.x, y = r.y + (dy or 0), w = r.w, h = r.h }
end

-- 検索欄の文字が OCR で読めたか。虫眼鏡のアイコンが字として前に付く・1〜2字を
-- 読み違えることがある（実機）ので、含んでいるか、6割以上の字が同じなら同じとみなす。
-- v, n は norm 済み
local function sameText(v, n)
  local vl, nl = utf8.len(v) or 0, utf8.len(n) or 0
  if vl == 0 or nl == 0 or nl > vl + 4 then return false end
  if n:find(v, 1, true) then return true end
  local want, have = {}, 0
  for _, c in utf8.codes(v) do want[c] = (want[c] or 0) + 1 end
  for _, c in utf8.codes(n) do
    if (want[c] or 0) > 0 then want[c] = want[c] - 1; have = have + 1 end
  end
  return have >= math.max(2, math.ceil(vl * 0.6))
end

-- 2つの名前（norm 済み）の近さ 0〜1。片方がもう片方を含めば 0.5 以上
-- （短い方/長い方の割合で上がる）。含まなければ同じ字の割合
local function nameSim(a, b)
  local la, lb = utf8.len(a) or 0, utf8.len(b) or 0
  if la == 0 or lb == 0 then return 0 end
  if a == b then return 1 end
  local lo, hi = math.min(la, lb), math.max(la, lb)
  if lo >= 2 and (a:find(b, 1, true) or b:find(a, 1, true)) then return 0.5 + 0.5 * lo / hi end
  local want, common = {}, 0
  for _, c in utf8.codes(a) do want[c] = (want[c] or 0) + 1 end
  for _, c in utf8.codes(b) do
    if (want[c] or 0) > 0 then want[c] = want[c] - 1; common = common + 1 end
  end
  return common / hi
end

local function measureShift(win, field, ffAX, items)
  local cy = ffAX.y + ffAX.h / 2
  local v = norm(attr(field, "AXValue") or "")
  -- 1) 検索欄の文字。一覧の行に同じ名前があっても、検索欄はその上なので一番上の物
  local best
  for _, it in ipairs(items) do
    if it.x >= ffAX.x - 10 and it.x <= ffAX.x + ffAX.w + 10 and math.abs(it.y - cy) <= L.SHIFT_MAX
       and (v ~= "" and sameText(v, it.n) or v == "" and isLabel(it.n, PLACEHOLDERS))
       and (not best or it.y < best.y) then
      best = it
    end
  end
  if best then return best.y - cy, v ~= "" and "検索欄の文字" or "検索欄の「検索」の表示" end
  -- 2) 一覧のセルの名前（AX の文字の位置と、同じ文字の OCR の位置の差。2つ以上が合う時だけ）
  local diffs = {}
  for _, cell in ipairs(bfsAll(hs.axuielement.windowElement(win),
                               function(e) return role(e) == "AXCell" end, 4000)) do
    local t = bfs(cell, function(e)
      return role(e) == "AXStaticText" and tostring(attr(e, "AXValue") or "") ~= ""
    end, 40)
    local tr, tn = t and axFrame(t), t and norm(attr(t, "AXValue"))
    if tr and tn and (utf8.len(tn) or 0) >= 2 and tr.x < ffAX.x + ffAX.w then
      local hit
      for _, it in ipairs(items) do
        if it.n == tn and it.x >= tr.x - 20 and it.x <= tr.x + tr.w + 20
           and math.abs(it.y - (tr.y + tr.h / 2)) <= L.SHIFT_MAX then
          if hit then hit = false; break end    -- 近くに同じ名前が2つ → どちらか分からない
          hit = it
        end
      end
      if hit then diffs[#diffs + 1] = hit.y - (tr.y + tr.h / 2) end
    end
  end
  if #diffs >= 2 then
    table.sort(diffs)
    local mid, agree = diffs[(#diffs + 1) // 2], 0
    for _, d in ipairs(diffs) do if math.abs(d - mid) <= 6 then agree = agree + 1 end end
    if agree * 2 > #diffs then return mid, "一覧のセルの名前 " .. agree .. " 個" end
  end
  return nil
end

-- AX の位置に足すずれ（dy）と、どう決めたか
local function axShift(win, field, ffAX, items)
  local f = win:frame()
  local memo = string.format("%.0f:%.0f:%.0f:%.0f", f.x, f.y, f.w, f.h)
  local dy, how = measureShift(win, field, ffAX, items or {})
  if dy then
    SHIFT = { memo = memo, dy = dy, how = how }
    return dy, how
  end
  if SHIFT and SHIFT.memo == memo then return SHIFT.dy, "前に測った値（" .. SHIFT.how .. "）" end
  return 0, "測れず、ずれ無しとみなした"
end

-- ---------- 2. トークを開いて確かめる ----------
-- 左ペインの AX のセル（トーク名が載っている）。名前が合わないセルも枠ごと返す
-- （OCR で見えた候補がどのセルの中か＝どの行かを数えるのに使う）。
-- 位置は画面の位置（AX の位置に dy を足した物。below も画面の位置）。
local function rowsByAX(win, paneX, below, dy)
  local rows, wf = {}, win:frame()
  for _, cell in ipairs(bfsAll(hs.axuielement.windowElement(win),
                               function(e) return role(e) == "AXCell" end, 4000)) do
    local r = axFrame(cell)
    if r then r = shifted(r, dy) end
    local t = bfs(cell, function(e)
      return role(e) == "AXStaticText" and tostring(attr(e, "AXValue") or "") ~= ""
    end, 40)
    -- 窓の下に半分以上はみ出した行（スクロールで隠れた行）は見えていないとみなす
    if r and r.x + r.w / 2 < paneX and r.y > below and r.y + r.h / 2 < wf.y + wf.h - 2 then
      local raw = t and tostring(attr(t, "AXValue")) or nil
      rows[#rows + 1] = { el = cell, n = raw and norm(raw) or "", raw = raw,
                          x = r.x + r.w / 2, y = r.y + r.h / 2, f = r }
    end
  end
  return rows
end

-- 検索欄にフォーカスがあるか（true / false / 分からない=nil）
local function fieldFocused(field, ff)
  local v = attr(field, "AXFocused")
  if v == true then return true end
  local sys = hs.axuielement.systemWideElement()
  local fe = sys and attr(sys, "AXFocusedUIElement")
  local fr = fe and axFrame(fe)
  if fr then return math.abs(fr.x - ff.x) < 2 and math.abs(fr.y - ff.y) < 2 end
  if v == false then return false end
  return nil
end

local function inside(it, f) return it.x >= f.x and it.x <= f.x + f.w and it.y >= f.y and it.y <= f.y + f.h end

-- 左の一覧とトーク欄の境目（x）。一覧の AX のセルの右端を使う。検索欄の
-- AX の枠は一覧より狭いことがある（実機で、検索欄の右端より右にも一覧の
-- 文字が並んでいた）ので、セルが無い時だけ仕切り（AXSplitter）、それも
-- 無ければ検索欄の右端で代える。実行中は窓が同じ間だけ覚えておく
-- （AX を毎回たどると遅い）。
local function listRight(win, ff)
  local f = win:frame()
  local memo = string.format("%.0f:%.0f:%.0f:%.0f:%.0f", f.x, f.w, f.h, ff.x, ff.w)
  if RUN and RUN.listRight and RUN.listRight.memo == memo then
    return RUN.listRight.x, RUN.listRight.how
  end
  local root = hs.axuielement.windowElement(win)
  local x, how, n = nil, nil, 0
  for _, cell in ipairs(bfsAll(root, function(e) return role(e) == "AXCell" end, 4000)) do
    local r = axFrame(cell)
    -- トーク欄のメッセージのセルは検索欄より右から始まるので数えない。
    -- 幅の無い・検索欄の真ん中より左で終わるセルも数えない（実機で、検索結果の
    -- 画面に右端 x=0 のセルが1個だけあり、境目を x=0 と取り違えて全件を見失った）
    if r and r.w >= 40 and r.h >= 10 and r.x < ff.x + ff.w and r.y > ff.y
       and r.x + r.w > ff.x + ff.w / 2 and r.x + r.w < f.x + f.w * 0.7 then
      n = n + 1; x = math.max(x or 0, r.x + r.w)
    end
  end
  if x then how = "一覧のセル " .. n .. " 個の右端"
  else
    local sp = bfs(root, function(e)
      if role(e) ~= "AXSplitter" then return false end
      local r = axFrame(e)
      return r ~= nil and r.x > ff.x and r.h > r.w                -- 縦の仕切り
    end, 3000)
    local r = sp and axFrame(sp)
    if r then x, how = r.x + r.w, "仕切り（AXSplitter）" end
  end
  if not x then return ff.x + ff.w + 10, "検索欄の右端（一覧の幅が分からない）" end
  if RUN then RUN.listRight = { memo = memo, x = x, how = how } end
  return x, how
end

-- 名前の行の候補を選ぶ。完全一致の行があればそれ（2行以上あれば上から順に）。
-- 無ければ部分一致の行を、名前より余分な字が少ない順に並べる（名前の絵文字を
-- OCR が1〜2字に読む「パプリカ🌶️」が、別のトーク「パプリカ○○会」より先）。
-- 部分一致の行は別のトークかもしれないが、開いた後の保存ダイアログで保存名が
-- 名前と完全に同じかを確かめ、違えば保存せずに次の候補へ進む（exportSteps）。
-- 候補は「行」で数える: OCR で見えた候補はそれを含む AX のセル（無ければ縦に
-- 30pt 以内でまとめた行）、AX のセルはそのセル。同じ行の名前とプレビューは1つ、
-- AX と OCR の片方にしか見えない行も1つとして数える。
-- OCR で見えた行はその位置を押し、AX にしか見えない行はそのセルを押す（el）。
-- 返す行には、ヘッダ照合用にその行の OCR の文字（ocrN）も持たせる。
local function pickRows(ctx, win, items, ff, paneX)
  local function inList(it) return it.y > ff.y + ff.h + 2 and it.x > ff.x - 80 and it.x < paneX end
  local ocrC, top = {}, 0
  for _, it in ipairs(items) do
    if inList(it) then
      local sc = score(ctx.tn, it.n)
      if sc > 0 then ocrC[#ocrC + 1] = { x = it.x, y = it.y, n = it.n, sc = sc }; top = math.max(top, sc) end
    end
  end
  local cells = {}
  if top < 3 then
    cells = rowsByAX(win, paneX, ff.y + ff.h, ctx.dy)
    for _, c in ipairs(cells) do c.sc = score(ctx.tn, c.n); top = math.max(top, c.sc) end
  end
  if top == 0 then return nil end

  local rows, byKey, loose_ = {}, {}, {}
  local function rowFor(k, r)
    if not byKey[k] then byKey[k] = r; rows[#rows + 1] = r end
    return byKey[k]
  end
  for _, c in ipairs(ocrC) do
    if c.sc == top then
      local k
      for i, cell in ipairs(cells) do if inside(c, cell.f) then k = "cell" .. i end end
      if not k then
        for i, y in ipairs(loose_) do if math.abs(c.y - y) < 30 then k = "y" .. i end end
        if not k then loose_[#loose_ + 1] = c.y; k = "y" .. #loose_ end
      end
      local r = rowFor(k, { x = c.x, y = c.y, ocrN = c.n, byOCR = true })
      if c.y < r.y then r.x, r.y, r.ocrN = c.x, c.y, c.n end
    end
  end
  for i, c in ipairs(cells) do
    if c.sc == top and not byKey["cell" .. i] then
      -- AX のセルだけで見つかった: そのセルを押す。ヘッダ照合用にセルの中の名前の
      -- OCR の文字（名前に一番合う物。無ければ右の列の時刻・未読数を除いた一番上の物）
      local o, os_ = nil, -1
      for _, it in ipairs(items) do
        if inside(it, c.f) and it.x < paneX - 70 and (utf8.len(it.n) or 0) >= 2 then
          local sc = score(ctx.tn, it.n)
          if sc > os_ or (sc == os_ and it.y < o.y) then o, os_ = it, sc end
        end
      end
      rowFor("cell" .. i, { x = c.x, y = c.y, el = c.el, ocrN = o and o.n, axN = c.n })
    end
  end
  local tl = utf8.len(ctx.tn) or 0
  for _, r in ipairs(rows) do
    local n = (top < 3 and r.axN) or r.ocrN or r.axN or ""
    r.extra = (utf8.len(countless(n)) or 99) - tl
  end
  table.sort(rows, function(a, b)
    if top < 3 and a.extra ~= b.extra then return a.extra < b.extra end
    if (a.byOCR == true) ~= (b.byOCR == true) then return a.byOCR == true end
    return a.y < b.y
  end)
  return rows, top
end

-- ヘッダ（トーク欄の上端）の行。トーク名は検索欄と同じ高さにある（2026-10 の
-- 実機）ので、まずその高さの行。そこに何も無い時だけ、帯の中で一番上の行。
-- 窓のタイトル「LINE」やアイコン（1字）は除く。その下のメッセージに同じ名前が
-- あっても拾わない。
local function headerRow(items, paneX, f, winTitle, ff)
  local skip = { line = true, [norm(winTitle or "")] = true }
  local band = {}
  for _, it in ipairs(items) do
    if it.x > paneX and it.y >= f.y and it.y < f.y + L.HEADER_H
       and not skip[it.n] and (utf8.len(it.n) or 0) > 1 then
      band[#band + 1] = it
    end
  end
  table.sort(band, function(a, b) return a.y < b.y end)
  local cy, level = ff.y + ff.h / 2, {}
  for _, it in ipairs(band) do
    if math.abs(it.y - cy) <= L.HEADER_DY then level[#level + 1] = it end
  end
  if #level > 0 then return level end
  local first = {}
  for _, it in ipairs(band) do
    if #first > 0 and it.y - first[1].y > 8 then break end
    first[#first + 1] = it
  end
  return #first > 0 and first or nil
end

-- 開いたトークのヘッダが、押した行と合うか。目的の名前に、押した行と同じ
-- 強さで合えばよい（完全一致の行を押したなら完全一致）。または、押した行の
-- OCR の文字とヘッダの文字が同じ（絵文字などを OCR が同じ字に読み違えた時）。
local function headerMatches(hrow, tn, row, top)
  local best, bs = nil, 0
  for _, it in ipairs(hrow or {}) do
    local sc = score(tn, it.n)
    if sc > bs then best, bs = it, sc end
  end
  if best and bs >= top then return best end
  if row.ocrN then
    local rc = countless(row.ocrN)
    for _, it in ipairs(hrow or {}) do
      if countless(it.n) == rc and score(tn, it.n) > 0 then return it end
    end
  end
  return nil
end

-- 失敗の記録用: ヘッダの行に見えたもの（伏せ字）
local function headerSeen(hrow)
  if not hrow or #hrow == 0 then return "ヘッダ行に文字が見えない" end
  local t = {}
  for _, it in ipairs(hrow) do t[#t + 1] = masked(it.text) end
  return string.format("ヘッダ行（y=%.0f）: %s", hrow[1].y, table.concat(t, " "))
end

-- 押した行のトークが開いたか、ヘッダを読んで確かめる。開くのに時間が
-- かかることがあるので、4秒までは読み直す。
-- 戻り値: ヘッダのトーク名（OCR の1件）/ nil, "ocr" か "mismatch", 撮影, 詳細
local function confirmHeader(ctx, win, ff, paneX, row, top)
  local f, limit = win:frame(), now() + 4
  while true do
    local cap = capture(win, "header")
    local items, oerr = ocr(cap)
    if not items then return nil, "ocr", cap, oerr end
    local hrow = headerRow(items, paneX, f, win:title(), ff)
    local hdr = headerMatches(hrow, ctx.tn, row, top)
    if hdr then return hdr end
    if now() >= limit then return nil, "mismatch", cap, headerSeen(hrow) end
    wait(0.5)
  end
end

-- 検索欄に名前を入れる。フォーカスが入ったと確かめられない時はキーを送らない
-- （前のトークのメッセージ入力欄に名前を貼ってしまわないように）。
-- フォーカスが入らないと分かった時だけ false。
-- ffAX は AX の枠（フォーカスの確認用）、ff は画面の位置（押す所）。
-- 入れるのは ctx.key（今の名前が分かっていればそれで探す文字。無ければ TARGETS の名前）。
local function typeName(ctx, field, ffAX, ff)
  local text = ctx.key or ctx.name
  guard()
  pcall(function() field:setAttributeValue("AXFocused", true) end); wait(0.2)
  local focused = fieldFocused(field, ffAX)
  if focused ~= true then
    clickAt(ff.x + ff.w / 2, ff.y + ff.h / 2); wait(0.3)   -- 画面の位置（AX の枠＋ずれ）
    focused = fieldFocused(field, ffAX)
  end
  if focused == false then return false end
  if focused then
    key({"cmd"}, "a"); wait(0.1)
    pasteText(text, function() return norm(attr(field, "AXValue") or "") == norm(text) end)
    wait(1.0)
  end
  local v = attr(field, "AXValue")
  if not focused or (v ~= nil and norm(v) ~= norm(text)) then
    -- フォーカスが分からない・貼り付けが入らない時は AX で値だけ入れる
    -- （どこにフォーカスがあるか分からない所にキーは送らない）
    pcall(function() field:setAttributeValue("AXValue", text) end); wait(1.0)
  end
  return true
end

-- 画面を撮って読み、AX の位置と画面のずれを測り直す（窓の出し方で変わるので
-- 読むたびに）。ctx.ff（画面の位置の検索欄）と ctx.dy を更新する。
local function readList(ctx, win, field, ffAX)
  local cap = capture(win, "list")
  local items, oerr = ocr(cap)
  if not items then return nil, cap, oerr end
  local dy, how = axShift(win, field, ffAX, items)
  if dy ~= ctx.dy then
    note(ctx, "位置", string.format("LINE が教える検索欄の位置と画面のずれ %+.0fpt（%s）", dy, how))
  end
  ctx.dy, ctx.ff = dy, shifted(ffAX, dy)
  return items, cap
end

-- ---------- 0. 今のトーク名を集める ----------
-- TARGETS の名前は古いことがある（LINE でトーク名を変えている）。書き出しの前に
-- 検索欄を空にしてトークの一覧を上から下まで読み、今のトーク名を集めてから、
-- TARGETS の名前を一番近い今の名前に結び付ける（resolveTarget）。探す・ヘッダで
-- 確かめる・保存名を確かめるのは、その今の名前で行う。
-- 名前とみなすのは、一覧の各行の一番上の行（右に時刻がある高さ）だけ。その下の
-- 行は最後のメッセージなので読まない。AX のセルに同じ文字があれば、その正確な
-- 文字（OCR の読み違いが無い）を使う。集めた名前は DEBUG_DIR/names.txt
-- （Dropbox。非公開）に書く。

-- 一覧の画面（OCR）から各行の名前を拾う。一覧の右の列（時刻・未読数）を行の
-- 目印にし、その高さの一番上の文字（2字以上）を名前とみなす。
local function rowNames(items, ff, paneX)
  local col, right = {}, {}
  for _, it in ipairs(items) do
    if it.y > ff.y + ff.h + 2 and it.x < paneX then
      if it.x > paneX - 70 then right[#right + 1] = it
      elseif it.x > ff.x + 20 and (utf8.len(it.n) or 0) >= 2 then col[#col + 1] = it end
    end
  end
  table.sort(right, function(a, b) return a.y < b.y end)
  local out, last = {}, nil
  for _, a in ipairs(right) do
    if not last or a.y - last >= 30 then          -- 時刻の下の未読数は同じ行
      last = a.y
      local best
      for _, it in ipairs(col) do
        if it.y >= a.y - 8 and it.y <= a.y + 22 and (not best or it.y < best.y) then best = it end
      end
      if best then out[#out + 1] = best end
    end
  end
  return out
end

-- 一覧の上でホイールを回す（正は上へ、負は下へ）。押す時と同じく、LINE が前面で
-- その位置に他の物が重なっていない時だけ
local function scrollList(x, y, amount)
  guard()
  if not ensureFront() then blocked(FRONT_LOST) end
  if not hitsLine(x, y) then blocked("押す所に LINE 以外の物が重なっている") end
  hs.mouse.absolutePosition(hs.geometry.point(x, y))
  hs.eventtap.scrollWheel({ 0, amount }, {}, "pixel")
  synthesized(); wait(0.6)
end

-- 検索欄を空にして、普段のトークの一覧に戻す。フォーカスが入ったと確かめられない
-- 時はキーを送らず、AX で値だけ消す（前のトークの入力欄の下書きを消さない）
local function clearSearch(field, ffAX, ff)
  if norm(attr(field, "AXValue") or "") == "" then return true end
  guard()
  pcall(function() field:setAttributeValue("AXFocused", true) end); wait(0.2)
  local focused = fieldFocused(field, ffAX)
  if focused ~= true then
    clickAt(ff.x + ff.w / 2, ff.y + ff.h / 2); wait(0.3)
    focused = fieldFocused(field, ffAX)
  end
  if focused == true then
    key({"cmd"}, "a"); wait(0.1); key({}, "delete"); wait(0.8)
  end
  if norm(attr(field, "AXValue") or "") ~= "" then
    pcall(function() field:setAttributeValue("AXValue", "") end); wait(0.8)
  end
  return norm(attr(field, "AXValue") or "") == ""
end

-- 今のトーク名を集める。戻り値: { {raw=表示の文字, n=norm, exact=AX の正確な文字か} … } / nil, 理由
local function harvestNames(win)
  local field, ffAX = searchField(win)
  if not ffAX then return nil, "検索欄が見つからない" end
  local paneX = listRight(win, ffAX)
  local ctx = {}
  local items = readList(ctx, win, field, ffAX)
  if not items then return nil, "OCR が動かない" end
  if not clearSearch(field, ffAX, ctx.ff) then return nil, "検索欄を空にできない" end
  local f = win:frame()
  local top = ctx.ff.y + ctx.ff.h
  local mx, my = (ctx.ff.x + paneX) / 2, (top + f.y + f.h) / 2
  local page = math.max(100, f.y + f.h - top - 90)      -- 1行ぶん重ねて送る
  scrollList(mx, my, 20000)                              -- 一番上から読む
  local list, seen = {}, {}
  for _ = 1, L.NAME_PAGES do
    items = readList(ctx, win, field, ffAX)
    if not items then break end
    local cells = rowsByAX(win, paneX, ctx.ff.y + ctx.ff.h, ctx.dy)
    local added = 0
    for _, it in ipairs(rowNames(items, ctx.ff, paneX)) do
      local raw, exact = it.text, false
      for _, c in ipairs(cells) do
        if c.raw and inside(it, c.f) and sameText(c.n, it.n) then raw, exact = c.raw, true end
      end
      local n = norm(raw)
      if n ~= "" and not seen[n] then
        seen[n] = true; added = added + 1
        list[#list + 1] = { raw = raw, n = n, exact = exact }
      end
    end
    if added == 0 then break end                         -- 一番下まで読んだ
    scrollList(mx, my, -page)
  end
  scrollList(mx, my, 20000)                              -- 一番上に戻しておく
  return list
end

-- TARGETS の名前に一番近い今の名前。完全一致（絵文字・空白・メンバー数を除いて）
-- ならそれ。無ければ近さ 0.85 以上（OCR が絵文字を1字に読んだ程度）で、2番目より
-- 0.15 以上近い時だけ。それより離れた名前（「村田研」と「村田研OB会」）は、名前を
-- 変えたのか別のトークなのかを名前だけでは決められないので結び付けない（別の
-- トークを書き出さない）。その時は TARGETS の名前のまま探し、names.txt に一番
-- 近い名前を書く（それを見て TARGETS を今の名前に直す）。
-- 戻り値: 今の名前（list の1件）か nil, 近さ, 一番近かったもの
local function resolveTarget(name, list)
  local tn = norm(name)
  local best, bs, second = nil, 0, 0
  for _, e in ipairs(list or {}) do
    local en = countless(e.n)
    local sc = (en == tn or e.n == tn) and 1 or nameSim(tn, en)
    if sc > bs then second = bs; best, bs = e, sc
    elseif sc > second then second = sc end
  end
  if bs == 1 then return best, 1 end
  if bs >= 0.85 and bs - second >= 0.15 then return best, bs end
  return nil, bs, best
end

-- 2つの文字列に共通する一番長い部分（検索欄に入れる文字。OCR が名前の絵文字を
-- 別の字に読んでいても、TARGETS の名前と共通の部分で探せば見つかる）
local function commonPart(a, b)
  local ok, r = pcall(function()
    local A, B = {}, {}
    for _, c in utf8.codes(a) do A[#A + 1] = c end
    for _, c in utf8.codes(b) do B[#B + 1] = c end
    local best, at, prev = 0, 0, {}
    for i = 1, #A do
      local cur = {}
      for j = 1, #B do
        if A[i] == B[j] then
          cur[j] = (prev[j - 1] or 0) + 1
          if cur[j] > best then best, at = cur[j], i end
        end
      end
      prev = cur
    end
    if best == 0 then return "" end
    return utf8.char(table.unpack(A, at - best + 1, at))
  end)
  return ok and r or ""
end

-- 1件ぶんの「今の名前」: 探す文字（key）・照合する名前（tn）を決める
local function realFor(name, list)
  local e, sc, near = resolveTarget(name, list)
  if not e then return { found = false, sim = sc, near = near } end
  local r = { found = true, raw = e.raw, n = e.n, exact = e.exact, sim = sc }
  if countless(e.n) == norm(name) then r.same = true; return r end
  if e.exact then r.key = e.raw
  else
    local cp = commonPart(name, e.raw):gsub("^%s+", ""):gsub("%s+$", "")
    r.key = (utf8.len(norm(cp)) or 0) >= 2 and cp or e.raw
  end
  return r
end

local function writeNames(list, map, why)
  local lines = {
    "# LINE の今のトーク名（一覧の上から）",
    "time: " .. os.date("%Y-%m-%d %H:%M:%S"),
    "version: " .. VERSION,
    "# 非公開（Dropbox）。一覧の各行の名前だけで、会話の中身は入れていない",
    "",
  }
  if not list then lines[#lines + 1] = "集められなかった: " .. tostring(why) end
  for _, e in ipairs(list or {}) do
    lines[#lines + 1] = e.raw .. (e.exact and "" or "\t（OCR で読んだ文字）")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "# TARGETS → 今の名前"
  for _, t in ipairs(TARGETS) do
    local name = targetName(t)
    local r = map[name]
    if not r or not r.found then
      lines[#lines + 1] = string.format("%s → 決められない（一番近い: %s %.2f）", name,
        r and r.near and r.near.raw or "なし", r and r.sim or 0)
    elseif r.same then
      lines[#lines + 1] = name .. " → " .. r.raw .. "（同じ名前）"
    else
      lines[#lines + 1] = string.format("%s → %s（近さ %.2f。「%s」で探す）", name, r.raw, r.sim, r.key)
    end
  end
  hs.fs.mkdir(DEBUG_DIR)
  local fh = io.open(DEBUG_DIR .. "/names.txt", "w")
  if fh then fh:write(table.concat(lines, "\n") .. "\n"); fh:close() end
end

-- 書き出しの前に今の名前を集めて、TARGETS ごとの「今の名前」を返す。
-- 集められない時（窓が無い・押す所に物が重なる 等）は空（TARGETS の名前のまま探す）。
-- 人の操作で止まった時は、その error をそのまま上へ（全体を止める）。
local function prepareNames(app)
  local map, list, why = {}, nil, nil
  local win = ensureWindow(app)
  if win then
    local ok, r1, r2 = pcall(harvestNames, win)
    if ok then list, why = r1, r2
    elseif type(r1) == "table" and r1.abort then error(r1, 0)
    else why = type(r1) == "table" and r1.blocked or tidy(r1) end
  else
    why = "LINE の窓が開かない"
  end
  for _, t in ipairs(TARGETS) do
    local name = targetName(t)
    map[name] = realFor(name, list)
  end
  pcall(writeNames, list, map, why)
  local found, renamed = 0, 0
  for _, r in pairs(map) do
    if r.found then found = found + 1; if not r.same then renamed = renamed + 1 end end
  end
  log(string.format("今のトーク名 %d 件を集めた（TARGETS %d 件のうち %d 件を結び付け、うち名前が変わっていた %d 件）%s",
    list and #list or 0, #TARGETS, found, renamed, list and "" or ("。集められず: " .. tostring(why))))
  return map, list
end

local function openChat(ctx, win)
  local field, ffAX = searchField(win)
  if not ffAX then return fail(ctx, "検索欄", "検索欄が見つからない") end
  local paneX, how = listRight(win, ffAX)
  ctx.paneX = paneX

  -- 行を押して、ヘッダで確かめる
  local function open(row, top, via)
    if row.el then
      if not press(row.el) then clickAt(row.x, row.y) end
    else
      clickAt(row.x, row.y)
    end
    wait(1.2)
    local hdr, why, cap, seen = confirmHeader(ctx, win, ctx.ff, paneX, row, top)
    if hdr then
      note(ctx, "トーク確認", string.format("%sを押して開き、ヘッダ（y=%.0f）で %s を確かめた",
        via, hdr.y, masked(hdr.text)))
      return { header = hdr, paneX = paneX }
    end
    return nil, why, cap, seen
  end

  local items, cap, oerr = readList(ctx, win, field, ffAX)
  if not items then return fail(ctx, "OCR", "OCR が動かない", cap, oerr) end
  local ff = ctx.ff
  note(ctx, "一覧", string.format("検索欄 x=%.0f〜%.0f y=%.0f / 一覧とトーク欄の境目 x=%.0f（%s）",
    ff.x, ff.x + ff.w, ff.y + ff.h / 2, paneX, how))

  -- 1) 今の一覧に名前がそのまま（完全一致で）見えていれば、検索せずに押す。
  --    検索欄が空（普段の一覧）の時だけ。前の件の検索結果には「メッセージ」の
  --    行なども並び、そこから開くと古い所が開くので使わない
  local rows, top
  if norm(attr(field, "AXValue") or "") == "" then
    rows, top = pickRows(ctx, win, items, ff, paneX)
  end
  if rows and top == 3 then
    note(ctx, "トーク選択", "今の一覧に見えていた（検索しない）")
    local st, why, hcap, seen = open(rows[1], top, "一覧の行")
    if st then return st end
    if why == "ocr" then return fail(ctx, "OCR", "OCR が動かない", hcap, seen) end
    log("一覧の行では " .. ctx.name .. " を確かめられなかったので、検索して開き直す（" .. seen .. "）")
  end

  -- 2) 検索欄に名前を入れ、出てきた行を押す
  if not typeName(ctx, field, ffAX, ctx.ff) then
    return fail(ctx, "検索欄", "検索欄にフォーカスが入らない（キー入力はしていない）")
  end
  for i = 1, 2 do                                -- 検索結果の表示が遅れることがある
    items, cap, oerr = readList(ctx, win, field, ffAX)
    if not items then return fail(ctx, "OCR", "OCR が動かない", cap, oerr) end
    rows, top = pickRows(ctx, win, items, ctx.ff, paneX)
    if rows or i == 2 then break end
    wait(1.0)
  end
  if not rows then return fail(ctx, "トーク選択", "一覧にも検索結果にも名前が見えない", cap) end
  note(ctx, "トーク選択", "検索して見つけた（" .. (top == 3 and "完全一致" or
    ("部分一致 " .. #rows .. " 件。保存名で本人か確かめる")) .. "）")
  -- 候補を順に開く。完全一致が2行あれば2行目も、部分一致は3行まで試す。
  -- 開けた時は、次の候補を開く関数（st.next）も返す: 保存名が名前と違った
  -- （別のトークだった）時に exportSteps が次の候補へ進むため
  local k, last = 0, math.min(#rows, top == 3 and 2 or 3)
  local hcap, seen
  local function nextRow()
    while k < last do
      k = k + 1
      local st, why
      st, why, hcap, seen = open(rows[k], top, "検索結果の行")
      if st then
        if k < last then st.next = nextRow end
        return st
      end
      if why == "ocr" then return fail(ctx, "OCR", "OCR が動かない", hcap, seen) end
    end
    return fail(ctx, "トーク確認", "開いたトークが違う（またはヘッダの名前が読めない）", hcap, seen)
  end
  return nextRow()
end

-- ---------- 3. ⋮ →「トークを保存」 ----------
local function near(a, b, d) return math.abs(a.x - b.x) < d and math.abs(a.y - b.y) < d end
-- ⋮ を押す前から画面にあった文字（チャット本文の「トークを保存」など）は除く
local function isNew(it, before)
  for _, b in ipairs(before) do
    if b.n == it.n and near(b, it, 15) then return false end
  end
  return true
end

local function pressSaveChat(ctx, win, st)
  local f = win:frame()
  local dotsX = f.x + f.w - L.MENU_FROM_RIGHT
  -- メニューは ⋮ の左下に開く。その範囲の、押す前に無かった文字だけを見る
  local function inMenu(it)
    return it.x > dotsX - L.MENU_W and it.x < f.x + f.w + 40
       and it.y > st.header.y - 10 and it.y < st.header.y + L.MENU_H
  end
  -- 比べる元は、押す直前に同じ撮り方（画面）で撮ったもの
  local baseCap = capture(win, "premenu", screenOf(win))
  local base, oerr = ocr(baseCap)
  if not base then return fail(ctx, "OCR", "OCR が動かない", baseCap, oerr) end
  local lastCap, opened = baseCap, false
  for i, d in ipairs({ { 0, 0 }, { L.MENU_RETRY_DX, L.MENU_RETRY_DY } }) do
    clickAt(dotsX + d[1], st.header.y + d[2]); wait(0.8)
    lastCap = capture(win, "menu" .. i, screenOf(win))
    local items, oerr2 = ocr(lastCap)
    if not items then return fail(ctx, "OCR", "OCR が動かない", lastCap, oerr2) end
    local hit, fresh, hint = nil, 0, false
    for _, it in ipairs(items) do
      if inMenu(it) and isNew(it, base) then
        fresh = fresh + 1
        if isLabel(it.n, MENU_HINTS) then hint = true end
        if isSaveLabel(it.n) and (not hit or it.y < hit.y) then hit = it end
      end
    end
    if hit then
      note(ctx, "メニュー", string.format("⋮（x=%.0f y=%.0f）→「トークを保存」を押した", dotsX + d[1], st.header.y + d[2]))
      clickAt(hit.x, hit.y); return true
    end
    -- 開いたのに目的の項目が無い → ヘッダのトーク名を押して閉じる
    -- （Escape は窓/トークを閉じるので使わない）
    if hint or fresh >= 3 then
      opened = true
      clickAt(st.header.x, st.header.y); wait(0.6)
    end
  end
  if opened then
    return fail(ctx, "メニュー", "メニューは開いたが「トークを保存」が見当たらない", lastCap)
  end
  return fail(ctx, "メニュー", "⋮ を押してもメニューが出ない（⋮ の位置: L.MENU_FROM_RIGHT）", lastCap,
    string.format("⋮ を押した位置 x=%.0f y=%.0f（窓の右端 %.0f）", dotsX, st.header.y, f.x + f.w))
end

-- ---------- 4. 保存 → OUT_DIR へ移す ----------
local function today() return os.date("%Y%m%d") end
local function stampedName(fname)
  local stem = fname:gsub("%.txt$", ""):gsub("_%d%d%d%d%d%d%d%d$", "")
  return stem .. "_" .. today() .. ".txt"
end

local function nameField(sheet)
  local fields = bfsAll(sheet, function(e) return role(e) == "AXTextField" end, 600)
  for _, e in ipairs(fields) do
    local v = tostring(attr(e, "AXValue") or "")
    if v:match("%.txt$") or v:match("^%[LINE%]") then return e end
  end
  return fields[1]
end

-- 保存シートが出ている段の失敗: 閉じる前の画面を残してからキャンセルする
local function failSheet(ctx, app, stage, msg, detail)
  local shot = capture(ctx.win, "save", screenOf(ctx.win))
  cancelSheet(app)
  return fail(ctx, stage, msg, shot, detail)
end

-- 保存先の候補。保存パネルは前回の場所を覚えるので、OUT_DIR に直接
-- 落ちることが多い。まず OUT_DIR だけを少し待って見る（ダウンロード等は
-- 「ファイルとフォルダ」の許可が要り、無人の時に確認ダイアログを出さないため）。
-- 名前欄の「/」は、実際のファイル名（POSIX）では「:」になる
-- （例: オーチュー/小林央忠 → [LINE]オーチュー:小林央忠.txt）。
local function fresh(p, since) return (hs.fs.attributes(p, "modification") or 0) >= since - 2 end
local function findSaved(fname, since)
  local posix = fname:gsub("/", ":")
  local dirs = { HOME .. "/Downloads", HOME .. "/Desktop", HOME .. "/Documents",
                 HOME .. "/Document", HOME }
  for _, d in ipairs(dirs) do
    local p = d .. "/" .. posix
    if fresh(p, since) then return p end
  end
  local function lit(s) return '"' .. s:gsub('[\\"]', "\\%0") .. '"' end
  local q = "kMDItemFSName == " .. lit(fname) .. " || kMDItemFSName == " .. lit(posix)
  local out = hs.execute("/usr/bin/mdfind -onlyin " .. sh(HOME) .. " " .. sh(q))
  for p in (out or ""):gmatch("[^\n]+") do
    if fresh(p, since) then return p end
  end
  return nil
end

-- 保存名の本体がトーク名と同じか。保存名は LINE が付ける正確な名前なので、
-- 絵文字・空白・記号を除いて完全一致を求める（行を部分一致で探した時も、
-- 別のトーク「かにっこにー3」「村田研OB会」はここで止まる）。
-- 除くもの: 先頭の [LINE]、末尾の .txt、英語表示の Chat with、「とのトーク」「のトーク」。
local function nameMatches(cur, name)
  if not cur:match("^%[LINE%]") then return false end
  local body = cur:gsub("%.txt$", ""):gsub("^%[LINE%]", "")
  local b = loose(body):gsub("^chatwith", "")
  local n = loose(name)
  if b == "" or n == "" then return false end
  return b == n or b == loose(name .. "とのトーク") or b == loose(name .. "のトーク")
end

-- 保存名・ファイル名の伏せ字。TARGETS のどれかと同じトークならその名前、
-- 違えば字数だけ（他のトーク名をログや診断ファイルに出さない）
local function maskedSave(cur)
  cur = tostring(cur or "")
  -- ファイルのパス（/ か ~ で始まる）だけ、置き場所とファイル名に分ける。
  -- 名前欄の値はトーク名の「/」をそのまま含むので、分けずに全体を伏せる
  local dir, base = cur:match("^([/~].*/)([^/]*)$")
  if dir then return dir:gsub("^" .. HOME:gsub("%p", "%%%0"), "~") .. maskedSave(base) end
  for _, t in ipairs(TARGETS) do
    if nameMatches(cur, targetName(t)) then return "[LINE]〈" .. targetName(t) .. "〉" end
  end
  local body = cur:gsub("%.txt$", ""):gsub("^%[LINE%]", "")
  return (cur:match("^%[LINE%]") and "[LINE]" or "") .. "■" .. (utf8.len(body) or #body) .. "字" ..
    (cur:match("%.txt$") and ".txt" or "")
end

-- 保存名が書き出したいトークか。TARGETS の名前と同じ（nameMatches）か、書き出しの
-- 前に集めた今の名前と同じ。今の名前が OCR で読んだ文字の時は読み違いがあるので、
-- 近さ 0.8 以上で認める（「パプリカ🌶️」を OCR が「パプリカ》」と読んだ等。
-- 「パプリカ会議」のような別のトークはここで止まる）
local function saveNameOK(cur, ctx)
  if nameMatches(cur, ctx.name) then return true end
  local r = ctx.real
  if not (r and cur:match("^%[LINE%]")) then return false end
  if nameMatches(cur, r.raw) then return true end
  if r.exact then return false end
  local body = cur:gsub("%.txt$", ""):gsub("^%[LINE%]", "")
  body = norm(body):gsub("^chatwith", ""):gsub("とのトーク$", ""):gsub("のトーク$", "")
  return nameSim(countless(body), countless(r.n)) >= 0.8
end

local function saveAndMove(ctx, app, st)
  local sheet = waitFor(function() return findSheet(app) end, 6)
  if not sheet then
    -- 遅れて出てきたら次の件の邪魔になるので、少し待って閉じておく
    if waitFor(function() return findSheet(app) end, 2) then cancelSheet(app) end
    return fail(ctx, "保存ダイアログ", "「トークを保存」を押しても保存ダイアログが出ない")
  end
  local field = waitFor(function() return nameField(sheet) end, 2)
  local cur = field and tostring(attr(field, "AXValue") or "") or ""

  -- 本当にトークの保存ダイアログか（[LINE] で始まる名前・保存とキャンセル）。
  -- 違うダイアログなら何も打たずに閉じる。
  if not (cur:match("^%[LINE%]") and findButton(sheet, { "保存", "Save" })
          and findButton(sheet, { "キャンセル", "Cancel" })) then
    return failSheet(ctx, app, "保存ダイアログ", "トークの保存ダイアログに見えない", "名前欄: " .. maskedSave(cur))
  end
  -- 既定名は「[LINE]<トーク名>.txt」。ここでも別トークでないか確かめる
  if not saveNameOK(cur, ctx) then
    local _, e = failSheet(ctx, app, "保存ダイアログ", "保存名がトーク名と合わない", "保存名: " .. maskedSave(cur))
    e.otherChat = true                            -- 別のトークだった（次の候補があれば試す）
    return nil, e
  end
  if ctx.dry then
    -- 確認だけ（check）: 保存名まで確かめたら、何も打たずにキャンセルする
    if not cancelSheet(app) then return fail(ctx, "保存ダイアログ", "確認の後、保存ダイアログを閉じられない") end
    note(ctx, "保存ダイアログ", "保存名 " .. maskedSave(cur) .. " を確かめた（確認なのでキャンセルした）")
    return "dry"
  end

  -- ファイル名に書き出し日を付ける（[LINE]○○_20261020.txt）。既定名は毎回
  -- 同じで、書き出しは画面に読み込まれた範囲しか取れないため、上書きすると
  -- 履歴を失う。名前欄は拡張子の手前まで選択された状態で開くので、
  -- →キーで選択を解いてカーソルをそこへ置き、日付を足す。
  local want = cur:match("%.txt$") and stampedName(cur) or (stampedName(cur):gsub("%.txt$", ""))
  if not cur:gsub("%.txt$", ""):match("_%d%d%d%d%d%d%d%d$") then
    key({}, "right"); wait(0.1)
    pasteText("_" .. today(), function() return attr(field, "AXValue") == want end)
  end
  local now = tostring(attr(field, "AXValue") or "")
  if now ~= want then                             -- 足せなかった時は名前ごと入れ直す
    pcall(function() field:setAttributeValue("AXValue", want) end); wait(0.2)
    now = tostring(attr(field, "AXValue") or "")
  end
  local stamped = now == want
  if not stamped then
    log("warn: " .. ctx.name .. " のファイル名に日付を付けられず（移すときに付ける）")
  end
  local savedAs = now ~= "" and now or cur
  if not savedAs:match("%.txt$") then savedAs = savedAs .. ".txt" end

  local since = os.time()
  local save = findButton(sheet, { "保存", "Save" })
  if not (save and press(save)) then return failSheet(ctx, app, "保存", "「保存」を押せない") end
  wait(0.8)
  -- 同名があると上書き確認が出る（「置き換える」/「置き換え」/ Replace）。
  -- 日付が付いた名前なら今日の分なので置き換えてよい。日付なしの名前は
  -- 過去の書き出しを上書きしうるので、置き換えずに止める。
  local repl = waitFor(function()
    local s = findSheet(app); return s and findButton(s, { "置き換え", "Replace" }, true)
  end, 1.5)
  if repl then
    if not stamped then
      return failSheet(ctx, app, "保存", "日付を付けられず、同名ファイルの上書きになるので中止")
    end
    press(repl); wait(0.7)
  end
  if waitFor(function() return not findSheet(app) end, 5) == nil then
    return failSheet(ctx, app, "保存", "保存ダイアログが閉じない（保存できていない）")
  end

  local posix = savedAs:gsub("/", ":")
  local src = waitFor(function()
    local p = OUT_DIR .. "/" .. posix
    return fresh(p, since) and p
  end, 3, 0.5) or waitFor(function() return findSaved(savedAs, since) end, 4, 0.5)
  if not src then return fail(ctx, "移動", "保存したファイルが見つからない", nil, maskedSave(savedAs)) end
  -- OUT_DIR では / と : を _ にそろえる（ingest.py の safe_filename と同じ扱い）
  local dst = OUT_DIR .. "/" .. stampedName(savedAs):gsub("[/:]", "_")
  if src ~= dst and not os.rename(src, dst) then
    hs.execute("/bin/mv -f " .. sh(src) .. " " .. sh(dst))
  end

  -- ---------- 5. 確認 ----------
  if (hs.fs.attributes(dst, "size") or 0) == 0 then
    return fail(ctx, "移動", "Linetxt に移せない（ダウンロード等へのアクセス許可を確認: " ..
      "docs/setup-mac-auto.md 手順3）", nil, maskedSave(src))
  end
  return dst
end


-- heartbeat（公開）用は決まった文言と画像の置き場だけ。detail（伏せ字済み）は
-- コンソールと診断ファイル（Dropbox）だけに出す。
local function describe(e, withDetail)
  if type(e) ~= "table" then return tostring(e) end
  return "[" .. e.stage .. "] " .. e.msg ..
    (withDetail and e.detail and ("（" .. e.detail .. "）") or "") ..
    (e.img and ("（画像: " .. e.img .. "）") or "")
end

local function exportSteps(app, ctx)
  -- 前の件の保存ダイアログが残っていると、以降のクリックも前面確認も効かない。
  -- 窓を確かめる前に片付ける（AX のキャンセルは前面でなくても押せる）。
  if findSheet(app) then
    log("warn: 前の保存ダイアログが残っていたのでキャンセルする")
    if not cancelSheet(app) then
      return false, select(2, fail(ctx, "窓", "残っていた保存ダイアログを閉じられない"))
    end
  end
  local win = ensureWindow(app)
  ctx.win = win
  if not win then
    return false, select(2, fail(ctx, "窓", "LINE の窓が開かない・前面に来ない（検索欄のある窓が無い）"))
  end
  local f = win:frame()
  note(ctx, "窓", string.format("メイン窓（x=%.0f y=%.0f %.0f×%.0f）を前面にした", f.x, f.y, f.w, f.h))
  local st, e = openChat(ctx, win)
  if not st then return false, e end
  local dst
  while true do
    local ok; ok, e = pressSaveChat(ctx, win, st)
    if not ok then return false, e end
    dst, e = saveAndMove(ctx, app, st)
    if dst then break end
    -- 部分一致で開いたのが別のトークだった（保存名が違った）→ 保存せずに次の候補を開く
    if not (e.otherChat and st.next) then return false, e end
    note(ctx, "保存ダイアログ", "別のトークだった（" .. e.detail .. "）ので、保存せずに次の候補を開く")
    local st2 = st.next()
    if not st2 then return false, e end           -- 次の候補も合わない: 保存名が違ったことを返す
    st = st2
  end
  if dst == "dry" then return true, "（確認だけ。保存はしていない）" end
  note(ctx, "保存", "保存して Linetxt に置いた（" .. (dst:match("[^/]+$") or dst) .. "）")
  return true, dst
end

-- 1件を書き出す（opts.dry なら保存ダイアログで保存名を確かめてキャンセルするまで）。
-- 人の操作を検知したら error({abort=…}) で全体を止める。opts.trace に段ごとの経過。
local function exportOne(app, name, opts)
  opts = opts or {}
  local ctx = { name = name, tn = norm(name), dry = opts.dry, trace = opts.trace or {} }
  -- 書き出しの前に集めた今の名前（名前が変わっていた時だけ。同じならこれまでどおり）
  local r = opts.real
  if r and r.found and not r.same then
    ctx.real, ctx.tn, ctx.key = r, countless(r.n), r.key
    note(ctx, "名前", string.format("今の一覧では %s（近さ %.2f）。「%s」で探す",
      masked(r.raw), r.sim, masked(r.key)))
  end
  local ok, r1, r2 = pcall(exportSteps, app, ctx)
  if ok then return r1, r2 end
  if type(r1) == "table" and r1.blocked then
    -- 押す所に別の物が重なっていた・LINE が前面に無い → この件だけ止める
    return false, select(2, fail(ctx, "クリック", r1.blocked))
  end
  error(r1, 0)
end

-- 失敗した時の「次にすること」（コンソール用）。この Mac で人が手を動かせば
-- 直るものだけ具体的に書く。読み方・押し方の問題は、診断と撮影画像を Dropbox に
-- 残すので、それを見て直した版を出す（Claude に「LINE書き出しの診断を見て直して」と頼む）。
local NO_HINT = "この Mac ですることは無い。診断と撮影画像を " .. DEBUG_SHOW ..
                " に残したので、Claude に「LINE書き出しの診断を見て直して」と頼む"
local function hintFor(e)
  local st, detail = e.stage, tostring(e.detail or "")
  if tostring(e.msg):find("保存ダイアログを閉じられない", 1, true) then
    return "LINE に保存ダイアログが出たままになっている。その「キャンセル」を手で押して閉じてから、もう一度"
  elseif st == "窓" or st == "検索欄" then
    return "LINE を開いて、トークの一覧（検索欄のある画面）を出しておく。別窓で開いたトークは閉じる"
  elseif st == "OCR" and detail:find("画面を撮れない", 1, true) then
    return "画面収録の許可を確かめる（システム設定 → プライバシーとセキュリティ → " ..
           "画面とシステムオーディオ録音 → Hammerspoon をオン → Hammerspoon を再起動）"
  elseif st == "OCR" then
    return "OCR（mac/ocr.applescript）が動かない。ターミナルで osascript " .. tidy(OCR_SCRIPT) ..
           " <画像> を試し、出たエラーを Claude に見せる"
  elseif st == "トーク選択" then
    return "TARGETS の名前を LINE の表示どおりに直す（⌘⌥⌃J で一覧を出せる）"
  elseif st == "保存ダイアログ" and tostring(e.msg):find("合わない", 1, true) then
    return "トーク名が変わったのかもしれない。LINE の表示名を確かめて TARGETS を直す（⌘⌥⌃J で一覧）"
  elseif st == "保存" and tostring(e.msg):find("上書き", 1, true) then
    return "過去の書き出しを上書きしないよう止めた。LINE で ⋮ →「トークを保存」を手で開き、名前欄に日付を足せるか確かめる"
  elseif st == "クリック" then
    return "集中モード（おやすみモード）を ON にして通知を止め、LINE の上に他の窓が無い状態でもう一度"
  elseif st == "移動" then
    return "ダウンロード等へのアクセス許可を確かめる（docs/setup-mac-auto.md 手順3）"
  elseif st == "中断" and not tostring(e.msg):find("時間切れ", 1, true) then
    return "実行中はマウスやキーに触らない（触ると止まる）。もう一度"
  end
  return NO_HINT
end

-- ダウンロード・デスクトップ・書類に一度触って、「ファイルとフォルダ」の
-- 確認ダイアログを人がいる手動実行のうちに出しておく（無人の 07:00 に出ると
-- 誰も押せずに止まる）。
local function probeFolders()
  for _, d in ipairs({ "/Downloads", "/Desktop", "/Documents" }) do
    pcall(function() for _ in hs.fs.dir(HOME .. d) do break end end)
  end
end

local function prepareApp(attended)
  if not screenRecordingOK() then
    return nil, "Hammerspoon に「画面収録」が許可されていない（docs/setup-mac-auto.md）"
  end
  local app = hs.application.find(LINE_BUNDLE)
  if not app then
    -- 起動した直後はこの処理の中からは見えない（起動中のアプリの一覧は処理が
    -- 終わるまで更新されない）ので、起動だけして次の機会に回す
    hs.execute("/usr/bin/open -b " .. LINE_BUNDLE)
    return nil, "LINE が起動していなかったので起動した", "notrunning"
  end
  if hs.fs.attributes(OCR_SCRIPT, "mode") ~= "file" then
    return nil, "OCR スクリプトが無い（mac/ocr.applescript）"
  end
  if hs.fs.attributes(OUT_DIR, "mode") ~= "directory" then
    return nil, "保存先フォルダ（Linetxt）が無い"
  end
  if attended then probeFolders() end
  pruneDebug()
  return app
end

-- 実行の始まりと終わり。手を離して静かになるのを待ってから見張りを始める
-- （ホットキーや「許可」を押した直後に手が動いていると、自分で止めてしまう）。
-- 10秒待っても静かにならなければ始めない（false）。
-- AX の応答待ちは短くする（LINE が固まっても1回あたり数秒で返す）。
-- 実行中は画面を消さない（途中で消えてロックされると、残りが全部失敗する）。
-- 無人の時は、画面が暗くなっていれば起こしてから始める（ロック中は maybeRun で除く）。
local function beginRun(app, auto)
  if auto then pcall(function() hs.caffeinate.declareUserActivity() end) end
  local quiet = waitFor(function()
    local p1 = hs.mouse.absolutePosition(); wait(0.5)
    local p2 = hs.mouse.absolutePosition()
    return idleSeconds() >= 1.5 and math.abs(p1.x - p2.x) < 1 and math.abs(p1.y - p2.y) < 1
  end, 10, 0.1)
  if not quiet then return false end
  local okd, keep = pcall(function() return hs.caffeinate.get("displayIdle") end)
  RUN = { deadline = now() + RUN_LIMIT_MIN * 60, lastSynth = now(),
          mouse = hs.mouse.absolutePosition(), pid = app:pid(), app = app,
          displayIdle = okd and keep == true }
  pcall(function() hs.caffeinate.set("displayIdle", true) end)
  pcall(function() hs.axuielement.systemWideElement():setTimeout(2) end)
  return true
end
local function endRun()
  local keep = RUN and RUN.displayIdle
  RUN = nil
  pcall(function() hs.caffeinate.set("displayIdle", keep == true) end)
  pcall(function() hs.axuielement.systemWideElement():setTimeout(AX_TIMEOUT_AFTER) end)
end

-- 書き出した txt を取り込んで push する。第2引数の true は「ログインシェルの
-- 環境を使う」指定。これが無いと PATH が最小限になり、git や python が
-- 見つからないことがある。
-- 戻り値: "push済" / "変更なし" / "push できず"（詳しくは mac/sync.log）。
-- sync.sh の出力には取り込んだファイル名（トーク名）が入るので、コンソールには結果だけ出す。
local function runSync()
  local out = hs.execute('/bin/bash "' .. REPO .. '/mac/sync.sh" 2>&1', true) or ""
  local r
  if out:find("push 完了", 1, true) then r = "push済"
  elseif out:find("変更なし", 1, true) or out:find("取り込む txt が無い", 1, true) then r = "変更なし"
  else r = "push できず" end
  log("sync: " .. r .. (r == "push できず" and ("（理由は " .. tidy(REPO) .. "/mac/sync.log）") or ""))
  return r
end

-- ---------- 毎日の自動実行の状態 ----------
-- 毎日1回を「取りこぼさない」ための追いかけ実行。
--
-- 固定時刻の hs.timer.doAt は Mac がスリープしていると発火せず、起きた後も
-- 追いかけない。実測でも 27日間で 07:00 に走ったのは1度だけだった。
-- そこで一定間隔で「今日はもう走ったか」を確認し、条件が整った最初の
-- タイミングで実行する。スリープから復帰した直後も確認する。
local STATE_PATH    = REPO .. "/mac/.last_run"     -- 最後に走った日 (YYYYMMDD[:中断回数])
local RESULT_PATH   = REPO .. "/mac/.last_result"  -- 今日の結果（版・失敗数・書き出せたトーク）
local LOADED_PATH   = REPO .. "/mac/.loaded_version"
local CHECK_EVERY   = 60    -- 1分ごとに条件を確認（離席して画面が消えるまでの間を逃さない）
local IDLE_REQUIRED = 180   -- 3分以上操作が無ければ「離席中」とみなす
local MAX_ABORTS    = 3     -- 人の操作で中断した日は、離席を待ってこの回数までやり直す
-- 自動更新: GitHub の main に新しい版が来たら取り込んで読み込み直す（2026-10-23 に了承を得た）。
-- 止めたい時は false にする（手で最新にするのは __LINE_EXPORT.update()）。
local AUTO_UPDATE   = true
local UPDATE_EVERY  = 1800  -- 30分ごとに確認

local function readState()
  local f = io.open(STATE_PATH, "r")
  if not f then return "", 0 end
  local s = (f:read("l") or ""):gsub("%s", "")
  f:close()
  local day, n = s:match("^(%d+):(%d+)$")
  if day then return day, tonumber(n) end
  return s, nil              -- 「YYYYMMDD」だけ = その日は済み
end
local function writeState(s)
  local f = io.open(STATE_PATH, "w")
  if f then f:write(s .. "\n"); f:close() end
end

-- 今日の結果。読み込み直しても、書き出せたトークを飛ばして続きからやれるように。
--   day / version（その結果を出した版）/ ng（最後まで回った時の失敗数）/
--   ok=（書き出せたトーク）/ failed=（始められなかった理由）/ stopped=（中断の理由）
-- 前の版（v4）は書かないので、無ければ heartbeat から日付・版・失敗数だけ読む。
local function readResult()
  local r = { day = "", version = "", ng = 0, ok = {} }
  local f = io.open(RESULT_PATH, "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^(%w+)=(.*)$")
      if k == "day" then r.day = v
      elseif k == "version" then r.version = v
      elseif k == "ng" then r.ng = tonumber(v) or 0
      elseif k == "ok" then r.ok[v] = true
      elseif k == "failed" then r.failed = v
      elseif k == "stopped" then r.stopped = v end
    end
    f:close()
    return r
  end
  local hb = readAll(REPO .. "/mac/heartbeat.txt") or ""
  local y, m, d = hb:match("last_run: (%d+)%-(%d+)%-(%d+)")
  if y then r.day = y .. m .. d end
  r.version = hb:match("version: ([^\n]+)") or ""
  r.ng = tonumber(hb:match("\nng: (%d+)")) or 0
  return r
end
local function writeResult(r)
  local f = io.open(RESULT_PATH, "w")
  if not f then return end
  f:write("day=" .. (r.day or today()) .. "\nversion=" .. (r.version or VERSION) .. "\nng=" .. (r.ng or 0) .. "\n")
  for n in pairs(r.ok or {}) do f:write("ok=" .. n .. "\n") end
  if r.failed then f:write("failed=" .. r.failed:gsub("[\r\n]", " ") .. "\n") end
  if r.stopped then f:write("stopped=" .. r.stopped:gsub("[\r\n]", " ") .. "\n") end
  f:close()
end
-- 今日の結果（別の日の結果なら空から）
local function todayResult()
  local r = readResult()
  if r.day ~= today() then r = { day = today(), version = "", ng = 0, ok = {} } end
  return r
end

local function screenLocked()
  local props = hs.caffeinate.sessionProperties()
  return props and props.CGSSessionScreenIsLocked or false
end

-- 画面を見ている人がいそうか（ビデオ会議・画面共有・動画）。3分触っていなくても
-- この間に LINE のトークを次々開くと、共有画面などに映ってしまう。
-- 常に起こしておくだけの道具（Amphetamine 等）の保持は数えない。
local KEEP_AWAKE = { Hammerspoon = true, Amphetamine = true, caffeinate = true,
                     Caffeine = true, KeepingYouAwake = true, Theine = true, Lungo = true }
local function watchedScreen()
  local okc, cams = pcall(function() return hs.camera.allCameras() end)
  if okc and cams then
    for _, c in ipairs(cams) do
      local ok, used = pcall(function() return c:isInUse() end)
      if ok and used then return "カメラ使用中" end
    end
  end
  local oka, why = pcall(function()
    for pid, list in pairs(hs.caffeinate.currentAssertions() or {}) do
      for _, a in ipairs(type(list) == "table" and list or {}) do
        local t = type(a) == "table" and a.AssertType
        if t == "PreventUserIdleDisplaySleep" or t == "NoDisplaySleepAssertion" then
          local app = hs.application.applicationForPID(tonumber(pid) or -1)
          local nm = app and app:name() or tostring(a.Process or a["Process Name"] or "")
          if not KEEP_AWAKE[nm] then return "画面スリープ抑止中（" .. nm .. "）" end
        end
      end
    end
  end)
  return oka and why or nil
end

-- ---------- 状態の表示（status と診断ファイル）----------
local function gitBranch()
  local out = hs.execute("git -C " .. sh(REPO) .. " symbolic-ref --short -q HEAD 2>/dev/null", true)
  return (((out or ""):match("([^\r\n]+)[\r\n]*$") or ""):gsub("%s", ""))
end
local function displaySleepMin()
  local out = hs.execute("/usr/bin/pmset -g 2>/dev/null")
  return tonumber((out or ""):match("displaysleep%s+(%d+)"))
end

local function statusLines()
  local t = {}
  local function add(ok, s) t[#t + 1] = (ok == true and "✓ " or ok == false and "✗ " or "・") .. s end
  add(nil, "版: " .. VERSION .. "（" .. LOADED_AT .. " に読み込み）")
  add(screenRecordingOK(), "画面収録の許可")
  add(hs.application.find(LINE_BUNDLE) ~= nil, "LINE が起動している")
  add(hs.fs.attributes(OCR_SCRIPT, "mode") == "file", "OCR スクリプト（mac/ocr.applescript）")
  add(hs.fs.attributes(OUT_DIR, "mode") == "directory", "保存先フォルダ（Linetxt）")
  local br = gitBranch()
  add(br == "main", "リポジトリのブランチ: " .. (br ~= "" and br or "不明") ..
    (br == "main" and "" or "（main 以外では取り込み・push・自動更新をしない）"))
  add(nil, "自動更新: " .. (AUTO_UPDATE and ("オン（" .. UPDATE_EVERY // 60 .. " 分ごとに GitHub の main を見る）") or "オフ") ..
    (M.lastUpdate and ("。最後: " .. os.date("%H:%M", M.lastUpdate.at) .. " " .. M.lastUpdate.why) or ""))
  local day, aborts = readState()
  local res = todayResult()
  if res.failed then
    -- 残すのは自動実行の「始められない」だけ（手動の失敗はその場でアラートとコンソールに出る）
    add(false, "今日の自動実行: 始められない（" .. res.failed .. "）。直れば次の確認で自動で始める")
  end
  if day == today() and aborts == nil then
    local known = res.version ~= ""
    local retry = known and res.ng > 0 and res.version ~= VERSION
    add(nil, "今日の書き出し: 済み" .. (known and ("（失敗 " .. res.ng .. " 件）") or "") ..
      (retry and "。新しい版が入ったので、離席したら失敗分をやり直す" or ""))
  elseif day == today() and aborts and aborts > 0 then
    add(nil, "今日の自動実行: " .. aborts .. " 回中断（最後: " .. (res.stopped or "理由不明") .. "）" ..
      (aborts >= MAX_ABORTS and "。今日は自動ではもうやらない（⌘⌥⌃L で手動）" or "。離席したら続きからやり直す"))
  elseif not res.failed then
    add(nil, "今日の自動実行: まだ")
  end
  add(nil, string.format("自動実行の条件: 毎日 %s 以降、%d 分以上 Mac を触っていない・画面ロック無し（%d 秒ごとに確認）",
    RUN_AT, IDLE_REQUIRED // 60, CHECK_EVERY))
  add(nil, "最後の確認: " .. (M.lastCheck and (os.date("%H:%M", M.lastCheck.at) .. " " .. M.lastCheck.why)
                                          or "まだ（読み込んだ直後）"))
  local okn, nt = pcall(function() return M.timer and M.timer:nextTrigger() end)
  if okn and type(nt) == "number" then
    add(nil, nt > 1 and string.format("次の確認: 約 %d 秒後", math.floor(nt)) or "次の確認: まもなく")
  end
  add(nil, string.format("今の無操作時間: %.0f 秒", idleSeconds()))
  local locked = screenLocked()
  add(not locked, "画面ロック: " .. (locked and "中（ロック中は自動実行しない）" or "なし"))
  local ds = displaySleepMin()
  if ds then
    if ds > 0 and ds * 60 <= IDLE_REQUIRED then
      add(false, "画面が " .. ds .. " 分で消える設定。" .. IDLE_REQUIRED // 60 ..
        " 分の離席を待つ前に消えてロックされると、自動実行が始まらない")
    else
      add(true, "画面が消えるまで: " .. (ds == 0 and "消えない設定" or (ds .. " 分")))
    end
  end
  local busy = watchedScreen()
  if busy then add(false, "見送りの理由: " .. busy) end
  add(nil, "撮影画像と診断の置き場: " .. DEBUG_SHOW)
  return t
end

-- 結果をリポジトリに残す（公開。決まった文言と数だけ）
local function writeHeartbeat(okN, ngN, ngLines, note)
  local hb = io.open(REPO .. "/mac/heartbeat.txt", "w")
  if not hb then return end
  hb:write(string.format("last_run: %s\nversion: %s\nok: %d\nng: %d\n",
    os.date("%Y-%m-%d %H:%M:%S"), VERSION, okN, ngN))
  if note then hb:write("note: " .. note .. "\n") end
  if #ngLines > 0 then
    hb:write("failures:\n")
    for _, line in ipairs(ngLines) do hb:write("  - " .. line .. "\n") end
    hb:write("debug: " .. DEBUG_SHOW .. "（撮影画像と診断。非公開）\n")
  end
  hb:close()
end

-- 診断ファイル（Dropbox の line-dump-debug/latest.txt と日時付きの控え）。
-- 段ごとの経過・失敗した時の画面の並び（伏せ字）・状態を書く。
-- この Mac に頼らず、こちらで読んで直すためのもの。
local function writeReport(title, results, extra)
  hs.fs.mkdir(DEBUG_DIR)
  local t = { "# LINE書き出しの診断（" .. title .. "）",
              "time: " .. os.date("%Y-%m-%d %H:%M:%S"), "version: " .. VERSION, "" }
  for _, r in ipairs(results or {}) do
    t[#t + 1] = "== " .. r.name .. ": " .. (r.ok and ("OK " .. (r.note or "")) or describe(r.e, true))
    for _, s in ipairs(r.trace or {}) do t[#t + 1] = "  ✓ " .. s.stage .. ": " .. s.text end
    if r.e and r.e.layout then
      t[#t + 1] = "  失敗した時の画面（伏せ字）:"
      for _, l in ipairs(r.e.layout) do t[#t + 1] = "    " .. l end
    end
  end
  for _, l in ipairs(extra or {}) do t[#t + 1] = l end
  t[#t + 1] = ""
  t[#t + 1] = "== 状態"
  for _, l in ipairs(statusLines()) do t[#t + 1] = "  " .. l end
  local text = table.concat(t, "\n") .. "\n"
  for _, p in ipairs({ DEBUG_DIR .. "/latest.txt",
                       DEBUG_DIR .. "/" .. os.date("%Y%m%d-%H%M%S") .. "_report.txt" }) do
    local f = io.open(p, "w")
    if f then f:write(text); f:close() end
  end
  return text
end

-- check と one の中身。段ごとの経過をコンソールに出し、診断を Dropbox に残す。
local function tryOne(name, dry)
  local title = dry and "確認（保存はしない）" or "1件だけ書き出す"
  local lines = { "=== " .. title .. ": " .. name .. "（" .. VERSION .. "）===" }
  local function out(s) lines[#lines + 1] = s end
  local result = { name = name }
  local function finish(alert)
    print(table.concat(lines, "\n"))
    writeReport(title, { result })
    pcall(function() hs.openConsole(true) end)
    hs.alert.show(alert, 5)
    return result.ok == true
  end
  local known = false
  for _, t in ipairs(TARGETS) do if targetName(t) == name then known = true end end
  if not known then out("・注意: 「" .. name .. "」は TARGETS に無い（試すことはできる）") end
  local app, err, why = prepareApp(true)
  if not app then
    out("✗ 準備: " .. err .. (why and "。開いたらもう一度" or ""))
    result.e = { stage = "準備", msg = err }
    return finish("NG: " .. err)
  end
  out("✓ 準備: 画面収録の許可・LINE・OCR スクリプト・保存先フォルダ")
  if not beginRun(app) then
    out("✗ 手が動いているので始めなかった。手を離してからもう一度")
    result.e = { stage = "準備", msg = "手が動いていた" }
    return finish("手が動いているので始めなかった。手を離してからもう一度")
  end
  local trace = {}
  result.trace = trace
  -- 今のトーク名を集めてから（TARGETS の名前が古くても、今の名前で探す）
  local okn, map, list = pcall(prepareNames, app)
  if not okn then
    if type(map) == "table" and map.abort then
      endRun()
      log("中断: " .. map.abort)
      result.e = { stage = "中断", msg = map.abort }
      out("✗ 中断（今のトーク名を集めている時）: " .. map.abort)
      out("    次にすること: " .. hintFor(result.e))
      return finish("LINE書き出しを中断: " .. map.abort)
    end
    map, list = {}, nil
  end
  local okc, ok, e = pcall(exportOne, app, name,
    { dry = dry, trace = trace, real = map[name] or (list and realFor(name, list)) })
  endRun()
  for _, s in ipairs(trace) do out("✓ " .. s.stage .. ": " .. s.text) end
  if not okc then
    if type(ok) == "table" and ok.abort then
      log("中断: " .. ok.abort)
      result.e = { stage = "中断", msg = ok.abort }
      out("✗ 中断: " .. ok.abort)
      out("    次にすること: " .. hintFor(result.e))
      return finish("LINE書き出しを中断: " .. ok.abort)
    end
    ok, e = false, { stage = "内部エラー", msg = tidy(ok) }
  end
  if not ok then
    result.e = e
    out("✗ " .. e.stage .. ": " .. e.msg)
    if e.detail then out("    詳しく: " .. e.detail) end
    if e.img then out("    画像: " .. e.img) end
    out("    次にすること: " .. hintFor(e))
    log("NG  " .. name .. "  " .. describe(e, true))
    return finish("NG: " .. name .. "\n[" .. e.stage .. "] " .. e.msg)
  end
  result.ok = true
  if dry then
    out("=== OK: 保存ダイアログで保存名まで確かめた（保存はしていない）。" ..
        "__LINE_EXPORT.one(\"" .. name .. "\") で本当に書き出せる ===")
    return finish("確認OK: " .. name .. "（保存はしていない）")
  end
  local file = e:match("[^/]+$") or e
  result.note = "→ " .. file
  log("OK  " .. name .. " → " .. tidy(e))
  local pushed = runSync()
  out("=== OK: " .. file .. " を書き出した / " .. pushed .. " ===")
  if pushed == "push できず" then
    out("    push できなかった（書き出したファイルは Linetxt にある）。理由は " .. tidy(REPO) .. "/mac/sync.log")
  end
  return finish("書き出しOK: " .. name .. " / " .. pushed)
end

-- 1件だけ本当に書き出す。Hammerspoon コンソールから: __LINE_EXPORT.one("Berry")
function M.one(name)
  if not name then M.help(); return false end
  return tryOne(name, false)
end
-- 1件を、保存ダイアログで保存名を確かめるところまで試す（保存はしない）: __LINE_EXPORT.check("Berry")
function M.check(name)
  return tryOne(name or targetName(TARGETS[1]), true)
end

-- 今日すでに書き出せたトーク。人の操作で中断した日や、新しい版でやり直す時は、
-- 済んだものを飛ばして残りから進める（毎回1件目からだと後ろが届かない）。
local DONE = (function()
  local r = readResult()
  return { day = r.day, ok = r.day == today() and r.ok or {} }
end)()

-- 全件を書き出す。auto=true は無人の自動実行。戻り値（2つ目は理由）:
--   "done" 最後まで / "aborted" 途中で止めた（人の操作・時間切れ。やり直してよい）/
--   "busy" 手が動いていて始めなかった / "notready" LINE を起動しただけ /
--   "failed" 始められない（画面収録の許可が無い・保存先が無い など）
-- busy・notready・failed はその日の回数を使わない（直れば次の確認で始める）。
local function runExport(auto)
  local app, err, why
  if #TARGETS == 0 then
    err = "TARGETS が空（line_export.lua に書き出すトークの名前を書く）"
  else
    app, err, why = prepareApp(not auto)
  end
  if not app then
    log(err)
    if why == "notrunning" then
      hs.alert.show(err .. (auto and "（次の確認で実行）" or "。開いたらもう一度 ⌘⌥⌃L"), 6)
      return "notready", err
    end
    -- 原因をリポジトリに残す（このMacのログを毎回見に行かなくて済むように）。
    -- 自動実行は直るまで毎分確かめるので、同じ理由は1日1回だけ残す
    local res = todayResult()
    if not auto or res.failed ~= err then
      hs.alert.show("LINE書き出し中止: " .. err, 6)
      writeHeartbeat(0, #TARGETS, { "全件: " .. err })
      if auto then res.failed = err; writeResult(res) end   -- 自動実行の「始められない」だけ残す
      writeReport("始められない: " .. err, {})
      runSync()
    end
    return "failed", err
  end

  if not beginRun(app, auto) then
    log("手が動いているので始めなかった")
    if not auto then hs.alert.show("手が動いているので始めなかった。手を離してからもう一度 ⌘⌥⌃L", 4) end
    return "busy", "手が動いていた"
  end
  if DONE.day ~= today() then DONE = { day = today(), ok = {} } end
  local okN, ngN, ngLines, stopped, results = 0, 0, {}, nil, {}
  -- 書き出しの前に今のトーク名を集める（今日まだ書き出していないものがある時だけ）
  local real, left = {}, false
  for _, t in ipairs(TARGETS) do if not (auto and DONE.ok[targetName(t)]) then left = true end end
  if left then
    local okn, r = pcall(prepareNames, app)
    if okn then real = r
    elseif type(r) == "table" and r.abort then stopped = r.abort .. "（今のトーク名を集めている時に中断）"
    else log("今のトーク名を集められなかった: " .. tidy(type(r) == "table" and r.blocked or r)) end
  end
  for i, t in ipairs(TARGETS) do
    if stopped then break end
    local name = targetName(t)
    if auto and DONE.ok[name] then
      okN = okN + 1; log("済み " .. name .. "（今日の前の実行で書き出し済み）")
      goto continue
    end
    -- 1件の想定外エラーで残りを止めず、heartbeat も必ず書く
    local trace = {}
    local okc, ok, e = pcall(exportOne, app, name, { trace = trace, real = real[name] })
    if not okc then
      if type(ok) == "table" and ok.abort then
        stopped = ok.abort .. "（" .. i .. "/" .. #TARGETS .. " 件目で中断）"
        results[#results + 1] = { name = name, ok = false, trace = trace,
                                  e = { stage = "中断", msg = ok.abort } }
        break
      end
      ok, e = false, { stage = "内部エラー", msg = tidy(ok) }
    end
    if ok then
      okN = okN + 1; DONE.ok[name] = true; log("OK  " .. name .. " → " .. tidy(e))
      results[#results + 1] = { name = name, ok = true, trace = trace, note = "→ " .. (e:match("[^/]+$") or e) }
    else
      ngN = ngN + 1; log("NG  " .. name .. "  " .. describe(e, true))
      ngLines[#ngLines + 1] = name .. ": " .. describe(e)
      results[#results + 1] = { name = name, ok = false, trace = trace, e = e }
    end
    wait(0.8)
    ::continue::
  end
  endRun()
  if stopped then log("中断: " .. stopped) end

  -- 結果をリポジトリに残す。ログはこのMacにしか無く、失敗の理由を
  -- 毎回コンソールから貼ってもらうのは現実的でないため、push して共有する。
  -- 段ごとの経過と失敗した時の画面（伏せ字）・撮影画像は Dropbox に置く。
  -- 途中で止めた時は、前に最後まで回った時の失敗数と版を残す（新しい版でのやり直しの目安）
  -- 日付は始めた日（日をまたいで終わっても、次の日の分にしない）。始められたので
  -- 「始められない」の印は消す
  local res = readResult()
  if res.day ~= DONE.day then res = { day = DONE.day, version = "", ng = 0, ok = {} } end
  if stopped then
    res.ok, res.stopped, res.failed = DONE.ok, stopped, nil
  else
    res = { day = DONE.day, version = VERSION, ng = ngN, ok = DONE.ok }
  end
  writeResult(res)
  writeHeartbeat(okN, ngN, ngLines, stopped and ("中断: " .. stopped))
  writeReport((auto and "自動実行" or "手動実行") .. (stopped and "・中断" or ""), results)

  local pushed = runSync()
  hs.alert.show(string.format("LINE書き出し OK:%d NG:%d%s / %s", okN, ngN,
    stopped and (" 中断") or "", pushed), 4)
  if not auto and (ngN > 0 or stopped or pushed == "push できず") then
    pcall(function() hs.openConsole(true) end)
  end
  return stopped and "aborted" or "done", stopped or (ngN .. " 件失敗")
end

-- 画面の読み取り診断: 今の LINE の窓を撮って、読めた文字を位置と領域つきで
-- 伏せ字で出す（TARGETS の名前と LINE の決まった表示以外は ■n字）。
-- 窓だけを撮るので LINE を前に出さない（コンソールが隠れない）。何も押さない。
-- quiet=true は自動の診断（コンソールを開かない・通知を出さない）。
function M.diag(quiet)
  local lines = {}
  local function out(s) lines[#lines + 1] = s end
  local function finish(alert)
    if not quiet then
      print(table.concat(lines, "\n"))
      pcall(function() hs.openConsole(true) end)
      if alert then hs.alert.show(alert, 4) end
    end
    writeReport(quiet and "自動の診断" or "診断", {}, lines)
  end
  local app = hs.application.find(LINE_BUNDLE)
  if not app then out("LINE が起動していない"); return finish("LINE が起動していない") end
  local win = findMain(app, true) or (not quiet and (app:focusedWindow() or app:mainWindow())) or nil
  if not win then
    -- 見えない理由を分けて出す（実機で「見えない」とだけ出て、原因が分からなかった）
    local all = (pcall(function() return app:allWindows() end) and app:allWindows()) or {}
    local mini = 0
    for _, w in ipairs(all) do if w:isMinimized() then mini = mini + 1 end end
    local okh, hidden = pcall(function() return app:isHidden() end)
    local why = (okh and hidden) and "LINE が隠されている（⌘H）"
             or (#all == 0) and "この画面（デスクトップ）に LINE の窓が無い（窓を閉じたか、フルスクリーンで別の画面にある）"
             or (mini == #all) and "LINE の窓が最小化されている"
             or "LINE の窓に検索欄が見つからない（トークの一覧の画面ではない）"
    out("LINE の窓が見えない: " .. why .. "（窓 " .. #all .. " 個・最小化 " .. mini .. " 個）")
    out("書き出しの時は LINE を前に出して開き直すので、多くの場合はそのままで動く")
    return finish("LINE の窓が見えない")
  end
  local cap = capture(win, "diag")
  local items, oerr = ocr(cap)
  if not items then out("OCR 診断: " .. tostring(oerr)); return finish(oerr) end
  local f = win:frame()
  local field, ffAX = searchField(win)
  local paneX, how, ff, dy, dyHow
  if ffAX then
    paneX, how = listRight(win, ffAX)
    dy, dyHow = axShift(win, field, ffAX, items)
    ff = shifted(ffAX, dy)
  end
  out("=== LINE 診断（" .. VERSION .. "。伏せ字: TARGETS の名前と LINE の決まった表示以外は ■n字）===")
  out(string.format("画面収録: %s / 窓 x=%.0f y=%.0f w=%.0f h=%.0f / 読めた文字 %d 件",
    screenRecordingOK() and "許可" or "未許可", f.x, f.y, f.w, f.h, #items))
  if ff then
    out(string.format("検索欄 x=%.0f〜%.0f y=%.0f（中身: %s）", ff.x, ff.x + ff.w, ff.y + ff.h / 2,
      masked(attr(field, "AXValue") or "")))
    out(string.format("LINE が教える位置と画面のずれ %+.0fpt（%s。AX では y=%.0f）", dy, dyHow,
      ffAX.y + ffAX.h / 2))
    out(string.format("一覧とトーク欄の境目 x=%.0f（%s）", paneX, how))
    local hrow = headerRow(items, paneX, f, win:title(), ff)
    out(headerSeen(hrow))
    if hrow then
      out(string.format("⋮ を押す位置（推定）x=%.0f y=%.0f", f.x + f.w - L.MENU_FROM_RIGHT, hrow[1].y))
    end
    out("TARGETS が今の一覧に見えるか:")
    local cells = rowsByAX(win, paneX, ff.y + ff.h, dy)
    for _, t in ipairs(TARGETS) do
      local name = targetName(t)
      local tn, where = norm(name), nil
      for _, it in ipairs(items) do
        if not where and it.x < paneX and it.y > ff.y + ff.h and score(tn, it.n) == 3 then where = it end
      end
      for _, c in ipairs(cells) do
        if not where and score(tn, c.n) == 3 then where = c end
      end
      out(where and string.format("  ✓ %s（y=%.0f）", name, where.y)
                or ("  ・" .. name .. " は見えない（書き出す時は検索する）"))
    end
  else
    out("検索欄が見つからない（LINE のトークの一覧を出しておく）")
  end
  out("読めた文字（伏せ字）:")
  for _, l in ipairs(layoutLines(items, ff, paneX, 40)) do out("  " .. l) end
  local img = keepDebug("diag", "screen", cap, win)
  out("=== ここまで（このまま貼っても会話の中身は出ません。画像は " .. (img or "保存できず") .. "）===")
  finish("診断をコンソールに出した（伏せ字）")
end

function M.status()
  print("=== LINE書き出し 状態 ===\n" .. table.concat(statusLines(), "\n"))
  pcall(function() hs.openConsole(true) end)
end

function M.help()
  print(table.concat({
    "=== LINE書き出し の使い方（" .. VERSION .. "）===",
    "  ふだんは何もしなくてよい。毎日 " .. RUN_AT .. " 以降、Mac を " .. IDLE_REQUIRED // 60 ..
      " 分以上触っていない時（画面ロック中は除く）に自動で書き出して push する。",
    "  1回の実行は " .. RUN_LIMIT_MIN .. " 分まで（固まったら止める）。",
    "  失敗したら撮影画像と診断（伏せ字）を " .. DEBUG_SHOW .. " に残す。",
    "  直した版は GitHub から自動で取り込む（" .. UPDATE_EVERY // 60 .. " 分ごと。自動実行の後にも）。",
    "",
    "  __LINE_EXPORT.status()        今の状態と、自動実行が走らない理由",
    "  __LINE_EXPORT.check(\"Berry\")  1件を保存ダイアログで保存名を確かめるところまで試す（保存しない）",
    "  __LINE_EXPORT.one(\"Berry\")    1件だけ本当に書き出して push",
    "  __LINE_EXPORT.diag()          画面の読み取り診断（⌘⌥⌃K と同じ。何も押さない）",
    "  __LINE_EXPORT.names()         トーク名の一覧（⌘⌥⌃J と同じ。TARGETS に貼れる形式）",
    "  __LINE_EXPORT.update()        今すぐ最新の版にする（ふだんは自動更新に任せてよい）",
    "  ⌘⌥⌃L 全件を今すぐ書き出す（⇧ 版でも可）",
    "  止めたいとき: マウスを動かすかキーを押す",
    "  status / check / one / diag の画面の文字は伏せ字（TARGETS の名前と LINE の決まった表示以外は ■n字）",
  }, "\n"))
  pcall(function() hs.openConsole(true) end)
end

-- 最新の版にする。git pull して、うまくいった時だけ読み込み直す（手で打った時だけ動く）。
function M.update()
  local out, ok = hs.execute("git -C " .. sh(REPO) .. " pull --ff-only -q origin main 2>&1", true)
  if not ok then
    print("=== 最新にできなかった（git pull に失敗。読み込み直していない）===\n" .. tidy(out or "") ..
      "\n手元で TARGETS などを書き換えたままだと失敗する。ターミナルで cd " .. tidy(REPO) ..
      " && git status を見る（分からなければ、この表示を Claude に見せる）")
    pcall(function() hs.openConsole(true) end)
    hs.alert.show("最新にできなかった（コンソールを見る）", 5)
    return false
  end
  print("=== 最新にした。読み込み直す ===")
  hs.reload()
  return true
end

-- ---------- 自動更新 ----------
-- GitHub の main に新しい版が来たら取り込み、読み込み直す（直した版を、この Mac で
-- 手を動かさずに使えるように。2026-10-23 に了承を得た）。UPDATE_EVERY ごとと自動実行の
-- 後に git pull --ff-only し、このファイルが変わっていれば、文法を確かめてから
-- 読み込み直す。読み込みに失敗したら元の版に戻す（同じ中身では2度試さない）。
-- 実行中・main 以外のブランチでは何もしない。
local function selfUpdate(why)
  if not AUTO_UPDATE or RUN then return "skip" end
  if gitBranch() ~= "main" then
    M.lastUpdate = { at = os.time(), why = "main 以外のブランチなので取り込まない" }
    return "notmain"
  end
  local out, ok = hs.execute("git -C " .. sh(REPO) .. " pull --ff-only -q origin main 2>&1", true)
  if not ok then
    local msg = tidy((out or ""):gsub("%s+", " ")):sub(1, 200)
    if not (M.lastUpdate and M.lastUpdate.err == msg) then   -- 同じ失敗は30分ごとに書かない
      log("warn: 自動更新の git pull に失敗（手元の変更があるか、ネットに繋がっていない）: " .. msg)
    end
    M.lastUpdate = { at = os.time(), why = "git pull に失敗（手元の変更・ネットを確認）", err = msg }
    return "pullfail"
  end
  local src = readAll(SELF)
  if not src or src == LOADED_SRC or src == _G.__LINE_EXPORT_BAD then
    M.lastUpdate = { at = os.time(),
                     why = (src and src == _G.__LINE_EXPORT_BAD) and "新しい版は読み込めないので次の版を待つ" or "新しい版なし" }
    return "same"
  end
  local chunk, err = load(src, "@" .. SELF)
  if not chunk then
    _G.__LINE_EXPORT_BAD = src
    M.lastUpdate = { at = os.time(), why = "新しい版に文法の誤りがあり、読み込まなかった" }
    log("error: 新しい版に文法の誤りがあるので読み込まない（今の版のまま動く）: " .. tidy(err))
    return "bad"
  end
  log("新しい版を読み込む（" .. why .. "）")
  _G.__LINE_EXPORT_SRC = src
  local okc, e = pcall(chunk)
  if okc then return "reloaded" end
  -- 新しい版の読み込みに失敗した: 元の版を読み込み直す（タイマーやホットキーを戻す）
  _G.__LINE_EXPORT_BAD = src
  log("error: 新しい版の読み込みに失敗したので元の版に戻す: " .. tidy(e))
  _G.__LINE_EXPORT_SRC = LOADED_SRC
  local old = load(LOADED_SRC, "@" .. SELF)
  if old then pcall(old) end
  return "failed"
end

-- トーク名の一覧（TARGETS に貼るため）。一覧の列の行だけを読む（トーク欄の
-- メッセージも AX のセルなので、範囲を絞らないと会話の中身まで出てしまう）。
-- 表示中の行しか取れないので、全部欲しければリストをスクロールしてからもう一度。
function M.names()
  local app = hs.application.find(LINE_BUNDLE)
  if not app then hs.alert.show("LINEが見つからない", 3); return end
  app:activate(true); wait(0.4)
  local win = findMain(app)
  local ff
  if win then ff = select(2, searchField(win)) end
  if not ff then hs.alert.show("LINE のトークの一覧（検索欄のある画面）を出しておく", 4); return end
  local paneX = listRight(win, ff)
  local names, seen, wf = {}, {}, win:frame()
  for _, cell in ipairs(bfsAll(hs.axuielement.windowElement(win),
                               function(e) return role(e) == "AXCell" end, 6000)) do
    local r = axFrame(cell)
    if r and r.x + r.w / 2 < paneX and r.y > ff.y + ff.h and r.y + r.h / 2 < wf.y + wf.h then
      local t = bfs(cell, function(e)
        return role(e) == "AXStaticText" and tostring(attr(e, "AXValue") or "") ~= ""
      end, 40)
      local v = t and tostring(attr(t, "AXValue"))
      if v and not seen[v] then seen[v] = true; names[#names + 1] = v end
    end
  end
  -- TARGETS に貼るための一覧なので、トーク名は伏せ字にしない（会話の中身は出さない）
  print("=== LINE トーク一覧 " .. #names .. "件（TARGETS にそのまま貼れる形式）===")
  for _, n in ipairs(names) do print(string.format('  "%s",', n)) end
  print("=== ここまで。表示中の行のみ。足りなければリストをスクロールして再度 ⌘⌥⌃J ===")
  pcall(function() hs.openConsole(true) end)
  hs.alert.show(string.format("%d件をコンソールに出力", #names), 3)
  return names
end

-- ---------- 毎日の自動実行 ----------
local skipLogged = {}
local function checked(why) M.lastCheck = { at = os.time(), why = why } end
-- 今日の heartbeat をもう書いたか（昼の「見送り中」を、読み込み直しても1日1回にする）
local function heartbeatToday()
  return (readAll(REPO .. "/mac/heartbeat.txt") or ""):find("last_run: " .. os.date("%Y-%m-%d"), 1, true) ~= nil
end
local function maybeRun()
  local day = today()
  local stateDay, aborts = readState()
  local before = (readAll(STATE_PATH) or ""):gsub("%s", "")   -- 始められなかった時に戻す
  local retry = false
  if stateDay == day and (aborts == nil or aborts >= MAX_ABORTS) then
    -- 今日は済み。ただし新しい版が入った日は、失敗していた分をもう一度試す（版ごとに1回）
    local res = readResult()
    if aborts == nil and res.day == day and res.ng > 0 and res.version ~= VERSION then
      retry = true
    else
      return checked(aborts == nil and "今日は済み" or ("今日は " .. aborts .. " 回中断したので、自動ではもうやらない"))
    end
  end

  local hh, mm = RUN_AT:match("^(%d+):(%d+)$")
  local t = os.date("*t")
  if t.hour * 60 + t.min < tonumber(hh) * 60 + tonumber(mm) then return checked(RUN_AT .. " より前") end

  -- ロック中・スクリーンセーバ中はクリックが通らない。操作中に割り込むと、
  -- クリックを奪い合って失敗する上に邪魔になる。画面を見ている人がいそうな時も見送る。
  local why
  if screenLocked() then
    why = "画面がロック中"
  else
    local idle = idleSeconds()
    if idle < IDLE_REQUIRED then
      why = string.format("使用中（無操作 %.0f 秒。%d 秒で始める）", idle, IDLE_REQUIRED)
    else
      why = watchedScreen()
      if why and not skipLogged[day .. why] then skipLogged[day .. why] = true; log("見送り: " .. why) end
    end
  end
  if why then
    -- 昼になっても走れていない日は、理由を heartbeat に残す（GitHub から見て
    -- 走らなかった理由が分かるように。今日の heartbeat がまだ無い時だけ＝1日1回）
    if t.hour >= 12 and stateDay ~= day and not heartbeatToday() then
      checked(why)                                -- 診断ファイルの「最後の確認」にこの理由を出す
      writeHeartbeat(0, 0, {}, "見送り中: " .. why)
      writeReport("見送り中: " .. why, {})
      runSync()
    end
    return checked(why)
  end

  -- 実行中の再入と、失敗時の一日中のリトライを防ぐため先に記録する
  writeState(day)
  checked(retry and "新しい版で失敗分のやり直しを開始" or "自動実行を開始")
  if retry then log("新しい版（" .. VERSION .. "）が入ったので、今日失敗した分をもう一度試す") end
  log("自動実行を開始（" .. os.date("%H:%M") .. "）")
  local okr, r, detail = pcall(runExport, true)
  if not okr then
    -- 想定外のエラー（書き出しの外側）。今日を済みにせず、次の確認でやり直す
    if RUN then endRun() end
    log("error: 自動実行で想定外のエラー: " .. tidy(r))
    r, detail = "failed", "想定外のエラー"
  end
  if r == "aborted" then
    -- 人が戻ってきて止めた・時間切れの日は、また離席したらやり直す（上限あり）
    writeState(day .. ":" .. ((stateDay == day and aborts or 0) + 1))
    checked("中断: " .. tostring(detail))
  elseif r == "done" then
    checked("自動実行: 最後まで（" .. tostring(detail) .. "）")
  else
    -- 始められなかった（LINE を起動しただけ・手が動いていた・画面収録の許可が無い など）。
    -- その日の回数は使わず、元の状態に戻して次の確認でやり直す
    writeState(before)
    checked((r == "notready" and "LINE を起動した（次の確認で始める）")
         or (r == "busy" and "手が動いていたので始めなかった")
         or ("始められない: " .. tostring(detail)))
  end
  -- 書き出した後は、新しい版が来ていれば読み込み直す（直した版で、失敗した分をやり直せるように）
  if r == "done" or r == "aborted" then selfUpdate("自動実行の後") end
end

-- 二重読み込み対策。init.lua に dofile 行が複数入っていたり、Reload を
-- 繰り返したりしても、タイマーとホットキーが多重にならないようにする
-- （多重になると 07:00 に自動操作が同時に2本走り、LINE の画面を奪い合う）。
if _G.__LINE_EXPORT then
  local prev = _G.__LINE_EXPORT
  for _, k in ipairs({ "timer", "waker", "wakeTimer", "diagTimer", "updater" }) do
    if prev[k] then pcall(function() prev[k]:stop() end) end
  end
  for _, hk in ipairs(prev.hotkeys or {}) do pcall(function() hk:delete() end) end
  log("前回の読み込み分を解除して張り直します")
end
_G.__LINE_EXPORT = M
M.hotkeys = {}

-- Ctrl版・Shift版の両方に割り当てる。以前ここは ⌘⌥⌃ を使う別スクリプトと
-- 競合していたため一度 Shift に逃がしたが、そちらを無効化した後も
-- 手が Ctrl を覚えているはずなので、どちらを押しても動くようにしておく。
local function bindBoth(k, fn)
  for _, mods in ipairs({{"cmd","alt","ctrl"}, {"cmd","alt","shift"}}) do
    M.hotkeys[#M.hotkeys + 1] = hs.hotkey.bind(mods, k, fn)
  end
end

M.timer = hs.timer.doEvery(CHECK_EVERY, maybeRun)
if AUTO_UPDATE then M.updater = hs.timer.doEvery(UPDATE_EVERY, function() selfUpdate("定期確認") end) end
M.waker = hs.caffeinate.watcher.new(function(ev)
  local w = hs.caffeinate.watcher
  if ev == w.systemDidWake or ev == w.screensDidUnlock
     or ev == w.sessionDidBecomeActive then
    -- 復帰直後は落ち着くまで少し待つ（タイマーは M に持たせる。持たないと
    -- ガベージコレクションで消えて発火しないことがある）
    M.wakeTimer = hs.timer.doAfter(120, maybeRun)
  end
end)
M.waker:start()

bindBoth("L", function() runExport(false) end)               -- 手動実行
bindBoth("K", function() M.diag() end)                        -- 画面の読み取り診断

bindBoth("J", function() M.names() end)                       -- トーク名を一括取得

-- テスト用（mac/tests/test_line_export.lua から中身を検証する）
M._t = {
  norm = norm, score = score, loose = loose, isSaveLabel = isSaveLabel, countless = countless,
  sameText = sameText,
  nameMatches = nameMatches, masked = masked, maskedSave = maskedSave,
  pngSize = pngSize, ocr = ocr, capture = capture, stampedName = stampedName,
  exportOne = exportOne, runExport = runExport, prepareApp = prepareApp,
  beginRun = beginRun, endRun = endRun, maybeRun = maybeRun, describe = describe, tidy = tidy,
  statusLines = statusLines, readResult = readResult, selfUpdate = selfUpdate,
  L = L, targets = TARGETS, OUT_DIR = OUT_DIR, REPO = REPO, DEBUG_DIR = DEBUG_DIR,
  VERSION = VERSION,
}

-- 読み込んだ版を残す。新しい版を初めて読み込んだ時は、何も押さない診断を
-- 1回だけ自動で撮っておく（直した版で画面がどう読めるかを、こちらで見るため）。
local prevLoaded = (readAll(LOADED_PATH) or ""):gsub("%s", "")
if prevLoaded ~= VERSION then
  local f = io.open(LOADED_PATH, "w")
  if f then f:write(VERSION .. "\n"); f:close() end
  M.diagTimer = hs.timer.doAfter(30, function()
    if not RUN and _G.__LINE_EXPORT == M and not screenLocked() and not watchedScreen() then
      pcall(M.diag, true)
    end
  end)
end

if not screenRecordingOK() then
  log("warn: Hammerspoon に「画面収録」が許可されていない。画面を読むので必須" ..
      "（システム設定 → プライバシーとセキュリティ → 画面とシステムオーディオ録音）")
end
log(string.format("読込完了 %s / 対象%d件 / %s以降 離席中に自動実行 / 使い方: __LINE_EXPORT.help()",
  VERSION, #TARGETS, RUN_AT))
return M
