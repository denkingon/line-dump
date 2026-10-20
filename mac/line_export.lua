-- =====================================================================
-- LINE 自動エクスポート v4 → line-dump リポジトリへ push（Hammerspoon）
--
--   毎日 RUN_AT 以降の離席中に、TARGETS のトークを Mac 版 LINE から
--   書き出し、mac/sync.sh を呼んでリポジトリに取り込み・push する。
--
--   v4 は固定座標をやめ、画面を撮って OCR で文字を読み、見つけた所を押す。
--   各段で画面を読み直して確かめてから次へ進み、違えばその段で止める。
--     1. 窓      LINE のメイン窓を前面に。窓が無ければ open -b（Escape は使わない）
--     2. トーク  検索欄に名前 → 左ペインを OCR → 一致する行を押す
--                → ヘッダを OCR してトーク名を確認
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
--   手動実行: ⌘⌥⌃L / OCR 診断: ⌘⌥⌃K / トーク名一覧: ⌘⌥⌃J（⇧ 版でも可）
--   1件だけ試す: コンソールで __LINE_EXPORT.one("トーク名")
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
-- 検索欄に入れて絞り込み、画面に出た名前と照合してから開く。照合は
-- 絵文字・空白・グループのメンバー数を無視する。完全に一致する行があれば
-- それを開き、ヘッダと保存名も完全一致を求める。完全一致が無い時だけ
-- 部分一致を使うが、候補が2つ以上あれば決めずに止める（別トークを
-- 書き出さないため）。名前は LINE の表示どおりに書くのが確実（⌘⌥⇧J で一覧）。
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

-- ▼ 画面の読み方（論理座標 pt）。左ペインとトーク欄の境目は毎回
--   検索欄の位置から割り出すので、窓の大きさが変わっても測り直しは要らない。
local L = {
  MENU_FROM_RIGHT = 24,   -- ⋮ は窓右端から 24pt 左・ヘッダのトーク名と同じ高さ
  -- ⋮ でメニューが出なかった時の再試行（1回だけ）。左へ大きくずらすと
  -- 隣の通話ボタンに当たりうるので、ずらし幅は小さくしておく。
  MENU_RETRY_DX   = -6,
  MENU_RETRY_DY   = 6,
  HEADER_H        = 130,  -- 窓の上端からこの高さまでをヘッダとみなす
  MENU_W          = 360,  -- ⋮ から左へこの幅・下へ MENU_H をメニューの範囲とみなす
  MENU_H          = 520,
}
-- ▲

-- ===================== 実装 ==========================================
local LINE_BUNDLE = "jp.naver.line.mac"
local OCR_SCRIPT  = REPO .. "/mac/ocr.applescript"
-- 失敗時の撮影画像はリポジトリの外に置く（トーク画面が写るので push しない）
local DEBUG_DIR   = HOME .. "/Library/Logs/line-dump/debug"
local DEBUG_SHOW  = "~/Library/Logs/line-dump/debug"   -- heartbeat に書く形（ユーザー名を出さない）
local DEBUG_KEEP_DAYS = 7
local RUN_LIMIT_MIN   = 20    -- 1回の実行の上限（固まっても Hammerspoon を返す）
local TMP = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")   -- 撮影の一時置き場
local SAVE_LABELS = { "トークを保存", "Save chat" }   -- ⋮ メニューの項目名
-- ⋮ メニューの他の項目。これが新しく見えたら「メニューは開いた」とみなす
local MENU_HINTS  = { "通知オフ", "通知オン", "トーク履歴を削除", "退会", "ブロック",
                      "非表示", "Notifications off", "Notifications on",
                      "Delete chat history", "Leave", "Block", "Hide" }

local function log(s) print(os.date("%H:%M:%S ") .. "[line-dump] " .. s) end
local function now() return hs.timer.secondsSinceEpoch() end
local function wait(sec) hs.timer.usleep(math.floor(sec * 1000000)) end
local function sh(s)                              -- シェル用の引用
  local q = tostring(s):gsub("'", "'\\''")
  return "'" .. q .. "'"
end
-- 時間で区切って待つ（AX が固まって1回の確認が長引いても上限を守る）
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
local RUN = nil   -- 実行中だけ { deadline, lastSynth, mouse, pid }

local function stop(reason) error({ abort = reason }, 0) end
local function blocked(reason) error({ blocked = reason }, 0) end

local function guard()
  if not RUN then return end
  local t = now()
  if t > RUN.deadline then stop("時間切れ（" .. RUN_LIMIT_MIN .. "分）") end
  if hs.host.idleTime() + 0.25 < t - RUN.lastSynth then stop("人の操作を検知") end
  if RUN.mouse then
    local p = hs.mouse.absolutePosition()
    if math.abs(p.x - RUN.mouse.x) > 3 or math.abs(p.y - RUN.mouse.y) > 3 then
      stop("マウスが動いた")
    end
  end
end
local function synthesized()
  if not RUN then return end
  RUN.lastSynth = now()
  RUN.mouse = hs.mouse.absolutePosition()
end

-- LINE が前面か。クリック・キー入力の前に必ず確かめる（他のアプリを操作しない）
local function lineFront()
  local a = hs.application.frontmostApplication()
  return a ~= nil and a:bundleID() == LINE_BUNDLE
end

-- その位置の一番上にあるのが LINE か（通知バナーや他の窓が重なっていないか）
local function hitsLine(x, y)
  if not (RUN and RUN.pid) then return true end
  local ok, el = pcall(hs.axuielement.systemElementAtPosition, x, y)
  if not ok or not el then return true end      -- 判定できない時は前面確認に任せる
  local ok2, pid = pcall(function() return el:pid() end)
  return not ok2 or pid == nil or pid == RUN.pid
end

local function clickAt(x, y)
  guard()
  if not lineFront() then blocked("LINE が前面に無い") end
  if not hitsLine(x, y) then blocked("押す所に LINE 以外の物が重なっている") end
  hs.eventtap.leftClick(hs.geometry.point(x, y))
  synthesized(); wait(0.3)
end
local function key(mods, k)
  guard()
  if not lineFront() then blocked("LINE が前面に無い") end
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

-- 照合の強さ: 3=完全一致 2=前方一致 1=部分一致 0=不一致。
-- グループのメンバー数「（82）」は無視し、「…」で切れた名前は前半で照合する。
local function score(tn, s)
  if tn == "" or s == "" then return 0 end
  local core = s:gsub("%(%d+%)$", "")
  if core == tn then return 3 end
  if core:sub(1, #tn) == tn then return 2 end
  if s:find(tn, 1, true) then return 1 end
  local cut = core:match("^(.-)%.%.%.$") or core:match("^(.-)…$")
  if cut and (utf8.len(cut) or 0) >= 3 and tn:sub(1, #cut) == cut then return 1 end
  return 0
end

-- 保存名とトーク名の照合用。ファイル名では / が _ や : に化けるので記号も落とす。
local function loose(s) return (norm(s):gsub("%p", "")) end

local function isLabel(n, labels)
  for _, lab in ipairs(labels) do
    local ln = norm(lab)
    if n == ln then return true end
    if n:sub(1, #ln) == ln and (utf8.len(n) or 99) - utf8.len(ln) <= 2 then return true end
  end
  return false
end
local function isSaveLabel(n) return isLabel(n, SAVE_LABELS) end

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

local function keepDebug(name, stage, cap, win)
  if not cap then cap = capture(win, "fail", screenOf(win)) end
  if not cap then return nil end
  hs.fs.mkdir(HOME .. "/Library/Logs/line-dump"); hs.fs.mkdir(DEBUG_DIR)
  local file = os.date("%Y%m%d-%H%M%S") .. "_" .. safeName(name) .. "_" .. safeName(stage) .. ".png"
  local src, dst = io.open(cap.path, "rb"), io.open(DEBUG_DIR .. "/" .. file, "wb")
  if not (src and dst) then
    if src then src:close() end
    if dst then dst:close() end
    return nil
  end
  dst:write(src:read("a")); src:close(); dst:close()
  return DEBUG_SHOW .. "/" .. file
end

local function pruneDebug()
  if hs.fs.attributes(DEBUG_DIR, "mode") ~= "directory" then return end
  local limit = os.time() - DEBUG_KEEP_DAYS * 86400
  for f in hs.fs.dir(DEBUG_DIR) do
    local p = DEBUG_DIR .. "/" .. f
    if f:match("%.png$") and (hs.fs.attributes(p, "modification") or limit) < limit then
      os.remove(p)
    end
  end
end

-- 段の失敗を返す。その時点の画面を DEBUG_DIR に残す。
-- msg は heartbeat（公開リポジトリ）に載る決まった文言だけにし、OCR で
-- 読んだ文字や他のトーク名など画面由来のものは detail（このMacのログだけ）に分ける。
local function fail(ctx, stage, msg, cap, detail)
  return nil, { stage = stage, msg = msg, detail = detail,
                img = keepDebug(ctx.name, stage, cap, ctx.win) }
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
local function findMain(app)
  local best, bestArea
  for _, w in ipairs(app:allWindows() or {}) do
    if w:isMinimized() then w:unminimize(); wait(0.5) end
    if w:isVisible() and searchField(w) then
      local f = w:frame()
      if not best or f.w * f.h > bestArea then best, bestArea = w, f.w * f.h end
    end
  end
  return best
end

-- 保存シート（窓の子の AXSheet か、ダイアログ窓）
local function findSheet(app)
  local axapp = hs.axuielement.applicationElement(app)
  for _, w in ipairs(attr(axapp, "AXWindows") or {}) do
    local sr = attr(w, "AXSubrole")
    if role(w) == "AXSheet" or sr == "AXDialog" or sr == "AXSystemDialog" then return w end
    for _, c in ipairs(attr(w, "AXChildren") or {}) do
      if role(c) == "AXSheet" then return c end
    end
  end
  return nil
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
    local win = findMain(app)
    if win then
      local sf, f = screenOf(win), win:frame()
      if math.abs(f.w - sf.w) > 40 or math.abs(f.h - sf.h) > 40 then
        win:setFrame(sf, 0); wait(0.6)            -- 広い方が名前が切れずに読める
      end
      -- メイン窓を最前面・キー窓にする（別窓で開いたトークにキー入力が行かないように）
      win:focus(); wait(0.4)
      local fw = app:focusedWindow()
      if lineFront() and (fw == nil or fw:id() == win:id()) then return win end
    end
    -- 窓が無い・見えない・検索欄が読めない・前面に来ない → Dock クリック相当で開き直す。
    -- hs.application.open / activate では窓が戻らない（実測）。Escape は使わない
    -- （LINE は Escape で窓やトークを閉じる。10/14 の連鎖失敗の元凶）。
    hs.execute("/usr/bin/open -b " .. LINE_BUNDLE); wait(2)
  end
  return nil
end

-- ---------- 2. トークを開いて確かめる ----------
local function rowsByAX(win, paneX, below)
  local rows = {}
  for _, cell in ipairs(bfsAll(hs.axuielement.windowElement(win),
                               function(e) return role(e) == "AXCell" end, 4000)) do
    local r = axFrame(cell)
    local t = bfs(cell, function(e)
      return role(e) == "AXStaticText" and tostring(attr(e, "AXValue") or "") ~= ""
    end, 40)
    if r and t and r.x + r.w / 2 < paneX and r.y > below then
      rows[#rows + 1] = { el = cell, n = norm(attr(t, "AXValue")), x = r.x + r.w / 2, y = r.y + r.h / 2 }
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

-- 名前の行を選ぶ。完全一致の行があればそれ（OCR の位置、無ければ AX のセル）。
-- 無ければ部分一致だが、候補の名前が2つ以上なら決めずに止める
-- （例: 「かにっこにー」の行を OCR が少し読み違え、「かにっこにー3」と並んだ時）。
-- AX のセルの名前は OCR の読み違いが無いので、あればそちらで候補を数える。
local function pickRow(ctx, win, items, ff, paneX)
  local function inList(it) return it.y > ff.y + ff.h + 2 and it.x > ff.x - 80 and it.x < paneX end
  local ocrC, top = {}, 0
  for _, it in ipairs(items) do
    if inList(it) then
      local sc = score(ctx.tn, it.n)
      if sc > 0 then ocrC[#ocrC + 1] = { x = it.x, y = it.y, n = it.n, sc = sc }; top = math.max(top, sc) end
    end
  end
  local axC = {}
  if top < 3 then
    for _, r in ipairs(rowsByAX(win, paneX, ff.y + ff.h)) do
      local sc = score(ctx.tn, r.n)
      if sc > 0 then r.sc = sc; axC[#axC + 1] = r; top = math.max(top, sc) end
    end
  end
  if top == 0 then return nil end
  local function topmost(list)
    local b
    for _, c in ipairs(list) do if c.sc == top and (not b or c.y < b.y) then b = c end end
    return b
  end
  if top < 3 then
    local names, count = {}, 0
    for _, c in ipairs(#axC > 0 and axC or ocrC) do
      if c.sc == top and not names[c.n] then names[c.n] = true; count = count + 1 end
    end
    if count > 1 then return nil, top, count end
  end
  return topmost(ocrC) or topmost(axC), top
end

-- ヘッダ（トーク欄の上端）の名前。帯の中の一番上の行だけを見る（窓の
-- タイトル「LINE」の行やアイコンだけの行は飛ばす）。その下のメッセージに
-- 同じ名前があっても拾わない。
local function headerMatch(items, tn, paneX, f, winTitle)
  local band = {}
  for _, it in ipairs(items) do
    if it.x > paneX and it.y >= f.y and it.y < f.y + L.HEADER_H then band[#band + 1] = it end
  end
  table.sort(band, function(a, b) return a.y < b.y end)
  local skip = { line = true, [norm(winTitle or "")] = true }
  local function titleLike(it) return skip[it.n] or (utf8.len(it.n) or 0) <= 1 end
  -- y が 8pt 以内のものを1行にまとめ、タイトル行でない最初の行を探す
  local rowsList, cur = {}, nil
  for _, it in ipairs(band) do
    if not cur or it.y - cur.y > 8 then cur = { y = it.y }; rowsList[#rowsList + 1] = cur end
    cur[#cur + 1] = it
  end
  for _, row in ipairs(rowsList) do
    local allTitle = true
    for _, it in ipairs(row) do if not titleLike(it) then allTitle = false end end
    if not allTitle then
      local bestIt, bestSc = nil, 0
      for _, it in ipairs(row) do
        local sc = score(tn, it.n)
        if sc > bestSc then bestIt, bestSc = it, sc end
      end
      return bestIt, bestSc, row[1]
    end
  end
  return nil, 0, band[1]
end

local function openChat(ctx, win)
  local field, ff = searchField(win)
  if not ff then return fail(ctx, "検索欄", "検索欄が見つからない") end
  local f = win:frame()
  local paneX = ff.x + ff.w + 10               -- これより右がトーク欄

  -- 検索欄にフォーカスを入れる。入ったと確かめられない時はキーを送らない
  -- （前のトークのメッセージ入力欄に名前を貼ってしまわないように）
  guard()
  pcall(function() field:setAttributeValue("AXFocused", true) end); wait(0.2)
  if fieldFocused(field, ff) ~= true then
    clickAt(ff.x + ff.w / 2, ff.y + ff.h / 2); wait(0.3)   -- 位置は AX の枠から
  end
  if fieldFocused(field, ff) == false then
    return fail(ctx, "検索欄", "検索欄にフォーカスが入らない（キー入力はしていない）")
  end
  key({"cmd"}, "a"); wait(0.1)
  pasteText(ctx.name, function() return norm(attr(field, "AXValue") or "") == ctx.tn end)
  wait(1.0)
  local v = attr(field, "AXValue")
  if v ~= nil and norm(v) ~= ctx.tn then
    -- 貼り付けが入らない時は AX で値だけ入れる（キーは打ち直さない）
    pcall(function() field:setAttributeValue("AXValue", ctx.name) end); wait(1.0)
  end

  -- 左ペイン（検索欄より下・トーク欄より左）を読んで、名前の行を探す。
  -- 検索結果の表示が遅れることがあるので、見つからなければ1回だけ読み直す。
  local cap, items, oerr, row, top, many
  for i = 1, 2 do
    cap = capture(win, "list")
    items, oerr = ocr(cap)
    if not items then return fail(ctx, "OCR", "OCR が動かない", cap, oerr) end
    row, top, many = pickRow(ctx, win, items, ff, paneX)
    if row or many or i == 2 then break end        -- 候補が複数なら待っても変わらない
    wait(1.0)
  end
  if not row then
    if many then
      return fail(ctx, "トーク選択", "名前に合う候補が " .. many .. " 件あり決められない" ..
        "（TARGETS の名前を LINE の表示どおりに）", cap)
    end
    return fail(ctx, "トーク選択", "検索結果に名前が見えない", cap)
  end
  local exact = top == 3
  if row.el then
    if not press(row.el) then clickAt(row.x, row.y) end
  else
    clickAt(row.x, row.y)
  end
  wait(1.2)

  -- ヘッダを読んで、開いたのが目的のトークか確かめる。押した行と同じ強さで
  -- 合うこと（完全一致の行を押したなら完全一致）。開くのに時間がかかることが
  -- あるので、合わなければ1回だけ読み直す。
  local hdr, hdrScore, first
  for i = 1, 2 do
    cap = capture(win, "header")
    items, oerr = ocr(cap)
    if not items then return fail(ctx, "OCR", "OCR が動かない", cap, oerr) end
    hdr, hdrScore, first = headerMatch(items, ctx.tn, paneX, f, win:title())
    if hdr and hdrScore >= top then break end
    hdr = nil
    if i == 1 then wait(1.0) end
  end
  if not hdr then
    return fail(ctx, "トーク確認", "開いたトークが違う", cap,
      "ヘッダ: 「" .. (first and first.text or "読めず") .. "」")
  end
  return { header = hdr, paneX = paneX, exact = exact }
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
    if hit then clickAt(hit.x, hit.y); return true end
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
  return fail(ctx, "メニュー", "⋮ を押してもメニューが出ない（⋮ の位置: L.MENU_FROM_RIGHT）", lastCap)
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

-- 保存名の本体（[LINE] と .txt と英語表示の Chat with を除いたもの）がトーク名と合うか。
-- 完全一致の行から開いた時は、保存名も完全一致を求める。
local function nameMatches(cur, name, exact)
  if not cur:match("^%[LINE%]") then return false end
  local b = loose((cur:gsub("%.txt$", ""):gsub("^%[LINE%]", "")))
  b = b:gsub("^chatwith", "")
  local n = loose(name)
  if b == "" or n == "" then return false end
  if exact then return b == n end
  return b:find(n, 1, true) ~= nil or n:find(b, 1, true) ~= nil
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
    return failSheet(ctx, app, "保存ダイアログ", "トークの保存ダイアログに見えない", "名前欄: " .. cur)
  end
  -- 既定名は「[LINE]<トーク名>.txt」。ここでも別トークでないか確かめる
  if not nameMatches(cur, ctx.name, st.exact) then
    return failSheet(ctx, app, "保存ダイアログ", "保存名がトーク名と合わない", "保存名: " .. cur)
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
  if not src then return fail(ctx, "移動", "保存したファイルが見つからない", nil, savedAs) end
  -- OUT_DIR では / と : を _ にそろえる（ingest.py の safe_filename と同じ扱い）
  local dst = OUT_DIR .. "/" .. stampedName(savedAs):gsub("[/:]", "_")
  if src ~= dst and not os.rename(src, dst) then
    hs.execute("/bin/mv -f " .. sh(src) .. " " .. sh(dst))
  end

  -- ---------- 5. 確認 ----------
  if (hs.fs.attributes(dst, "size") or 0) == 0 then
    return fail(ctx, "移動", "Linetxt に移せない（ダウンロード等へのアクセス許可を確認: " ..
      "docs/setup-mac-auto.md 手順3）", nil, src)
  end
  return dst
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
  local st, e = openChat(ctx, win)
  if not st then return false, e end
  local ok; ok, e = pressSaveChat(ctx, win, st)
  if not ok then return false, e end
  local dst; dst, e = saveAndMove(ctx, app, st)
  if not dst then return false, e end
  return true, dst
end

-- 1件を書き出す。人の操作を検知したら error({abort=…}) で全体を止める。
local function exportOne(app, name)
  local ctx = { name = name, tn = norm(name) }
  local ok, r1, r2 = pcall(exportSteps, app, ctx)
  if ok then return r1, r2 end
  if type(r1) == "table" and r1.blocked then
    -- 押す所に別の物が重なっていた・LINE が前面に無い → この件だけ止める
    return false, select(2, fail(ctx, "クリック", r1.blocked))
  end
  error(r1, 0)
end

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

-- heartbeat（公開）用は決まった文言と画像パスだけ。detail はこのMacのログだけ。
local function describe(e, withDetail)
  if type(e) ~= "table" then return tostring(e) end
  return "[" .. e.stage .. "] " .. e.msg ..
    (withDetail and e.detail and ("（" .. e.detail .. "）") or "") ..
    (e.img and ("（画像: " .. e.img .. "）") or "")
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
    hs.execute("/usr/bin/open -b " .. LINE_BUNDLE); wait(5)
    app = hs.application.find(LINE_BUNDLE)
  end
  if not app then return nil, "LINE を起動できない" end
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

local function targetName(t) return type(t) == "table" and t[1] or t end

-- 実行の始まりと終わり。手動実行のホットキーを離すのを待ってから見張りを始める。
-- AX の応答待ちは短くする（LINE が固まっても1回あたり数秒で返す）。
local function beginRun(app)
  wait(1.0)
  RUN = { deadline = now() + RUN_LIMIT_MIN * 60, lastSynth = now(),
          mouse = hs.mouse.absolutePosition(), pid = app:pid() }
  pcall(function() hs.axuielement.systemWideElement():setTimeout(2) end)
end
local function endRun()
  RUN = nil
  pcall(function() hs.axuielement.systemWideElement():setTimeout(0) end)
end

-- 書き出した txt を取り込んで push する。第2引数の true は「ログインシェルの
-- 環境を使う」指定。これが無いと PATH が最小限になり、git や python が
-- 見つからないことがある。
local function runSync()
  local out = hs.execute('/bin/bash "' .. REPO .. '/mac/sync.sh" 2>&1', true)
  log("sync:\n" .. (out or ""))
  return (out or ""):match("push 完了") and "push済" or "push無し"
end

local function writeHeartbeat(okN, ngN, ngLines, note)
  local hb = io.open(REPO .. "/mac/heartbeat.txt", "w")
  if not hb then return end
  hb:write(string.format("last_run: %s\nversion: v4 (OCR)\nok: %d\nng: %d\n",
    os.date("%Y-%m-%d %H:%M:%S"), okN, ngN))
  if note then hb:write("note: " .. note .. "\n") end
  if #ngLines > 0 then
    hb:write("failures:\n")
    for _, line in ipairs(ngLines) do hb:write("  - " .. line .. "\n") end
  end
  hb:close()
end

-- 1件だけ試す。Hammerspoon コンソールから:
--   __LINE_EXPORT.one("Berry")
function M.one(name)
  local app, err = prepareApp(true)
  if not app then log(err); hs.alert.show(err, 4); return false end
  beginRun(app)
  local okc, ok, e = pcall(exportOne, app, name)
  endRun()
  if not okc then
    if type(ok) == "table" and ok.abort then
      log("中断: " .. ok.abort); hs.alert.show("LINE書き出しを中断: " .. ok.abort, 4); return false
    end
    ok, e = false, { stage = "内部エラー", msg = tidy(ok) }
  end
  if not ok then
    log("NG  " .. name .. "  " .. describe(e, true))
    hs.alert.show("NG: " .. name .. "\n" .. describe(e, true), 6)
    return false
  end
  log("OK  " .. name .. " → " .. e)
  local pushed = runSync()
  hs.alert.show("書き出しOK: " .. name .. " / " .. pushed, 4)
  return true
end

-- 全件を書き出す。auto=true は無人の自動実行。戻り値 "aborted" は人の操作で止めた時。
local function runExport(auto)
  if #TARGETS == 0 then
    hs.alert.show("TARGETS が空です。line_export.lua を編集してください", 4)
    log("TARGETS が空"); return
  end

  local app, err = prepareApp(not auto)
  if not app then
    -- 原因をリポジトリに残す（このMacのログを毎回見に行かなくて済むように）
    log(err); hs.alert.show("LINE書き出し中止: " .. err, 6)
    writeHeartbeat(0, #TARGETS, { "全件: " .. err })
    runSync()
    return
  end

  beginRun(app)
  local okN, ngN, ngLines, stopped = 0, 0, {}, nil
  for i, t in ipairs(TARGETS) do
    local name = targetName(t)
    -- 1件の想定外エラーで残りを止めず、heartbeat も必ず書く
    local okc, ok, e = pcall(exportOne, app, name)
    if not okc then
      if type(ok) == "table" and ok.abort then
        stopped = ok.abort .. "（" .. i .. "/" .. #TARGETS .. " 件目で中断）"
        break
      end
      ok, e = false, { stage = "内部エラー", msg = tidy(ok) }
    end
    if ok then
      okN = okN + 1; log("OK  " .. name .. " → " .. e)
    else
      ngN = ngN + 1; log("NG  " .. name .. "  " .. describe(e, true))
      ngLines[#ngLines + 1] = name .. ": " .. describe(e)
    end
    wait(0.8)
  end
  endRun()
  if stopped then log("中断: " .. stopped) end

  -- 結果をリポジトリに残す。ログはこのMacにしか無く、失敗の理由を
  -- 毎回コンソールから貼ってもらうのは現実的でないため、push して共有する。
  -- （撮影画像は DEBUG_DIR に残すだけで push しない）
  writeHeartbeat(okN, ngN, ngLines, stopped and ("中断: " .. stopped))

  local pushed = runSync()
  hs.alert.show(string.format("LINE書き出し OK:%d NG:%d%s / %s", okN, ngN,
    stopped and (" 中断") or "", pushed), 4)
  return stopped and "aborted" or "done"
end

-- OCR 診断: 今の LINE の窓を撮って、読めた文字と位置をコンソールに出す。
-- 画面収録の許可や、OCR が名前・メニューを読めているかの確認用。
function M.diag()
  local app = hs.application.find(LINE_BUNDLE)
  local win = app and (findMain(app) or app:focusedWindow() or app:mainWindow())
  if not win then hs.alert.show("LINEの窓が見つからない", 3); return end
  app:activate(true); wait(0.5)
  local cap = capture(win, "diag", screenOf(win))
  local items, oerr = ocr(cap)
  if not items then print("OCR 診断: " .. oerr); hs.alert.show(oerr, 5); return end
  local f = win:frame()
  print(string.format("=== OCR 診断 %d件（画面収録: %s / 窓 x=%.0f y=%.0f w=%.0f h=%.0f）===",
    #items, screenRecordingOK() and "許可" or "未許可", f.x, f.y, f.w, f.h))
  for _, it in ipairs(items) do print(string.format("  %5.0f,%5.0f  %s", it.x, it.y, it.text)) end
  local img = keepDebug("diag", "ocr", cap, win)
  hs.alert.show(string.format("OCR %d件をコンソールに出力\n%s", #items, img or "画像を保存できず"), 4)
end

-- 二重読み込み対策。init.lua に dofile 行が複数入っていたり、Reload を
-- 繰り返したりしても、タイマーとホットキーが多重にならないようにする。
-- （多重になると 07:00 に自動操作が同時に2本走り、LINE の画面を奪い合う）
if _G.__LINE_EXPORT then
  local prev = _G.__LINE_EXPORT
  if prev.timer then prev.timer:stop() end
  if prev.waker then prev.waker:stop() end
  for _, hk in ipairs(prev.hotkeys or {}) do hk:delete() end
  log("前回の読み込み分を解除して張り直します")
end
M.hotkeys = {}

-- Ctrl版・Shift版の両方に割り当てる。以前ここは ⌘⌥⌃ を使う別スクリプトと
-- 競合していたため一度 Shift に逃がしたが、そちらを無効化した後も
-- 手が Ctrl を覚えているはずなので、どちらを押しても動くようにしておく。
local function bindBoth(k, fn)
  for _, mods in ipairs({{"cmd","alt","ctrl"}, {"cmd","alt","shift"}}) do
    M.hotkeys[#M.hotkeys + 1] = hs.hotkey.bind(mods, k, fn)
  end
end

-- 毎日1回を「取りこぼさない」ための追いかけ実行。
--
-- 固定時刻の hs.timer.doAt は Mac がスリープしていると発火せず、起きた後も
-- 追いかけない。実測でも 27日間で 07:00 に走ったのは1度だけだった。
-- そこで一定間隔で「今日はもう走ったか」を確認し、条件が整った最初の
-- タイミングで実行する。スリープから復帰した直後も確認する。
local STATE_PATH = REPO .. "/mac/.last_run"   -- 最後に走った日 (YYYYMMDD[:中断回数])
local CHECK_EVERY   = 600   -- 10分ごとに条件を確認
local IDLE_REQUIRED = 180   -- 3分以上操作が無ければ「離席中」とみなす
local MAX_ABORTS    = 3     -- 人の操作で中断した日は、離席を待ってこの回数までやり直す

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

local function screenLocked()
  local props = hs.caffeinate.sessionProperties()
  return props and props.CGSSessionScreenIsLocked or false
end

-- 画面を見ている人がいそうか（ビデオ会議・画面共有・動画）。3分触っていなくても
-- この間に LINE のトークを次々開くと、共有画面などに映ってしまう。
-- 常に起こしておくだけの道具（Amphetamine 等）の保持は数えない。
local KEEP_AWAKE = { Hammerspoon = true, Amphetamine = true, caffeinate = true,
                     KeepingYouAwake = true, Theine = true, Lungo = true }
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

local skipLogged = {}
local function maybeRun()
  local day = today()
  local stateDay, aborts = readState()
  if stateDay == day and (aborts == nil or aborts >= MAX_ABORTS) then return end

  local hh, mm = RUN_AT:match("^(%d+):(%d+)$")
  local t = os.date("*t")
  if t.hour * 60 + t.min < tonumber(hh) * 60 + tonumber(mm) then return end

  -- ロック中・スクリーンセーバ中はクリックが通らない
  if screenLocked() then return end
  -- 操作中に割り込むと、クリックを奪い合って失敗する上に邪魔になる
  if hs.host.idleTime() < IDLE_REQUIRED then return end
  local busy = watchedScreen()
  if busy then
    if not skipLogged[day .. busy] then skipLogged[day .. busy] = true; log("見送り: " .. busy) end
    return
  end

  -- 実行中の再入と、失敗時の一日中のリトライを防ぐため先に記録する
  writeState(day)
  log("自動実行を開始（" .. os.date("%H:%M") .. "）")
  if runExport(true) == "aborted" then
    -- 人が戻ってきて止めた日は、また離席したらやり直す（上限あり）
    writeState(day .. ":" .. ((stateDay == day and aborts or 0) + 1))
  end
end

M.timer = hs.timer.doEvery(CHECK_EVERY, maybeRun)
M.waker = hs.caffeinate.watcher.new(function(ev)
  local w = hs.caffeinate.watcher
  if ev == w.systemDidWake or ev == w.screensDidUnlock
     or ev == w.sessionDidBecomeActive then
    hs.timer.doAfter(120, maybeRun)   -- 復帰直後は落ち着くまで少し待つ
  end
end)
M.waker:start()

bindBoth("L", function() runExport(false) end)               -- 手動実行
bindBoth("K", function() M.diag() end)                        -- OCR 診断

bindBoth("J", function()                                      -- トーク名を一括取得
  local app = hs.application.find(LINE_BUNDLE)
  if not app then hs.alert.show("LINEが見つからない", 3); return end
  app:activate(true); hs.timer.usleep(400000)
  local win = findMain(app) or app:focusedWindow() or app:mainWindow()
  if not win then hs.alert.show("LINEウィンドウ無し", 3); return end

  -- トークリストの行は AX で取れる（⋮ と違ってツリーに乗っている）。
  -- ただし表示中の行しか取れないので、全部欲しければリストをスクロールしてから押す。
  local names, seen = {}, {}
  for _, cell in ipairs(bfsAll(hs.axuielement.windowElement(win),
                               function(e) return role(e) == "AXCell" end, 6000)) do
    local t = bfs(cell, function(e)
      return role(e) == "AXStaticText" and tostring(attr(e, "AXValue") or "") ~= ""
    end, 40)
    if t then
      local v = tostring(attr(t, "AXValue"))
      if not seen[v] then seen[v] = true; names[#names + 1] = v end
    end
  end

  print("=== LINE トーク一覧 " .. #names .. "件（TARGETS にそのまま貼れる形式）===")
  for _, n in ipairs(names) do
    print(string.format('  "%s",', n))
  end
  print("=== ここまで。表示中の行のみ。足りなければリストをスクロールして再度 ⌘⌥⇧J ===")
  hs.alert.show(string.format("%d件をコンソールに出力", #names), 3)
end)

-- テスト用（mac/tests/test_line_export.lua から中身を検証する）
M._t = {
  norm = norm, score = score, loose = loose, isSaveLabel = isSaveLabel,
  nameMatches = nameMatches,
  pngSize = pngSize, ocr = ocr, capture = capture, stampedName = stampedName,
  exportOne = exportOne, runExport = runExport, prepareApp = prepareApp,
  beginRun = beginRun, endRun = endRun, maybeRun = maybeRun, describe = describe, tidy = tidy,
  L = L, targets = TARGETS, OUT_DIR = OUT_DIR, REPO = REPO, DEBUG_DIR = DEBUG_DIR,
}

_G.__LINE_EXPORT = M

if not screenRecordingOK() then
  log("warn: Hammerspoon に「画面収録」が許可されていない。v4 は画面を読むので必須" ..
      "（システム設定 → プライバシーとセキュリティ → 画面とシステムオーディオ録音）")
end
log(string.format(
  "読込完了 v4 / 対象%d件 / %s以降 離席中に自動実行 / 手動 ⌘⌥⌃L(⇧も可) / OCR診断 ⌘⌥⌃K / 一覧 ⌘⌥⌃J / 止める: マウスを動かす",
  #TARGETS, RUN_AT))
return M
