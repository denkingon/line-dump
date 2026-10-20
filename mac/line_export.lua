-- =====================================================================
-- LINE 自動エクスポート v4 → line-dump リポジトリへ push（Hammerspoon）
--
--   毎日 RUN_AT 以降の離席中に、TARGETS のトークを Mac 版 LINE から
--   書き出し、mac/sync.sh を呼んでリポジトリに取り込み・push する。
--
--   v4 は固定座標をやめ、画面を撮って OCR で文字を読み、見つけた所を押す。
--   各段で画面を読み直して確かめてから次へ進み、違えばその段で止める。
--     1. 窓      LINE を前面に。窓が無ければ open -b（Escape は使わない）
--     2. トーク  検索欄に名前 → 左ペインを OCR → 一致する行を押す
--                → ヘッダを OCR してトーク名を確認
--     3. メニュー ⋮（窓右端−24, ヘッダのトーク名と同じ高さ）を押す
--                → OCR で「トークを保存」を探して押す（型指定・較正は不要）
--     4. 保存    保存シートを AX で待つ → →キー＋「_YYYYMMDD」→ 保存 →（置き換え）
--                保存先は既定のまま。保存後に OUT_DIR へ移す
--     5. 確認    OUT_DIR に今日付きのファイルがあれば OK
--   失敗したら撮影画像を mac/debug/ に残し、heartbeat に段と画像パスを書く。
--
--   OCR は mac/ocr.applescript（macOS 標準の Vision）。Hammerspoon に
--   「画面収録」の許可が要る（docs/setup-mac-auto.md）。
--
--   手動実行: ⌘⌥⌃L / OCR 診断: ⌘⌥⌃K / トーク名一覧: ⌘⌥⌃J（⇧ 版でも可）
--   1件だけ試す: コンソールで __LINE_EXPORT.one("トーク名")
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
-- 絵文字・空白を無視した部分一致（完全一致の行があればそちらを優先）なので、
-- 名前は一意に絞れる範囲で短くてよい（絵文字はその手前まででよい）。
--
-- 一覧を作り直したいときは ⌘⌥⇧J（この形式でコンソールに出力される）。
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
}
-- ▲

-- ===================== 実装 ==========================================
local LINE_BUNDLE = "jp.naver.line.mac"
local OCR_SCRIPT  = REPO .. "/mac/ocr.applescript"
local DEBUG_DIR   = REPO .. "/mac/debug"
local DEBUG_KEEP_DAYS = 7
local TMP = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")   -- 撮影の一時置き場
local SAVE_LABELS = { "トークを保存", "Save chat" }   -- ⋮ メニューの項目名

local function log(s) print(os.date("%H:%M:%S ") .. "[line-dump] " .. s) end
local function wait(sec) hs.timer.usleep(math.floor(sec * 1000000)) end
local function sh(s)                              -- シェル用の引用
  local q = tostring(s):gsub("'", "'\\''")
  return "'" .. q .. "'"
end
local function clickAt(x, y)
  hs.eventtap.leftClick(hs.geometry.point(x, y)); wait(0.3)
end
local function waitFor(fn, timeout, step)
  step = step or 0.25
  for _ = 0, math.ceil(timeout / step) do
    local v = fn()
    if v then return v end
    wait(step)
  end
  return nil
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
  local cut = s:match("^(.-)%.%.%.$") or s:match("^(.-)…$")
  if cut and (utf8.len(cut) or 0) >= 3 and tn:sub(1, #cut) == cut then return 1 end
  return 0
end

-- 保存名とトーク名の照合用。ファイル名では / が _ や : に化けるので記号も落とす。
local function loose(s) return (norm(s):gsub("%p", "")) end

local function isSaveLabel(n)
  for _, lab in ipairs(SAVE_LABELS) do
    local ln = norm(lab)
    if n == ln then return true end
    if n:sub(1, #ln) == ln and (utf8.len(n) or 99) - utf8.len(ln) <= 2 then return true end
  end
  return false
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

-- 画面の矩形（論理座標）を撮る。窓単体（-l）ではなく画面を撮るのは、⋮ の
-- メニューが別窓として出た場合でも写すため（クリックが当たる見た目そのもの）。
-- 撮れなければ窓単体の撮影に落とす。
local function capture(rect, tag, win)
  local path = TMP .. "/line_export_" .. tag .. ".png"
  os.remove(path)
  local r = { x = math.floor(rect.x), y = math.floor(rect.y),
              w = math.ceil(rect.w), h = math.ceil(rect.h) }
  hs.execute(string.format("/usr/sbin/screencapture -x -R %d,%d,%d,%d %s",
    r.x, r.y, r.w, r.h, sh(path)))
  local pw, ph = pngSize(path)
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

-- 画像を OCR し、各文字列の中心を画面の論理座標に直して返す
local function ocr(cap)
  if not cap then return {} end
  local out = hs.execute("/usr/bin/osascript " .. sh(OCR_SCRIPT) .. " " .. sh(cap.path))
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
  if not cap then cap = capture(screenOf(win), "fail", win) end
  if not cap then return nil end
  hs.fs.mkdir(DEBUG_DIR)
  local rel = "mac/debug/" .. os.date("%Y%m%d-%H%M%S") .. "_" ..
              safeName(name) .. "_" .. safeName(stage) .. ".png"
  local src, dst = io.open(cap.path, "rb"), io.open(REPO .. "/" .. rel, "wb")
  if not (src and dst) then
    if src then src:close() end
    if dst then dst:close() end
    return nil
  end
  dst:write(src:read("a")); src:close(); dst:close()
  return rel
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

-- 段の失敗を返す。その時点の画面を mac/debug/ に残す
local function fail(ctx, stage, msg, cap)
  return nil, { stage = stage, msg = msg, img = keepDebug(ctx.name, stage, cap, ctx.win) }
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

-- 幅優先で探す。チャット欄は要素数が多いので、見る数に上限を設ける
local function bfs(root, pred, budget)
  if not root then return nil end
  local q, head = { root }, 1
  while q[head] and head <= (budget or 3000) do
    local el = q[head]; head = head + 1
    if pred(el) then return el end
    for _, c in ipairs(attr(el, "AXChildren") or {}) do q[#q + 1] = c end
  end
  return nil
end
local function bfsAll(root, pred, budget)
  local found = {}
  bfs(root, function(e) if pred(e) then found[#found + 1] = e end; return false end, budget)
  return found
end

-- トークリストの検索欄: 窓の上の方にある AXTextField（下のメッセージ入力欄と区別）
local function searchField(win)
  local f = win:frame()
  return bfs(hs.axuielement.windowElement(win), function(e)
    if role(e) ~= "AXTextField" then return false end
    local r = axFrame(e)
    return r ~= nil and r.y + r.h / 2 < f.y + f.h * 0.4
  end)
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
local function findButton(root, names)
  return bfs(root, function(e)
    if role(e) ~= "AXButton" then return false end
    local t = title(e)
    for _, n in ipairs(names) do if t == n then return true end end
    return false
  end, 800)
end

-- 文字列を貼り付けで入力する。キー入力だと日本語入力が ON のとき崩れるため。
-- 元のクリップボードは戻す。
local function pasteText(s)
  local saved
  if hs.pasteboard.readAllData then
    local ok, d = pcall(hs.pasteboard.readAllData); if ok then saved = d end
  end
  hs.pasteboard.setContents(s); wait(0.1)
  hs.eventtap.keyStroke({"cmd"}, "v"); wait(0.4)
  if saved and next(saved) then pcall(hs.pasteboard.writeAllData, saved)
  else hs.pasteboard.clearContents() end
end

-- ---------- 1. 窓 ----------
local function ensureWindow(app)
  for _ = 1, 3 do
    app:activate(true); wait(0.8)
    local win = findMain(app)
    if win then
      local sf, f = screenOf(win), win:frame()
      if math.abs(f.w - sf.w) > 40 or math.abs(f.h - sf.h) > 40 then
        win:setFrame(sf, 0); wait(0.6)            -- 広い方が名前が切れずに読める
      end
      return win
    end
    -- 窓が無い・見えない・検索欄が読めない → Dock クリック相当で開き直す。
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

local function best(items, tn, inArea)
  local b, bs = nil, 0
  for _, it in ipairs(items) do
    if inArea(it) then
      local sc = score(tn, it.n)
      if sc > bs or (sc == bs and sc > 0 and it.y < b.y) then b, bs = it, sc end
    end
  end
  return b, bs
end

local function openChat(ctx, win)
  local field = searchField(win)
  local ff = field and axFrame(field)
  if not ff then return fail(ctx, "検索欄", "検索欄が見つからない") end
  local f = win:frame()
  local paneX = ff.x + ff.w + 10               -- これより右がトーク欄

  field:setAttributeValue("AXFocused", true); wait(0.2)
  hs.eventtap.keyStroke({"cmd"}, "a"); wait(0.1)
  pasteText(ctx.name); wait(1.2)
  local v = attr(field, "AXValue")
  if v ~= nil and norm(v) ~= ctx.tn then        -- 貼り付けが効かない時はキー入力で
    field:setAttributeValue("AXFocused", true); wait(0.2)
    hs.eventtap.keyStroke({"cmd"}, "a"); wait(0.1)
    hs.eventtap.keyStrokes(ctx.name); wait(1.2)
  end

  -- 左ペイン（検索欄より下・トーク欄より左）を読んで、名前の行を探す。
  -- 検索結果の表示が遅れることがあるので、見つからなければ1回だけ読み直す。
  local cap, row
  for i = 1, 2 do
    cap = capture(f, "list", win)
    if not cap then return fail(ctx, "撮影", "画面を撮れない（画面収録の許可を確認）") end
    row = best(ocr(cap), ctx.tn, function(it)
      return it.y > ff.y + ff.h + 2 and it.x > ff.x - 80 and it.x < paneX
    end)
    if row or i == 2 then break end
    wait(1.0)
  end
  if row then
    clickAt(row.x, row.y)
  else
    -- OCR で読めない時は AX のセル（トーク名が載っている）で探す。
    -- どちらで開いても、下のヘッダ確認を通らなければ先へ進まない。
    local axRow = best(rowsByAX(win, paneX, ff.y + ff.h), ctx.tn, function() return true end)
    if not axRow then
      return fail(ctx, "トーク選択", "検索結果に「" .. ctx.name .. "」が見えない", cap)
    end
    if not pcall(function() axRow.el:performAction("AXPress") end) then
      clickAt(axRow.x, axRow.y)
    end
  end
  wait(1.2)

  -- ヘッダ（トーク欄の上端）を読んで、開いたのが目的のトークか確かめる。
  -- 開くのに時間がかかることがあるので、合わなければ1回だけ読み直す。
  local function inHeader(it)
    return it.x > paneX and it.y >= f.y and it.y < f.y + L.HEADER_H
  end
  local items, hdr
  for i = 1, 2 do
    cap = capture(f, "header", win)
    items = ocr(cap)
    hdr = best(items, ctx.tn, inHeader)
    if hdr or i == 2 then break end
    wait(1.0)
  end
  if not hdr then
    local seen
    for _, it in ipairs(items) do
      if inHeader(it) and (not seen or it.y < seen.y) then seen = it end
    end
    return fail(ctx, "トーク確認", "開いたトークが違う（ヘッダ: 「" ..
      (seen and seen.text or "読めず") .. "」）", cap)
  end
  return { header = hdr, before = items, paneX = paneX }
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
  local function inMenu(it) return it.x > f.x + f.w * 0.4 and it.y > st.header.y - 10 end
  local lastCap, opened = nil, false
  for i, d in ipairs({ { 0, 0 }, { L.MENU_RETRY_DX, L.MENU_RETRY_DY } }) do
    clickAt(f.x + f.w - L.MENU_FROM_RIGHT + d[1], st.header.y + d[2]); wait(0.8)
    lastCap = capture(screenOf(win), "menu" .. i, win)
    local items = ocr(lastCap)
    local hit, fresh = nil, 0
    for _, it in ipairs(items) do
      if inMenu(it) and isNew(it, st.before) then
        fresh = fresh + 1
        if isSaveLabel(it.n) and (not hit or it.y < hit.y) then hit = it end
      end
    end
    if hit then clickAt(hit.x, hit.y); return true end
    -- 何か開いたのに目的の項目が無い → ヘッダのトーク名を押して閉じる
    -- （Escape は窓/トークを閉じるので使わない）
    if fresh >= 2 then
      opened = true
      clickAt(st.header.x, st.header.y); wait(0.6)
    end
  end
  if opened then
    return fail(ctx, "メニュー", "メニューは開いたが「トークを保存」が見当たらない", lastCap)
  end
  return fail(ctx, "メニュー", "⋮ を押してもメニューが出ない", lastCap)
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

local function cancelSheet(app)
  local sheet = findSheet(app)
  local b = sheet and findButton(sheet, { "キャンセル", "Cancel" })
  if b then b:performAction("AXPress"); wait(0.6) end
end

-- 保存先の候補。保存パネルは前回の場所を覚えるので、OUT_DIR に直接
-- 落ちることもある。どこにも無ければ Spotlight で探す。
-- 名前欄の「/」は、実際のファイル名（POSIX）では「:」になる
-- （例: オーチュー/小林央忠 → [LINE]オーチュー:小林央忠.txt）。
local function findSaved(fname, since)
  local posix = fname:gsub("/", ":")
  local dirs = { OUT_DIR, HOME .. "/Downloads", HOME .. "/Desktop",
                 HOME .. "/Documents", HOME .. "/Document", HOME }
  for _, d in ipairs(dirs) do
    local p = d .. "/" .. posix
    if (hs.fs.attributes(p, "modification") or 0) >= since - 2 then return p end
  end
  local function lit(s) return '"' .. s:gsub('[\\"]', "\\%0") .. '"' end
  local q = "kMDItemFSName == " .. lit(fname) .. " || kMDItemFSName == " .. lit(posix)
  local out = hs.execute("/usr/bin/mdfind -onlyin " .. sh(HOME) .. " " .. sh(q))
  for p in (out or ""):gmatch("[^\n]+") do
    if (hs.fs.attributes(p, "modification") or 0) >= since - 2 then return p end
  end
  return nil
end

local function saveAndMove(ctx, app)
  local sheet = waitFor(function() return findSheet(app) end, 6)
  if not sheet then return fail(ctx, "保存ダイアログ", "「トークを保存」を押しても保存ダイアログが出ない") end
  local field = waitFor(function() return nameField(sheet) end, 2)
  local cur = field and tostring(attr(field, "AXValue") or "") or ""
  if cur == "" then
    cancelSheet(app); return fail(ctx, "保存ダイアログ", "ファイル名欄が読めない")
  end

  -- 既定名は「[LINE]<トーク名>.txt」。ここでも別トークでないか確かめる
  local body = cur:gsub("%.txt$", ""):gsub("^%[LINE%]", "")
  if cur:match("^%[LINE%]") and loose(body) ~= "" and loose(ctx.name) ~= ""
     and not loose(body):find(loose(ctx.name), 1, true)
     and not loose(ctx.name):find(loose(body), 1, true) then
    cancelSheet(app)
    return fail(ctx, "保存ダイアログ", "保存名「" .. cur .. "」がトーク名と合わない")
  end

  -- ファイル名に書き出し日を付ける（[LINE]○○_20261020.txt）。既定名は毎回
  -- 同じで、書き出しは画面に読み込まれた範囲しか取れないため、上書きすると
  -- 履歴を失う。名前欄は拡張子の手前まで選択された状態で開くので、
  -- →キーで選択を解いてカーソルをそこへ置き、日付を足す。
  local want = cur:match("%.txt$") and stampedName(cur) or (stampedName(cur):gsub("%.txt$", ""))
  if not cur:gsub("%.txt$", ""):match("_%d%d%d%d%d%d%d%d$") then
    hs.eventtap.keyStroke({}, "right"); wait(0.1)
    pasteText("_" .. today()); wait(0.2)
  end
  local now = tostring(attr(field, "AXValue") or "")
  if now ~= want then                             -- 足せなかった時は名前ごと入れ直す
    field:setAttributeValue("AXValue", want); wait(0.2)
    now = tostring(attr(field, "AXValue") or "")
  end
  if now ~= want then
    log("warn: " .. ctx.name .. " のファイル名に日付を付けられず（移すときに付ける）")
  end
  local savedAs = now ~= "" and now or cur
  if not savedAs:match("%.txt$") then savedAs = savedAs .. ".txt" end

  local since = os.time()
  local save = findButton(sheet, { "保存", "Save" })
  if not save then cancelSheet(app); return fail(ctx, "保存", "「保存」ボタンが見つからない") end
  save:performAction("AXPress"); wait(0.8)
  local repl = waitFor(function()
    local s = findSheet(app); return s and findButton(s, { "置き換え", "Replace" })
  end, 1.5)
  if repl then repl:performAction("AXPress"); wait(0.7) end
  if waitFor(function() return not findSheet(app) end, 5) == nil then
    local shot = capture(screenOf(ctx.win), "save", ctx.win)
    cancelSheet(app)
    return fail(ctx, "保存", "保存ダイアログが閉じない（保存できていない）", shot)
  end

  local src = waitFor(function() return findSaved(savedAs, since) end, 6, 0.5)
  if not src then return fail(ctx, "移動", "保存したファイル「" .. savedAs .. "」が見つからない") end
  -- OUT_DIR では / と : を _ にそろえる（ingest.py の safe_filename と同じ扱い）
  local dst = OUT_DIR .. "/" .. stampedName(savedAs):gsub("[/:]", "_")
  if src ~= dst and not os.rename(src, dst) then
    hs.execute("/bin/mv -f " .. sh(src) .. " " .. sh(dst))
  end

  -- ---------- 5. 確認 ----------
  if (hs.fs.attributes(dst, "size") or 0) == 0 then
    return fail(ctx, "確認", "OUT_DIR に今日付きのファイルが無い（" .. src .. "）")
  end
  return dst
end

local function exportOne(app, name)
  local ctx = { name = name, tn = norm(name) }
  local win = ensureWindow(app)
  ctx.win = win
  if not win then return false, select(2, fail(ctx, "窓", "LINE の窓が開かない（検索欄のある窓が無い）")) end
  -- 前の件の保存ダイアログが残っていると、以降のクリックが全部効かない
  if findSheet(app) then
    log("warn: 前の保存ダイアログが残っていたのでキャンセルする")
    cancelSheet(app)
    if findSheet(app) then
      return false, select(2, fail(ctx, "窓", "残っていた保存ダイアログを閉じられない"))
    end
  end
  local st, e = openChat(ctx, win)
  if not st then return false, e end
  local ok; ok, e = pressSaveChat(ctx, win, st)
  if not ok then return false, e end
  local dst; dst, e = saveAndMove(ctx, app)
  if not dst then return false, e end
  return true, dst
end

local function describe(e)
  if type(e) ~= "table" then return tostring(e) end
  return "[" .. e.stage .. "] " .. e.msg .. (e.img and ("（画像: " .. e.img .. "）") or "")
end

local function prepareApp()
  if not screenRecordingOK() then
    return nil, "Hammerspoon に「画面収録」が許可されていない（docs/setup-mac-auto.md）"
  end
  local app = hs.application.find(LINE_BUNDLE)
  if not app then
    hs.execute("/usr/bin/open -b " .. LINE_BUNDLE); wait(5)
    app = hs.application.find(LINE_BUNDLE)
  end
  if not app then return nil, "LINE を起動できない" end
  if hs.fs.attributes(OUT_DIR, "mode") ~= "directory" then
    return nil, "保存先フォルダが無い: " .. OUT_DIR
  end
  pruneDebug()
  return app
end

local function targetName(t) return type(t) == "table" and t[1] or t end

-- 書き出した txt を取り込んで push する。第2引数の true は「ログインシェルの
-- 環境を使う」指定。これが無いと PATH が最小限になり、git や python が
-- 見つからないことがある。
local function runSync()
  local out = hs.execute('/bin/bash "' .. REPO .. '/mac/sync.sh" 2>&1', true)
  log("sync:\n" .. (out or ""))
  return (out or ""):match("push 完了") and "push済" or "push無し"
end

local function writeHeartbeat(okN, ngN, ngLines)
  local hb = io.open(REPO .. "/mac/heartbeat.txt", "w")
  if not hb then return end
  hb:write(string.format("last_run: %s\nversion: v4 (OCR)\nok: %d\nng: %d\n",
    os.date("%Y-%m-%d %H:%M:%S"), okN, ngN))
  if #ngLines > 0 then
    hb:write("failures:\n")
    for _, line in ipairs(ngLines) do hb:write("  - " .. line .. "\n") end
  end
  hb:close()
end

-- 1件だけ試す。Hammerspoon コンソールから:
--   __LINE_EXPORT.one("Berry")
function M.one(name)
  local app, err = prepareApp()
  if not app then log(err); hs.alert.show(err, 4); return false end
  local okc, ok, e = pcall(exportOne, app, name)
  if not okc then ok, e = false, { stage = "内部エラー", msg = tostring(ok) } end
  if not ok then
    log("NG  " .. name .. "  " .. describe(e))
    hs.alert.show("NG: " .. name .. "\n" .. describe(e), 6)
    return false
  end
  log("OK  " .. name .. " → " .. e)
  local pushed = runSync()
  hs.alert.show("書き出しOK: " .. name .. " / " .. pushed, 4)
  return true
end

local function runExport()
  if #TARGETS == 0 then
    hs.alert.show("TARGETS が空です。line_export.lua を編集してください", 4)
    log("TARGETS が空"); return
  end

  local app, err = prepareApp()
  if not app then
    -- 原因をリポジトリに残す（このMacのログを毎回見に行かなくて済むように）
    log(err); hs.alert.show("LINE書き出し中止: " .. err, 6)
    writeHeartbeat(0, #TARGETS, { "全件: " .. err })
    runSync()
    return
  end

  local okN, ngN, ngLines = 0, 0, {}
  for _, t in ipairs(TARGETS) do
    local name = targetName(t)
    -- 1件の想定外エラーで残りを止めず、heartbeat も必ず書く
    local okc, ok, e = pcall(exportOne, app, name)
    if not okc then ok, e = false, { stage = "内部エラー", msg = tostring(ok) } end
    if ok then
      okN = okN + 1; log("OK  " .. name .. " → " .. e)
    else
      ngN = ngN + 1; log("NG  " .. name .. "  " .. describe(e))
      ngLines[#ngLines + 1] = name .. ": " .. describe(e)
    end
    wait(0.8)
  end

  -- 結果をリポジトリに残す。ログはこのMacにしか無く、失敗の理由を
  -- 毎回コンソールから貼ってもらうのは現実的でないため、push して共有する。
  -- （撮影画像は mac/debug/ に残すだけで push しない。.gitignore 済み）
  writeHeartbeat(okN, ngN, ngLines)

  local pushed = runSync()
  hs.alert.show(string.format("LINE書き出し OK:%d NG:%d / %s", okN, ngN, pushed), 4)
end

-- OCR 診断: 今の LINE の窓を撮って、読めた文字と位置をコンソールに出す。
-- 画面収録の許可や、OCR が名前・メニューを読めているかの確認用。
function M.diag()
  local app = hs.application.find(LINE_BUNDLE)
  local win = app and (findMain(app) or app:focusedWindow() or app:mainWindow())
  if not win then hs.alert.show("LINEの窓が見つからない", 3); return end
  app:activate(true); wait(0.5)
  local cap = capture(screenOf(win), "diag", win)
  local items = ocr(cap)
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
local function bindBoth(key, fn)
  for _, mods in ipairs({{"cmd","alt","ctrl"}, {"cmd","alt","shift"}}) do
    M.hotkeys[#M.hotkeys + 1] = hs.hotkey.bind(mods, key, fn)
  end
end

-- 毎日1回を「取りこぼさない」ための追いかけ実行。
--
-- 固定時刻の hs.timer.doAt は Mac がスリープしていると発火せず、起きた後も
-- 追いかけない。実測でも 27日間で 07:00 に走ったのは1度だけだった。
-- そこで一定間隔で「今日はもう走ったか」を確認し、条件が整った最初の
-- タイミングで実行する。スリープから復帰した直後も確認する。
local STATE_PATH = REPO .. "/mac/.last_run"   -- 最後に走った日 (YYYYMMDD)
local CHECK_EVERY   = 600   -- 10分ごとに条件を確認
local IDLE_REQUIRED = 180   -- 3分以上操作が無ければ「離席中」とみなす

local function lastRunDay()
  local f = io.open(STATE_PATH, "r")
  if not f then return "" end
  local d = (f:read("l") or ""):gsub("%s", "")
  f:close()
  return d
end

local function screenLocked()
  local props = hs.caffeinate.sessionProperties()
  return props and props.CGSSessionScreenIsLocked or false
end

local function maybeRun()
  local day = today()
  if lastRunDay() == day then return end

  local hh, mm = RUN_AT:match("^(%d+):(%d+)$")
  local now = os.date("*t")
  if now.hour * 60 + now.min < tonumber(hh) * 60 + tonumber(mm) then return end

  -- ロック中・スクリーンセーバ中はクリックが通らない
  if screenLocked() then return end
  -- 操作中に割り込むと、クリックを奪い合って失敗する上に邪魔になる
  if hs.host.idleTime() < IDLE_REQUIRED then return end

  -- 実行中の再入と、失敗時の一日中のリトライを防ぐため先に記録する
  local f = io.open(STATE_PATH, "w")
  if f then f:write(day .. "\n"); f:close() end
  log("自動実行を開始（" .. os.date("%H:%M") .. "）")
  runExport()
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

bindBoth("L", runExport)                                      -- 手動実行
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
  pngSize = pngSize, ocr = ocr, capture = capture, stampedName = stampedName,
  exportOne = exportOne, runExport = runExport, prepareApp = prepareApp,
  L = L, targets = TARGETS, OUT_DIR = OUT_DIR, REPO = REPO,
}

_G.__LINE_EXPORT = M

if not screenRecordingOK() then
  log("warn: Hammerspoon に「画面収録」が許可されていない。v4 は画面を読むので必須" ..
      "（システム設定 → プライバシーとセキュリティ → 画面とシステムオーディオ録音）")
end
log(string.format(
  "読込完了 v4 / 対象%d件 / %s以降 離席中に自動実行 / 手動 ⌘⌥⌃L(⇧も可) / OCR診断 ⌘⌥⌃K / 一覧 ⌘⌥⌃J",
  #TARGETS, RUN_AT))
return M
