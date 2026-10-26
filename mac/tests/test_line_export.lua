-- line_export.lua（v4）のテスト。Mac も Hammerspoon も無い所で流れを検証する。
--
--   lua mac/tests/test_line_export.lua        （Lua 5.4。-v で途中ログも出す）
--
-- hs.* を偽物に差し替え、画面・AX・保存シート・クリック・OCR 出力を持つ
-- 「偽の LINE」を動かす。OCR は偽の画面の文字と位置をそのまま返すので、
-- ここで確かめられるのは「読んだ結果からどこを押すか・どう止まるか」の
-- 判断と座標換算まで。実機の OCR 精度や LINE の見た目は ⌘⌥⌃K の診断で確かめる。
-- macOS（BSD の stat/touch）でも Linux でも動く。
local VERBOSE = arg and arg[1] == "-v"
local here = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "mac"
local SCRIPT = here .. "/line_export.lua"

local function sh(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function run(cmd) local p = io.popen(cmd); local o = p:read("a"); p:close(); return o end
local ROOT = run("mktemp -d"):gsub("%s+$", "")
-- ROOT の下を rm -rf するので、作れなかった時は何もせずに止める（mktemp が見つからず
-- ROOT が空になると、/home や /tmp を消してしまう。10/26 に試験の環境で実際に起きた）
if not (ROOT:match("^/.+/[^/]+$") and run("test -d " .. sh(ROOT) .. " && echo ok") == "ok\n") then
  io.stderr:write("一時フォルダを作れない（mktemp -d の結果: " .. ROOT .. "）。何も消さずに止める\n")
  os.exit(2)
end
local ENV = {
  HOME = ROOT .. "/home", LINE_DUMP_REPO = ROOT .. "/repo",
  LINE_DUMP_RAW_DIR = ROOT .. "/out", TMPDIR = ROOT .. "/tmp",
  -- 眠り・「より前」の試験は 07:00 を境にして作ってある（境の時刻に依らない仕組みの
  -- 試験）。本物の既定（00:00）は「開始の時刻」の試験で確かめる
  LINE_DUMP_RUN_AT = "07:00",
}
local realgetenv = os.getenv
os.getenv = function(k) return ENV[k] or realgetenv(k) end
local HOME, REPO, OUT = ENV.HOME, ENV.LINE_DUMP_REPO, ENV.LINE_DUMP_RAW_DIR

local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end; return false end
local function readfile(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function writefile(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
-- 更新日時を ago 秒前にする（POSIX の touch -t なので macOS でも動く）
local function age(p, ago) run("touch -t " .. os.date("%Y%m%d%H%M.%S", os.time() - ago) .. " " .. sh(p)) end
local DEBUG = ROOT .. "/line-dump-debug"          -- 撮影画像と診断の置き場（本物は Dropbox）

-- ===================== 偽の世界 =====================
local W
local SCALE = 2
local SCREEN = { x = 0, y = 25, w = 1440, h = 875 }
local LINE_PID, OTHER_PID, HS_PID = 4242, 999, 777
local T = 1000000                     -- 偽の時計（usleep で進む）

local function reset(opts)
  assert(ROOT:match("^/.+/[^/]+$"), "一時フォルダが変: " .. ROOT)
  run("rm -rf " .. sh(ROOT .. "/home") .. " " .. sh(ROOT .. "/repo") .. " " ..
      sh(ROOT .. "/out") .. " " .. sh(ROOT .. "/tmp") .. " " .. sh(DEBUG))
  for _, d in ipairs({ HOME .. "/Downloads", HOME .. "/Desktop", HOME .. "/Documents",
                       REPO .. "/mac", OUT, ENV.TMPDIR }) do
    run("mkdir -p " .. sh(d))
  end
  writefile(REPO .. "/mac/ocr.applescript", "-- 偽物（osascript は hs.execute の偽物が受ける）\n")
  W = {
    running = true,
    win = { x = 100, y = 100, w = 1000, h = 700, visible = true, minimized = false, exists = true },
    chats = {}, search = "", open = nil, menuOpen = false, sheet = nil,
    focus = "input",                 -- 前のトークのメッセージ入力欄にフォーカスがある
    clipboard = "ORIGINAL", knobs = {}, axCalls = 0, clickN = 0,
    clicks = {}, keys = {}, cmds = {}, caps = {}, alerts = {}, logs = {},
    opens = 0, synced = 0, escape = false, called = false, menuClicked = {}, openLog = {}, after = {},
    mouse = { x = 5, y = 5 }, lastHID = T - 999,
  }
  for k, v in pairs(opts or {}) do W[k] = v end
end

local function lsdir(d)
  local t = {}
  for n in run("ls " .. sh(d) .. " 2>/dev/null"):gmatch("[^\n]+") do t[#t + 1] = n end
  return t
end

local function chat(name) for _, c in ipairs(W.chats) do if c.name == name then return c end end end
-- 積み直しで新しい版が届いた時に、読み込み元の写しに足す（自動更新のテスト用。SELF_COPY は後で決まる）
local function appendCopyFake(extra)
  local p = ROOT .. "/self/line_export.lua"
  local f = io.open(p, "rb"); local src = f and f:read("a"); if f then f:close() end
  if src then local g = io.open(p, "wb"); g:write(src .. extra); g:close() end
end

local function layout()
  local f = W.win
  local field = { x = f.x + 80, y = f.y + 50, w = 260, h = 28 }
  local k = W.knobs
  local hy = f.y + 66 + (k.headerDY or 0)
  -- 実機では検索欄の AX の枠が見た目（一覧の幅）より狭い
  local fieldAX = k.narrowField and { x = field.x, y = field.y, w = k.narrowField == true and 150 or k.narrowField, h = field.h } or field
  return {
    field = field, fieldAX = fieldAX,
    -- 一覧はスクロールできる（listScroll）。listTop より上に来た行は見えない
    rowY = function(i) return field.y + field.h + 40 + (i - 1) * 64 - (W.listScroll or 0) end,
    listTop = field.y + field.h + 20,
    rowX = field.x + 130,
    header = { x = f.x + 430, y = hy },
    dots = { x = f.x + f.w - 24 + (k.menuDX or 0), y = hy + (k.menuDY or 0) },
    call = { x = f.x + f.w - 60, y = hy },
    menuItem = function(i) return { x = f.x + f.w - 90, y = hy + 40 + i * 32 } end,
    input = { x = f.x + 360, y = f.y + f.h - 60, w = 600, h = 40 },
  }
end

-- 一覧に出ている行。hidden のトークは普段の一覧には無く、検索した時だけ出る
local function results()
  local r = {}
  for _, c in ipairs(W.chats) do
    if (W.search == "" and not c.hidden) or (W.search ~= "" and c.name:find(W.search, 1, true)) then
      r[#r + 1] = c
    end
  end
  return r
end

local function menuItems()
  local c = W.open and chat(W.open)                 -- Keep メモ などは「トークを保存」が無い
  return (c and c.menuItems) or W.knobs.menuItems or { "通知オフ", "トークを保存", "トーク履歴を削除", "退会" }
end

-- 画面に見えている文字（論理座標）。screen=true は画面を撮った時（別窓の
-- メニューや通知バナーも写る）、false は LINE の窓だけを撮った時。
local function visibleTexts(screen)
  local L, t = layout(), {}
  local function add(s, x, y) t[#t + 1] = { s = s, x = x, y = y } end
  if not W.win.visible then return t end
  add(W.knobs.winTitle or "LINE", W.win.x + W.win.w / 2, W.win.y + 12)   -- 窓のタイトル
  -- 検索欄の文字（実機では虫眼鏡のアイコンが字として前に付くことがある: searchPrefix）。
  -- 実機の窓表示では、入れた文字が写らず「…を検索」の表示のままだった（searchShowsHint）
  if W.knobs.searchShowsHint then
    add("友だち、トーク、メッセージを検索", L.field.x + L.field.w / 2, L.field.y + L.field.h / 2)
  elseif not W.knobs.searchUnread then
    add(W.search ~= "" and ((W.knobs.searchPrefix or "") .. W.search) or "検索",
      L.field.x + L.field.w / 2, L.field.y + L.field.h / 2)
  end
  if W.knobs.magnifier then add("Q", L.field.x + 19, L.field.y + L.field.h / 2) end
  -- 一覧の列の中・検索欄と同じ高さにある物（検索欄の AX の枠より右。実機ではアイコン等）
  if W.knobs.listJunk then add(W.knobs.listJunk, L.field.x + 230, L.field.y + L.field.h / 2) end
  -- 検索中は検索欄の下に絞り込みのタブが並ぶ
  if W.knobs.searchTabs and W.search ~= "" then
    for i, s in ipairs({ "すべて", "友だち", "グループ", "トーク", "メッセージ" }) do
      add(s, L.field.x + (i - 1) * 55, L.field.y + L.field.h + 14)
    end
  end
  for i, c in ipairs(results()) do
    if L.rowY(i) < L.listTop then goto hidden end
    -- ocrRowOpen: そのトークが開いている（一覧で選ばれて色が付いた）間の行の OCR の文字。
    -- ocrRowAfterOpen: 一度開いた後の行の OCR の文字（未読の印が消える等）
    if not W.knobs.ocrDropRows then
      -- ocrRowLate = { at = k, text = s }: k 回目に行を開いた後は s と読める（時刻の幅が変わって「…」の位置がずれる等）
      add((W.open == c.name and c.ocrRowOpen) or (c.ocrRowLate and #W.openLog >= c.ocrRowLate.at and c.ocrRowLate.text)
          or (c.openedOnce and c.ocrRowAfterOpen) or c.ocrRow or c.name, L.rowX, L.rowY(i))
    end
    -- 最後のメッセージ。実機では時刻の 20pt 下（名前の 11pt 下）のこともある: previewDY
    add(c.preview or "最後のメッセージ", L.rowX, L.rowY(i) + (W.knobs.previewDY or 18))
    -- 行の右上に最後のメッセージの時刻（実機と同じく名前より少し上）
    if not W.knobs.noRowTimes and not (W.knobs.noTimesAfterSheet and (W.sheetsOpened or 0) >= W.knobs.noTimesAfterSheet) then add(c.time or "12:34", L.field.x + (W.knobs.timeDX or 250), L.rowY(i) - 9) end
    ::hidden::
  end
  if not W.open and W.knobs.emptyLogo then
    add("LINE", W.win.x + W.win.w * 0.65, W.win.y + W.win.h / 2)
    add("トークを選択", W.win.x + W.win.w * 0.65, W.win.y + W.win.h / 2 + 80)
  end
  if W.open then
    local c = chat(W.open) or { name = W.open }
    -- ヘッダは開いてから headerDelay 秒たって出る（読み込みが遅い時）
    if not W.knobs.headerDelay or T - (W.openedAt or 0) >= W.knobs.headerDelay then
      add(c.ocrHeader or c.name, L.header.x, L.header.y)
    end
    -- ヘッダの右端の ⋮（OCR では1字として読める。noDotsOCR で読めない）と、その左の通話ボタン
    if not W.knobs.noDotsOCR then add("⋮", L.dots.x, L.dots.y) end
    if W.knobs.callOCR then add("☎", L.call.x, L.call.y) end
    -- トーク欄の上端（ヘッダより上）にある別の文字
    if W.knobs.paneTop then add(W.knobs.paneTop, W.win.x + 600, W.win.y + 30) end
    for _, m in ipairs(c.messages or {}) do add(m.s, W.win.x + m.dx, W.win.y + m.dy) end
  end
  -- ⋮ のメニューは別窓として出る（LINE の窓だけを撮ると写らない）
  if W.menuOpen and (screen or W.knobs.menuInWindow) then
    for i, s in ipairs(menuItems()) do
      if not (W.knobs.ocrDrop and W.knobs.ocrDrop[s]) then
        local p = L.menuItem(i); add(s, p.x, p.y)
      end
    end
  end
  if screen then
    for _, b in ipairs(W.banners or {}) do add(b.s, W.win.x + b.dx, W.win.y + b.dy) end
  end
  return t
end

local function ocrOutput(cap)
  local lines = {}
  for _, it in ipairs(visibleTexts(cap.screen)) do
    if it.x >= cap.x and it.x <= cap.x + cap.w and it.y >= cap.y and it.y <= cap.y + cap.h then
      lines[#lines + 1] = string.format("%s\t%d\t%d\t%d\t%d", it.s,
        math.floor((it.x - cap.x) * SCALE + 0.5),
        math.floor((it.y - cap.y) * SCALE + 0.5) + (W.knobs.ocrHalf and 1 or 0),   -- 0.5pt ずれた読み
        14 * utf8.len(it.s) * SCALE, 20 * SCALE)
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

local function u32(n)
  return string.char((n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255)
end
local function writePng(path, w, h)
  writefile(path, "\137PNG\r\n\26\n" .. "\0\0\0\13IHDR" .. u32(w) .. u32(h) .. "\8\2\0\0\0")
end

local function openSheet()
  W.keysAtSheet = #W.keys
  W.sheet = { value = W.knobs.defaultName or ("[LINE]" .. W.open .. ".txt"), cursorEnd = false }
  W.focus = "sheet"
  if W.knobs.frontLostOnSheet then W.knobs.frontIsOther = true end
  -- k 回目の保存ダイアログが出た時だけ、別のアプリが前に出る（次に前に出し直すと戻る）
  W.sheetsOpened = (W.sheetsOpened or 0) + 1
  if W.knobs.frontLostOnSheetN == W.sheetsOpened then W.knobs.frontIsOther = true; W.frontLostAt = W.sheetsOpened end
end

local function doSave(p)
  writefile(p, "2026.10.20 火曜日\n10:00 誰か テスト\n")
  if W.knobs.mtimeAgo then age(p, W.knobs.mtimeAgo) end
  W.saved = p; W.sheet = nil; W.focus = nil
  W.savesN = (W.savesN or 0) + 1                    -- k 件目を保存した直後に人が触る・別のアプリが前に
  if W.knobs.userActsAtSaveN == W.savesN then W.pendingUser = "key" end
  if W.knobs.frontLostAtSaveN == W.savesN then W.pendingFrontLoss = true end
end

-- 行を押した時に開くトーク（wrongChatOnce は最初の1回だけ別のトークが開く）
local function opened(c)
  if W.knobs.wrongChatOnce and not W.wrongDone then W.wrongDone = true; return W.knobs.wrongChatOnce end
  return W.knobs.wrongChatOnClick or c.name
end

-- 押した所に重なっている物（通知バナーなど）。untilT を過ぎたら消える（バナー）。
-- console = true は Hammerspoon のコンソール: 「常に手前」の間（または covers の時）だけ
-- LINE に重なり、最小化すると重ならない
local function overlayAt(pt)
  for _, o in ipairs(W.overlays or {}) do
    local x, y = W.win.x + o.dx, W.win.y + o.dy
    local active = not (o.untilT and T >= o.untilT)
    if o.console then active = active and not W.consoleMinimized and (W.consoleOnTop or o.covers) end
    if active and pt.x >= x and pt.x <= x + o.w and pt.y >= y and pt.y <= y + o.h then return o end
  end
end

local function click(pt)
  W.clickN = W.clickN + 1
  if W.knobs.jumpAtClick == W.clickN then T = T + 1300 end   -- 1回の上限（20分）を越える
  W.clicks[#W.clicks + 1] = { x = pt.x, y = pt.y }
  W.mouse = { x = pt.x, y = pt.y }; if not W.knobs.synthNoReset then W.lastHID = T end
  if W.knobs.userActsAtClick == W.clickN then W.pendingUser = "key" end
  if W.knobs.userMovesAtClick == W.clickN then W.pendingUser = "mouse" end
  if W.knobs.frontIsOther then W.clickedElsewhere = true; return end
  if overlayAt(pt) then W.clickedOverlay = true; return end
  local L = layout()
  if W.sheet then return end                       -- シートはモーダル
  if math.abs(pt.x - L.call.x) < 12 and math.abs(pt.y - L.call.y) < 12 then W.called = true; return end
  if W.menuOpen then
    for i, s in ipairs(menuItems()) do
      local p = L.menuItem(i)
      if math.abs(pt.y - p.y) < 12 and math.abs(pt.x - p.x) < 70 then
        W.menuClicked[#W.menuClicked + 1] = s
        W.menuOpen = false
        -- saveDead: そのトークでは「トークを保存」を押しても保存ダイアログが出ない（saveDeadOnce は1回目だけ）
        local oc = W.open and chat(W.open)
        if s == "トークを保存" and oc and (oc.saveDead or (oc.saveDeadOnce and not oc.saveDeadDone)) then
          oc.saveDeadDone = true; return
        end
        if s == "トークを保存" and not W.knobs.saveItemDead then openSheet() end
        return
      end
    end
    W.menuOpen = false                              -- 外を押すと閉じる
    return
  end
  if W.knobs.bannerAfterDots and math.abs(pt.x - L.dots.x) < 12 and math.abs(pt.y - L.dots.y) < 12 then
    W.banners = { W.knobs.bannerAfterDots }        -- ⋮ を押した直後に通知が届いた
  end
  if not W.open and math.abs(pt.x - L.dots.x) < 12 and math.abs(pt.y - L.dots.y) < 12 then
    W.dotsWithoutChat = true                        -- 何も開いていないのに ⋮ の所を押した
  end
  if W.open and not W.knobs.menuBroken
     and math.abs(pt.x - L.dots.x) < 5 and math.abs(pt.y - L.dots.y) < 5 then
    W.menuOpen = true; return
  end
  local f = L.field
  if pt.x >= f.x and pt.x <= f.x + f.w and pt.y >= f.y and pt.y <= f.y + f.h then
    if not W.knobs.clickNoFocus then W.focus = "search" end
    return
  end
  -- 一覧を読んでから押すまでの間に新着が来て、そのトークが一番上へ（reorderBeforeRowClick = { [k] = 名前 }:
  -- k 回目に行を押す直前）
  local rb = W.knobs.reorderBeforeRowClick
  if rb and rb[#W.openLog + 1] and pt.x > L.field.x - 60 and pt.x < L.field.x + L.field.w + 10 and pt.y > L.listTop then
    local nm = rb[#W.openLog + 1]; rb[#W.openLog + 1] = nil
    for k, x in ipairs(W.chats) do if x.name == nm then if k >= (W.knobs.insertAt or 1) then table.remove(W.chats, k); table.insert(W.chats, math.min(W.knobs.insertAt or 1, #W.chats + 1), x) end; break end end
  end
  for i, c in ipairs(results()) do
    if L.rowY(i) >= L.listTop and math.abs(pt.y - L.rowY(i)) < 28
       and pt.x > L.field.x - 60 and pt.x < L.field.x + L.field.w + 10 then
      W.openLog[#W.openLog + 1] = c.name
      if c.noOpen then return end                  -- 押しても開かない行
      -- 1回目を押しても開かない行（実機 10/26: 最初の行を押してもトーク欄が空のままだった）
      if c.firstClickNoOpen and not c.clickedOnce then
        c.clickedOnce = true
        -- 1回目が効かなかった後、押し直すまでの間に新着で別のトークが一番上へ（reorderAfterNoOpen）
        local rn = W.knobs.reorderAfterNoOpen
        if rn then
          W.knobs.reorderAfterNoOpen = nil
          for k, x in ipairs(W.chats) do
            if x.name == rn then if k >= (W.knobs.insertAt or 1) then table.remove(W.chats, k); table.insert(W.chats, math.min(W.knobs.insertAt or 1, #W.chats + 1), x) end; break end
          end
        end
        return
      end
      W.open = c.opens or opened(c); W.openedAt = T  -- opens: 押すと別のトークが開く行
      c.openedOnce = true
      -- 開いた後で、別のトークが一覧の下へ動く（実機 10/26: 保存したトークが下へ動き、
      -- その下の行が1行ずつ上がった）
      local mv = W.knobs.moveOnOpen
      if mv and c.name == mv.when then
        W.knobs.moveOnOpen = nil
        for k, x in ipairs(W.chats) do
          if x.name == mv.name then table.remove(W.chats, k); table.insert(W.chats, math.min(mv.to, #W.chats + 1), x); break end
        end
      end
      W.focus = "input"
      -- k 回目に行を開いた後で、そのトークに新着が来て一番上へ（reorderAtOpens = { [k] = 名前 }）
      local ro = W.knobs.reorderAtOpens and W.knobs.reorderAtOpens[#W.openLog]
      if ro then
        W.knobs.reorderAtOpens[#W.openLog] = nil
        for k, x in ipairs(W.chats) do
          if x.name == ro then if k >= (W.knobs.insertAt or 1) then table.remove(W.chats, k); table.insert(W.chats, math.min(W.knobs.insertAt or 1, #W.chats + 1), x) end; break end
        end
      end
      -- 新着で別のトークが一覧の一番上に来る（reorderAtClick 回目に押した後）
      if W.knobs.reorderAtClick == W.clickN then
        for k, x in ipairs(W.chats) do
          if x.name == W.knobs.reorderName then if k >= (W.knobs.insertAt or 1) then table.remove(W.chats, k); table.insert(W.chats, math.min(W.knobs.insertAt or 1, #W.chats + 1), x) end; break end
        end
      end
      return
    end
  end
end

-- 文字が入る先（フォーカスのある所）
local function typeInto(s)
  if W.knobs.frontIsOther then W.typedElsewhere = true; return end
  if W.focus == "search" then
    if not W.knobs.searchIgnoresPaste then W.search = s end
  elseif W.focus == "input" then
    W.draft = (W.draft or "") .. s                  -- 前のトークの下書きを壊した
  elseif W.focus == "sheet" and W.sheet and not W.knobs.sheetIgnoresPaste then
    local v = W.sheet.value
    if W.sheet.cursorEnd then
      W.sheet.value = v:match("%.txt$") and (v:gsub("%.txt$", "") .. s .. ".txt") or (v .. s)
    else
      W.sheet.value = s .. (v:match("%.txt$") and ".txt" or "")
    end
  end
end

-- ---------- AX ----------
local function el(attrs, actions)
  actions = actions or {}
  return {
    attributeValue = function(_, k)
      local v = attrs[k]; if type(v) == "function" then return v() end; return v
    end,
    setAttributeValue = function(self, k, v) if actions.set then actions.set(k, v) end; return self end,
    performAction = function(self, a)
      if actions[a] and actions[a]() == "fail" then return nil, "kAXErrorActionUnsupported" end
      return self
    end,
    pid = function() return attrs.pid or LINE_PID end,
    setTimeout = function() return true end,
  }
end
-- LINE の部品の AX の位置。axDY の分だけ画面に写る位置からずれて報告される
-- （実機: フルスクリーンで 30pt 下）
local function frameAttrs(t, r)
  local dy = W.knobs.axDY or 0
  t.AXPosition = { x = r.x, y = r.y + dy }; t.AXSize = { w = r.w, h = r.h }; return t
end

local function sheetEl()
  local s = W.sheet
  local kids = {
    el({ AXRole = "AXStaticText", AXValue = "名前:" }),
    el({ AXRole = "AXTextField", AXValue = function() return W.sheet and W.sheet.value end },
       { set = function(k, v)
           if k == "AXValue" and not W.knobs.sheetIgnoresAXSet then W.sheet.value = v end
         end }),
    el({ AXRole = "AXButton", AXTitle = W.knobs.saveTitle or "保存" }, { AXPress = function()
      local final = W.sheet.value
      if not final:match("%.txt$") then final = final .. ".txt" end
      -- 名前欄の「/」は POSIX のファイル名では「:」になる（macOS の仕様）
      local p = (W.knobs.saveDir or (HOME .. "/Downloads")) .. "/" .. final:gsub("/", ":")
      if W.knobs.saveFails then return end
      -- saveFailsOnce: そのトークでは1回目だけ「保存」を押しても保存されない（ダイアログが閉じない）
      local oc3 = W.open and chat(W.open)
      if oc3 and oc3.saveFailsOnce and not oc3.saveFailDone then oc3.saveFailDone = true; return end
      if oc3 and oc3.saveFails then return end       -- saveFails: そのトークはいつも保存されない
      W.pressedSave = true
      if exists(p) then W.sheet.confirm = p; return end
      doSave(p)
    end }),
    el({ AXRole = "AXButton", AXTitle = "キャンセル" }, { AXPress = function()
      W.clickAtCancel = W.clickN
      if W.sheet.confirm or W.knobs.cancelIgnored then return end   -- 上書き確認が出ている間は効かない
      W.sheet = nil; W.focus = nil; W.cancelled = true; W.scrollsAtCancel = W.scrollsAtCancel or W.scrolls or 0
    end }),
  }
  if s.confirm then
    kids[#kids + 1] = el({ AXRole = "AXSheet", AXChildren = {
      el({ AXRole = "AXButton", AXTitle = W.knobs.replaceTitle or "置き換える" }, { AXPress = function()
        W.replaced = true; doSave(W.sheet.confirm)
      end }),
      el({ AXRole = "AXButton", AXTitle = "キャンセル" }, { AXPress = function()
        W.sheet.confirm = nil; W.alertCancelled = true
      end }),
    } })
  end
  return el({ AXRole = "AXSheet", AXChildren = kids })
end

local function fieldEl(L)
  return el(frameAttrs({ AXRole = "AXTextField",
    AXValue = function() return W.search end,
    AXFocused = function() if W.knobs.focusUnknown then return nil end; return W.focus == "search" end,
  }, L.fieldAX), { set = function(k, v)
    if k == "AXFocused" and not W.knobs.focusIgnored then W.focus = "search" end
    if k == "AXValue" then W.search = v; W.searchSetByAX = true end
  end })
end

local function winEl()
  W.axCalls = W.axCalls + 1
  local hideField = (W.knobs.fieldHiddenUntil and W.axCalls <= W.knobs.fieldHiddenUntil)
                    or (W.knobs.fieldHiddenUntilReopen and W.opens == 0)
  local L = layout()
  return el({
    AXRole = "AXWindow", AXSubrole = "AXStandardWindow",
    AXChildren = function()
      -- メッセージ入力欄（窓の下の方の AXTextField）を検索欄より先に置き、
      -- 「上の方の AXTextField＝検索欄」の絞り込みが効くかを試す
      local paneKids = {
        el(frameAttrs({ AXRole = "AXTextField", AXValue = "" }, L.input),
           { set = function(k) if k == "AXFocused" then W.focus = "input" end end }),
      }
      -- トーク欄のメッセージも AX のセル（一覧の幅を割り出す時に数えないか）
      if W.open then
        for i = 1, 3 do
          paneKids[#paneKids + 1] = el(frameAttrs({ AXRole = "AXCell", AXChildren = {
            el({ AXRole = "AXStaticText", AXValue = "メッセージ" .. i }) } },
            { x = W.win.x + 400, y = W.win.y + 150 + i * 60, w = W.win.w - 420, h = 50 }))
        end
      end
      local pane = el({ AXRole = "AXGroup", AXChildren = paneKids })
      local cells = {}
      for i, c in ipairs(results()) do
        if c.noAX or L.rowY(i) < L.listTop then goto skip end
        cells[#cells + 1] = el(frameAttrs({ AXRole = "AXCell", AXChildren = {
          el(frameAttrs({ AXRole = "AXStaticText", AXValue = c.name },
                        { x = L.field.x - 30, y = L.rowY(i) - 10, w = 220, h = 20 })),
        } }, { x = L.field.x - 40, y = L.rowY(i) - 30, w = 330, h = 60 }),
          { AXPress = function()
              if W.knobs.axPressFails then return "fail" end
              W.open = opened(c); W.axPressed = c.name; W.openedAt = T
              W.openLog[#W.openLog + 1] = c.name
            end })
        ::skip::
      end
      -- 実機: 検索結果の画面に、幅の無い（右端 x=0 の）セルが1個だけあった
      if W.knobs.bogusCell then
        table.insert(cells, 1, el(frameAttrs({ AXRole = "AXCell" }, { x = W.win.x - W.win.x, y = L.field.y + 60, w = 0, h = 0 })))
      end
      local left = { el({ AXRole = "AXList", AXChildren = cells }) }
      if W.knobs.splitterX then
        left[#left + 1] = el(frameAttrs({ AXRole = "AXSplitter" },
          { x = W.win.x + W.knobs.splitterX, y = W.win.y, w = 1, h = W.win.h }))
      end
      if not hideField then table.insert(left, 1, fieldEl(L)) end
      local kids = { pane, el({ AXRole = "AXGroup", AXChildren = left }) }
      if W.sheet then kids[#kids + 1] = sheetEl() end
      return kids
    end,
  })
end

-- ---------- hs.* ----------
local screenObj = { frame = function() return { x = SCREEN.x, y = SCREEN.y, w = SCREEN.w, h = SCREEN.h } end }
local winObj = {
  frame = function() return { x = W.win.x, y = W.win.y, w = W.win.w, h = W.win.h } end,
  isVisible = function() return W.win.visible and not W.knobs.appHidden end,   -- 本物も隠したアプリの窓は見えない扱い
  isMinimized = function() return W.win.minimized end,
  unminimize = function() W.win.minimized = false; W.win.visible = true end,
  id = function() return 42 end,
  title = function() return W.knobs.winTitle or "LINE" end,
  screen = function() return screenObj end,
  setFrame = function(_, r) if not W.knobs.noResize then W.win.x, W.win.y, W.win.w, W.win.h = r.x, r.y, r.w, r.h end end,
  snapshot = function() return nil end,
  focus = function() W.focusCalls = (W.focusCalls or 0) + 1; if not W.knobs.cannotFocus then W.focusedOther = false end end,
}
local otherWin = { id = function() return 77 end }
local appObj = {
  bundleID = function() return "jp.naver.line.mac" end,
  pid = function() return LINE_PID end,
  isFrontmost = function() return not (W.knobs.frontIsOther or W.stolen) end,
  allWindows = function()
    if W.knobs.userActsInFindMain and not W.findActDone then   -- 窓を探している間に人が戻った
      W.findActDone = true; W.lastHID = T; W.knobs.frontIsOther = true
    end
    return W.win.exists and { winObj } or {}
  end,
  focusedWindow = function()
    if W.focusedOther then return otherWin end
    return W.win.visible and winObj or nil
  end,
  mainWindow = function() return W.win.exists and winObj or nil end,
  isHidden = function() return W.knobs.appHidden == true end,
  activate = function()
    if W.frontLostAt then                            -- 1回目の出し直しは効かず、2回目で戻る
      W.frontTries = (W.frontTries or 0) + 1
      if W.frontTries >= 2 then W.knobs.frontIsOther = nil; W.frontLostAt = nil end
    end
    if W.knobs.userActsAtFirstActivate and not W.actDone then
      W.actDone = true; W.pendingUser = "key"; W.knobs.frontIsOther = true   -- 人が戻って別のアプリを押した
    end
    if W.stolen then
      W.stolen = false; W.reactivated = (W.reactivated or 0) + 1
      if W.knobs.userActsAtActivate then W.pendingUser = "key" end   -- 前に出し直している間に人が触った
    end
  end,
}

local function execute(cmd, userEnv)
  W.cmds[#W.cmds + 1] = cmd
  -- 本物の hs.execute(cmd, true) は $SHELL -l -i -c "cmd" で、中身を逃がさない。
  -- " や $ や改行を含む命令はそこで壊れる（10/26 の見直しで見つかった）
  if userEnv and cmd:find('["$\n`]') then W.brokenUserEnv = (W.brokenUserEnv or 0) + 1 end
  local x, y, w, h, path = cmd:match("screencapture %-x %-R (%-?%d+),(%-?%d+),(%d+),(%d+) '(.-)'$")
  if x then
    if W.knobs.noCapture then return "", false end
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    writePng(path, w * SCALE, h * SCALE); W.caps[path] = { x = x, y = y, w = w, h = h, screen = true }
    return "", true
  end
  local id, wpath = cmd:match("screencapture %-x %-o %-l (%d+) '(.-)'$")
  if id then
    if W.knobs.noCapture then return "", false end
    local f = W.win
    writePng(wpath, f.w * SCALE, f.h * SCALE); W.caps[wpath] = { x = f.x, y = f.y, w = f.w, h = f.h }
    return "", true
  end
  local img = cmd:match("osascript '.-' '(.-)' 2>&1$")
  if img then
    if W.knobs.ocrFails then return "osascript: execution error: Vision が無い (-2700)\n", false end
    return W.caps[img] and ocrOutput(W.caps[img]) or "", true
  end
  if cmd:match("open %-b jp%.naver%.line%.mac") then
    W.opens = W.opens + 1; W.running = true; W.win.exists = true; W.win.visible = true
    return "", true
  end
  local src, dst = cmd:match("^/bin/mv %-f '(.-)' '(.-)'$")
  if src then
    if W.knobs.moveFails then return "mv: Operation not permitted\n", false end
    os.rename(src, dst); return "", true
  end
  if cmd:match("mdfind") then W.mdfindUsed = true; return W.knobs.mdfind or "", true end
  if cmd:match("ioreg %-c IOHIDSystem") then
    if W.knobs.noIoreg then return "", true end
    return string.format("%d\n", math.floor((T - W.lastHID) * 1e9)), true
  end
  if cmd:match("sync%.sh") then
    W.synced = W.synced + 1
    if W.knobs.syncTimeout then return "LINE_DUMP_TIMEOUT\n", false end
    if W.knobs.syncThrows then error("sync boom", 0) end
    if W.knobs.syncOut then return W.knobs.syncOut, true end
    if W.knobs.syncFails then return "error: push に失敗。ネットワークか認証を確認する\n", true end
    return "push 完了\n", true
  end
  if cmd:match("symbolic%-ref") then return (W.knobs.branch or "main") .. "\n", true end
  if cmd:match("pull %-%-ff%-only") then
    W.pulled = true
    if W.knobs.pullTimeout then return "LINE_DUMP_TIMEOUT\n", false end
    if W.knobs.pullFails then return "error: Your local changes to the following files would be overwritten by merge:\n", false end
    if W.knobs.pullDiverged then return "fatal: Not possible to fast-forward, aborting.\n", false end
    if W.knobs.appendOnPull then appendCopyFake(W.knobs.appendOnPull); W.knobs.appendOnPull = nil end
    return "", true
  end
  -- 早送りできない時の積み直し（手元に送れなかった取り込みの commit がある）
  if cmd:match("pull %-%-rebase") then
    W.rebased = true
    if W.knobs.pullFails or W.knobs.rebaseFails then
      run("mkdir -p " .. sh(REPO .. "/.git/rebase-merge"))    -- ぶつかって途中で止まった
      return "error: could not apply 1234abc... mac: LINE書き出しを取り込み\n", false
    end
    if W.knobs.newSourceOnRebase then appendCopyFake(W.knobs.newSourceOnRebase) end
    return "", true
  end
  if cmd:match("rebase %-%-abort") then
    W.rebaseAborted = true; run("rm -rf " .. sh(REPO .. "/.git/rebase-merge")); return "", true
  end
  if cmd:match("status %-%-porcelain") then return W.knobs.dirty or "", true end
  if cmd:match("push %-q origin main") then W.pushedAfterRebase = true; return "", true end
  if cmd:match("pmset %-g") then
    return " displaysleep         " .. (W.knobs.displaySleep or 10) .. "\n" ..
      (W.knobs.systemSleep and (" sleep                " .. W.knobs.systemSleep .. "\n") or ""), true
  end
  if cmd:match("^/usr/bin/sips") then W.sips = (W.sips or 0) + 1; return "", true end   -- Linux には無い → PNG のまま
  return "", true
end

-- hs.fs.attributes の偽物。GNU（Linux）と BSD（macOS）の stat の両方に対応
local function stat(path)
  local out = run("stat -c '%F|%s|%Y' " .. sh(path) .. " 2>/dev/null || stat -f '%HT|%z|%m' " .. sh(path) .. " 2>/dev/null")
  local typ, size, mt = out:match("^(.-)|(%d+)|(%d+)")
  if not typ then return nil end
  return { mode = typ:lower() == "directory" and "directory" or "file",
           size = tonumber(size), modification = tonumber(mt) }
end

local realRename = os.rename
os.rename = function(a, b)
  if W and W.knobs.moveFails then return nil, "Operation not permitted" end
  return realRename(a, b)
end

hs = {
  timer = {
    usleep = function(us)
      T = T + us / 1000000
      if W.knobs.userBusy then W.mouse = { x = W.mouse.x + 1, y = W.mouse.y }; W.lastHID = T end
      -- 待っている間に人が戻ってきた
      if W.pendingUser == "key" then W.lastHID = T; W.pendingUser = nil end
      if W.pendingFrontLoss then W.knobs.frontIsOther = true; W.pendingFrontLoss = nil end
      -- マウスだけ動いた（無操作時間の見張りをすり抜けても、位置の見張りで止まるか）
      if W.pendingUser == "mouse" then W.mouse = { x = W.mouse.x + 40, y = W.mouse.y }; W.pendingUser = nil end
    end,
    secondsSinceEpoch = function() return T end,
    doEvery = function() return { stop = function() end, nextTrigger = function() return 42 end } end,
    doAfter = function(_, fn) W.after[#W.after + 1] = fn; return { stop = function() end } end,
  },
  caffeinate = {
    sessionProperties = function() return { CGSSessionScreenIsLocked = W.knobs.locked or nil } end,
    get = function(k) return W.displayIdle == true end,
    set = function(k, v)
      if k == "displayIdle" then
        W.displayIdle = v; W.displayIdleSet = (W.displayIdleSet or 0) + 1
        if v then W.displayIdleWasOn = true end
      end
    end,
    declareUserActivity = function() W.declared = true end,
    currentAssertions = function() return W.knobs.assertions or {} end,
    watcher = { new = function(fn) W.watcherFn = fn; return { start = function() end, stop = function() end } end,
                systemDidWake = 1, screensDidUnlock = 2, sessionDidBecomeActive = 3, systemWillSleep = 4,
                screensDidLock = 5, screensDidSleep = 6, screensDidWake = 7, systemWillPowerOff = 8 },
  },
  battery = { powerSource = function() return W.knobs.powerSource end },
  camera = {
    allCameras = function()
      return { { isInUse = function() return W.knobs.cameraInUse == true end } }
    end,
  },
  -- 本物と同じく 2^30 ns（約1.07秒）刻みの整数（切り捨て）
  host = { idleTime = function() return math.floor((T - W.lastHID) * 1e9 / 2^30) end },
  mouse = { absolutePosition = function(pt)
    if pt then                                      -- マウスを動かす（自動の操作）
      W.mouse = { x = pt.x, y = pt.y }; W.mouseMoves = (W.mouseMoves or 0) + 1
      if not W.knobs.synthNoReset then W.lastHID = T end
      return
    end
    return { x = W.mouse.x, y = W.mouse.y }
  end },
  hotkey = { bind = function() return { delete = function() end } end },
  alert = { show = function(s) W.alerts[#W.alerts + 1] = s end },
  geometry = { point = function(x, y) return { x = x, y = y } end },
  eventtap = {
    leftClick = click,
    keyStroke = function(mods, k)
      W.keys[#W.keys + 1] = table.concat(mods, "+") .. "+" .. k
      if not W.knobs.synthNoReset then W.lastHID = T end
      if W.knobs.frontIsOther then W.typedElsewhere = true; return end
      if k == "escape" then W.escape = true; W.win.visible = false; W.open = nil end
      if k == "v" and mods[1] == "cmd" then
        typeInto(W.clipboard)
        if W.knobs.frontLostAfterPaste then W.knobs.frontIsOther = true end
      end
      if k == "right" and W.sheet and W.focus == "sheet" then W.sheet.cursorEnd = true end
      if k == "delete" then
        if W.focus == "search" then W.search = ""
        elseif W.focus == "input" then W.draft = "（入力欄で delete を押した）" end
      end
    end,
    -- ホイール（正は上へ）。マウスが一覧の上にある時だけ一覧が動く
    scrollWheel = function(off, mods, unit)
      W.scrolls = (W.scrolls or 0) + 1
      -- 本物は量を整数に直して読む（小数は 0 になり、動かない）
      local amount = math.tointeger(off[2])
      if not amount then W.fractionalScroll = true; return end
      -- 最初に下へ送った時に、いくつ開いていたか（見えている最後の行の番号を知るため）
      if off[2] < 0 and not W.opensAtFirstScroll and #W.openLog > 0 then W.opensAtFirstScroll = #W.openLog end
      if W.sheet then return end                     -- シートが出ている間は一覧も動かない
      -- 点（pixel）単位・行（line）単位のどちらが効くかはアプリしだい（実機 10/24: pixel で動かない）
      if (unit or "line") == "pixel" and W.knobs.pixelScrollIgnored then return end
      if unit == "line" and W.knobs.lineScrollIgnored then return end
      if unit == "line" then amount = amount * (W.knobs.lineScale or 64) end
      off = { off[1], amount }
      if W.knobs.userActsAtScroll == W.scrolls then W.pendingUser = "key" end
      -- k 回目に下へ送った時に、新着でそのトークが一番上へ（reorderAtDownScroll = { [k] = 名前 }）
      if off[2] < 0 and W.knobs.reorderAtDownScroll then
        W.downScrolls = (W.downScrolls or 0) + 1
        local nm = W.knobs.reorderAtDownScroll[W.downScrolls]
        if nm then                                  -- 名前の表なら、その順に一番上へ
          W.knobs.reorderAtDownScroll[W.downScrolls] = nil
          for _, one in ipairs(type(nm) == "table" and nm or { nm }) do
            for k, x in ipairs(W.chats) do if x.name == one then if k >= (W.knobs.insertAt or 1) then table.remove(W.chats, k); table.insert(W.chats, math.min(W.knobs.insertAt or 1, #W.chats + 1), x) end; break end end
          end
        end
      end
      if not W.knobs.synthNoReset then W.lastHID = T end
      if W.knobs.frontIsOther then W.scrolledElsewhere = true; return end
      local L = layout()
      if W.mouse.x > L.field.x - 60 and W.mouse.x < L.field.x + L.field.w + 10 and W.mouse.y > L.listTop then
        local n = #results()
        local maxScroll = math.max(0, n * 64 + 60 - (W.win.y + W.win.h - L.listTop))
        W.listScroll = math.max(0, math.min(maxScroll, (W.listScroll or 0) - off[2]))
      end
    end,
    keyStrokes = function(s)
      W.keys[#W.keys + 1] = "type:" .. s
      if not W.knobs.synthNoReset then W.lastHID = T end
      typeInto(s)
    end,
  },
  pasteboard = {
    setContents = function(s) W.clipboard = s end,
    readAllData = function() return { ["public.utf8-plain-text"] = W.clipboard } end,
    writeAllData = function(t)
      W.clipboard = t["public.utf8-plain-text"]
      -- 貼り付けの直前に通知などで一瞬前面が外れる（前に出し直せば戻る）
      if W.knobs.stealOnPaste and W.clipboard ~= "ORIGINAL" then W.stolen = true end
      if t["org.nspasteboard.TransientType"] then W.transientMarked = true end
      return true
    end,
    clearContents = function() W.clipboard = "" end,
  },
  screen = { primaryScreen = function() return screenObj end },
  screenRecordingState = function() return not W.knobs.noPermission end,
  openConsole = function() W.consoleOpened = true end,
  processInfo = { processID = HS_PID },
  -- コンソールの「常に手前」（Hammerspoon の設定）と、コンソールの窓
  consoleOnTop = function(v) if v ~= nil then W.consoleOnTop = v end; return W.consoleOnTop == true end,
  console = { hswindow = function()
    return { isMinimized = function() return W.consoleMinimized == true end,
             minimize = function() W.consoleMinimized = true; W.consoleMinimizedN = (W.consoleMinimizedN or 0) + 1 end,
             unminimize = function() W.consoleMinimized = false end }
  end },
  reload = function() W.reloaded = true end,
  application = {
    find = function() return W.running and appObj or nil end,
    -- 本物は処理の途中では更新されない（コンソールから実行すると Hammerspoon のまま）
    frontmostApplication = function()
      return { bundleID = function() return "org.hammerspoon.Hammerspoon" end }
    end,
    applicationForPID = function(pid)
      local names = W.knobs.pidNames or {}
      if pid == HS_PID then
        return { name = function() return "Hammerspoon" end, bundleID = function() return "org.hammerspoon.Hammerspoon" end }
      end
      if W.knobs.helperPid and pid == W.knobs.helperPid then   -- LINE の補助プロセス
        return { name = function() return "LINE Helper" end, bundleID = function() return "jp.naver.line.mac.helper" end }
      end
      if names[pid] then return { name = function() return names[pid] end, bundleID = function() return "com.example" end } end
    end,
  },
  axuielement = {
    windowElement = function() return winEl() end,
    applicationElement = function()
      return el({ AXRole = "AXApplication", AXWindows = function()
        local ws = {}
        -- LINE の設定画面など、保存とは関係ないダイアログ（先に並ぶ）
        if W.knobs.otherDialog then
          ws[#ws + 1] = el({ AXRole = "AXWindow", AXSubrole = "AXDialog", AXChildren = {
            el({ AXRole = "AXTextField", AXValue = "表示名" }),
            el({ AXRole = "AXButton", AXTitle = "閉じる" }, { AXPress = function() W.otherClosed = true end }),
          } })
        end
        ws[#ws + 1] = winEl()
        return ws
      end })
    end,
    systemElementAtPosition = function(x, y)
      local o = overlayAt({ x = x, y = y })
      if o then return el({ pid = o.pid or (o.console and HS_PID) or OTHER_PID }) end
      return el({ pid = W.knobs.helperPid or LINE_PID })
    end,
    systemWideElement = function()
      return el({ AXFocusedApplication = function()
        return el({ AXTitle = (W.knobs.frontIsOther or W.stolen) and "Finder" or "LINE" })
      end, AXFocusedUIElement = function()
        if W.knobs.focusUnknown then return nil end
        local L = layout()
        if W.focus == "search" then return el(frameAttrs({}, L.fieldAX)) end
        if W.focus == "input" then return el(frameAttrs({}, L.input)) end
      end })
    end,
  },
  execute = execute,
  fs = {
    attributes = function(p, a) local t = stat(p); if not t then return nil end; return a and t[a] or t end,
    mkdir = function(p) run("mkdir -p " .. sh(p)); return true end,
    dir = function(p)
      if W.knobs.dirThrows and p:find("line-dump-debug", 1, true) then error("cannot open " .. p .. ": Operation not permitted") end
      local names = {}
      for n in run("ls -a " .. sh(p)):gmatch("[^\n]+") do names[#names + 1] = n end
      local i = 0
      return function() i = i + 1; return names[i] end
    end,
  },
}

local realprint = print
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  local s = table.concat(parts, "\t")
  if W then W.logs[#W.logs + 1] = s end
  if VERBOSE then realprint(s) end
end

local function load()
  _G.__LINE_EXPORT = nil
  return dofile(SCRIPT)
end

-- ===================== テストの枠 =====================
local passed, failed = 0, 0
local current
local function check(cond, msg)
  if cond then passed = passed + 1
  else
    failed = failed + 1
    realprint("  NG: [" .. current .. "] " .. msg)
  end
end
local ONLY = realgetenv("LINE_TEST_ONLY")      -- 名前にこの文字を含むテストだけ流す
local function test(name, fn)
  if ONLY and not name:find(ONLY, 1, true) then return end
  current = name
  local ok, err = pcall(fn)
  if not ok then
    failed = failed + 1
    realprint("  NG: [" .. name .. "] 例外: " .. tostring(type(err) == "table" and (err.abort or err.blocked) or err))
    if W then for _, l in ipairs(W.logs) do realprint("      " .. l) end end
  end
end
-- どのシナリオでも守ること（危ない操作をしていない）
local function safe()
  check(not W.escape, "Escape を押していない")
  check(not W.called, "通話ボタンを押していない")
  check(W.draft == nil, "前のトークの入力欄に打ち込んでいない（下書き: " .. tostring(W.draft) .. "）")
  check(not W.typedElsewhere and not W.clickedElsewhere, "他のアプリを操作していない")
  check(not W.clickedOverlay, "重なった物を押していない")
  for _, s in ipairs(W.menuClicked) do
    check(s == "トークを保存", "メニューで「トークを保存」以外を押していない（押したのは " .. s .. "）")
  end
  check(W.clipboard == "ORIGINAL", "クリップボードを元に戻している（今: " .. tostring(W.clipboard) .. "）")
  check(not exists(REPO .. "/mac/debug"), "撮影画像をリポジトリの中に置いていない")
end

local TODAY = os.date("%Y%m%d")
local function chats(list)
  local t = {}
  for _, c in ipairs(list) do t[#t + 1] = type(c) == "table" and c or { name = c } end
  return t
end
-- 1件だけ書き出す（runExport と同じく見張り付きで）
local function exportOne(name)
  local M = load()
  local app = assert(M._t.prepareApp())
  M._t.beginRun(app)
  local ok, r1, r2 = pcall(M._t.exportOne, app, name)
  M._t.endRun()
  if not ok then error(r1, 0) end
  return r1, r2
end
local function at9am(fn)
  local realdate = os.date
  os.date = function(fmt, ...)
    if fmt == "*t" then local t = realdate("*t", ...); t.hour = 9; return t end
    return realdate(fmt, ...)
  end
  local ok, err = pcall(fn)
  os.date = realdate
  if not ok then error(err, 0) end
end
local function heartbeat() return readfile(REPO .. "/mac/heartbeat.txt") or "" end
local function line(hb, s) return hb:find("\n" .. s .. "\n", 1, true) ~= nil end

-- ===================== 純粋な関数 =====================
test("正規化と照合", function()
  reset()
  local M = load()
  local n, score = M._t.norm, M._t.score
  check(n("パプリカ🌶️（82）") == "パプリカ(82)", "絵文字を落とし全角括弧を半角に: " .. n("パプリカ🌶️（82）"))
  check(n("Ｂｅｒｒｙ") == "berry", "全角英字→半角小文字")
  check(n("3日後　ハートランド") == n("3日後 ハートランド"), "全角/半角スペースを無視")
  check(n("mP-廣瀬舞") == n("mPー廣瀬舞"), "ハイフンと長音を同一視")
  check(n("卜ークを保存") == n("トークを保存"), "卜とトを同一視")
  check(score(n("パプリカ"), n("パプリカ🌶️（82）")) == 3, "メンバー数付きでも完全一致")
  check(score(n("かにっこにー"), n("かにっこにー")) == 3, "完全一致=3")
  check(score(n("かにっこにー"), n("かにっこにー3")) == 2, "前方一致=2")
  check(score(n("Koyo"), n("p Koyo")) == 1, "部分一致=1")
  check(score(n("il 石川ありがとう"), n("il 石川あり…")) == 1, "…で切れた名前も部分一致")
  check(score(n("il 石川ありがとう"), n("il 石川ありが…（12）")) == 1, "…で切れたグループ名（メンバー数付き）も部分一致")
  check(score(n("il 石川ありがとう"), n("il…")) == 0, "切れた前半が短すぎれば不一致")
  check(score(n("Berry"), n("Cherry")) == 0, "不一致=0")
  check(score("", n("何か")) == 0, "空の名前は何にも一致しない")
  check(M._t.loose("オーチュー/小林央忠") == M._t.loose("オーチュー_小林央忠"), "保存名照合では / と _ を無視")
  local nm = M._t.nameMatches
  check(nm("[LINE]かにっこにー.txt", "かにっこにー"), "保存名: 完全一致")
  check(not nm("[LINE]かにっこにー3.txt", "かにっこにー"), "保存名: 前方一致は通さない")
  check(not nm("[LINE]村田研OB会.txt", "村田研"), "保存名: 部分一致は通さない")
  check(nm("[LINE]パプリカ🌶️.txt", "パプリカ"), "保存名: 絵文字は無視")
  check(nm("[LINE] Chat with Berry.txt", "Berry"), "保存名: 英語表示")
  check(nm("[LINE] 田中とのトーク.txt", "田中"), "保存名: 「とのトーク」付き")
  check(not nm("プロフィール", "Berry"), "保存名: [LINE] で始まらない物は通さない")
end)

test("メニュー項目の判定", function()
  reset()
  local M = load()
  local n, is = M._t.norm, M._t.isSaveLabel
  check(is(n("トークを保存")), "トークを保存")
  check(is(n("Save chat")), "Save chat")
  check(is(n("卜ークを保存")), "OCR の取り違え（卜）")
  check(not is(n("トークを保存しといて")), "本文の一部は対象外")
  check(not is(n("トーク履歴を削除")), "別の項目は対象外")
end)

test("PNG の大きさ・OCR 出力の読み取り・日付スタンプ", function()
  reset()
  local M = load()
  local p = ENV.TMPDIR .. "/x.png"
  writePng(p, 2880, 1750)
  local w, h = M._t.pngSize(p)
  check(w == 2880 and h == 1750, "PNG ヘッダから幅と高さ")
  writefile(p, "not a png")
  check(M._t.pngSize(p) == nil, "PNG でなければ nil")

  local cap = { path = "/x", rect = { x = 100, y = 50 }, sx = 2, sy = 2 }
  local orig = hs.execute
  hs.execute = function() return "トークを保存\t200\t100\t120\t30\n通知オフ\t200.0\t160\t80\t30\n壊れた行\n", true end
  local items = M._t.ocr(cap)
  hs.execute = orig
  check(#items == 2, "壊れた行は無視して2件")
  check(items[1].x == 200 and items[1].y == 100, "画像px→論理座標（÷2 + 撮影位置）")
  check(items[2].text == "通知オフ" and items[2].y == 130, "小数表記の座標も読む")
  hs.execute = function() return "execution error: 何か (-2700)\n", false end
  local none, why = M._t.ocr(cap)
  hs.execute = orig
  check(none == nil and why:find("OCR が動かない", 1, true), "osascript が失敗したら nil と理由")

  check(M._t.stampedName("[LINE]Berry.txt") == "[LINE]Berry_" .. TODAY .. ".txt", "日付を付ける")
  check(M._t.stampedName("[LINE]Berry_20261019.txt") == "[LINE]Berry_" .. TODAY .. ".txt", "古い日付は今日に")
end)

-- ===================== 流れ全体 =====================
test("正常: 一覧に見えている行→ヘッダ確認→⋮→トークを保存→保存→OUT_DIRへ移動", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }) })
  local ok, dst = exportOne("Berry")
  check(ok, "成功する: " .. tostring(type(dst) == "table" and dst.msg or dst))
  local want = OUT .. "/[LINE]Berry_" .. TODAY .. ".txt"
  check(dst == want, "保存先は OUT_DIR/[LINE]Berry_今日.txt: " .. tostring(dst))
  check(exists(want), "ファイルがある")
  check(not exists(HOME .. "/Downloads/[LINE]Berry_" .. TODAY .. ".txt"), "既定の保存先からは移した")
  check(W.win.w == SCREEN.w and W.win.h == SCREEN.h, "窓を画面いっぱいにした")
  check(W.search == "", "一覧に見えていたので検索していない")
  for i = 1, W.keysAtSheet or 0 do check(W.keys[i] ~= "cmd+v", "保存ダイアログの前に何も貼っていない") end
  check(W.menuClicked[1] == "トークを保存", "「トークを保存」を押した")
  check(W.transientMarked, "一時的なクリップボードには履歴に残らない印を付けた")
  check(W.displayIdleWasOn and W.displayIdle == false, "実行中だけ画面を消さないようにし、終わったら戻した")
  safe()
end)

test("一覧に無いトークは検索して開く（検索→行→ヘッダ確認）", function()
  reset({ chats = { { name = "直承Jikisho" }, { name = "Berry", hidden = true } }, knobs = { searchTabs = true } })
  local ok, dst = exportOne("Berry")
  check(ok and dst == OUT .. "/[LINE]Berry_" .. TODAY .. ".txt", "成功する: " .. tostring(type(dst) == "table" and dst.msg or dst))
  check(W.search == "Berry" and not W.searchSetByAX, "検索欄に名前を貼り付けた")
  safe()
end)

test("完全一致の行を優先（かにっこにー3 より かにっこにー（5））", function()
  reset({ chats = { { name = "かにっこにー3" }, { name = "かにっこにー4" },
                    { name = "かにっこにー", ocrRow = "かにっこにー（5）", ocrHeader = "かにっこにー（5）" } } })
  local ok = exportOne("かにっこにー")
  check(ok, "成功する")
  check(W.saved and W.saved:find("[LINE]かにっこにー_", 1, true), "かにっこにー を保存: " .. tostring(W.saved))
  safe()
end)

test("目的のトークが一覧に無く、名前を含む別トークが1つだけでも書き出さない", function()
  -- 「村田研」が抜けて「村田研OB会」だけがある / 「かにっこにー」が無く「かにっこにー3」だけ
  for _, case in ipairs({ { "村田研", "村田研OB会" }, { "かにっこにー", "かにっこにー3" } }) do
    reset({ chats = chats({ "直承Jikisho", case[2] }) })
    local ok, e = exportOne(case[1])
    check(not ok and e.stage == "保存ダイアログ" and e.msg:find("合わない", 1, true),
      case[1] .. ": 保存名で止める: " .. tostring(e and e.msg))
    check(not W.saved and W.cancelled, case[1] .. ": 保存していない")
    safe()
  end
end)

test("…で切れた名前は部分一致で開き、保存名で完全一致を確かめる", function()
  reset({ chats = { { name = "il 石川ありがとう", ocrRow = "il 石川ありが…（12）", noAX = true,
                      preview = "il 石川ありがとうって言ってた" } } })
  local ok = exportOne("il 石川ありがとう")
  check(ok and W.saved and W.saved:find("[LINE]il 石川ありがとう_", 1, true), "書き出した: " .. tostring(W.saved))
  safe()
end)

test("完全一致が無く候補が複数なら順に開き、保存名が違えば保存せずに次へ（全部違えば止める）", function()
  reset({ chats = chats({ "かにっこにー3", "かにっこにー4" }) })
  local ok, e = exportOne("かにっこにー")
  check(not ok and e.stage == "保存ダイアログ" and e.msg:find("合わない", 1, true), "保存名で止める: " .. tostring(e and e.msg))
  check(#W.openLog == 2 and W.openLog[1] == "かにっこにー3" and W.openLog[2] == "かにっこにー4",
    "2件とも開いて確かめた: " .. table.concat(W.openLog, ","))
  check(not W.saved and W.cancelled and not W.sheet, "保存していない（ダイアログは閉じた）")
  safe()
end)

test("完全一致の行を OCR が読み違えても、AX の名前で完全一致を選ぶ", function()
  -- 「かにっこにー（5」の閉じ括弧が落ちて前方一致になり、かにっこにー3 と並ぶ
  reset({ chats = { { name = "かにっこにー3" },
                    { name = "かにっこにー", ocrRow = "かにっこにー（5", ocrHeader = "かにっこにー（5）" } } })
  local ok = exportOne("かにっこにー")
  check(ok and W.saved:find("[LINE]かにっこにー_", 1, true), "かにっこにー を保存: " .. tostring(W.saved))
  safe()
end)

test("候補は行で数える（AX にしか・OCR にしか見えない行も1つと数える）", function()
  -- かにっこにー4 の行は AX に出てこない。OCR では2行とも見える → 2件（同じ行を2度開かない）
  reset({ chats = { { name = "かにっこにー4", noAX = true }, { name = "かにっこにー3" } } })
  local ok, e = exportOne("かにっこにー")
  check(not ok and e.msg:find("合わない", 1, true), "保存名で止める: " .. tostring(e and e.msg))
  check(#W.openLog == 2 and W.openLog[1] ~= W.openLog[2], "2行を1回ずつ開いた: " .. table.concat(W.openLog, ","))
  check(not W.saved, "保存していない")
  safe()
end)

test("フルスクリーン（LINE が AX で教える位置が画面より 30pt 下）でも、ヘッダを読んで ⋮ を押して保存する", function()
  for _, k in ipairs({ { axDY = 30, searchPrefix = "Q " }, { axDY = 30, focusIgnored = true },
                       { axDY = 30, searchUnread = true }, { axDY = -10 }, { axDY = 0 } }) do
    reset({ chats = chats({ "直承Jikisho", "Berry" }) })
    for kk, v in pairs(k) do W.knobs[kk] = v end
    W.knobs.paneTop = "裏フェス Urafess"           -- トーク欄の上端の別の文字（ヘッダと取り違えない）
    local ok, e = exportOne("Berry")
    local tag = "axDY=" .. k.axDY .. (k.focusIgnored and " 押してフォーカス" or "") .. (k.searchUnread and " 検索欄が読めない" or "")
    check(ok and W.saved and W.saved:find("[LINE]Berry_", 1, true), tag .. ": 保存した: " .. tostring(e and e.msg))
    local L, hitDots = layout(), false
    for _, c in ipairs(W.clicks) do
      if math.abs(c.x - L.dots.x) < 5 and math.abs(c.y - L.dots.y) < 5 then hitDots = true end
    end
    check(hitDots, tag .. ": 画面の ⋮ の位置を押した")
    safe()
  end
end)

test("実機どおり検索欄に前の名前が残っている時も（検索して開く）、ずれを測って書き出す", function()
  for _, k in ipairs({ { axDY = 30 }, { axDY = 30, searchPrefix = "Q " }, { axDY = 30, focusIgnored = true },
                       { axDY = 30, searchUnread = true, magnifier = true }, { axDY = 0 },
                       { axDY = 0, searchShowsHint = true, magnifier = true, focusIgnored = true } }) do
    reset({ chats = { { name = "直承Jikisho" }, { name = "Berry", hidden = true } } })
    for kk, v in pairs(k) do W.knobs[kk] = v end
    W.search = "直承"                                -- 前の件の名前
    W.knobs.paneTop = "裏フェス Urafess"
    local ok, e = exportOne("Berry")
    local tag = "axDY=" .. k.axDY .. (k.focusIgnored and " 押してフォーカス" or "") ..
                (k.searchUnread and " 読めない" or "") .. (k.searchShowsHint and " 表示" or "")
    check(ok and W.saved and W.saved:find("[LINE]Berry_", 1, true), tag .. ": 書き出した: " .. tostring(e and e.msg))
    check(W.search == "Berry", tag .. ": 検索した")
    if k.focusIgnored then
      local f, hit = layout().field, false
      for _, c in ipairs(W.clicks) do
        if c.x >= f.x and c.x <= f.x + f.w and c.y >= f.y and c.y <= f.y + f.h then hit = true end
      end
      check(hit, tag .. ": 画面の検索欄を押した")
    end
    safe()
  end
end)

test("ずれを測れない時は、検索欄のつもりで一覧の行を押さない（AX で名前だけ入れる）", function()
  reset({ chats = { { name = "直承Jikisho" }, { name = "Berry", hidden = true } },
          knobs = { axDY = 30, searchUnread = true, focusIgnored = true } })
  W.search = "直承"
  local ok = exportOne("Berry")
  check(W.searchSetByAX, "AX で名前を入れた")
  check(#W.openLog == 0 or W.openLog[1] == "Berry", "別のトークを開いていない: " .. table.concat(W.openLog, ","))
  check(not W.saved or W.saved:find("[LINE]Berry_", 1, true), "別のトークを保存していない")
  safe()
end)

test("窓表示の実機: 検索欄に入れた文字が写らず、すぐ下の結果の行に同じ名前がある時、ずれを結果の行で測らない", function()
  for _, k in ipairs({ { axDY = 0, searchShowsHint = true, magnifier = true },
                       { axDY = 0, searchShowsHint = true },
                       { axDY = 0, searchUnread = true, magnifier = true },
                       { axDY = 30, searchShowsHint = true, magnifier = true },
                       { axDY = 30, searchUnread = true, magnifier = true } }) do
    -- Berry は普段の一覧に無く、検索して出てくる（検索欄のすぐ下の結果の行に名前が出る）
    reset({ chats = { { name = "直承Jikisho" }, { name = "Berry", hidden = true } } })
    for kk, v in pairs(k) do W.knobs[kk] = v end
    local M = load(); W.logs = {}
    local ok = M.check("Berry")
    local out = table.concat(W.logs, "\n")
    local tag = "axDY=" .. k.axDY .. (k.searchShowsHint and " 検索の表示" or " 読めない") .. (k.magnifier and " 虫眼鏡" or "")
    check(ok, tag .. ": 確かめられた:\n" .. out)
    check(not out:find("ずれ %+[1-9]"), tag .. ": 下へのずれと測っていない:\n" .. out)
    safe()
  end
end)

test("ずれは毎回測る（同じ実行の中でフルスクリーンから窓表示に変わっても合わせる）", function()
  reset({ chats = chats({ "Berry", "直承Jikisho" }) })
  W.knobs.axDY = 30
  W.knobs.paneTop = "裏フェス Urafess"             -- 前のずれのまま探すと、ヘッダをこれと取り違える
  local M = load()
  local app = assert(M._t.prepareApp())
  M._t.beginRun(app)
  local ok1 = M._t.exportOne(app, "Berry")
  W.knobs.axDY = 0
  local ok2 = M._t.exportOne(app, "直承Jikisho")
  M._t.endRun()
  check(ok1 and ok2, "どちらも書き出した")
  safe()
end)

test("幅の無いセルを一覧とトーク欄の境目に使わない（実機: 右端 x=0 のセルで全件を見失った）", function()
  -- 実機と同じく、一覧の AX のセルはその1個だけ（検索結果の行は AX に出ない）
  reset({ chats = { { name = "直承Jikisho", noAX = true }, { name = "Berry", noAX = true } } })
  W.knobs.bogusCell = true; W.knobs.axDY = 30
  local ok, e = exportOne("Berry")
  check(ok, "書き出した: " .. tostring(e and e.msg))
  local M = load(); W.logs = {}
  M.diag()
  local out = table.concat(W.logs, "\n")
  check(not out:find("境目 x=0（", 1, true) and out:find("境目 x=", 1, true), "境目が x=0 でない:\n" .. out)
  check(out:find("ずれ %-30pt") , "ずれを診断に出す:\n" .. out)
end)

test("検索欄の文字の照合（OCR の読み違い・虫眼鏡のアイコンが付いても同じ）", function()
  reset()
  local M = load()
  local n, same = M._t.norm, M._t.sameText
  check(same(n("H Village"), n("Q H Village")), "アイコンが前に付く")
  check(same(n("il 石川ありがとう"), n("i1 石川ありがとう")), "1字の読み違い")
  check(not same(n("Berry"), n("すべて")), "別の文字")
  check(not same(n("村田研"), n("村田研の会議の議事録とその他のメモ")), "長すぎる文字は別物")
end)

test("部分一致の候補は、名前より余分な字が少ない順（絵文字を OCR が1字に読んだトークが先）", function()
  reset({ chats = { { name = "パプリカ定例会" },
                    { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true } } })
  local ok = exportOne("パプリカ")
  check(ok and W.saved and W.saved:find("[LINE]パプリカ🌶️_", 1, true), "パプリカ🌶️ を保存: " .. tostring(W.saved))
  -- 絵文字だけ違うので、残りの候補が別のトークだと確かめてから開き直して保存する
  check(table.concat(W.openLog, ",") == "パプリカ🌶️,パプリカ定例会,パプリカ🌶️", "順に開いた: " .. table.concat(W.openLog, ","))
  check(not exists(OUT .. "/[LINE]パプリカ定例会_" .. TODAY .. ".txt"), "別のトークは保存していない")
  safe()
end)

test("名前が絵文字だけ違うトーク（パプリカ🌶️ と パプリカ🍅）があれば、絵文字の無い TARGETS では決めずに止める", function()
  reset({ chats = { { name = "パプリカ🍅", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true },
                    { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true } } })
  local ok, e = exportOne("パプリカ")
  check(not ok and e.msg:find("合わない", 1, true) and tostring(e.detail):find("絵文字", 1, true),
    "止めた: " .. tostring(e and e.msg) .. " " .. tostring(e and e.detail))
  check(not W.saved, "どちらも保存していない")
  safe()
end)

test("TARGETS に絵文字まで書けば（パプリカ🌶️）、パプリカ🍅 と区別して書き出す", function()
  reset({ chats = { { name = "パプリカ🍅", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true },
                    { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true } } })
  local ok = exportOne("パプリカ🌶️")
  check(ok and W.saved and W.saved:find("[LINE]パプリカ🌶️_", 1, true), "パプリカ🌶️ を保存: " .. tostring(W.saved))
  safe()
end)

test("部分一致で先に開いたのが別のトークなら、保存せずに次の候補を開いて保存する", function()
  reset({ chats = { { name = "パプリカ会" },
                    { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true } } })
  local ok = exportOne("パプリカ")
  check(ok and W.saved and W.saved:find("[LINE]パプリカ🌶️_", 1, true), "パプリカ🌶️ を保存: " .. tostring(W.saved))
  check(table.concat(W.openLog, ",") == "パプリカ会,パプリカ🌶️", "順に開いた: " .. table.concat(W.openLog, ","))
  check(W.cancelled, "別のトークの保存ダイアログはキャンセルした")
  check(not exists(OUT .. "/[LINE]パプリカ会_" .. TODAY .. ".txt"), "別のトークは保存していない")
  safe()
end)

test("部分一致の候補は3件まで（それ以上は開かない）", function()
  reset({ chats = chats({ "村田研A", "村田研B", "村田研C", "村田研D" }) })
  local ok, e = exportOne("村田研")
  check(not ok and e.msg:find("合わない", 1, true), "保存名で止める: " .. tostring(e and e.msg))
  check(#W.openLog == 3, "3件まで: " .. table.concat(W.openLog, ","))
  check(not W.saved, "保存していない")
  safe()
end)

test("名前の絵文字を OCR が同じ字に読み違えても、AX で選んだ行のトークなら通す", function()
  reset({ chats = { { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》（82]" } } })
  local ok = exportOne("パプリカ")
  check(ok and W.axPressed == "パプリカ🌶️", "AX の行を押して書き出した")
  safe()
end)

test("H Village と【H Village 全体連絡】: 完全一致の方を開く", function()
  reset({ chats = { { name = "【H Village 全体連絡】" }, { name = "H Village", ocrRow = "H ViIIage" } } })
  local ok = exportOne("H Village")
  check(ok and W.saved:find("[LINE]H Village_", 1, true), "H Village を保存: " .. tostring(W.saved))
  safe()
end)

test("前の件の保存ダイアログが残っていたらキャンセルしてから進む", function()
  reset({ chats = chats({ "Berry", "直承Jikisho" }) })
  W.open = "直承Jikisho"; W.sheet = { value = "[LINE]直承Jikisho.txt" }; W.focus = "sheet"
  W.focusedOther = true                            -- シートがキー窓になっている
  local ok = exportOne("Berry")
  check(W.cancelled, "残っていたダイアログをキャンセルした")
  check(ok and W.saved:find("[LINE]Berry_", 1, true), "Berry を保存した")
  safe()
end)

test("別のトークが開いたらヘッダ確認で止める", function()
  reset({ chats = chats({ "Berry", "直承Jikisho" }), knobs = { wrongChatOnClick = "直承Jikisho" } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "トーク確認", "トーク確認で失敗: " .. tostring(e and e.stage))
  check(e.detail and e.detail:find("ヘッダ行", 1, true) and e.detail:find("■", 1, true)
        and not e.detail:find("Jikisho", 1, true), "ヘッダに見えた名前は伏せ字で detail に: " .. tostring(e.detail))
  check(not e.msg:find("直承Jikisho", 1, true), "公開される msg には画面の文字を入れない")
  check(e.imgPath and e.imgPath:sub(1, #DEBUG) == DEBUG and exists(e.imgPath),
    "撮影画像をリポジトリの外（Dropbox の line-dump-debug）に残す: " .. tostring(e.imgPath))
  check(e.img and e.img:find("^Dropbox の ") and not e.img:find(HOME, 1, true), "heartbeat に書く形はユーザー名を含まない: " .. tostring(e.img))
  check(e.layout and #e.layout > 0, "失敗した時の画面の並び（伏せ字）を付ける")
  for _, l in ipairs(e.layout or {}) do
    check(not l:find("Jikisho", 1, true) and not l:find("最後のメッセージ", 1, true), "並びも伏せ字: " .. l)
  end
  check(#W.menuClicked == 0 and not W.menuOpen and not W.sheet, "メニューも保存も触っていない")
  safe()
end)

test("ヘッダの下のメッセージに目的の名前があっても、別トークは通さない", function()
  reset({ chats = { { name = "Berry" },
                    { name = "直承Jikisho", messages = { { s = "Berry", dx = 500, dy = 120 } } } },
          knobs = { wrongChatOnClick = "直承Jikisho" } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "トーク確認", "トーク確認で失敗: " .. tostring(e and e.stage))
  check(#W.menuClicked == 0, "メニューを押していない")
  safe()
end)

test("⋮ が少しずれていたら1回だけずらして押し直す", function()
  reset({ chats = chats({ "Berry" }), knobs = { menuDX = -6, menuDY = 6 } })
  local ok = exportOne("Berry")
  check(ok, "2回目で成功")
  safe()
end)

test("⋮ でメニューが出なければ止める（本文の「トークを保存」は押さない）", function()
  -- 自分の吹き出しは右寄せ＝メニューの範囲の中に出る
  reset({ chats = { { name = "Berry", messages = { { s = "トークを保存", dx = SCREEN.w - 140, dy = 200 } } } },
          knobs = { menuBroken = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "メニュー", "メニューで失敗: " .. tostring(e and e.stage))
  check(e.msg:find("メニューが出ない", 1, true), "メニューが出ない旨: " .. tostring(e.msg))
  for _, c in ipairs(W.clicks) do
    check(not (math.abs(c.x - (W.win.x + SCREEN.w - 140)) < 30 and math.abs(c.y - (W.win.y + 200)) < 20),
      "本文の「トークを保存」を押していない")
  end
  safe()
end)

test("メニューの範囲の外にある「トークを保存」は押さない", function()
  -- ⋮ を押した直後に、本文に「トークを保存」を含む通知が範囲の外に届いた
  reset({ chats = chats({ "Berry" }),
          knobs = { menuBroken = true, bannerAfterDots = { s = "トークを保存", dx = 600, dy = 300 } } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "メニュー", "メニューで失敗")
  for _, c in ipairs(W.clicks) do
    check(not (math.abs(c.x - (W.win.x + 600)) < 30 and math.abs(c.y - (W.win.y + 300)) < 20),
      "範囲外の「トークを保存」を押していない")
  end
  safe()
end)

test("本文に「トークを保存」があっても、メニューの方を押す", function()
  reset({ chats = { { name = "Berry", messages = { { s = "トークを保存", dx = SCREEN.w - 140, dy = 150 } } } } })
  local ok = exportOne("Berry")
  check(ok, "成功する")
  check(W.menuClicked[1] == "トークを保存", "メニューの項目を押した")
  safe()
end)

test("メニューは別窓として出る（画面を撮らないと写らない）", function()
  reset({ chats = chats({ "Berry" }) })
  local ok = exportOne("Berry")
  check(ok, "画面を撮って読めた")
  local screenShots = 0
  for _, c in ipairs(W.cmds) do if c:find("screencapture -x -R", 1, true) then screenShots = screenShots + 1 end end
  check(screenShots >= 2, "メニューの前後は画面を撮った")
  safe()
end)

test("メニューに「トークを保存」が無ければ閉じて止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { menuItems = { "通知オフ", "トーク履歴を削除", "退会" } } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "メニュー", "メニューで失敗")
  check(e.msg:find("見当たらない", 1, true), "項目が無い旨: " .. tostring(e.msg))
  check(not W.menuOpen, "メニューは閉じた（Escape ではなくヘッダのトーク名で）")
  check(#W.menuClicked == 0, "メニューの項目は何も押していない")
  safe()
end)

test("ずらした2回目でだけ開いたメニューも、閉じてから止める", function()
  reset({ chats = chats({ "Berry" }),
          knobs = { menuDX = -6, menuDY = 6, menuItems = { "通知オフ", "トーク履歴を削除", "退会" } } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "メニュー", "メニューで失敗")
  check(not W.menuOpen, "開いたメニューを閉じた")
  safe()
end)

test("⋮ が読めず1回目でメニューが出なければ、隣のボタンを押さないよう押し直さずに止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { menuDX = -16, noDotsOCR = true, callOCR = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "メニュー" and e.msg:find("メニューが出ない", 1, true), "止めた: " .. tostring(e and e.msg))
  check(not W.called, "通話ボタンを押していない")
  local L, n = layout(), 0
  for _, c in ipairs(W.clicks) do if math.abs(c.y - L.dots.y) < 20 and c.x > L.call.x - 20 then n = n + 1 end end
  check(n == 1, "ヘッダの右端は1回だけ押した（" .. n .. " 回）")
  safe()
end)

test("⋮ が 8pt を超えて左に読めても（隣のボタンかもしれない）押し直さない", function()
  reset({ chats = chats({ "Berry" }), knobs = { menuDX = -16 } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "メニュー", "止めた: " .. tostring(e and e.stage))
  safe()
end)

test("一覧の行で開いたのが「かにっこにー (2)」だったら、保存せずに検索して「かにっこにー」を開き直す", function()
  reset({ chats = chats({ "かにっこにー (2)", "かにっこにー" }) })
  local ok = exportOne("かにっこにー")
  check(ok and W.saved and W.saved:find("[LINE]かにっこにー_", 1, true), "かにっこにー を保存: " .. tostring(W.saved))
  check(W.cancelled, "かにっこにー (2) のダイアログはキャンセルした")
  check(#lsdir(DEBUG) == 0 or not table.concat(lsdir(DEBUG), ","):find("保存ダイアログ", 1, true),
    "別のトークの撮影は残さない: " .. table.concat(lsdir(DEBUG), ","))
  safe()
end)

test("別のトークの保存ダイアログが閉じなければ、次の候補へ進まない", function()
  reset({ chats = chats({ "かにっこにー3", "かにっこにー4" }), knobs = { cancelIgnored = true } })
  local ok, e = exportOne("かにっこにー")
  check(not ok and e.msg:find("合わない", 1, true), "止めた: " .. tostring(e and e.msg))
  check(#W.openLog == 1 and W.clickN == W.clickAtCancel, "次の候補を押していない: " .. table.concat(W.openLog, ","))
  check(not W.saved, "保存していない")
end)

test("OCR が「トークを保存」を読めなければ押さずに止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { ocrDrop = { ["トークを保存"] = true } } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "メニュー", "メニューで失敗")
  check(#W.menuClicked == 0, "当てずっぽうで押していない")
  safe()
end)

test("保存名がトーク名と合わなければキャンセルして止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { defaultName = "[LINE]直承Jikisho.txt" } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "保存ダイアログ", "保存ダイアログで失敗: " .. tostring(e and e.stage))
  check(W.cancelled and not W.sheet and not W.saved, "キャンセルを押し、保存していない")
  check(not e.msg:find("Jikisho", 1, true) and not e.detail:find("Jikisho", 1, true)
        and e.detail:find("[LINE]■9字.txt", 1, true), "別トーク名は伏せ字（字数だけ）: " .. tostring(e.detail))
  safe()
end)

test("トークの保存ダイアログに見えなければ、何も打たずに閉じる", function()
  -- 名前は [LINE] で始まるが「保存」ボタンが無い（別のダイアログ）
  reset({ chats = chats({ "Berry" }), knobs = { saveTitle = "OK" } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "保存ダイアログ" and e.msg:find("保存ダイアログに見えない", 1, true),
    "保存ダイアログで失敗: " .. tostring(e and e.msg))
  check(not W.pressedSave and W.cancelled, "保存は押さずにキャンセルした")
  for _, k in ipairs(W.keys) do check(k ~= "+right", "名前欄にキーを送っていない") end
  safe()
end)

test("名前に / があるトーク（保存ファイル名では : になる）", function()
  reset({ chats = chats({ "オーチュー/小林央忠" }) })
  local ok, dst = exportOne("オーチュー/小林央忠")
  check(ok, "成功する: " .. tostring(type(dst) == "table" and dst.msg or dst))
  check(W.saved == HOME .. "/Downloads/[LINE]オーチュー:小林央忠_" .. TODAY .. ".txt", "保存は : で: " .. tostring(W.saved))
  check(dst == OUT .. "/[LINE]オーチュー_小林央忠_" .. TODAY .. ".txt" and exists(dst), "OUT_DIR では _ にそろえる: " .. tostring(dst))
  safe()
end)

test("保存名の / が _ に化けていても同じトークとみなす", function()
  reset({ chats = chats({ "オーチュー/小林央忠" }), knobs = { defaultName = "[LINE]オーチュー_小林央忠.txt" } })
  local ok, dst = exportOne("オーチュー/小林央忠")
  check(ok, "成功する")
  check(dst == OUT .. "/[LINE]オーチュー_小林央忠_" .. TODAY .. ".txt", "日付付きで移した: " .. tostring(dst))
  safe()
end)

test("名前欄の日付は →キー＋貼り付けで足す（AX で入れ直さない）", function()
  reset({ chats = chats({ "Berry" }), knobs = { sheetIgnoresAXSet = true } })
  local ok = exportOne("Berry")
  check(ok, "成功する")
  check(W.saved == HOME .. "/Downloads/[LINE]Berry_" .. TODAY .. ".txt", "日付付きで保存: " .. tostring(W.saved))
  safe()
end)

test("名前欄に貼り付けが効かなければ AX で入れ直す", function()
  reset({ chats = chats({ "Berry" }), knobs = { sheetIgnoresPaste = true } })
  local ok = exportOne("Berry")
  check(ok, "成功する")
  check(W.saved == HOME .. "/Downloads/[LINE]Berry_" .. TODAY .. ".txt", "日付付きで保存: " .. tostring(W.saved))
  safe()
end)

test("名前欄に日付を足せなくても、移すときに付ける", function()
  reset({ chats = chats({ "Berry" }), knobs = { sheetIgnoresPaste = true, sheetIgnoresAXSet = true } })
  local ok, dst = exportOne("Berry")
  check(ok, "成功する")
  check(W.saved == HOME .. "/Downloads/[LINE]Berry.txt", "既定名で保存された")
  check(dst == OUT .. "/[LINE]Berry_" .. TODAY .. ".txt" and exists(dst), "移すときに日付を付けた")
  safe()
end)

test("保存先が OUT_DIR ならそのまま（他のフォルダは見に行かない）", function()
  reset({ chats = chats({ "Berry" }), knobs = { saveDir = OUT } })
  local ok, dst = exportOne("Berry")
  check(ok and dst == OUT .. "/[LINE]Berry_" .. TODAY .. ".txt" and exists(dst), "OUT_DIR に今日付き")
  check(not W.mdfindUsed, "Spotlight で探していない")
  safe()
end)

test("同名があれば「置き換える」を押す", function()
  reset({ chats = chats({ "Berry" }) })
  writefile(HOME .. "/Downloads/[LINE]Berry_" .. TODAY .. ".txt", "前回分")
  local ok = exportOne("Berry")
  check(ok and W.replaced, "置き換えて成功")
  safe()
end)

test("上書き確認の「置き換え」表記でも押す", function()
  reset({ chats = chats({ "Berry" }), knobs = { replaceTitle = "置き換え" } })
  writefile(HOME .. "/Downloads/[LINE]Berry_" .. TODAY .. ".txt", "前回分")
  local ok = exportOne("Berry")
  check(ok and W.replaced, "置き換えて成功")
  safe()
end)

test("日付を付けられず同名があるときは、上書きせずに止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { sheetIgnoresPaste = true, sheetIgnoresAXSet = true, saveDir = OUT } })
  writefile(OUT .. "/[LINE]Berry.txt", "過去の書き出し")
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "保存", "保存で失敗: " .. tostring(e and e.stage))
  check(readfile(OUT .. "/[LINE]Berry.txt") == "過去の書き出し", "過去の書き出しは無事")
  check(not W.replaced and W.alertCancelled and not W.sheet, "上書き確認→保存ダイアログの順にキャンセルした")
  safe()
end)

test("上書き確認が残ったままでも、次の件の前に両方閉じる", function()
  reset({ chats = chats({ "Berry", "直承Jikisho" }) })
  W.open = "直承Jikisho"
  W.sheet = { value = "[LINE]直承Jikisho.txt", confirm = HOME .. "/Downloads/x.txt" }; W.focus = "sheet"
  local ok = exportOne("Berry")
  check(W.alertCancelled and W.cancelled, "内側→外側の順に閉じた")
  check(ok, "続けて成功")
  safe()
end)

test("古い同名ファイルより、今保存した方を拾う", function()
  reset({ chats = chats({ "Berry" }), knobs = { saveDir = HOME .. "/Desktop" } })
  local stale = HOME .. "/Downloads/[LINE]Berry_" .. TODAY .. ".txt"
  writefile(stale, "古い")
  age(stale, 2 * 86400)
  local ok, dst = exportOne("Berry")
  check(ok, "成功する")
  check(readfile(dst) and readfile(dst):find("テスト", 1, true), "Desktop の新しい方を移した")
  check(exists(stale), "古い方には触らない")
  safe()
end)

test("候補のフォルダに無ければ Spotlight で探し、古い方は拾わない", function()
  reset({ chats = chats({ "Berry" }) })
  run("mkdir -p " .. sh(HOME .. "/Elsewhere") .. " " .. sh(HOME .. "/Old"))
  W.knobs.saveDir = HOME .. "/Elsewhere"
  local stale = HOME .. "/Old/[LINE]Berry_" .. TODAY .. ".txt"
  writefile(stale, "古い"); age(stale, 3 * 86400)
  W.knobs.mdfind = stale .. "\n" .. HOME .. "/Elsewhere/[LINE]Berry_" .. TODAY .. ".txt\n"
  local ok, dst = exportOne("Berry")
  check(ok and readfile(dst):find("テスト", 1, true), "新しい方を移した")
  check(readfile(stale) == "古い", "古い方には触らない")
  safe()
end)

test("保存してもファイルが見つからなければ止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { mtimeAgo = 2 * 86400 } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "移動", "移動で失敗: " .. tostring(e and e.stage))
  safe()
end)

test("Linetxt に移せなければ OK にしない（ファイルとフォルダの許可）", function()
  reset({ chats = chats({ "Berry" }), knobs = { moveFails = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "移動" and e.msg:find("アクセス許可", 1, true), "移動で失敗: " .. tostring(e and e.msg))
  check(not exists(OUT .. "/[LINE]Berry_" .. TODAY .. ".txt"), "Linetxt には無い")
  safe()
end)

test("保存ダイアログが閉じなければキャンセルして止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { saveFails = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "保存", "保存で失敗: " .. tostring(e and e.stage))
  check(not W.sheet and W.cancelled, "ダイアログはキャンセルで閉じた")
  safe()
end)

test("検索欄が一時的に読めなくても、開き直して続ける", function()
  reset({ chats = chats({ "Berry" }), knobs = { fieldHiddenUntilReopen = true } })
  local ok = exportOne("Berry")
  check(ok, "成功する")
  check(W.opens == 1, "open -b で1回開き直した")
  safe()
end)

test("窓が閉じていたら open -b で開き直す（Escape は使わない）", function()
  reset({ chats = chats({ "Berry" }) })
  W.win.visible = false
  local ok = exportOne("Berry")
  check(ok and W.opens >= 1, "開き直して成功")
  safe()
end)

test("検索欄が最後まで読めなければ「窓」で止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { fieldHiddenUntil = 99 } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "窓", "窓で失敗: " .. tostring(e and e.stage))
  check(#W.clicks == 0, "何も押していない")
  safe()
end)

test("AX でフォーカスが入らなければ検索欄を押してから打つ", function()
  reset({ chats = { { name = "Berry", hidden = true } }, knobs = { focusIgnored = true } })
  local ok = exportOne("Berry")
  check(ok and W.search == "Berry", "検索欄を押してフォーカスを入れた")
  safe()
end)

test("検索欄にフォーカスが入らなければ、何も打たずに止める", function()
  reset({ chats = { { name = "Berry", hidden = true } }, knobs = { focusIgnored = true, clickNoFocus = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "検索欄", "検索欄で失敗: " .. tostring(e and e.stage))
  for _, k in ipairs(W.keys) do check(k ~= "cmd+a" and k ~= "cmd+v", "キーを送っていない: " .. k) end
  safe()
end)

test("貼り付けが検索欄に入らなければ AX で値を入れる（キーは打ち直さない）", function()
  reset({ chats = { { name = "直承Jikisho" }, { name = "Berry", hidden = true } }, knobs = { searchIgnoresPaste = true } })
  local ok = exportOne("Berry")
  check(ok and W.search == "Berry" and W.searchSetByAX, "AX で入れて成功")
  for _, k in ipairs(W.keys) do check(not k:find("^type:"), "キー入力で打ち直していない: " .. k) end
  safe()
end)

test("OCR で行が読めなければ AX のセルで開く（ヘッダ確認は通す）", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }), knobs = { ocrDropRows = true } })
  local ok = exportOne("Berry")
  check(ok and W.axPressed == "Berry", "AX で Berry を開いた")
  safe()
end)

test("AX の行を押せなければ、その行の位置をクリックする", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }), knobs = { ocrDropRows = true, axPressFails = true } })
  local ok = exportOne("Berry")
  check(ok, "クリックで開いて成功")
  safe()
end)

test("AX で完全一致の行を開いたのに別トークが開いたら止める（ヘッダは前方一致で通っても保存名で止まる）", function()
  reset({ chats = chats({ "かにっこにー3", "かにっこにー" }),
          knobs = { ocrDropRows = true, wrongChatOnClick = "かにっこにー3" } })
  local ok, e = exportOne("かにっこにー")
  check(not ok and (e.stage == "トーク確認" or (e.stage == "保存ダイアログ" and e.msg:find("合わない", 1, true))),
    "トーク確認か保存名で失敗: " .. tostring(e and e.stage))
  check(not W.saved and not W.sheet, "保存していない（ダイアログは閉じた）")
  safe()
end)

test("検索結果に無ければトーク選択で止める", function()
  reset({ chats = chats({ "直承Jikisho" }) })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "トーク選択", "トーク選択で失敗: " .. tostring(e and e.stage))
  check(e.imgPath and exists(e.imgPath), "撮影画像を残す")
  safe()
end)

test("絵文字・メンバー数付きの名前（パプリカ🌶️（82））", function()
  reset({ chats = { { name = "パプリカ🌶️", ocrHeader = "パプリカ🌶️（82）" } } })
  local ok, dst = exportOne("パプリカ")
  check(ok, "成功する")
  check(dst == OUT .. "/[LINE]パプリカ🌶️_" .. TODAY .. ".txt", "保存名: " .. tostring(dst))
  safe()
end)

test("画面の座標換算（窓が画面の途中にあっても押す所が合う）", function()
  reset({ chats = chats({ "Berry" }), knobs = { noResize = true } })
  W.win.x, W.win.y = 300, 140
  local ok = exportOne("Berry")
  check(ok, "最大化できない窓でも成功")
  safe()
end)

test("「かにっこにー」を押したのに「かにっこにー3」が開いたら止める（ヘッダは前方一致で通っても保存名で止まる）", function()
  reset({ chats = chats({ "かにっこにー3", "かにっこにー" }), knobs = { wrongChatOnClick = "かにっこにー3" } })
  local ok, e = exportOne("かにっこにー")
  check(not ok and (e.stage == "トーク確認" or (e.stage == "保存ダイアログ" and e.msg:find("合わない", 1, true))),
    "トーク確認か保存名で失敗: " .. tostring(e and e.stage))
  check(not W.saved and not W.sheet, "保存していない（ダイアログは閉じた）")
  safe()
end)

test("完全一致の行から開いたのに保存名が前方一致なら止める", function()
  reset({ chats = chats({ "かにっこにー" }), knobs = { defaultName = "[LINE]かにっこにー3.txt" } })
  local ok, e = exportOne("かにっこにー")
  check(not ok and e.stage == "保存ダイアログ", "保存ダイアログで失敗: " .. tostring(e and e.stage))
  check(W.cancelled and not W.saved, "キャンセルして保存していない")
  check(e.imgPath and exists(e.imgPath), "閉じる前の画面を残した")
  safe()
end)

test("英語表示の保存名（[LINE] Chat with ○○.txt）も同じトークとみなす", function()
  reset({ chats = chats({ "Berry" }), knobs = { defaultName = "[LINE] Chat with Berry.txt" } })
  local ok = exportOne("Berry")
  check(ok, "成功する")
  safe()
end)

test("通知バナーに同じ名前が出ていても、ヘッダは LINE の窓から読む", function()
  reset({ chats = { { name = "パプリカ🌶️", ocrHeader = "パプリカ（82）" } } })
  W.banners = { { s = "パプリカ（82）", dx = 1250, dy = 30 } }
  local ok = exportOne("パプリカ")
  check(ok, "成功する（バナーの位置で ⋮ を押していない）")
  safe()
end)

test("検索結果に完全一致が2行あり、1行目で別のトークが開いたら2行目を試す", function()
  -- 検索結果の「メッセージ」の行など、同じ名前の行が上にあって、押すと別の物が開く
  reset({ chats = { { name = "直承Jikisho" }, { name = "Berry", hidden = true }, { name = "Berry", hidden = true, preview = "別の行" } },
          knobs = { wrongChatOnce = "直承Jikisho" } })
  local ok, e = exportOne("Berry")
  check(ok, "2行目で成功: " .. tostring(type(e) == "table" and e.msg or e))
  safe()
end)

test("通知バナーがヘッダと同じ高さに目的の名前を出していても、別トークが開いたら止める", function()
  -- バナーは画面を撮ると写る。ヘッダは LINE の窓だけを撮って読む
  reset({ chats = chats({ "Berry", "直承Jikisho" }), knobs = { wrongChatOnClick = "直承Jikisho" } })
  W.banners = { { s = "Berry", dx = 900, dy = 64 } }
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "トーク確認", "トーク確認で止める: " .. tostring(e and e.stage))
  check(#W.menuClicked == 0, "メニューを押していない")
  safe()
end)

test("押す所に通知などが重なっていたら押さずに止める", function()
  reset({ chats = chats({ "Berry" }) })
  -- 画面右上（⋮ のあたり）に通知が出ている
  W.overlays = { { dx = SCREEN.w - 360, dy = 20, w = 360, h = 90 } }
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "クリック", "クリックで失敗: " .. tostring(e and e.stage))
  safe()
end)

test("Hammerspoon のコンソールが「常に手前」で ⋮ に重なっていても、実行中だけ外して押し、終わったら戻す", function()
  reset({ chats = chats({ "Berry" }) })
  W.consoleOnTop = true
  W.overlays = { { console = true, dx = SCREEN.w - 180, dy = 40, w = 180, h = 800 } }   -- 実機: 右側に縦長
  local ok, e = exportOne("Berry")
  check(ok and W.saved, "⋮ を押して保存した: " .. tostring(e and e.msg))
  check(not W.clickedOverlay, "コンソールを押していない")
  check(W.consoleOnTop == true, "終わったら「常に手前」に戻した")
  check(not W.consoleMinimizedN, "「常に手前」を外すだけで足り、最小化はしていない")
  safe()
end)

test("「常に手前」でなくてもコンソールが重なっていれば、最小化して押し、終わったら戻す", function()
  reset({ chats = chats({ "Berry" }) })
  W.overlays = { { console = true, covers = true, dx = SCREEN.w - 180, dy = 40, w = 180, h = 800 } }
  local ok, e = exportOne("Berry")
  check(ok and W.saved, "保存した: " .. tostring(e and e.msg))
  check(W.consoleMinimizedN == 1 and not W.consoleMinimized, "最小化して、終わったら戻した")
  safe()
end)

test("通知のバナーが重なっていたら、消えるまで待って押す", function()
  reset({ chats = chats({ "Berry" }) })
  W.overlays = { { dx = SCREEN.w - 360, dy = 20, w = 360, h = 90, untilT = T + 4 } }
  local ok, e = exportOne("Berry")
  check(ok and W.saved, "待ってから押して保存した: " .. tostring(e and e.msg))
  check(not W.clickedOverlay, "バナーを押していない")
  safe()
end)

test("消えない物が重なっていたら押さずに止め、何が重なっていたかを書く", function()
  reset({ chats = chats({ "Berry" }), knobs = { pidNames = { [OTHER_PID] = "Dropbox" } } })
  W.overlays = { { dx = SCREEN.w - 360, dy = 20, w = 360, h = 90 } }
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "クリック" and e.msg:find("（Dropbox）", 1, true), "名前を書いて止めた: " .. tostring(e and e.msg))
  check(not W.clickedOverlay, "押していない")
end)

test("LINE の補助プロセスの部品は、LINE 以外の物とみなさない", function()
  reset({ chats = chats({ "Berry" }), knobs = { helperPid = 4300 } })
  local ok, e = exportOne("Berry")
  check(ok and W.saved, "保存した: " .. tostring(e and e.msg))
  safe()
end)

test("LINE が前面に来なければ、何も打ち込まずに止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { frontIsOther = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "窓", "窓で失敗: " .. tostring(e and e.stage))
  check(not W.typedElsewhere, "他のアプリにキーを送っていない")
  check(W.clipboard == "ORIGINAL", "クリップボードにも触っていない")
end)

test("途中で他のアプリが前に出たら、そのアプリには打ち込まない（検索の後）", function()
  reset({ chats = { { name = "直承Jikisho" }, { name = "Berry", hidden = true } }, knobs = { frontLostAfterPaste = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "クリック", "クリックで失敗: " .. tostring(e and e.stage))
  check(not W.typedElsewhere and not W.clickedElsewhere, "他のアプリを操作していない")
  check(W.clipboard == "ORIGINAL", "クリップボードは戻した")
end)

test("途中で他のアプリが前に出たら、そのアプリには打ち込まない（保存ダイアログ）", function()
  reset({ chats = chats({ "Berry" }), knobs = { frontLostOnSheet = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "クリック", "クリックで失敗: " .. tostring(e and e.stage))
  check(not W.typedElsewhere and not W.clickedElsewhere, "他のアプリを操作していない")
end)

test("別窓（ポップアウトしたトーク）がキー窓なら、メイン窓を前に出してから打つ", function()
  reset({ chats = chats({ "Berry" }) })
  W.focusedOther = true
  local ok = exportOne("Berry")
  check(ok, "成功する")
  safe()
end)

test("メイン窓をキー窓にできなければ止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { cannotFocus = true } })
  W.focusedOther = true
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "窓", "窓で失敗: " .. tostring(e and e.stage))
  check(W.search == "", "検索欄にも打っていない")
end)

test("OCR が動かなければ「OCR」の段で止める（別トーク扱いにしない）", function()
  reset({ chats = chats({ "Berry" }), knobs = { ocrFails = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "OCR", "OCR で失敗: " .. tostring(e and e.stage))
  check(e.detail and e.detail:find("Vision", 1, true), "osascript のエラーは detail に: " .. tostring(e.detail))
  safe()
end)

-- ===================== 一覧の上から順に書き出す =====================
local function namesTxt() return readfile(DEBUG .. "/names.txt") or "" end
local function outFiles()                          -- OUT_DIR の今日付きの書き出し（名前の順）
  local t = {}
  for _, n in ipairs(lsdir(OUT)) do if n:find("_" .. TODAY .. "%.txt$") then t[#t + 1] = n end end
  table.sort(t)
  return t
end
local function has(name) return exists(OUT .. "/[LINE]" .. name .. "_" .. TODAY .. ".txt") end
local function numbered(n, preview)
  local list = {}
  for i = 1, n do list[#list + 1] = { name = "トーク" .. i .. "番", preview = preview and ("秘密のメッセージ" .. i) or nil } end
  return list
end

test("毎日の書き出しは、普段の一覧の上から 20 件を順に開き、LINE の保存名のまま保存する", function()
  reset({ chats = numbered(30, true) })
  local M = load()
  W.search = "前の検索"
  local r = M._t.runExport(true)
  check(r == "done", "最後まで: " .. tostring(r))
  local all = true
  for i = 1, 20 do if not has("トーク" .. i .. "番") then all = false end end
  check(all and not has("トーク21番") and #outFiles() == 20, "上から 20 件だけ保存した: " .. table.concat(outFiles(), ","))
  local order = true
  for i = 1, 20 do if W.openLog[i] ~= "トーク" .. i .. "番" then order = false end end
  check(order and #W.openLog == 20, "上から順に開いた: " .. table.concat(W.openLog, ","))
  local hb = heartbeat()
  check(line(hb, "ok: 20") and line(hb, "ng: 0"), "heartbeat の数:\n" .. hb)
  check(not hb:find("トーク", 1, true), "heartbeat（公開）にトーク名を書かない:\n" .. hb)
  local nt = namesTxt()
  check(nt:find("\n1. [LINE]トーク1番_" .. TODAY .. ".txt\t保存した\n", 1, true)
        and nt:find("\n20. [LINE]トーク20番_", 1, true), "names.txt に今日保存したトーク:\n" .. nt)
  check(not nt:find("秘密", 1, true), "最後のメッセージは書かない")
  check(W.synced == 1, "取り込んで push した")
  safe()
end)

test("点単位で一覧が動かなくても、行単位で送って 20 件目まで開く", function()
  for _, scale in ipairs({ 192, 10 }) do           -- 1行で3行ぶん動くアプリ・少ししか動かないアプリ
    reset({ chats = numbered(30), knobs = { pixelScrollIgnored = true, lineScale = scale } })
    local M = load()
    M._t.runExport(true)
    check(#outFiles() == 20 and has("トーク20番") and not has("トーク21番"),
      "1行=" .. scale .. "pt でも 20 件: " .. table.concat(outFiles(), ","))
    -- 1行の量を測って一覧の高さの 8 割ずつ送る（1行ずつ少しずつ送り続けない）
    check((W.scrolls or 0) <= 12, "1行=" .. scale .. "pt: 送った回数 " .. tostring(W.scrolls))
    safe()
  end
end)

test("一覧が 20 件より短ければ、あるだけ保存して終える（送っても動かない＝一覧の終わり）", function()
  reset({ chats = numbered(5) })
  local M = load()
  local r = M._t.runExport(true)
  check(r == "done" and #outFiles() == 5, "5 件: " .. table.concat(outFiles(), ","))
  check(line(heartbeat(), "ng: 0"), "失敗にしない:\n" .. heartbeat())
  safe()
end)

test("「トークを保存」が無いトーク（Keep メモ など）は飛ばし、失敗に数えない", function()
  local list = numbered(4)
  list[2].menuItems = { "通知オフ", "トーク履歴を削除" }
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  check(#outFiles() == 3 and not has("トーク2番"), "残りは保存した: " .. table.concat(outFiles(), ","))
  check(line(heartbeat(), "ng: 0"), "失敗に数えない:\n" .. heartbeat())
  check(namesTxt():find("2. トーク2番\t⋮ に「トークを保存」が無い", 1, true), "names.txt に飛ばした理由:\n" .. namesTxt())
  safe()
end)

test("押しても開かない行は、その行だけ失敗にして次へ進む", function()
  local list = numbered(4)
  list[3].noOpen = true
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  check(#outFiles() == 3 and not has("トーク3番"), "ほかは保存した: " .. table.concat(outFiles(), ","))
  local hb = heartbeat()
  check(line(hb, "ng: 1") and hb:find("一覧の3番目: [トーク確認]", 1, true), "その行だけ失敗:\n" .. hb)
  safe()
end)

test("同じに読める名前（パプリカ🍅 と パプリカ🌶️）の行も、それぞれ開いて保存し、送り続けない", function()
  local function pair()
    return { name = "パプリカ🍅", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true },
           { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true }
  end
  local a, b = pair()
  reset({ chats = { a, { name = "Berry" }, b } })
  local M = load()
  local r = M._t.runExport(true)
  check(r == "done" and has("パプリカ🍅") and has("パプリカ🌶️") and has("Berry"), "3 件とも: " .. table.concat(outFiles(), ","))
  check((W.scrolls or 0) <= 6, "短い一覧で送り続けない: " .. tostring(W.scrolls))
  -- 点単位で動かない一覧（実機）で、2つが1番目と4番目にある長い一覧
  a, b = pair()
  local list = numbered(30)
  table.insert(list, 1, a); table.insert(list, 4, b)
  reset({ chats = list, knobs = { pixelScrollIgnored = true } })
  M = load()
  r = M._t.runExport(true)
  check(r == "done" and #outFiles() == 20 and has("パプリカ🍅") and has("パプリカ🌶️"),
    "20 件・2つとも: " .. tostring(r) .. " " .. table.concat(outFiles(), ","))
  check((W.scrolls or 0) <= 12, "送った回数: " .. tostring(W.scrolls))
  safe()
end)

test("保存ダイアログの途中で別のアプリが前に出て止まっても、ダイアログを閉じて次の行から続ける", function()
  reset({ chats = numbered(6), knobs = { frontLostOnSheetN = 2 } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(line(hb, "ok: 5") and line(hb, "ng: 1"), "2番目だけ失敗し、残りは保存:\n" .. hb)
  check(#outFiles() == 5 and not has("トーク2番"), "保存: " .. table.concat(outFiles(), ","))
  check(not W.sheet, "保存ダイアログは閉じた")
  check(not W.typedElsewhere and not W.clickedElsewhere, "他のアプリを操作していない")
end)

test("一覧が読めなくなったら（時刻が見えない）、送り続けずに止めて失敗に書く", function()
  reset({ chats = numbered(5) })
  local M = load()
  local n0 = 0
  local orig = hs.eventtap.leftClick
  hs.eventtap.leftClick = function(pt)
    orig(pt)
    n0 = n0 + 1
    if n0 == 4 then W.knobs.noRowTimes = true end    -- 2件目を開いた後から一覧の時刻が読めない
  end
  local r = M._t.runExport(true)
  hs.eventtap.leftClick = orig
  check(r == "done" and (W.scrolls or 0) <= 4, "送り続けない: " .. tostring(r) .. " scrolls=" .. tostring(W.scrolls))
  check(heartbeat():find("一覧: [一覧] ", 1, true), "失敗に書く:\n" .. heartbeat())
end)

test("「…」で切れた名前の行も、押す前から開いていたトークなら開いたとみなす", function()
  reset({ chats = { { name = "il 石川ありがとう", ocrRow = "il 石川あり…" }, { name = "Berry" } } })
  W.open = "il 石川ありがとう"
  local M = load()
  M._t.runExport(true)
  check(has("il 石川ありがとう") and has("Berry"), "2 件とも: " .. table.concat(outFiles(), ","))
  check(line(heartbeat(), "ng: 0"), "失敗にしない:\n" .. heartbeat())
  safe()
end)

test("名前の文字が読めない行（絵文字だけの名前を OCR が何も返さない）も押して保存する", function()
  reset({ chats = { { name = "Berry" }, { name = "🐱", ocrRow = "", ocrHeader = "" }, { name = "直承Jikisho" } } })
  local M = load()
  M._t.runExport(true)
  check(has("🐱") and has("Berry") and has("直承Jikisho"), "3 件とも: " .. table.concat(outFiles(), ","))
  safe()
end)

test("「トークを保存」が無いトークを閉じる時は、ヘッダ右端のボタン（通話など）を押さない", function()
  local list = { { name = "Berry" }, { name = "母", menuItems = { "通知オフ", "トーク履歴を削除" } }, { name = "直承Jikisho" } }
  reset({ chats = list, knobs = { callOCR = true } })
  local M = load()
  M._t.runExport(true)
  check(not W.called, "通話ボタンを押していない")
  check(#outFiles() == 2, "ほかは保存: " .. table.concat(outFiles(), ","))
  local imgs = 0
  for _, f in ipairs(lsdir(DEBUG)) do if f:find("メニュー", 1, true) then imgs = imgs + 1 end end
  check(imgs == 1, "飛ばしたトークの撮影画像は最初の分だけ残す: " .. imgs)
  safe()
end)

test("保存したばかりのトークに新着が来て一番上に来ても、失敗にも 20 件にも数えない", function()
  for _, k in ipairs({ { 4, "トーク2番" }, { 7, "トーク3番" } }) do   -- k[1] 回目に押した時に k[2] に新着
    reset({ chats = numbered(30), knobs = { reorderAtClick = k[1], reorderName = k[2] } })
    local M = load()
    local r = M._t.runExport(true)
    check(r == "done" and #outFiles() == 20 and has("トーク20番"), k[2] .. ": 20 件: " .. table.concat(outFiles(), ","))
    check(line(heartbeat(), "ok: 20") and line(heartbeat(), "ng: 0"), k[2] .. ": 失敗にしない:\n" .. heartbeat())
    safe()
  end
end)

test("見えている最後の行で保存ダイアログが残っても、閉じてから下へ送って続ける", function()
  reset({ chats = numbered(30) })
  load()._t.runExport(true)
  local last = W.opensAtFirstScroll                -- 見えている最後の行（下へ送る前に開いた数）
  check(last and last >= 5, "見えている行の数: " .. tostring(last))
  for _, k in ipairs({ last - 1, last }) do
    reset({ chats = numbered(30), knobs = { frontLostOnSheetN = k } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(line(hb, "ok: 19") and line(hb, "ng: 1") and #outFiles() == 19,
      k .. " 件目で止まっても残りを保存: " .. table.concat(outFiles(), ",") .. "\n" .. hb)
    check(not W.sheet, "保存ダイアログは閉じた")
  end
end)

test("「トークを保存」が無いトークが続いたら（読み方が変わった？）、一覧の終わりまで回らずに止めて失敗に書く", function()
  local list = numbered(30)
  for i = 1, 30 do list[i].menuItems = { "通知オフ", "トーク履歴を削除" } end
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  check(#W.openLog == 8, "8 件で止めた: " .. #W.openLog)
  local hb = heartbeat()
  check(line(hb, "ng: 1") and hb:find("「トークを保存」が無いトークが 8 件続いた", 1, true), "失敗に書く:\n" .. hb)
  local imgs = 0
  for _, f in ipairs(lsdir(DEBUG)) do if f:find("番目_メニュー", 1, true) then imgs = imgs + 1 end end
  check(imgs == 2, "飛ばした行の撮影画像は最初の2件だけ: " .. imgs)
  safe()
end)

test("最初の行を押しても開かず、前から開いていた別のトークのままなら、それを代わりに保存しない", function()
  local list = numbered(5)
  list[1].noOpen = true
  reset({ chats = list })
  W.open = "トーク4番"                             -- 押す前から4番目のトークが開いている
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(line(hb, "ng: 1") and hb:find("一覧の1番目: [トーク確認]", 1, true), "1番目は開かなかった失敗:\n" .. hb)
  check(not has("トーク1番") and has("トーク4番") and #outFiles() == 4, "4番は自分の行で1回だけ: " .. table.concat(outFiles(), ","))
  safe()
end)

test("今日の結果に残す保存済みの名前は、読み込み直しても増えない", function()
  reset({ chats = chats({ "Berry", "直承Jikisho" }) })
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  writefile(REPO .. "/mac/.last_result", "day=" .. TODAY .. "\nversion=v4.1-c7f58660\nng=1\nok=Berry\n")
  for _ = 1, 3 do
    local M = load()
    W.lastHID = T - 999
    at9am(function() M._t.maybeRun() end)
  end
  local res = readfile(REPO .. "/mac/.last_result") or ""
  local n = select(2, res:gsub("\nok=", ""))
  check(n == 2, "保存済みは2件のまま: " .. n .. "\n" .. res)
  check(not res:find("とのトーク", 1, true) and not res:find("chatwith", 1, true), "別名は書かない:\n" .. res)
end)

test("前の版（名前で探していた版）が今日保存したトークは、新しい版でのやり直しで保存し直さない", function()
  reset({ chats = chats({ "Berry", "p Koyo", "パプリカ🌶️", "オーチュー/小林央忠", "直承Jikisho" }) })
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  writefile(REPO .. "/mac/.last_result", "day=" .. TODAY .. "\nversion=v4.1-c7f58660\nng=8\n" ..
    "ok=Berry\nok=p Koyo\nok=パプリカ🌶️\nok=オーチュー/小林央忠\n")
  local M = load()
  at9am(function() M._t.maybeRun() end)
  check(#outFiles() == 1 and has("直承Jikisho"), "まだの1件だけ保存した: " .. table.concat(outFiles(), ","))
  check(line(heartbeat(), "ok: 5") and line(heartbeat(), "ng: 0"), "合わせて 5 件:\n" .. heartbeat())
  safe()
end)

test("ヘッダが押す前のままなら、前のトークが「トークを保存」の無いトークでも、その行は開かなかった失敗にする", function()
  local list = numbered(4)
  list[2].menuItems = { "通知オフ", "トーク履歴を削除" }   -- Keep メモ など（保存名が分からない）
  list[3].noOpen = true
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(line(hb, "ng: 1") and hb:find("一覧の3番目: [トーク確認]", 1, true), "トーク3番の行は開かなかった失敗:\n" .. hb)
  check(namesTxt():find("\n3. トーク3番\t失敗: [トーク確認]", 1, true)
        and namesTxt():find("\n2. トーク2番\t⋮ に「トークを保存」が無い（20 件に数えない）", 1, true),
    "names.txt にも失敗と書く:\n" .. namesTxt())
  safe()
end)

test("ヘッダの名前が読めないトーク（1字・絵文字だけ）で押した行が開かなければ、前と同じ保存名で気づいて失敗にする", function()
  reset({ chats = { { name = "母" }, { name = "🐱", noOpen = true }, { name = "Berry" } } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(line(hb, "ok: 2") and line(hb, "ng: 1") and hb:find("一覧の2番目: [トーク確認]", 1, true),
    "2番目は失敗（黙って飛ばさない）:\n" .. hb)
  check(has("母") and has("Berry") and #outFiles() == 2, "ほかは保存: " .. table.concat(outFiles(), ","))
  safe()
end)

test("押した行で、この実行でもう保存したトークがまた開いたら、保存せず 20 件にも数えない", function()
  local list = numbered(21)
  list[4].opens = "トーク2番"                      -- 4番目の行を押すと（3番目から変わって）2番目のトークが開く
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  -- 同じトークは 20 件に数えないので、21 番目の行まで進んで 20 件保存する
  check(#outFiles() == 20 and has("トーク21番") and not has("トーク4番"),
    "同じトークは数えない: " .. table.concat(outFiles(), ","))
  check(line(heartbeat(), "ng: 0"), "失敗にしない:\n" .. heartbeat())
  safe()
end)

test("一覧が途中で並び替わっても（新着）、同じトークを2回保存せず、上から 20 件に入れる", function()
  reset({ chats = numbered(30), knobs = { reorderAtClick = 7, reorderName = "トーク25番" } })   -- 3件目を開いた時に新着
  local M = load()
  M._t.runExport(true)
  local seen, dup = {}, false
  for _, n in ipairs(W.openLog) do if seen[n] and n ~= "トーク25番" then dup = true end; seen[n] = true end
  check(has("トーク25番") and #outFiles() == 20, "新着のトークも 20 件に入れた: " .. table.concat(outFiles(), ",") ..
    " / 開いた順: " .. table.concat(W.openLog, ","))
  check(line(heartbeat(), "ok: 20") and line(heartbeat(), "ng: 0"), "数:\n" .. heartbeat())
  safe()
end)

-- ===================== 実機の初回（10/26 17:54）で見えたこと =====================
test("実機 10/26: 保存したトークが下へ動いて済んだ行が1行ずつ上がり、開いたままのトークの行をまた押しても、失敗にせず数えない", function()
  local list = numbered(25)
  list[3].ocrHeader = "トーク3番 ゆう"              -- ヘッダは一覧の名前より長い（実機）
  list[10].ocrHeader = "トーク10番 さん"
  reset({ chats = list, knobs = { moveOnOpen = { when = "トーク3番", name = "トーク2番", to = 7 } } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(line(hb, "ng: 0") and line(hb, "ok: 20"), "失敗にしない:\n" .. hb)
  check(#outFiles() == 20 and has("トーク20番") and has("トーク3番"), "20 件: " .. table.concat(outFiles(), ","))
  local rep = readfile(DEBUG .. "/latest.txt") or ""
  check(namesTxt():find("保存した", 1, true) and not namesTxt():find("失敗", 1, true), "names.txt に失敗は無い:\n" .. namesTxt())
  safe()
end)

test("実機 10/26 21:22: 今日もう保存済みのトークが並び替わってまた開いても、2回目は 20 件に数えない", function()
  reset({ chats = numbered(25), knobs = { moveOnOpen = { when = "トーク3番", name = "トーク3番", to = 6 } } })
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  writefile(REPO .. "/mac/.last_result", "day=" .. TODAY .. "\nversion=v4.1-00000000\nng=1\nok=トーク3番\n")
  local M = load()
  at9am(function() M._t.maybeRun() end)
  local opened3 = 0
  for _, n in ipairs(W.openLog) do if n == "トーク3番" then opened3 = opened3 + 1 end end
  check(opened3 == 2, "保存済みのトークを2回開く場面になっている: " .. table.concat(W.openLog, ","))
  local _, inNames = namesTxt():gsub("トーク3番", "")
  check(inNames == 1, "names.txt に1回だけ:\n" .. namesTxt())
  check(has("トーク20番") and not has("トーク3番"), "下の行まで届き、保存済みは保存し直さない: " .. table.concat(outFiles(), ","))
  local hb = heartbeat()
  check(line(hb, "ok: 20") and line(hb, "ng: 0"), "合わせて 20 件:\n" .. hb)
  safe()
end)

-- ===================== 見直し 10/26 夜: 行の字の揺れ・並び替わり =====================
local function opensOf(name) local k = 0; for _, n in ipairs(W.openLog) do if n == name then k = k + 1 end end; return k end
local function retryAfter(list, upto)              -- 今日 1〜upto 番目は保存済み（新しい版でのやり直し）
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  local ok = {}
  for i = 1, upto do ok[#ok + 1] = "ok=" .. list[i].name end
  writefile(REPO .. "/mac/.last_result", "day=" .. TODAY .. "\nversion=v4.1-00000000\nng=1\n" .. table.concat(ok, "\n") .. "\n")
end

test("実機 10/26 21:22: 開いて選ばれた行の字が変わっても（メンバー数・「…」の位置）、同じトークを続けて2回開かない", function()
  local list = numbered(25)
  list[7].ocrRow, list[7].ocrRowOpen = "トーク7番(123)", "トーク7番"          -- 選ばれるとメンバー数が読めない
  list[17].name = "トーク17番のみんなの会"
  list[17].ocrRow, list[17].ocrRowOpen = "トーク17番の…", "トーク17番のみ…"   -- 選ばれると切れる所が1字ずれる
  list[18].ocrRow, list[18].ocrRowOpen, list[18].ocrHeader = "トーク18番(1", "トーク18番(12", "トーク18番(123)ビ"
  reset({ chats = list })
  retryAfter(list, 19)
  local M = load()
  at9am(function() M._t.maybeRun() end)
  local hb = heartbeat()
  check(line(hb, "ok: 20") and line(hb, "ng: 0") and has("トーク20番"), "20 件:\n" .. hb)
  check(opensOf("トーク7番") == 1 and opensOf("トーク17番のみんなの会") == 1 and opensOf("トーク18番") == 1,
    "1回ずつ開く: " .. table.concat(W.openLog, ","))
  check(#W.openLog == 20, "開いたのは 20 行: " .. #W.openLog)
  safe()
end)

test("見直し 10/26 夜: 開いて選ばれた行の字が変わり、ヘッダが行の名前と違うトークでも、また押して失敗にしない", function()
  for _, v in ipairs({
    { row = "トーク3番(123)", open = "トーク3番", header = "トーク3番 ゆう" },   -- メンバー数が消える＋ヘッダが長い（実機）
    { row = "トーク3番", open = "トーク3番ミ" },                                -- 選ばれるとアイコンを字に読む
    { row = "トーク3番", open = "" },                                           -- 選ばれると名前の字が読めない
    { row = "トーク3番 3", after = "トーク3番", header = "トーク3番 ゆう" },     -- 開いた後は未読の印が消える
    { row = "トーク3番 (12", after = "トーク3番 (12)", header = "トーク3番 ゆう" },
  }) do
    local list = numbered(25)
    list[3].ocrRow, list[3].ocrRowOpen, list[3].ocrRowAfterOpen, list[3].ocrHeader = v.row, v.open, v.after, v.header
    reset({ chats = list })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local tag = (v.open or v.after) .. ": "
    check(line(hb, "ng: 0") and line(hb, "ok: 20") and has("トーク20番"), tag .. "失敗にせず 20 件目まで:\n" .. hb)
    check(opensOf("トーク3番") == 1, tag .. "3番を1回だけ開く: " .. table.concat(W.openLog, ","))
    safe()
  end
end)

test("見直し 10/26 夜: 始める前から開いていた（選ばれていた）トークの行の字が、次の行を開いた後で戻っても、また開かない", function()
  local list = numbered(25)
  list[1].ocrRowOpen = "トーク1番ミ"
  reset({ chats = list, open = "トーク1番" })
  local M = load()
  M._t.runExport(true)
  check(line(heartbeat(), "ok: 20") and line(heartbeat(), "ng: 0") and has("トーク20番"), "20 件:\n" .. heartbeat())
  check(opensOf("トーク1番") == 1, "1番を1回だけ開く: " .. table.concat(W.openLog, ","))
  safe()
end)

test("見直し 10/26 夜: 失敗した・飛ばしたトークの行の字が開いた後で変わっても、もう1回開いて2回数えない", function()
  for _, kind in ipairs({ "once", "always", "skip" }) do
    local list = numbered(25)
    list[3].ocrRow, list[3].ocrRowOpen = "トーク3番(123)", "トーク3番"
    if kind == "once" then list[3].saveDeadOnce = true
    elseif kind == "always" then list[3].saveDead = true
    else list[3].menuItems = { "通知オフ", "トーク履歴を削除", "退会" } end
    reset({ chats = list })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(opensOf("トーク3番") == 1, kind .. ": 3番を1回だけ開く: " .. table.concat(W.openLog, ","))
    check(kind == "skip" or has("トーク20番"), kind .. ": 20 件目まで届く: " .. table.concat(outFiles(), ","))
    check(not line(hb, "ng: 2") and not hb:find("2 件飛ばした", 1, true), kind .. ": 1つのトークを2回数えない:\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜: 下へ送った後で、まだ開いていない上位のトークに新着が来て一番上へ動いても、取りこぼさない", function()
  for _, ro in ipairs({ { [15] = "トーク18番" }, { [14] = "トーク17番", [16] = "トーク19番" }, { [13] = "トーク28番" } }) do
    local want, moved = {}, {}                      -- 上位 20 件（偽物は ro を使うと消すので先に）
    for _, nm in pairs(ro) do moved[nm] = true; want[#want + 1] = nm end
    for i = 1, 30 do
      local nm = "トーク" .. i .. "番"
      if not moved[nm] and #want < 20 then want[#want + 1] = nm end
    end
    reset({ chats = numbered(30), knobs = { reorderAtOpens = ro } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    for _, nm in ipairs(want) do check(has(nm), nm .. " を保存: " .. table.concat(outFiles(), ",")) end
    check(#outFiles() == 20, "20 件だけ: " .. table.concat(outFiles(), ","))
    check(line(hb, "ok: 20") and line(hb, "ng: 0"), "数:\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜: 新着で一番上に来たトークの下の、済んだ行を開き直さない", function()
  reset({ chats = numbered(30), knobs = { reorderAtOpens = { [8] = "トーク25番" } } })
  local M = load()
  M._t.runExport(true)
  local distinct, seen = 0, {}
  for _, nm in ipairs(W.openLog) do if not seen[nm] then seen[nm] = true; distinct = distinct + 1 end end
  check(#W.openLog == distinct, "開き直さない: " .. table.concat(W.openLog, ","))
  check(has("トーク25番") and has("トーク19番") and #outFiles() == 20, "20 件: " .. table.concat(outFiles(), ","))
  safe()
end)

test("見直し 10/26 夜: 1回押しても開かなかった行は、もう1回押して開く（並び替わっても2回数えない）", function()
  local list = numbered(30)
  list[3].firstClickNoOpen = true
  reset({ chats = list, knobs = { reorderAtOpens = { [5] = "トーク25番" } } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(has("トーク3番") and has("トーク25番") and has("トーク19番") and #outFiles() == 20, "上位 20 件: " .. table.concat(outFiles(), ","))
  check(line(hb, "ok: 20") and line(hb, "ng: 0"), "数:\n" .. hb)
  safe()
end)

test("見直し 10/26 夜: 「トークを保存」が無いトークに新着が来て開き直しても、飛ばした数を2回数えない", function()
  for _, k in ipairs({ { reorderAtOpens = { [5] = "トーク2番" } }, { moveOnOpen = { when = "トーク2番", name = "トーク2番", to = 1 } } }) do
    local list = numbered(30)
    list[2].menuItems = { "通知オフ", "トーク履歴を削除" }
    reset({ chats = list, knobs = k })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(not hb:find("2 件飛ばした", 1, true), "飛ばしたのは1件:\n" .. hb)
    local _, lines = namesTxt():gsub("トーク2番\t", "")
    check(lines == 1, "names.txt に1回:\n" .. namesTxt())
    check(#outFiles() == 20 and line(hb, "ng: 0"), "20 件: " .. table.concat(outFiles(), ","))
    safe()
  end
end)

test("見直し 10/26 夜: ヘッダの読めないトーク（1字）の行を、並び替わってまた押しても失敗にしない", function()
  for _, mv in ipairs({ { when = "母", name = "母", to = 1 }, { when = "母", name = "トーク2番", to = 7 } }) do
    for _, retry in ipairs({ false, true }) do
      local list = numbered(25)
      list[3] = { name = "母" }
      reset({ chats = list, knobs = { moveOnOpen = mv } })
      if retry then retryAfter(list, 3) end
      local M = load()
      if retry then at9am(function() M._t.maybeRun() end) else M._t.runExport(true) end
      local hb = heartbeat()
      check(line(hb, "ng: 0") and line(hb, "ok: 20") and has("トーク20番"), mv.name .. (retry and "（やり直し）" or "") .. ": 失敗にせず 20 件目まで:\n" .. hb)
      safe()
    end
  end
end)

test("見直し 10/26 夜: 20 件目の後で一覧が読めなくなっても、済んだ実行を失敗に数えない", function()
  reset({ chats = numbered(25), knobs = { noTimesAfterSheet = 20 } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(#outFiles() == 20 and line(hb, "ok: 20") and line(hb, "ng: 0"), "20 件済んだ:\n" .. hb)
  check((readfile(REPO .. "/mac/.last_result") or ""):find("\nng=0\n", 1, true), "次の版でやり直しを起こさない")
  safe()
end)

test("見直し 10/26 夜: 押しても開かない行は、押し直してもヘッダが変わらなければ、今開いているトークと保存名で見分けて失敗にする", function()
  local list = numbered(6)
  list[3].noOpen = true
  list[3].ocrRow = "トーク2番"                       -- 開かない行が、今開いているトークと同じに読める
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  -- 名前で見分けられない（同じ字）: 保存名も前のトークと同じなので、今開いているトークの行と
  -- みなす（数えない）。黙って取りこぼすのは同じに読める2つの行の片方が開かない時だけ
  check(line(hb, "ok: 5"), "ほかの5件は保存:\n" .. hb)
  reset({ chats = numbered(6) })
  W.chats[3].noOpen = true
  M = load()
  M._t.runExport(true)
  hb = heartbeat()
  check(line(hb, "ok: 5") and line(hb, "ng: 1") and hb:find("一覧の3番目: [トーク確認]", 1, true), "名前が違えば失敗:\n" .. hb)
  check(opensOf("トーク3番") == 2, "押し直した: " .. table.concat(W.openLog, ","))
  safe()
end)

test("見直し 10/26 夜（2）: 見えている一番下の行が開いて選ばれると字が変わっても、失敗にせず 20 件目まで", function()
  for _, v in ipairs({
    { open = "" }, { open = "トーク12番ミ" }, { open = "", header = "トーク12番 ゆう" },
    { name = "トーク12番のみんなの会", row = "トーク12番の…", open = "トーク12番のみ…" },
  }) do
    local list = numbered(25)
    if v.name then list[12].name = v.name end
    list[12].ocrRow, list[12].ocrRowOpen, list[12].ocrHeader = v.row, v.open, v.header
    reset({ chats = list })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local tag = "[" .. tostring(v.open) .. "/" .. tostring(v.header) .. "] "
    check(line(hb, "ng: 0") and line(hb, "ok: 20") and has("トーク20番") and has(list[12].name), tag .. "失敗にせず 20 件目まで:\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜（2）: 押しても開かない行の名前が今開いているトークの名前を含む・含まれても、黙って取りこぼさない", function()
  for _, v in ipairs({
    { prev = "トーク家族の会", row = "トーク家族" }, { prev = "トーク家族", row = "トーク家族の会" },
    { prev = "母", row = "母の会" },                    -- 前のトークはヘッダの読めない1字
  }) do
    local list = numbered(25)
    list[2] = { name = v.prev }
    list[3] = { name = v.row, noOpen = true }
    reset({ chats = list })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(line(hb, "ng: 1") and hb:find("一覧の3番目: [トーク確認]", 1, true) and line(hb, "ok: 19"),
      v.row .. ": 開かなかった行は失敗に数える:\n" .. hb)
    safe()
  end
  local list = numbered(25)
  list[2] = { name = "母" }
  list[3] = { name = "母の会", firstClickNoOpen = true }   -- 1回目の押しで開かない
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  check(has("母の会") and line(heartbeat(), "ng: 0") and line(heartbeat(), "ok: 20"), "押し直して保存:\n" .. heartbeat())
  safe()
end)

test("見直し 10/26 夜（2）: 開いたトークが下へ動き、名前の読めない行（絵文字だけ）が上がってきても、済んだことにしない", function()
  local cases = {
    { at = 4, mv = { when = "トーク3番", name = "トーク3番", to = 4 } },     -- 開いた3番が1行下へ
    { at = 5, mv = { when = "トーク4番", name = "トーク3番", to = 5 } },     -- 前に開いた3番が2行下へ（実機 10/26 の形）
  }
  for _, c in ipairs(cases) do
    local list = numbered(25)
    table.insert(list, c.at, { name = "🐱", ocrRow = "", ocrHeader = "" })
    reset({ chats = list, knobs = { moveOnOpen = c.mv } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(has("🐱") and line(hb, "ng: 0") and #outFiles() == 20, c.mv.name .. " が動いた時: 🐱 を保存: " .. table.concat(outFiles(), ",") .. "\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜（2）: 1回押しても開かず、押し直すまでに新着で一覧が1行ずれても、別の行を押さない（取りこぼすなら失敗に数える）", function()
  for _, nm in ipairs({ "トーク22番", "トーク9番" }) do
    local list = numbered(25)
    list[5].firstClickNoOpen = true
    reset({ chats = list, knobs = { reorderAfterNoOpen = nm } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(has("トーク5番") or (line(hb, "ng: 1") and hb:find("[トーク確認]", 1, true)), nm .. ": 5番は保存か失敗:\n" .. hb)
    check(has(nm), nm .. ": 新着のトークも保存: " .. table.concat(outFiles(), ","))
    local ok = tonumber(hb:match("\nok: (%d+)")) or -1
    local ng = tonumber(hb:match("\nng: (%d+)")) or -1
    check(ok + ng == 20 and ok == #outFiles(), nm .. ": 数が合う:\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜（2）: 行単位で送る一覧でも、下へ送った後の新着で一番上へ戻して開き、20 件だけ保存する", function()
  for _, k in ipairs({ { pixelScrollIgnored = true }, { pixelScrollIgnored = true, lineScale = 192 },
                       { pixelScrollIgnored = true, lineScale = 10 }, {} }) do
    for _, ro in ipairs({ { [15] = "トーク18番" }, { [13] = "トーク28番", [16] = "トーク29番" }, { [14] = "トーク12番" } }) do
      local knobs, moved = {}, {}
      for a, b in pairs(k) do knobs[a] = b end
      knobs.reorderAtOpens = {}
      for a, b in pairs(ro) do knobs.reorderAtOpens[a] = b; moved[#moved + 1] = b end
      reset({ chats = numbered(30), knobs = knobs })
      local M = load()
      M._t.runExport(true)
      local hb = heartbeat()
      local tag = "[" .. tostring(k.lineScale or (k.pixelScrollIgnored and "line" or "px")) .. " " .. table.concat(moved, ",") .. "] "
      check(#outFiles() == 20 and line(hb, "ng: 0") and line(hb, "ok: 20"), tag .. "20 件: " .. table.concat(outFiles(), ","))
      for _, nm in ipairs(moved) do check(has(nm), tag .. nm .. " を保存") end
      safe()
    end
  end
end)

local function missingOf(names)
  local t = {}
  for _, nm in ipairs(names) do if not has(nm) then t[#t + 1] = nm end end
  return t
end
local function firstN(list, k) local t = {}; for i = 1, k do t[#t + 1] = list[i].name end; return t end

test("見直し 10/26 夜（3）: 済んだトークが開いた行より下へ動いても（実機 10/26 17:54 の形）、すぐ下のトークを取りこぼさない", function()
  local cases = {
    { n = 25, mv = { when = "トーク3番", name = "トーク2番", to = 7 }, hdr = true },
    { n = 25, mv = { when = "母", name = "トーク2番", to = 7 }, mother = true },
    { n = 30, mv = { when = "トーク8番", name = "トーク7番", to = 12 } },
    { n = 30, mv = { when = "トーク4番", name = "トーク1番", to = 9 } },
    { n = 30, mv = { when = "トーク15番", name = "トーク13番", to = 20 } },
    { n = 30, mv = { when = "トーク5番", name = "トーク2番", to = 30 } },
  }
  for _, c in ipairs(cases) do
    local list = numbered(c.n)
    if c.hdr then list[3].ocrHeader = "トーク3番 ゆう"; list[10].ocrHeader = "トーク10番 さん" end
    if c.mother then list[3] = { name = "母" } end
    local want = firstN(list, 20)
    reset({ chats = list, knobs = { moveOnOpen = c.mv } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local miss = missingOf(want)
    local tag = c.mv.when .. "/" .. c.mv.name .. "→" .. c.mv.to .. ": "
    check(#miss == 0 and not has("トーク21番"), tag .. "上位 20 件: 足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ","))
    check(line(hb, "ok: 20") and line(hb, "ng: 0"), tag .. "数:\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜（3）: 開いている間にすぐ下の名前の読めない・同じに読めるトークに新着が来ても、取りこぼさない", function()
  local list = numbered(30)
  table.insert(list, 3, { name = "🐱", ocrRow = "", ocrHeader = "" })
  local want = firstN(list, 20)
  reset({ chats = list, knobs = { reorderAtOpens = { [2] = "🐱" } } })
  local M = load()
  M._t.runExport(true)
  local miss = missingOf(want)
  check(#miss == 0, "🐱: 足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ","))
  safe()
  list = numbered(30)
  table.insert(list, 4, { name = "パプリカ🍅", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true })
  table.insert(list, 5, { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true })
  want = firstN(list, 20)
  reset({ chats = list, knobs = { reorderAtOpens = { [4] = "トーク2番" } } })
  M = load()
  M._t.runExport(true)
  miss = missingOf(want)
  check(#miss == 0, "パプリカ: 足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ","))
  check(line(heartbeat(), "ng: 0"), "パプリカ: 失敗にしない:\n" .. heartbeat())
  safe()
end)

test("見直し 10/26 夜（3）: 下へ送るのと同時に、新着で一番上へ来たトークも、20 件の後で一番上を見て保存する", function()
  for _, nm in ipairs({ "トーク25番", "トーク15番" }) do
    local want = { nm }
    for i = 1, 30 do
      local x = "トーク" .. i .. "番"
      if x ~= nm and #want < 20 then want[#want + 1] = x end
    end
    reset({ chats = numbered(30), knobs = { reorderAtDownScroll = { [1] = nm } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local miss = missingOf(want)
    check(#miss == 0, nm .. ": 足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ","))
    check(line(hb, "ng: 0") and #outFiles() <= 21, nm .. ": 数:\n" .. hb .. table.concat(outFiles(), ","))
    safe()
  end
  -- 新着が無い日は、一番上を見ても何も開き直さない
  reset({ chats = numbered(30) })
  local M = load()
  M._t.runExport(true)
  check(#W.openLog == 20 and #outFiles() == 20 and line(heartbeat(), "ok: 20"), "新着が無い日は 20 件だけ: " .. table.concat(W.openLog, ","))
  safe()
end)

test("見直し 10/26 夜（3）: 一覧を読んでから押すまでに新着で1行ずれて開かなかった行は、ずれた所を押し直して開く", function()
  local want = { "トーク25番" }
  for i = 1, 19 do want[#want + 1] = "トーク" .. i .. "番" end
  reset({ chats = numbered(30), knobs = { reorderBeforeRowClick = { [5] = "トーク25番" } } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  local miss = missingOf(want)
  check(#miss == 0, "足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ","))
  check(line(hb, "ng: 0") and line(hb, "ok: 20"), "数:\n" .. hb)
  safe()
end)

test("見直し 10/26 夜（4）: 開いたトーク・その上の済んだトークに新着が来て一番上へ動いても、すぐ下のトークを取りこぼさない", function()
  for _, who in ipairs({ "トーク4番", "トーク2番" }) do
    reset({ chats = numbered(30), knobs = { reorderAtOpens = { [4] = who } } })
    local M = load()
    M._t.runExport(true)
    local miss = missingOf(firstN(numbered(30), 20))
    check(#miss == 0 and not has("トーク21番"), who .. ": 足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ","))
    check(line(heartbeat(), "ok: 20") and line(heartbeat(), "ng: 0"), who .. ": 数:\n" .. heartbeat())
    safe()
  end
end)

test("見直し 10/26 夜（4）: 開かなかった行は、names.txt に行の名前で失敗と書く（前のトークの名前で書かない）", function()
  local list = numbered(6)
  list[3].noOpen = true
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  check(namesTxt():find("\n3. トーク3番\t失敗", 1, true), "3番を失敗と書く:\n" .. namesTxt())
  local _, k = namesTxt():gsub("トーク2番", "")
  check(k == 1, "2番は1回だけ:\n" .. namesTxt())
  safe()
end)

test("見直し 10/26 夜（4）: 始める前から開いていたトークの行を後で押してヘッダが変わらなくても、まだ保存していなければ保存する", function()
  local list = numbered(25)
  list[1].firstClickNoOpen = true                     -- 最初の行は1回目の押しで開かない
  list[2].ocrHeader = "トーク2番 ゆう"                -- 開いていたトークはヘッダが行の名前より長い
  reset({ chats = list, open = "トーク2番" })
  local M = load()
  M._t.runExport(true)
  check(has("トーク2番"), "2番を保存: " .. table.concat(outFiles(), ",") .. "\n" .. heartbeat())
  local ok = tonumber(heartbeat():match("\nok: (%d+)")) or -1
  check(ok == #outFiles(), "ok の数と保存した数が合う:\n" .. heartbeat())
  safe()
end)

test("見直し 10/26 夜（4）: 押しても開かない行の名前が今開いているトークの名前を含んでも、黙って取りこぼさない", function()
  local list = numbered(25)
  list[3].name = "トーク2番の会"
  list[3].noOpen = true
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(line(hb, "ng: 1") and hb:find("一覧の3番目: [トーク確認]", 1, true), "失敗に数える:\n" .. hb)
  safe()
end)

test("見直し 10/26 夜（4）: 「トークを保存」の無いトークの後で、保存済みのトークに新着が来てまた開いても、失敗にも2回にも数えない", function()
  for _, kind in ipairs({ "skip", "saveDead" }) do
    local list = numbered(30)
    list[3].ocrHeader = "トーク3番 ゆう"
    if kind == "skip" then list[4].menuItems = { "通知オフ", "トーク履歴を削除" } else list[4].saveDead = true end
    reset({ chats = list, knobs = { reorderAtOpens = { [4] = "トーク3番" } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(line(hb, kind == "skip" and "ng: 0" or "ng: 1"), kind .. ": 失敗は " .. (kind == "skip" and "0" or "4番の1") .. " 件:\n" .. hb)
    local _, k = namesTxt():gsub("トーク3番", "")
    check(k == 1, kind .. ": 3番は names.txt に1回:\n" .. namesTxt())
    safe()
  end
end)

test("見直し 10/26 夜（5）: 開いたトークに保存中に新着が来て一番上へ動き、選ばれた行の字が変わっても、失敗にせず 20 件目まで", function()
  for _, v in ipairs({ { i = 15, open = "トーク15番ミ" }, { i = 15, open = "" }, { i = 4, open = "トーク4番ミ" } }) do
    local list = numbered(30)
    list[v.i].ocrRowOpen = v.open
    reset({ chats = list, knobs = { reorderAtOpens = { [v.i] = list[v.i].name } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local tag = v.i .. "/" .. v.open .. ": "
    check(line(hb, "ng: 0") and line(hb, "ok: 20") and has("トーク20番"), tag .. "失敗にせず 20 件目まで:\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜（5）: 一番上へ戻した後で開かない行・保存ダイアログが出ないトークをまた開いても、失敗を2回数えない", function()
  for _, kind in ipairs({ "noOpen", "saveDead" }) do
    local list = numbered(30)
    list[5][kind] = true
    reset({ chats = list, knobs = { reorderAtOpens = { [14] = "トーク6番", [16] = "トーク27番" } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(line(hb, "ng: 1") and line(hb, "ok: 19"), kind .. ": 5番の失敗は1回だけ:\n" .. hb)
    check(has("トーク19番") and has("トーク27番"), kind .. ": 上位 20 件: " .. table.concat(outFiles(), ","))
    safe()
  end
end)

test("見直し 10/26 夜（5）: 失敗した行を開き直して保存できたら、失敗を取り消して 20 件に2回数えない", function()
  local list = numbered(30)
  list[5].saveDeadOnce = true                         -- 1回目は保存ダイアログが出ない
  reset({ chats = list, knobs = { reorderAtOpens = { [14] = "トーク6番", [16] = "トーク27番" } } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  if has("トーク5番") then
    check(line(hb, "ng: 0") and line(hb, "ok: 20"), "失敗を取り消した:\n" .. hb)
    check(namesTxt():find("失敗の後で開き直した: 保存した", 1, true), "names.txt に書く:\n" .. namesTxt())
  else
    check(line(hb, "ng: 1") and line(hb, "ok: 19"), "保存できなければ失敗1件:\n" .. hb)
  end
  check(has("トーク19番") and has("トーク27番"), "上位 20 件: " .. table.concat(outFiles(), ","))
  safe()
end)

test("見直し 10/26 夜（5）: 20 件の後で一番上を見る時は、一度も見なかった名前を全部開く", function()
  reset({ chats = numbered(30), knobs = { reorderAtDownScroll = { [1] = { "トーク27番", "トーク25番" } } } })
  local M = load()
  M._t.runExport(true)
  check(has("トーク25番") and has("トーク27番") and line(heartbeat(), "ng: 0"), "2件とも: " .. table.concat(outFiles(), ","))
  safe()
  local list = numbered(30)
  list[2].name = "トーク2番の長いグループ名"
  list[2].ocrRow = "トーク2番の長いグル…"
  list[2].ocrRowLate = { at = 15, text = "トーク2番の長いグ…" }
  reset({ chats = list, knobs = { reorderAtDownScroll = { [1] = "トーク25番" }, reorderAtOpens = { [15] = "トーク2番の長いグループ名" } } })
  M = load()
  M._t.runExport(true)
  check(has("トーク25番") and line(heartbeat(), "ng: 0"), "字の変わった済んだ行に紛れない: " .. table.concat(outFiles(), ",") .. "\n" .. heartbeat())
  safe()
end)

-- ===================== R2 見直し（取りこぼし）: find-miss =====================
local function dumpRun(tag)
  return tag .. " 開いた順 " .. table.concat(W.openLog, ",") .. " / 保存 " .. table.concat(outFiles(), ",") .. "\n" .. heartbeat() .. "\n" .. namesTxt()
end

test("見直し 10/26 夜（6）: A1: 一覧を読んでから最初の行を押すまでに新着で1行ずれ、押した所に別のトークが開いても、元の1番を取りこぼさない", function()
  reset({ chats = numbered(30), knobs = { reorderBeforeRowClick = { [1] = "トーク25番" } } })
  local M = load()
  M._t.runExport(true)
  local want = { "トーク25番" }
  for i = 1, 19 do want[#want + 1] = "トーク" .. i .. "番" end
  local miss = missingOf(want)
  check(#miss == 0, dumpRun("A1: 足りない " .. table.concat(miss, ",")))
  safe()
end)

test("見直し 10/26 夜（6）: A2: 新着で一番上に来たトークを開いた後、次の行を押す直前の新着で、押した所に済んだ別のトークが来ても、その行を取りこぼさない", function()
  reset({ chats = numbered(30), knobs = { reorderAtOpens = { [3] = "トーク25番" }, reorderBeforeRowClick = { [5] = "トーク26番" } } })
  local M = load()
  M._t.runExport(true)
  local want = { "トーク26番", "トーク25番" }
  for i = 1, 18 do want[#want + 1] = "トーク" .. i .. "番" end
  local miss = missingOf(want)
  check(#miss == 0, dumpRun("A2: 足りない " .. table.concat(miss, ",")))
  safe()
end)

test("見直し 10/26 夜（6）: B: 済んだトークが開いた行より下へ動き（実機 10/26 17:54 の形）、開いた行が選ばれて字が変わっても、失敗にせず 20 件目まで", function()
  for _, open in ipairs({ "トーク3番ミ", "" }) do
    local list = numbered(25)
    list[3].ocrRowOpen = open
    local want = firstN(list, 20)
    reset({ chats = list, knobs = { moveOnOpen = { when = "トーク3番", name = "トーク2番", to = 7 } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local miss = missingOf(want)
    check(#miss == 0 and line(hb, "ok: 20") and line(hb, "ng: 0"), dumpRun("B[" .. open .. "]: 足りない " .. table.concat(miss, ",")))
    safe()
  end
end)

test("見直し 10/26 夜（6）: C1: 下へ送るのと同時に新着で一番上へ来た、名前の読めないトーク（絵文字だけ）も保存する", function()
  local list = numbered(30)
  table.insert(list, 25, { name = "🐱", ocrRow = "", ocrHeader = "" })
  reset({ chats = list, knobs = { reorderAtDownScroll = { [1] = "🐱" } } })
  local M = load()
  M._t.runExport(true)
  check(has("🐱"), dumpRun("C1: 🐱 を保存"))
  safe()
end)

test("見直し 10/26 夜（6）: C2: 下へ送る間に新着で一番上へ来たトークが2つあっても、両方保存する", function()
  reset({ chats = numbered(30), knobs = { reorderAtDownScroll = { [1] = { "トーク25番", "トーク26番" } } } })
  local M = load()
  M._t.runExport(true)
  check(has("トーク25番") and has("トーク26番"), dumpRun("C2: 25 と 26 を保存"))
  safe()
end)

test("見直し 10/26 夜（6）: D: 20 件目を開いている間に、一覧で見えていた 21 番目以降のトークに新着が来て一番上へ動いても、保存する", function()
  for _, nm in ipairs({ "トーク21番", "トーク22番", "トーク25番" }) do
    reset({ chats = numbered(30), knobs = { reorderAtOpens = { [20] = nm } } })
    local M = load()
    M._t.runExport(true)
    local want = { nm }
    for i = 1, 19 do want[#want + 1] = "トーク" .. i .. "番" end
    local miss = missingOf(want)
    check(#miss == 0, dumpRun("D[" .. nm .. "]: 足りない " .. table.concat(miss, ",")))
    safe()
  end
end)

test("見直し 10/26 夜（6）: B2: 「トークを保存」の無いトークが見えている一番下の行で、選ばれると字が読めなくなっても、失敗にしない", function()
  for _, at in ipairs({ 10, 11, 12 }) do
    local list = numbered(25)
    list[at].menuItems = { "通知オフ", "トーク履歴を削除" }
    list[at].ocrRowOpen = ""
    reset({ chats = list })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(line(hb, "ng: 0") and line(hb, "ok: 20"), dumpRun("B2[" .. at .. "]"))
    safe()
  end
end)

test("見直し 10/26 夜（6）: E: ピン留めの下へ新着が来ても（一番上の2件はピン留め）、済んだ行を開き直さず、開かない行を2回数えない", function()
  for _, kind in ipairs({ "noOpen", "saveDead" }) do
    local list = numbered(30)
    list[5][kind] = true
    reset({ chats = list, knobs = { insertAt = 3, reorderAtOpens = { [8] = "トーク25番" } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    -- 最後の上位 20 件は 1・2・25・3〜19番。5番は失敗（20 件に数える）
    local want = { "トーク1番", "トーク2番", "トーク25番" }
    for i = 3, 19 do if i ~= 5 then want[#want + 1] = "トーク" .. i .. "番" end end
    local miss = missingOf(want)
    check(#miss == 0 and line(hb, "ng: 1"), dumpRun("E[" .. kind .. "]: 足りない " .. table.concat(miss, ",")))
    local distinct, seen = 0, {}
    for _, nm in ipairs(W.openLog) do if not seen[nm] then seen[nm] = true; distinct = distinct + 1 end end
    check(#W.openLog - distinct <= 2, "E[" .. kind .. "]: 開き直しの数 " .. (#W.openLog - distinct) .. ": " .. table.concat(W.openLog, ","))
    safe()
  end
end)

test("見直し 10/26 夜（6）: B3: 開いている間にそのトークに新着が来て一番上へ動き、選ばれた行の字が変わっていても、失敗にせず 20 件目まで", function()
  for _, open in ipairs({ "トーク4番ミ", "" }) do
    for _, pin in ipairs({ false, true }) do
      local list = numbered(25)
      list[4].ocrRowOpen = open
      reset({ chats = list, knobs = { reorderAtOpens = { [4] = "トーク4番" }, insertAt = pin and 3 or nil } })
      local M = load()
      M._t.runExport(true)
      local hb = heartbeat()
      local miss = missingOf(firstN(numbered(25), 20))
      check(#miss == 0 and line(hb, "ok: 20") and line(hb, "ng: 0"), dumpRun("B3[" .. open .. (pin and " ピン留め" or "") .. "]: 足りない " .. table.concat(miss, ",")))
      safe()
    end
  end
end)

test("見直し fuzz（見つかった種。FUZZ_FROM で範囲）", function()
  -- 普段は見つかったことのある種だけ流す。FUZZ_FROM〜FUZZ_TO を付けると、その範囲を全部流す
  local seeds = { 149, 198, 353 }
  if realgetenv("FUZZ_FROM") then
    seeds = {}
    for k = tonumber(realgetenv("FUZZ_FROM")), tonumber(realgetenv("FUZZ_TO") or "200") do seeds[#seeds + 1] = k end
  end
  local shown = 0
  for _, seed in ipairs(seeds) do
    math.randomseed(seed)
    local R = math.random
    local list = numbered(30)
    local desc = {}
    local pinned = R(1, 3) == 1
    local knobs = {}
    if pinned then knobs.insertAt = 3; desc[#desc + 1] = "pinned2" end
    for i = 3, 25 do
      local c = list[i]
      local u = R(1, 100)
      if u <= 12 then c.ocrRowOpen = ""; desc[#desc + 1] = c.name .. ".open=''"
      elseif u <= 24 then c.ocrRowOpen = c.name .. "ミ"; desc[#desc + 1] = c.name .. ".open=ミ" end
      if R(1, 100) <= 12 then c.ocrHeader = c.name .. " ゆう"; desc[#desc + 1] = c.name .. ".hdr" end
    end
    if R(1, 4) == 1 then
      local at = R(3, 20)
      table.insert(list, at, { name = "🐱", ocrRow = "", ocrHeader = "" }); desc[#desc + 1] = "🐱@" .. at
    end
    if R(1, 4) == 1 then
      local at = R(3, 20)
      table.insert(list, at, { name = "母" }); desc[#desc + 1] = "母@" .. at
    end
    local skipName
    if R(1, 4) == 1 then
      local at = R(3, 20)
      skipName = list[at].name
      list[at].menuItems = { "通知オフ", "トーク履歴を削除" }; desc[#desc + 1] = "skip=" .. skipName
    end
    if R(1, 2) == 1 then
      local k = R(4, 18)
      local nameIdx = (R(1, 2) == 1) and (k - 1) or k
      local mv = { when = list[k].name, name = list[nameIdx].name, to = k + R(1, 6) }
      knobs.moveOnOpen = mv; desc[#desc + 1] = "move(" .. mv.when .. ":" .. mv.name .. "->" .. mv.to .. ")"
    end
    if R(1, 10) <= 7 then
      knobs.reorderAtOpens = {}
      for _ = 1, R(1, 2) do
        local j = R(1, 17)
        local nm = list[R(pinned and 3 or 2, #list)].name
        knobs.reorderAtOpens[j] = nm; desc[#desc + 1] = "ro[" .. j .. "]=" .. nm
      end
    end
    local mvName = knobs.moveOnOpen and knobs.moveOnOpen.name   -- 偽物は使うと消すので先に
    reset({ chats = list, knobs = knobs })
    local M = load()
    local ok, err = pcall(function() M._t.runExport(true) end)
    local final = {}
    for _, c in ipairs(W.chats) do if not c.hidden then final[#final + 1] = c.name end end
    local missing = {}
    -- 保存した後で 20 番目より下へ動いたトーク（実機 10/26 の形）は 20 件の1つに数えた。その分
    -- 最後の 20 番目は上がってきただけなので見ない
    local limit = 20
    if mvName and has(mvName) then
      local inTop = false
      for i = 1, 20 do if final[i] == mvName then inTop = true end end
      if not inTop then limit = 19 end
    end
    for i = 1, limit do
      local nm = final[i]
      if nm ~= skipName and not has(nm) then missing[#missing + 1] = nm end
    end
    local hb = heartbeat()
    local okN = tonumber(hb:match("\nok: (%d+)")) or -1
    local ngN = tonumber(hb:match("\nng: (%d+)")) or -1
    local bad = {}
    if not ok then bad[#bad + 1] = "例外 " .. tostring(err) end
    if #missing > ngN then bad[#bad + 1] = "取りこぼし(NG無し) " .. table.concat(missing, ",") .. " ng=" .. ngN end
    if ngN > #missing then bad[#bad + 1] = "NG多すぎ ng=" .. ngN .. " missing=" .. #missing end
    if okN ~= #outFiles() then
      local dupday = 0
      bad[#bad + 1] = "ok数 " .. okN .. " ≠ 保存 " .. #outFiles()
    end
    if #bad > 0 then
      shown = shown + 1
      check(false, "seed " .. seed .. ": " .. table.concat(bad, " / ") .. "\n    設定: " .. table.concat(desc, " ") ..
        "\n    開いた順: " .. table.concat(W.openLog, ",") .. "\n    最終: " .. table.concat(final, ",", 1, 22) ..
        "\n    hb: " .. hb:gsub("\n", " | ") .. (realgetenv("FUZZ_NAMES") and ("\n" .. namesTxt() .. "\n" .. table.concat(W.logs, "\n")) or ""))
    end
  end
end)

test("見直し fuzzS（見つかった種。FUZZ_FROM で範囲）", function()
  -- 普段は見つかったことのある種だけ流す。FUZZ_FROM〜FUZZ_TO を付けると、その範囲を全部流す
  local seeds = { 183 }
  if realgetenv("FUZZ_FROM") then
    seeds = {}
    for k = tonumber(realgetenv("FUZZ_FROM")), tonumber(realgetenv("FUZZ_TO") or "200") do seeds[#seeds + 1] = k end
  end
  local shown = 0
  for _, seed in ipairs(seeds) do
    math.randomseed(seed)
    local R = math.random
    local list = numbered(40)
    local desc = {}
    local pinned = R(1, 3) == 1
    local knobs = {}
    if pinned then knobs.insertAt = 3; desc[#desc + 1] = "pinned2" end
    for i = 3, 25 do
      local c = list[i]
      local u = R(1, 100)
      if u <= 12 then c.ocrRowOpen = ""; desc[#desc + 1] = c.name .. ".open=''"
      elseif u <= 24 then c.ocrRowOpen = c.name .. "ミ"; desc[#desc + 1] = c.name .. ".open=ミ" end
      if R(1, 100) <= 12 then c.ocrHeader = c.name .. " ゆう"; desc[#desc + 1] = c.name .. ".hdr" end
    end
    if R(1, 4) == 1 then
      local at = R(3, 20)
      table.insert(list, at, { name = "🐱", ocrRow = "", ocrHeader = "" }); desc[#desc + 1] = "🐱@" .. at
    end
    if R(1, 4) == 1 then
      local at = R(3, 20)
      table.insert(list, at, { name = "母" }); desc[#desc + 1] = "母@" .. at
    end
    local skipName
    if R(1, 4) == 1 then
      local at = R(3, 20)
      skipName = list[at].name
      list[at].menuItems = { "通知オフ", "トーク履歴を削除" }; desc[#desc + 1] = "skip=" .. skipName
    end
    if R(1, 2) == 1 then
      local k = R(9, 19)
      local nameIdx = (R(1, 2) == 1) and (k - 1) or k
      local mv = { when = list[k].name, name = list[nameIdx].name, to = k + R(1, 6) }
      knobs.moveOnOpen = mv; desc[#desc + 1] = "move(" .. mv.when .. ":" .. mv.name .. "->" .. mv.to .. ")"
    end
    if R(1, 10) <= 7 then
      knobs.reorderAtOpens = {}
      for _ = 1, R(1, 2) do
        local j = R(9, 19)
        local nm = list[R(pinned and 3 or 2, #list)].name
        knobs.reorderAtOpens[j] = nm; desc[#desc + 1] = "ro[" .. j .. "]=" .. nm
      end
    end
    reset({ chats = list, knobs = knobs })
    local M = load()
    local ok, err = pcall(function() M._t.runExport(true) end)
    local final = {}
    for _, c in ipairs(W.chats) do if not c.hidden then final[#final + 1] = c.name end end
    local missing = {}
    local init, targets = {}, {}
    for i, c in ipairs(list) do init[c.name] = i end
    for _, nm in pairs(knobs.reorderAtOpens or {}) do targets[nm] = true end
    local moved = knobs.moveOnOpen and knobs.moveOnOpen.name
    for i = 1, 20 do
      local nm = final[i]
      if nm ~= skipName and not has(nm) and ((init[nm] or 99) <= 19 or targets[nm]) then missing[#missing + 1] = nm end
    end
    local hb = heartbeat()
    local okN = tonumber(hb:match("\nok: (%d+)")) or -1
    local ngN = tonumber(hb:match("\nng: (%d+)")) or -1
    local bad = {}
    if not ok then bad[#bad + 1] = "例外 " .. tostring(err) end
    if #missing > ngN then bad[#bad + 1] = "取りこぼし(NG無し) " .. table.concat(missing, ",") .. " ng=" .. ngN end
    if false then bad[#bad + 1] = "NG多すぎ ng=" .. ngN .. " missing=" .. #missing end
    if okN ~= #outFiles() then
      local dupday = 0
      bad[#bad + 1] = "ok数 " .. okN .. " ≠ 保存 " .. #outFiles()
    end
    if #bad > 0 then
      shown = shown + 1
      check(false, "seed " .. seed .. ": " .. table.concat(bad, " / ") .. "\n    設定: " .. table.concat(desc, " ") ..
        "\n    開いた順: " .. table.concat(W.openLog, ",") .. "\n    最終: " .. table.concat(final, ",", 1, 22) ..
        "\n    hb: " .. hb:gsub("\n", " | ") .. (realgetenv("FUZZ_NAMES") and ("\n" .. namesTxt() .. "\n" .. table.concat(W.logs, "\n")) or ""))
    end
  end
end)

test("見直し fuzzW（見つかった種。FUZZ_FROM で範囲）", function()
  -- 普段は見つかったことのある種だけ流す。FUZZ_FROM〜FUZZ_TO を付けると、その範囲を全部流す
  local seeds = { 9, 88, 130, 149 }
  if realgetenv("FUZZ_FROM") then
    seeds = {}
    for k = tonumber(realgetenv("FUZZ_FROM")), tonumber(realgetenv("FUZZ_TO") or "200") do seeds[#seeds + 1] = k end
  end
  local shown = 0
  for _, seed in ipairs(seeds) do
    math.randomseed(seed)
    local R = math.random
    local list = numbered(30)
    local desc = {}
    local pinned = R(1, 3) == 1
    local knobs = {}
    if pinned then knobs.insertAt = 3; desc[#desc + 1] = "pinned2" end
    for i = 3, 25 do
      local c = list[i]
      local u = R(1, 100)
      if u <= 12 then c.ocrRowOpen = ""; desc[#desc + 1] = c.name .. ".open=''"
      elseif u <= 24 then c.ocrRowOpen = c.name .. "ミ"; desc[#desc + 1] = c.name .. ".open=ミ" end
      if R(1, 100) <= 12 then c.ocrHeader = c.name .. " ゆう"; desc[#desc + 1] = c.name .. ".hdr" end
    end
    if R(1, 4) == 1 then
      local at = R(3, 20)
      table.insert(list, at, { name = "🐱", ocrRow = "", ocrHeader = "" }); desc[#desc + 1] = "🐱@" .. at
    end
    if R(1, 4) == 1 then
      local at = R(3, 20)
      table.insert(list, at, { name = "母" }); desc[#desc + 1] = "母@" .. at
    end
    local skipName
    if R(1, 4) == 1 then
      local at = R(3, 20)
      skipName = list[at].name
      list[at].menuItems = { "通知オフ", "トーク履歴を削除" }; desc[#desc + 1] = "skip=" .. skipName
    end
    if R(1, 2) == 1 then
      local k = R(4, 18)
      local nameIdx = (R(1, 2) == 1) and (k - 1) or k
      local mv = { when = list[k].name, name = list[nameIdx].name, to = k + R(1, 6) }
      knobs.moveOnOpen = mv; desc[#desc + 1] = "move(" .. mv.when .. ":" .. mv.name .. "->" .. mv.to .. ")"
    end
    if R(1, 10) <= 7 then
      knobs.reorderAtOpens = {}
      for _ = 1, R(1, 2) do
        local j = R(1, 17)
        local nm = list[R(pinned and 3 or 2, #list)].name
        knobs.reorderAtOpens[j] = nm; desc[#desc + 1] = "ro[" .. j .. "]=" .. nm
      end
    end
    local openName
    if R(1, 3) == 1 then openName = list[R(1, 25)].name; desc[#desc + 1] = "preopen=" .. openName end
    if R(1, 3) == 1 then local i = R(1, 20); list[i].firstClickNoOpen = true; desc[#desc + 1] = "fcno=" .. list[i].name end
    if R(1, 10) <= 6 then
      knobs.reorderBeforeRowClick = {}
      local j = R(1, 18)
      local nm = list[R(pinned and 3 or 2, #list)].name
      knobs.reorderBeforeRowClick[j] = nm; desc[#desc + 1] = "rb[" .. j .. "]=" .. nm
    end
    local mvName = knobs.moveOnOpen and knobs.moveOnOpen.name   -- 偽物は使うと消すので先に
    reset({ chats = list, knobs = knobs, open = openName })
    local M = load()
    local ok, err = pcall(function() M._t.runExport(true) end)
    local final = {}
    for _, c in ipairs(W.chats) do if not c.hidden then final[#final + 1] = c.name end end
    local missing = {}
    -- 保存した後で 20 番目より下へ動いたトーク（実機 10/26 の形）は 20 件の1つに数えた。その分
    -- 最後の 20 番目は上がってきただけなので見ない
    local limit = 20
    if mvName and has(mvName) then
      local inTop = false
      for i = 1, 20 do if final[i] == mvName then inTop = true end end
      if not inTop then limit = 19 end
    end
    for i = 1, limit do
      local nm = final[i]
      if nm ~= skipName and not has(nm) then missing[#missing + 1] = nm end
    end
    local hb = heartbeat()
    local okN = tonumber(hb:match("\nok: (%d+)")) or -1
    local ngN = tonumber(hb:match("\nng: (%d+)")) or -1
    local bad = {}
    if not ok then bad[#bad + 1] = "例外 " .. tostring(err) end
    if #missing > ngN then bad[#bad + 1] = "取りこぼし(NG無し) " .. table.concat(missing, ",") .. " ng=" .. ngN end
    if ngN > #missing then bad[#bad + 1] = "NG多すぎ ng=" .. ngN .. " missing=" .. #missing end
    if okN ~= #outFiles() then
      local dupday = 0
      bad[#bad + 1] = "ok数 " .. okN .. " ≠ 保存 " .. #outFiles()
    end
    if #bad > 0 then
      shown = shown + 1
      check(false, "seed " .. seed .. ": " .. table.concat(bad, " / ") .. "\n    設定: " .. table.concat(desc, " ") ..
        "\n    開いた順: " .. table.concat(W.openLog, ",") .. "\n    最終: " .. table.concat(final, ",", 1, 22) ..
        "\n    hb: " .. hb:gsub("\n", " | ") .. (realgetenv("FUZZ_NAMES") and ("\n" .. namesTxt() .. "\n" .. table.concat(W.logs, "\n")) or ""))
    end
  end
end)

test("見直し 10/26 夜（7）: 20 件目を保存した直後に人が触っても・LINE が前面から外れても、済んだ実行を中断・失敗にしない", function()
  reset({ chats = numbered(30), knobs = { userActsAtSaveN = 20 } })
  local M = load()
  local r = M._t.runExport(true)
  local hb = heartbeat()
  check(#outFiles() == 20 and line(hb, "ok: 20") and r == "done" and not hb:find("中断", 1, true), "人が触った: " .. tostring(r) .. "\n" .. hb)
  writefile(REPO .. "/mac/.last_run", TODAY .. (r == "aborted" and ":1" or "") .. "\n")
  local menus = #W.menuClicked
  W.lastHID = T - 999
  at9am(function() M._t.maybeRun() end)
  check(#W.menuClicked - menus == 0, "済んだ日に 20 件を開き直さない: " .. (#W.menuClicked - menus))
  safe()
  reset({ chats = numbered(30), knobs = { frontLostAtSaveN = 20 } })
  M = load()
  M._t.runExport(true)
  hb = heartbeat()
  check(#outFiles() == 20 and line(hb, "ok: 20") and line(hb, "ng: 0")
        and (readfile(REPO .. "/mac/.last_result") or ""):find("\nng=0\n", 1, true), "前面から外れた:\n" .. hb)
end)

test("見直し 10/26 夜（7）: 保存ダイアログが出ずに失敗したトークが並び替わってまた開いても、2回数えず 20 番目まで届く", function()
  local cases = {
    { tag = "once/jump", dead = "saveDeadOnce", knobs = { reorderAtOpens = { [3] = "トーク3番" } } },
    { tag = "always/jump", dead = "saveDead", knobs = { reorderAtOpens = { [3] = "トーク3番" } } },
    { tag = "always/down", dead = "saveDead", knobs = { moveOnOpen = { when = "トーク3番", name = "トーク3番", to = 8 } } },
  }
  for _, c in ipairs(cases) do
    local list = numbered(30)
    list[3][c.dead] = true
    reset({ chats = list, knobs = c.knobs })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local _, k = namesTxt():gsub("トーク3番", "")
    local ng = tonumber(hb:match("\nng: (%d+)")) or -1
    check(k == 1, c.tag .. ": 3番は names.txt に1回:\n" .. namesTxt())
    check(has("トーク20番"), c.tag .. ": 20番まで届く: " .. table.concat(outFiles(), ","))
    check((has("トーク3番") and ng == 0) or (not has("トーク3番") and ng == 1), c.tag .. ": 失敗の数:\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜（7）: 始める前から「トークを保存」の無いトークが開いていて、最初の行が1回目の押しで開かなくても、飛ばしたことにしない", function()
  local list = numbered(25)
  table.insert(list, 6, { name = "トーク公式", menuItems = { "通知オフ", "トーク履歴を削除" } })
  list[1].firstClickNoOpen = true
  reset({ chats = list, open = "トーク公式" })
  local M = load()
  M._t.runExport(true)
  local hb, nt = heartbeat(), namesTxt()
  check(has("トーク1番") or (line(hb, "ng: 1") and nt:find("\n1. トーク1番\t失敗", 1, true)), "1番は保存か失敗:\n" .. hb .. nt)
  check(not nt:find("トーク1番\t⋮", 1, true), "開かなかった1番を「トークを保存」が無いと書かない:\n" .. nt)
  safe()
end)

test("見直し 10/26 夜（7）: 下へ送る間に新着で上へ来たトークは 20 件の後で全部保存し、heartbeat と names.txt に書く", function()
  for _, v in ipairs({ { "トーク25番" }, { "トーク25番", "トーク26番" } }) do
    reset({ chats = numbered(30), knobs = { reorderAtDownScroll = { [1] = #v == 1 and v[1] or v } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local top = {}
    for i = 1, 20 do top[#top + 1] = W.chats[i].name end
    local miss = missingOf(top)
    check(#miss == 0, table.concat(v, "+") .. ": 上位 20 件を保存: 足りない " .. table.concat(miss, ","))
    check(hb:find("20 件の後で新着で上へ来たトークを " .. #v .. " 件保存した", 1, true) and line(hb, "ng: 0"), table.concat(v, "+") .. ": heartbeat に書く:\n" .. hb)
    check(namesTxt():find("20 件の後で新着で上へ来た", 1, true), "names.txt に書く:\n" .. namesTxt())
    safe()
  end
end)

local function dumpRunV(tag) return dumpRun(tag) end

test("見直し 10/26 夜（8）: 開いたトークに保存中に新着が来て一番上へ動き、選ばれた行の字が変わっても、失敗にせず 20 件目まで", function()
  for _, v in ipairs({
    { i = 15, open = "トーク15番ミ" }, { i = 15, open = "" },    -- 下へ送った後（一番上へ戻すと、選ばれたままの行が上にある）
    { i = 4, open = "トーク4番ミ" }, { i = 4, open = "" },       -- 一番上の画面
    { i = 12, open = "トーク12番ミ" },                           -- 見えている一番下の行（すぐ下に比べられる行が無い）
    { i = 20, open = "トーク20番ミ" },                           -- 20 件目（20 件の後の見直しで一番上を見る）
    { i = 7, open = "トーク7番", row = "トーク7番(123)" },      -- 選ばれるとメンバー数が読めない
    { i = 4, open = "トーク4番ミ", who = "トーク3番" },          -- 前に開いたトークが一番上へ（開いた行は動かない）
  }) do
    local list = numbered(30)
    list[v.i].ocrRowOpen = v.open
    if v.row then list[v.i].ocrRow = v.row end
    local nm = list[v.i].name
    reset({ chats = list, knobs = { reorderAtOpens = { [v.i] = v.who or nm } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local tag = nm .. "（選ばれると「" .. v.open .. "」" .. (v.who and ("・" .. v.who .. " が上へ") or "") .. "）: "
    check(line(hb, "ng: 0") and line(hb, "ok: 20"), tag .. "失敗にしない:\n" .. hb)
    local miss = missingOf(firstN(numbered(30), 20))
    check(#miss == 0 and not has("トーク21番"), tag .. "上位 20 件: 足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ","))
    -- 一番上へ動いた行をまた押す（ヘッダが変わらないので押し直して、保存名で確かめる）のは1回まで
    check(opensOf(nm) <= 3, tag .. "開き直しは1回まで: " .. table.concat(W.openLog, ","))
    check(not namesTxt():find("失敗", 1, true), tag .. "names.txt に失敗と書かない:\n" .. namesTxt())
    safe()
  end
end)

test("見直し 10/26 夜（8）: 開いている間に、押しても開かない別のトークが一番上へ来たら、黙って取りこぼさず失敗に数える", function()
  for _, i in ipairs({ 12, 4 }) do
    local list = numbered(30)
    list[i].ocrRowOpen = "トーク" .. i .. "番ミ"
    list[28].noOpen = true
    reset({ chats = list, knobs = { reorderAtOpens = { [i] = "トーク28番" } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(not line(hb, "ng: 0") and hb:find("[トーク確認]", 1, true), i .. ": 28番は開かないので失敗:\n" .. hb)
    check(namesTxt():find("トーク28番\t失敗", 1, true), i .. ": names.txt に 28番を失敗と書く:\n" .. namesTxt())
    safe()
  end
end)

test("見直し 10/26 夜（8）: 最初の行を押す直前の新着で1行ずれ、別のトークが開いても、元の1番を取りこぼさない", function()
  -- 開いたトーク（25番）の行が選ばれて字が変わる・読めなくなる時も
  for _, v in ipairs({ { pre = false }, { pre = true }, { open = "" }, { open = "トーク25番ミ" } }) do
    local list = numbered(30)
    list[25].ocrRowOpen = v.open
    reset({ chats = list, knobs = { reorderBeforeRowClick = { [1] = "トーク25番" } }, open = v.pre and "トーク28番" or nil })
    local M = load()
    M._t.runExport(true)
    local want = { "トーク25番" }
    for i = 1, 19 do want[#want + 1] = "トーク" .. i .. "番" end
    local miss = missingOf(want)
    local hb = heartbeat()
    check(#miss == 0 and not has("トーク20番") and line(hb, "ok: 20") and line(hb, "ng: 0"),
      dumpRunV((v.pre and "前から開いていた: " or "") .. (v.open and ("25番の選ばれた字「" .. v.open .. "」: ") or "") .. "足りない " .. table.concat(miss, ",")))
    safe()
  end
end)

test("見直し 10/26 夜（8）: 一番上へ来たトークを開いた後、次の行を押す直前の新着で、押した所に済んだ別のトークが来ても、その行を取りこぼさない", function()
  reset({ chats = numbered(30), knobs = { reorderAtOpens = { [3] = "トーク25番" }, reorderBeforeRowClick = { [5] = "トーク26番" } } })
  local M = load()
  M._t.runExport(true)
  local want = { "トーク26番", "トーク25番" }
  for i = 1, 18 do want[#want + 1] = "トーク" .. i .. "番" end
  local miss = missingOf(want)
  local hb = heartbeat()
  check(#miss == 0 and line(hb, "ok: 20") and line(hb, "ng: 0"), dumpRunV("足りない " .. table.concat(miss, ",")))
  safe()
end)

test("見直し 10/26 夜（8）: 20 件目を保存した直後に人が戻っても、済んだ実行を中断にせず、済んだ 20 件を開き直さない", function()
  reset({ chats = numbered(30), knobs = { userActsAtSaveN = 20 } })
  local M = load()
  local r = M._t.runExport(true)
  local hb = heartbeat()
  check(#outFiles() == 20 and line(hb, "ok: 20") and line(hb, "ng: 0"), "20 件保存:\n" .. hb)
  check(r == "done" and not hb:find("中断", 1, true), "20 件済んだ実行を中断にしない: " .. tostring(r) .. "\n" .. hb)
  safe()
  writefile(REPO .. "/mac/.last_run", TODAY .. (r == "aborted" and ":1" or "") .. "\n")
  local menus = #W.menuClicked
  W.lastHID = T - 999
  at9am(function() M._t.maybeRun() end)
  check(#W.menuClicked - menus == 0, "済んだ日に 20 件を開き直さない: " .. (#W.menuClicked - menus))
end)

test("見直し 10/26 夜（8）: 20 件目を保存した直後に LINE が前面から外れても、済んだ実行を失敗に数えず、何も押さない", function()
  reset({ chats = numbered(30), knobs = { frontLostAtSaveN = 20 } })
  local M = load()
  local r = M._t.runExport(true)
  local hb = heartbeat()
  check(r == "done" and #outFiles() == 20 and line(hb, "ok: 20"), "20 件保存:\n" .. hb)
  check(line(hb, "ng: 0") and (readfile(REPO .. "/mac/.last_result") or ""):find("\nng=0\n", 1, true),
    "済んだ実行を失敗に数えない（次の版でやり直さない）:\n" .. hb)
  check(not W.scrolledElsewhere, "別のアプリの上で一覧を送っていない")
  safe()
end)

test("見直し 10/26 夜（8）: 下へ送っている間に、済んだトークと未保存のトークに新着が来て一番上へ戻しても、済んだ行を開き直さず、開かない行を2回失敗に数えない", function()
  -- 14 件目を開いた後で、済んだトーク6番（見えている所より上）に新着、16 件目の後で 27番に新着
  -- （下へ送るのと同時に 25番に新着が来て、送った量に紛れる形も）
  local cases = {
    { ro = { [14] = "トーク6番", [16] = "トーク27番" }, top = { "トーク27番", "トーク6番" }, last = 19 },
    { rds = { [1] = "トーク25番" }, ro = { [16] = "トーク28番" }, top = { "トーク28番", "トーク25番" }, last = 18 },
  }
  for ci, c in ipairs(cases) do
    for _, kind in ipairs({ "none", "noOpen", "saveDead" }) do
      local list = numbered(30)
      if kind ~= "none" then list[5][kind] = true end
      local function copy(t) if not t then return nil end; local u = {}; for a, b in pairs(t) do u[a] = b end; return u end
      reset({ chats = list, knobs = { reorderAtOpens = copy(c.ro), reorderAtDownScroll = copy(c.rds) } })   -- 偽物は使った分を消す
      local M = load()
      M._t.runExport(true)
      local hb = heartbeat()
      local tag = ci .. "/" .. kind .. ": "
      local want = { c.top[1], c.top[2] }
      for i = 1, c.last do
        local nm = "トーク" .. i .. "番"
        if nm ~= c.top[2] and not (kind ~= "none" and i == 5) then want[#want + 1] = nm end
      end
      local miss = missingOf(want)
      check(#miss == 0, tag .. "上位 20 件: 足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ","))
      check(line(hb, kind == "none" and "ng: 0" or "ng: 1"), tag .. "5番の失敗は1回だけ:\n" .. hb)
      local _, k5 = namesTxt():gsub("トーク5番[\t_]", "")
      check(k5 == 1, tag .. "5番は names.txt に1回:\n" .. namesTxt())
      -- 保存ダイアログは保存した数＋（開かない行の1回・一番上へ動いた済んだトークの確かめの1回）まで
      -- 見えている所より上で起きた並び替わりに気づけなかった時は、済んだ行を開き直すことがある
      -- （保存名で確かめて数えない。時間がかかるだけ）ので、保存ダイアログの数は見ない
      safe()
    end
  end
end)

test("見直し 10/26 夜（8）ピン留め: ピン留めが上に2件ある一覧で新着がその下に来ても、済んだ行を開き直さず、失敗したトークを2回数えず、20 件目まで開く", function()
  for _, kind in ipairs({ "none", "noOpen", "saveDead" }) do
    local list = numbered(30)
    if kind == "noOpen" then list[5].noOpen = true elseif kind == "saveDead" then list[5].saveDead = true end
    reset({ chats = list, knobs = { insertAt = 3, reorderAtOpens = { [8] = "トーク25番" } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local miss = {}                                 -- 上位 20 件: 1, 2,（25）, 3〜19
    for i = 1, 19 do
      local nm = "トーク" .. i .. "番"
      if i ~= 5 and not has(nm) then miss[#miss + 1] = nm end
    end
    check(not has("トーク20番") or kind ~= "none", kind .. ": 21 番目は保存しない: " .. table.concat(outFiles(), ","))
    check(has("トーク25番"), kind .. ": 新着の25番を保存: " .. table.concat(outFiles(), ","))
    check(#miss == 0, kind .. ": 足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ","))
    check(line(hb, kind == "none" and "ng: 0" or "ng: 1"), kind .. ": 失敗は1つのトークで1回:\n" .. hb)
    local reopened = {}
    for _, nm in ipairs({ "トーク3番", "トーク4番", "トーク6番", "トーク7番" }) do
      if opensOf(nm) > 1 then reopened[#reopened + 1] = nm end
    end
    check(#reopened == 0, kind .. ": 済んだ行を開き直さない: " .. table.concat(W.openLog, ","))
    safe()
  end
end)

test("見直し 10/26 夜（8）ピン留め: ピン留めが上に2件ある一覧で、どこで新着が来ても上位 20 件だけを1回ずつ保存する", function()
  for _, ro in ipairs({ { [2] = "トーク25番" }, { [3] = "トーク25番" }, { [8] = "トーク6番" },
                        { [14] = "トーク18番" }, { [14] = "トーク28番" }, { [13] = "トーク17番", [16] = "トーク19番" } }) do
    local want, moved, desc = {}, {}, {}
    for k, nm in pairs(ro) do moved[nm] = true; desc[#desc + 1] = k .. "=" .. nm end
    desc = table.concat(desc, " ")
    want = { "トーク1番", "トーク2番" }
    for _, nm in pairs(ro) do if nm ~= "トーク1番" and nm ~= "トーク2番" then want[#want + 1] = nm end end
    for i = 3, 30 do
      local nm = "トーク" .. i .. "番"
      if not moved[nm] and #want < 20 then want[#want + 1] = nm end
    end
    local list = numbered(30)
    list[5].noOpen = true
    reset({ chats = list, knobs = { insertAt = 3, reorderAtOpens = ro } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local miss = {}
    for _, nm in ipairs(want) do if nm ~= "トーク5番" and not has(nm) then miss[#miss + 1] = nm end end
    check(#miss == 0, desc .. ": 足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ","))
    check(#outFiles() == 19, desc .. ": 19 件だけ: " .. table.concat(outFiles(), ","))
    check(line(hb, "ok: 19") and line(hb, "ng: 1"), desc .. ": 数:\n" .. hb)
    local _, k5 = namesTxt():gsub("トーク5番", "")
    check(k5 == 1, desc .. ": 5番は names.txt に1回:\n" .. namesTxt())
    safe()
  end
end)

test("見直し 10/26 夜（8）ピン留め: ピン留めの最後の行を開いている間にすぐ下へ新着が来て、その行が開かなくても、黙って取りこぼさない", function()
  local list = numbered(30)
  list[25].noOpen = true
  reset({ chats = list, knobs = { insertAt = 3, reorderAtOpens = { [2] = "トーク25番" } } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  local l25 = namesTxt():match("[^\n]*トーク25番[^\n]*") or ""
  check(l25:find("失敗", 1, true) ~= nil, "25番は失敗と書く:\n" .. namesTxt())
  check(line(hb, "ok: 19") and line(hb, "ng: 1") and not has("トーク20番"), "21 番目を保存せず失敗に数える:\n" .. hb)
  safe()
end)

-- ===================== r3: 同じ行の字（名前の読めない行・同じに読める名前）の別のトークが、済んだ行の位置に来る =====================
local function r3top(n) local t = {}; for i = 1, n do t[#t + 1] = W.chats[i].name end; return t end
local function r3miss(names) local t = {}; for _, nm in ipairs(names) do if not has(nm) then t[#t + 1] = nm end end; return t end
test("見直し 10/26 夜（9）r3 T1: 開いた名前の読めないトークが下へ動き、すぐ下の名前の読めない別のトークが上がってきても取りこぼさない", function()
  local list = numbered(25)
  table.insert(list, 5, { name = "🐱", ocrRow = "", ocrHeader = "" })
  table.insert(list, 6, { name = "🐶", ocrRow = "", ocrHeader = "" })
  reset({ chats = list, knobs = { moveOnOpen = { when = "🐱", name = "🐱", to = 9 } } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  local miss = r3miss(r3top(20))
  check(#miss == 0 or line(hb, "ng: " .. #miss), "T1 取りこぼし(NG無し): " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ",") .. "\n" .. hb)
  safe()
end)
test("見直し 10/26 夜（9）r3 T2: 開いた同じに読める名前のトークが下へ動き、もう片方が上がってきても取りこぼさない", function()
  local list = numbered(25)
  table.insert(list, 5, { name = "パプリカ🍅", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true })
  table.insert(list, 6, { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true })
  reset({ chats = list, knobs = { moveOnOpen = { when = "パプリカ🍅", name = "パプリカ🍅", to = 9 } } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  local miss = r3miss(r3top(20))
  check(#miss == 0 or line(hb, "ng: " .. #miss), "T2 取りこぼし(NG無し): " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ",") .. "\n" .. hb)
  safe()
end)
test("見直し 10/26 夜（9）r3 T3: 一番上の名前の読めないトークを開いた後、名前の読めない別のトークに新着が来て一番上へ来ても取りこぼさない", function()
  local list = numbered(25)
  table.insert(list, 1, { name = "🐱", ocrRow = "", ocrHeader = "" })
  table.insert(list, 17, { name = "🐶", ocrRow = "", ocrHeader = "" })
  reset({ chats = list, knobs = { reorderAtOpens = { [5] = "🐶" } } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  local miss = r3miss(r3top(20))
  check(#miss == 0 or line(hb, "ng: " .. #miss), "T3 取りこぼし(NG無し): " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ",") .. "\n" .. hb)
  safe()
end)
test("見直し 10/26 夜（9）r3 T4: 下へ送った後、名前の読めない別のトークに新着が来て一番上へ来ても（一番上も名前の読めないトーク）、取りこぼさない", function()
  for _, v in ipairs({ { a = { name = "🐱", ocrRow = "", ocrHeader = "" }, b = { name = "🐶", ocrRow = "", ocrHeader = "" } },
                       { a = { name = "パプリカ🍅", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true },
                         b = { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true } } }) do
    local list = numbered(30)
    table.insert(list, 1, v.a)
    table.insert(list, 27, v.b)
    reset({ chats = list, knobs = { reorderAtOpens = { [15] = v.b.name } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local miss = r3miss(r3top(20))
    check(#miss == 0 or line(hb, "ng: " .. #miss), "T4 " .. v.b.name .. " 取りこぼし(NG無し): " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ",") .. "\n保存 " .. table.concat(outFiles(), ",") .. "\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜（9）r3 T5: 選ばれると字が読めない一番上のトークの後、名前の読めない（絵文字だけの）トークに新着が来て一番上へ来ても取りこぼさない", function()
  for _, v in ipairs({ { at = 5, pre = false }, { at = 15, pre = false }, { at = 5, pre = true }, { at = 15, pre = true } }) do
    local list = numbered(30)
    list[1].ocrRowOpen = ""                          -- 選ばれると名前の字が読めない（実機）
    table.insert(list, 27, { name = "🐶", ocrRow = "", ocrHeader = "" })   -- 絵文字だけの名前
    reset({ chats = list, knobs = { reorderAtOpens = { [v.at] = "🐶" } }, open = v.pre and "トーク1番" or nil })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local miss = r3miss(r3top(20))
    check(#miss == 0 or line(hb, "ng: " .. #miss), "T5 at=" .. v.at .. (v.pre and " 前から開いていた" or "") .. " 取りこぼし(NG無し): " .. table.concat(miss, ",") ..
      " / 開いた順 " .. table.concat(W.openLog, ",") .. "\n保存 " .. #outFiles() .. (has("トーク20番") and " (21番目のトーク20番を保存)" or "") .. "\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜（9）r3 T6: 保存で失敗したトークに新着が来て開き直しても（この実行で済んだ保存名）、保存しないまま失敗を取り消さない", function()
  for _, v in ipairs({ { ro = { [6] = "トーク3番" } }, { ro = { [15] = "トーク3番" } }, { mv = { when = "トーク4番", name = "トーク3番", to = 6 } } }) do
    local list = numbered(30)
    list[3].saveFailsOnce = true                      -- 3番は1回目の保存でダイアログが閉じない（失敗）
    reset({ chats = list, knobs = { reorderAtOpens = v.ro, moveOnOpen = v.mv } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local miss = r3miss(r3top(20))
    check(#miss == 0 or line(hb, "ng: " .. #miss), "T6 " .. (v.ro and next(v.ro) or "mv") .. ": 取りこぼし(NG無し): " .. table.concat(miss, ",") ..
      " / 開いた順 " .. table.concat(W.openLog, ",") .. "\n保存 " .. #outFiles() .. (has("トーク21番") and " (トーク21番を保存)" or "") .. "\n" .. hb ..
      "\nnames.txt の3番: " .. (namesTxt():match("[^\n]*トーク3番[^\n]*") or "?"))
    safe()
  end
end)

test("見直し 10/26 夜（9）r3 T7: 始める前から開いていたトークの名前が最初の行の名前を含む時、最初の行が1回目の押しで開かなくても、取りこぼさない", function()
  for _, v in ipairs({ { top = "トーク1番", pre = "トーク1番の家族" }, { top = "トーク1番の家族", pre = "トーク1番" } }) do
    local list = numbered(25)
    list[1] = { name = v.top, firstClickNoOpen = true }
    table.insert(list, 6, { name = v.pre })
    reset({ chats = list, open = v.pre })
    local M = load()
    M._t.runExport(true)
    local hb, nt = heartbeat(), namesTxt()
    local miss = r3miss(r3top(20))
    check(#miss == 0 or line(hb, "ng: " .. #miss), "T7 " .. v.top .. "/" .. v.pre .. ": 取りこぼし(NG無し): " .. table.concat(miss, ",") ..
      " / 開いた順 " .. table.concat(W.openLog, ",") .. "\n" .. hb .. (nt:match("\n1%. [^\n]*") or ""))
    safe()
  end
end)

test("見直し 10/26 夜（9）r3 T8: 開いた行が選ばれて字が変わっている間に、その名前を含む・含まれる別のトークに新着が来て一番上へ来ても、取りこぼさない", function()
  for _, v in ipairs({ { open = "トーク3番ミ", other = "トーク3番の会" }, { open = "", other = "トーク3番の会" },
                       { open = "トーク3番ミ", other = "トーク3" }, { open = "トーク3番", row = "トーク3番(123)", other = "トーク3番の会" } }) do
    local list = numbered(30)
    list[3].ocrRowOpen = v.open
    list[3].ocrRow = v.row
    table.insert(list, 16, { name = v.other })
    reset({ chats = list, knobs = { reorderAtOpens = { [3] = v.other } } })
    local M = load()
    M._t.runExport(true)
    local hb, nt = heartbeat(), namesTxt()
    local tag = "T8 open='" .. v.open .. "'" .. (v.row and (" row=" .. v.row) or "") .. " " .. v.other .. ": "
    check(has(v.other), tag .. "新着で一番上へ来た " .. v.other .. " を開いて保存する / 開いた順 " .. table.concat(W.openLog, ","))
    check(line(hb, "ng: 0") and not nt:find("トーク3番[^\n]*\t失敗", 1), tag .. "保存した3番を失敗にしない:\n" .. hb .. (nt:match("\n4%. [^\n]*") or ""))
    safe()
  end
end)

test("見直し 10/26 夜（9）r3 fuzzR（FUZZ_FROM を付けた時だけ）", function()
  if not realgetenv("FUZZ_FROM") then return end
  local FROM = tonumber(realgetenv("FUZZ_FROM") or "1")
  local TO = tonumber(realgetenv("FUZZ_TO") or "200")
  local UNIQUE = realgetenv("FUZZ_UNIQUE")          -- 同じに読める名前・名前の読めない行を使わない
  for seed = FROM, TO do
    math.randomseed(seed)
    local R = math.random
    local list = numbered(34)
    local desc = {}
    local pinned = R(1, 3) == 1
    local knobs = {}
    if pinned then knobs.insertAt = 3; desc[#desc + 1] = "pinned2" end
    for i = 2, 26 do
      local c = list[i]
      local u = R(1, 100)
      if u <= 10 then c.ocrRowOpen = ""; desc[#desc + 1] = c.name .. ".open=''"
      elseif u <= 20 then c.ocrRowOpen = c.name .. "ミ"; desc[#desc + 1] = c.name .. ".open=ミ"
      elseif u <= 26 then c.ocrRow = c.name .. "(123)"; c.ocrRowOpen = c.name; desc[#desc + 1] = c.name .. ".(123)"
      elseif u <= 32 then c.ocrRow = c.name .. " 3"; c.ocrRowAfterOpen = c.name; desc[#desc + 1] = c.name .. ".unread" end
      if R(1, 100) <= 10 then c.ocrHeader = c.name .. " ゆう"; desc[#desc + 1] = c.name .. ".hdr" end
    end
    if not UNIQUE then
      if R(1, 4) == 1 then local at = R(1, 22); table.insert(list, at, { name = "🐱", ocrRow = "", ocrHeader = "" }); desc[#desc + 1] = "🐱@" .. at end
      if R(1, 5) == 1 then local at = R(1, 22); table.insert(list, at, { name = "🐶", ocrRow = "", ocrHeader = "" }); desc[#desc + 1] = "🐶@" .. at end
    end
    if R(1, 4) == 1 then local at = R(1, 22); table.insert(list, at, { name = "母" }); desc[#desc + 1] = "母@" .. at end
    if R(1, 5) == 1 then local at = R(1, 22); table.insert(list, at, { name = "母の会" }); desc[#desc + 1] = "母の会@" .. at end
    local skips = {}
    if R(1, 4) == 1 then
      local at = R(2, 20)
      skips[list[at].name] = true
      list[at].menuItems = { "通知オフ", "トーク履歴を削除" }; desc[#desc + 1] = "skip=" .. list[at].name
    end
    if R(1, 2) == 1 then
      local k = R(3, 19)
      local nameIdx = k - R(0, 2)
      local mv = { when = list[k].name, name = list[nameIdx].name, to = k + R(1, 5) }
      knobs.moveOnOpen = mv; desc[#desc + 1] = "move(" .. mv.when .. ":" .. mv.name .. "->" .. mv.to .. ")"
    end
    if R(1, 10) <= 7 then
      knobs.reorderAtOpens = {}
      for _ = 1, R(1, 3) do
        local j = R(1, 19)
        local nm = list[R(pinned and 3 or 2, #list)].name
        knobs.reorderAtOpens[j] = nm; desc[#desc + 1] = "ro[" .. j .. "]=" .. nm
      end
    end
    if R(1, 4) == 1 then
      local nm = list[R(14, #list)].name
      knobs.reorderAtDownScroll = { [1] = nm }; desc[#desc + 1] = "rds=" .. nm
    end
    if R(1, 4) == 1 then
      knobs.reorderBeforeRowClick = {}
      local j = R(1, 18)
      local nm = list[R(pinned and 3 or 2, #list)].name
      knobs.reorderBeforeRowClick[j] = nm; desc[#desc + 1] = "rb[" .. j .. "]=" .. nm
    end
    local openName
    if R(1, 4) == 1 then openName = list[R(1, 25)].name; desc[#desc + 1] = "preopen=" .. openName end
    if R(1, 4) == 1 then local i = R(1, 20); list[i].firstClickNoOpen = true; desc[#desc + 1] = "fcno=" .. list[i].name end
    local mvName = knobs.moveOnOpen and knobs.moveOnOpen.name
    reset({ chats = list, knobs = knobs, open = openName })
    local M = load()
    local ok, err = pcall(function() M._t.runExport(true) end)
    local final = {}
    for _, c in ipairs(W.chats) do if not c.hidden then final[#final + 1] = c.name end end
    local limit = 20
    if mvName and has(mvName) then
      local inTop = false
      for i = 1, 20 do if final[i] == mvName then inTop = true end end
      if not inTop then limit = 19 end
    end
    local missing, want = {}, 0
    for _, nm in ipairs(final) do
      if want >= limit then break end
      if not skips[nm] then
        want = want + 1
        if not has(nm) then missing[#missing + 1] = nm end
      end
    end
    local hb = heartbeat()
    local okN = tonumber(hb:match("\nok: (%d+)")) or -1
    local ngN = tonumber(hb:match("\nng: (%d+)")) or -1
    local bad = {}
    if not ok then bad[#bad + 1] = "例外 " .. tostring(type(err) == "table" and (err.abort or err.blocked) or err) end
    if #missing > ngN then bad[#bad + 1] = "取りこぼし(NG無し) " .. table.concat(missing, ",") .. " ng=" .. ngN end
    if okN ~= #outFiles() then bad[#bad + 1] = "ok数 " .. okN .. " ≠ 保存 " .. #outFiles() end
    for _, s in ipairs(W.menuClicked) do if s ~= "トークを保存" then bad[#bad + 1] = "メニュー " .. s end end
    if #bad > 0 then
      check(false, "seed " .. seed .. ": " .. table.concat(bad, " / ") .. "\n    設定: " .. table.concat(desc, " ") ..
        "\n    開いた順: " .. table.concat(W.openLog, ",") .. "\n    最終: " .. table.concat(final, ",", 1, 22) ..
        "\n    hb: " .. hb:gsub("\n", " | ") .. (realgetenv("FUZZ_NAMES") and ("\n" .. namesTxt() .. "\n" .. table.concat(W.logs, "\n")) or ""))
    end
  end
end)

test("見直し 10/26 夜（10）: 行単位で送る一覧で、最初に送る（1行の量を測る）間に新着が来ても、上位 20 件を取りこぼさない", function()
  for _, ls in ipairs({ 10, 16, 24, 40, 64 }) do
    for _, who in ipairs({ "トーク17番", "トーク30番" }) do
      reset({ chats = numbered(34), knobs = { pixelScrollIgnored = true, lineScale = ls, reorderAtDownScroll = { [1] = who } } })
      local M = load()
      M._t.runExport(true)
      local hb = heartbeat()
      local top = {}
      for i = 1, 20 do top[#top + 1] = W.chats[i].name end
      local miss = missingOf(top)
      check(#miss == 0 and line(hb, "ng: 0"), ls .. "pt/" .. who .. ": 足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ",") .. "\n" .. hb)
      safe()
    end
  end
end)

test("見直し 10/26 夜（10）: 下へ送る間に上へ来たトークは、途中で一番上へ戻して見えただけでも、20 件の後の見直しで開く", function()
  for _, k in ipairs({ { reorderAtDownScroll = { [1] = "トーク13番" }, reorderAtOpens = { [19] = "トーク29番" } },
                       { reorderAtOpens = { [13] = "トーク25番" }, reorderAtDownScroll = { [2] = "トーク17番" } } }) do
    reset({ chats = numbered(30), knobs = k })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local top = {}
    for i = 1, 20 do top[#top + 1] = W.chats[i].name end
    local miss = missingOf(top)
    check(#miss == 0 and line(hb, "ng: 0"), "足りない " .. table.concat(miss, ",") .. " / 開いた順 " .. table.concat(W.openLog, ",") .. "\n" .. hb)
    safe()
  end
end)

test("見直し 10/26 夜（11）: 保存で失敗したトークを新着で開き直しても、保存しないまま「保存済み」にして失敗を消さない", function()
  for _, kind in ipairs({ "saveFails", "saveFailsOnce" }) do
    local list = numbered(30)
    list[3][kind] = true
    reset({ chats = list, knobs = { reorderAtOpens = { [5] = "トーク3番" } } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    local res = readfile(REPO .. "/mac/.last_result") or ""
    if has("トーク3番") then
      check(line(hb, "ng: 0") and namesTxt():find("失敗の後で開き直した: 保存した", 1, true), kind .. ": 開き直して保存できたら取り消す:\n" .. hb .. namesTxt())
    else
      check(line(hb, "ng: 1") and not res:find("\nng=0\n", 1, true), kind .. ": 保存できなければ失敗のまま:\n" .. hb)
      check(not namesTxt():find("この実行で保存済み", 1, true), kind .. ": 保存済みと書かない:\n" .. namesTxt())
      check(not has("トーク21番"), kind .. ": 21 番目を保存しない")
    end
    safe()
  end
end)

test("見直し 10/26 夜（11）: 同じに読める別のトークの失敗を、もう片方の保存・失敗で取り消したり、まとめたりしない", function()
  for _, pair in ipairs({ { "トーク会のグループA", "トーク会のグループB", "トーク会のグル…" }, { "トークパプリカ🍅", "トークパプリカ🌶️", nil } }) do
    for _, bFails in ipairs({ false, true }) do
      local list = numbered(30)
      list[3] = { name = pair[1], ocrRow = pair[3], saveDead = true }
      list[15] = { name = pair[2], ocrRow = pair[3], saveDead = bFails }
      reset({ chats = list })
      local M = load()
      M._t.runExport(true)
      local hb = heartbeat()
      local tag = pair[1] .. (bFails and "/両方失敗" or "/B は保存") .. ": "
      check(not has(pair[1]), tag .. "A は保存していない")
      check(line(hb, bFails and "ng: 2" or "ng: 1"), tag .. "失敗の数:\n" .. hb)
      check(not has("トーク21番"), tag .. "21 番目を保存しない: " .. table.concat(outFiles(), ","))
      safe()
    end
  end
end)

test("見直し 10/26 夜（11）: 押した所に新着で別のトークが来て、そのトークの保存が失敗した時、押した行の保存で取り消さない", function()
  local list = numbered(30)
  list[25].saveFails = true
  reset({ chats = list, knobs = { reorderBeforeRowClick = { [1] = "トーク25番" } } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(not has("トーク25番") and line(hb, "ng: 1"), "25番の失敗は残す:\n" .. hb .. namesTxt())
  check(has("トーク1番") and has("トーク19番"), "ほかの上位は保存: " .. table.concat(outFiles(), ","))
  safe()
end)

test("実機 10/26: 最初の行を押してもトーク欄が空のままなら、もう1回押して開く", function()
  local list = numbered(5)
  list[1].firstClickNoOpen = true
  reset({ chats = list, knobs = { emptyLogo = true } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(line(hb, "ok: 5") and line(hb, "ng: 0") and has("トーク1番"), "押し直して保存した:\n" .. hb)
  check(not W.dotsWithoutChat, "何も開いていないのに ⋮ を押していない")
  safe()
end)

test("実機 10/26: 押してもトーク欄が空のままのトーク（別の窓で開く等）は、⋮ を押さずに失敗にする", function()
  local list = numbered(4)
  list[1].noOpen = true
  reset({ chats = list, knobs = { emptyLogo = true } })
  local M = load()
  M._t.runExport(true)
  local hb = heartbeat()
  check(line(hb, "ng: 1") and hb:find("一覧の1番目: [トーク確認] 押した行のトークが開かない（トーク欄が空のまま）", 1, true),
    "空のままと書く:\n" .. hb)
  check(not W.dotsWithoutChat, "何も開いていないのに ⋮ を押していない")
  check(line(hb, "ok: 3") and #outFiles() == 3, "ほかは保存: " .. table.concat(outFiles(), ","))
  safe()
end)

test("実機 10/26: 下へ送った後の古いトークの日付（10.18・10 / 18・2025-10-18・10,18・10 18・全角の 10／18）も時刻として読む", function()
  for _, fmt in ipairs({ "10.18", "10 / 18", "2025-10-18", "10,18", "10 18", "10／18" }) do
    local list = numbered(30)
    for i = 6, 30 do list[i].time = fmt end
    reset({ chats = list })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(line(hb, "ok: 20") and line(hb, "ng: 0") and has("トーク20番"), fmt .. ": 20 件:\n" .. hb)
  end
end)

test("実機 10/26: 一覧が読めない時は、右の列に見えたものの形（数字は 9）を診断に残す（名前は出さない）", function()
  local list = numbered(30)
  for i = 6, 30 do list[i].time = "1018" end        -- 時刻と見なせない形（区切りが読めない）
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  local rep = readfile(DEBUG .. "/latest.txt") or ""
  check(rep:find("一覧の右の列: ", 1, true) and rep:find("9999", 1, true), "形を残す:\n" .. rep)
  check(not rep:find("トーク7番", 1, true), "名前は出さない")
  -- 数字と日付の区切り以外の記号（顔文字など）は、形でなく伏せ字にする
  list = numbered(30)
  for i = 1, 30 do list[i].time = "(^_^)" end
  reset({ chats = list })
  M = load()
  M._t.runExport(true)
  rep = readfile(DEBUG .. "/latest.txt") or ""
  check(rep:find("一覧の右の列: ［数字］", 1, true) and not rep:find("(^_^)", 1, true), "記号は伏せ字:\n" .. rep)
end)

test("見直し 10/26: 同じに読める名前のトーク（パプリカ🍅 と 🌶️）が離れていても、両方保存する（名前だけで飛ばさない）", function()
  local list = numbered(30)
  table.insert(list, 2, { name = "パプリカ🍅", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true })
  table.insert(list, 14, { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true })
  reset({ chats = list })
  local M = load()
  M._t.runExport(true)
  check(has("パプリカ🍅") and has("パプリカ🌶️"), "両方保存: " .. table.concat(outFiles(), ","))
  check(line(heartbeat(), "ng: 0"), "失敗なし:\n" .. heartbeat())
  safe()
end)

test("見直し 10/26: 同じに読める名前の片方が保存の後で下へ動いても、もう片方を取りこぼさない", function()
  local list = numbered(30)
  table.insert(list, 1, { name = "パプリカ🍅", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true })
  table.insert(list, 4, { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true })
  reset({ chats = list, knobs = { moveOnOpen = { when = "パプリカ🍅", name = "パプリカ🍅", to = 13 } } })
  local M = load()
  M._t.runExport(true)
  check(has("パプリカ🍅") and has("パプリカ🌶️"), "両方保存: " .. table.concat(outFiles(), ","))
  check(line(heartbeat(), "ng: 0"), "失敗なし:\n" .. heartbeat())
  safe()
end)

test("見直し 10/26: 押しても開かなかった行は、並び替わって位置が変わっても、もう一度試す", function()
  local list = numbered(25)
  list[3].firstClickNoOpen = true                   -- 1回目は開かない（ヘッダは前のトークのまま）
  reset({ chats = list, knobs = { moveOnOpen = { when = "トーク4番", name = "トーク1番", to = 9 } } })
  local M = load()
  M._t.runExport(true)
  check(has("トーク3番"), "後でもう一度押して保存: " .. table.concat(outFiles(), ",") .. " / " .. table.concat(W.openLog, ","))
  safe()
end)

test("見直し 10/26: 一覧とトーク欄の境目が測れない時（検索欄の右端で代える）も、空のトーク欄を見分ける", function()
  for _, case in ipairs({ { first = true, want = "ok: 5" }, { noOpen = true, want = "トーク欄が空のまま" } }) do
    local list = numbered(5)
    for _, c in ipairs(list) do c.noAX = true end
    if case.first then list[1].firstClickNoOpen = true else list[1].noOpen = true end
    reset({ chats = list, knobs = { emptyLogo = true, timeDX = 285 } })
    local M = load()
    M._t.runExport(true)
    local hb = heartbeat()
    check(hb:find(case.want, 1, true), case.want .. ":\n" .. hb)
    check(not W.dotsWithoutChat, "何も開いていないのに ⋮ を押していない")
    safe()
  end
end)

test("名前が同じに見えるトーク（かにっこにー と かにっこにー (2)）も、それぞれの保存名で保存する", function()
  reset({ chats = chats({ "かにっこにー", "かにっこにー (2)", "Berry" }) })
  local M = load()
  M._t.runExport(true)
  check(has("かにっこにー") and has("かにっこにー (2)") and has("Berry"), "3 件とも: " .. table.concat(outFiles(), ","))
  safe()
end)

test("名前の絵文字を OCR が別の字に読んでも、LINE の保存名（パプリカ🌶️）のまま保存する", function()
  reset({ chats = { { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true }, { name = "Berry" } } })
  local M = load()
  M._t.runExport(true)
  check(has("パプリカ🌶️") and has("Berry"), "保存名のまま: " .. table.concat(outFiles(), ","))
  safe()
end)

test("途中で人が触ったら止め、次はもう保存したトークを保存し直さずに続きから", function()
  reset({ chats = numbered(30), knobs = { userActsAtClick = 13 } })
  local M = load()
  at9am(function()
    M._t.maybeRun()
    check(heartbeat():find("中断", 1, true), "1回目は中断:\n" .. heartbeat())
    local first = #outFiles()
    check(first >= 3 and first < 20, "途中まで保存: " .. first)
    W.knobs.userActsAtClick = nil; W.lastHID = T - 999
    local saves0 = W.pressedSaveN or 0
    W.cancelled = false
    M._t.maybeRun()
    check(#outFiles() == 20, "合わせて 20 件: " .. table.concat(outFiles(), ","))
    check(W.cancelled, "保存済みのトークは保存ダイアログをキャンセルした")
    local hb = heartbeat()
    check(line(hb, "ok: 20") and line(hb, "ng: 0"), "合わせて 20 件 OK:\n" .. hb)
    check(namesTxt():find("今日もう保存済み", 1, true), "names.txt に保存済みと書く")
  end)
  safe()
end)

test("実機の行の並び（最後のメッセージが時刻の 20pt 下）・1字や絵文字だけの名前でも、最後のメッセージを名前として扱わない", function()
  reset({ chats = { { name = "母", preview = "秘密のメッセージ1" }, { name = "🐱", preview = "秘密のメッセージ2" },
                    { name = "Berry", preview = "秘密のメッセージ3" } }, knobs = { previewDY = 11 } })
  local M = load()
  M._t.runExport(true)
  check(#outFiles() == 3, "3 件: " .. table.concat(outFiles(), ","))
  check(not namesTxt():find("秘密", 1, true) and not (readfile(DEBUG .. "/latest.txt") or ""):find("秘密", 1, true),
    "names.txt・診断に会話の中身を書かない")
  for _, l in ipairs(W.logs) do check(not l:find("秘密", 1, true), "コンソールにも出さない: " .. l) end
  safe()
end)

test("フルスクリーン（AX が 30pt 下）・時刻が境目より右（実機 x=344）・0.5pt のずれでも、上から順に保存する", function()
  for _, k in ipairs({ { axDY = 30 }, { timeDX = 285 }, { ocrHalf = true } }) do
    local list = numbered(25)
    if k.timeDX then for _, c in ipairs(list) do c.noAX = true end end
    reset({ chats = list, knobs = k })
    local M = load()
    W.search = "前の検索"
    M._t.runExport(true)
    check(#outFiles() == 20, "20 件: " .. table.concat(outFiles(), ","))
    check(not W.fractionalScroll, "小数の量でスクロールしていない")
    safe()
  end
end)

test("前の件の保存ダイアログが残っていたら、閉じてから始める", function()
  reset({ chats = chats({ "Berry", "直承Jikisho" }) })
  local M = load()
  W.open = "直承Jikisho"; W.sheet = { value = "[LINE]直承Jikisho.txt" }; W.focus = "sheet"
  M._t.runExport(true)
  check(W.cancelled and W.scrollsAtCancel == 0, "スクロールより先に閉じた: " .. tostring(W.scrollsAtCancel))
  check(#outFiles() == 2, "2 件: " .. table.concat(outFiles(), ","))
  safe()
end)

test("検索欄にフォーカスが入らない時は、キーを送らずに AX で消してから始める", function()
  reset({ chats = chats({ "Berry", "直承Jikisho" }), knobs = { focusIgnored = true, clickNoFocus = true } })
  local M = load()
  W.search = "前の検索"
  M._t.runExport(true)
  check(W.draft == nil, "入力欄に何も打っていない・消していない: " .. tostring(W.draft))
  check(#outFiles() == 2, "2 件: " .. table.concat(outFiles(), ","))
  safe()
end)

test("一覧を読んでいる時に人が触ったら、何も開かずに止める", function()
  reset({ chats = chats({ "Berry", "直承Jikisho" }), knobs = { userActsAtScroll = 1 } })
  local M = load()
  local r = M._t.runExport(true)
  check(r == "aborted", "中断: " .. tostring(r))
  check(#W.openLog == 0 and #outFiles() == 0, "何も開いていない")
  check(heartbeat():find("中断", 1, true), "heartbeat に中断:\n" .. heartbeat())
end)

-- ===================== 人が戻ってきた =====================
test("途中でキーボードを触ったら、その場で止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { userActsAtClick = 2 } })
  local ok, err = pcall(exportOne, "Berry")
  check(not ok and type(err) == "table" and err.abort, "中断した: " .. tostring(type(err) == "table" and err.abort or err))
  check(W.clickN == 2, "それ以上押していない（" .. W.clickN .. " 回）")
  check(W.clipboard == "ORIGINAL", "クリップボードは戻した")
end)

test("途中でマウスを動かしたら、その場で止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { userMovesAtClick = 1 } })
  local ok, err = pcall(exportOne, "Berry")
  check(not ok and type(err) == "table" and err.abort == "マウスが動いた", "中断した")
  check(W.clickN == 1, "それ以上押していない")
end)

-- ===================== 2回目のレビューで見つかった穴 =====================
test("ioreg が読めず idleTime が1秒刻みでも、誰も触らなければ止まらない", function()
  reset({ knobs = { noIoreg = true } })
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  local r = M._t.runExport()
  local hb = heartbeat()
  check(r == "done" and not hb:find("中断", 1, true), "最後まで: \n" .. hb)
  check(line(hb, "ok: " .. #M._t.targets), "全件 OK")
end)

test("自分の操作で無操作時間が戻らない Mac でも、誰も触らなければ止まらない", function()
  reset({ knobs = { synthNoReset = true } })
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  local r = M._t.runExport()
  check(r == "done" and not heartbeat():find("中断", 1, true), "最後まで: \n" .. heartbeat())
end)

test("ioreg が読めない時も、打ち続けていれば止まる", function()
  reset({ chats = chats({ "Berry" }), knobs = { noIoreg = true } })
  local M = load()
  local app = assert(M._t.prepareApp())
  M._t.beginRun(app)
  local orig = hs.timer.usleep
  hs.timer.usleep = function(us) orig(us); if W.clickN >= 1 then W.lastHID = T end end   -- 1回押した後から打ち続ける
  local ok, err = pcall(M._t.exportOne, app, "Berry")
  hs.timer.usleep = orig
  M._t.endRun()
  check(not ok and type(err) == "table" and err.abort, "中断した")
end)

test("手が動いている間は始めない（ホットキーや「許可」を押した直後）", function()
  reset({ chats = chats({ "Berry" }), knobs = { userBusy = true } })
  local M = load()
  local r = M._t.runExport(false)
  check(r == "busy" and #W.clicks == 0, "何も押さずに戻った: " .. tostring(r))
  check(heartbeat() == "", "heartbeat も書いていない")
end)

test("前面アプリの古い値（NSWorkspace）には頼らない", function()
  -- 偽物の frontmostApplication は常に Hammerspoon を返す。それでも動く
  reset({ chats = chats({ "Berry" }) })
  local ok = exportOne("Berry")
  check(ok, "成功する")
  safe()
end)

test("LINE が起動していなければ、起動だけして次の機会に回す", function()
  reset({ chats = chats({ "Berry" }) })
  W.running = false
  local M = load()
  local r = M._t.runExport(true)
  check(r == "notready" and W.opens == 1, "起動だけした")
  check(heartbeat() == "" and W.synced == 0, "heartbeat も push もしない")
end)

test("LINE の別のダイアログ（設定など）は保存ダイアログとみなさず、触らない", function()
  reset({ chats = chats({ "Berry" }), knobs = { otherDialog = true } })
  local ok = exportOne("Berry")
  check(ok and not W.otherClosed, "別のダイアログには触らずに成功")
  safe()
end)

test("フォーカスが分からない時はキーを送らず、AX で検索欄に入れる", function()
  reset({ chats = { { name = "直承Jikisho" }, { name = "Berry", hidden = true } },
          knobs = { focusUnknown = true, focusIgnored = true, clickNoFocus = true } })
  local ok = exportOne("Berry")
  check(ok and W.searchSetByAX, "AX で入れて成功")
  for i = 1, W.keysAtSheet or #W.keys do
    check(W.keys[i] ~= "cmd+a" and W.keys[i] ~= "cmd+v", "検索の時にキーを送っていない: " .. W.keys[i])
  end
  safe()
end)

test("昼になっても見送りが続く日は、理由を heartbeat に残す（1日1回）", function()
  reset({ chats = chats({ "Berry" }), knobs = { cameraInUse = true } })
  local M = load()
  local realdate = os.date
  os.date = function(fmt, ...)
    if fmt == "*t" then local t = realdate("*t", ...); t.hour = 13; return t end
    return realdate(fmt, ...)
  end
  local ok, err = pcall(function()
    M._t.maybeRun(); M._t.maybeRun()
  end)
  os.date = realdate
  if not ok then error(err, 0) end
  check(heartbeat():find("note: 見送り中: カメラ使用中", 1, true), "理由を書いた: " .. heartbeat())
  check(W.synced == 1 and #W.clicks == 0, "1回だけ push し、何も押していない")
end)

-- ===================== 1日分の実行 =====================
test("runExport: 一覧の上から順に回し、heartbeat に段と画像を書いて push する", function()
  local list = numbered(5)
  list[3].noOpen = true
  reset({ chats = list })
  local M = load()
  M._t.runExport()
  local hb = heartbeat()
  check(hb:find("\nversion: v4%.1%-%x+\n"), "heartbeat に版（v4.1-中身から作る印）")
  check(line(hb, "ok: 4") and line(hb, "ng: 1"), "ok/ng の数: \n" .. hb)
  check(hb:find("一覧の3番目: [トーク確認]", 1, true), "失敗した段を書く:\n" .. hb)
  check(hb:find("（画像: Dropbox の ", 1, true) and hb:find("\ndebug: Dropbox の ", 1, true), "画像の置き場を書く（Dropbox）")
  check(exists(DEBUG .. "/latest.txt"), "診断ファイルを Dropbox に書いた")
  check(not hb:find(HOME, 1, true), "heartbeat にユーザー名入りのパスを書かない")
  check(W.synced == 1, "sync.sh を1回呼んだ")
  check(#outFiles() == 4, "OUT_DIR に今日付きが 4 件: " .. table.concat(outFiles(), ","))
  safe()
end)

test("runExport: heartbeat には画面の文字や他のトーク名を書かない", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }), knobs = { wrongChatOnClick = "直承Jikisho" } })
  local M = load()
  M._t.runExport()
  local hb = heartbeat()
  check(not hb:find("Jikisho", 1, true), "heartbeat に別トーク名が無い:\n" .. hb)
  check(hb:find("[トーク確認]", 1, true) and not hb:find("ヘッダ行", 1, true) and not hb:find("■", 1, true),
    "画面由来の detail は伏せ字でも heartbeat に書かない:\n" .. hb)
  local logged = table.concat(W.logs, "\n")
  check(not logged:find("Jikisho", 1, true), "コンソールのログにも別トーク名を出さない（伏せ字）")
  local report = readfile(DEBUG .. "/latest.txt") or ""
  check(report:find("[トーク確認]", 1, true) and not report:find("Jikisho", 1, true), "診断ファイルも伏せ字:\n" .. report)
end)

test("runExport: 画面収録が未許可なら操作せず、理由を heartbeat に書く", function()
  reset({ chats = chats({ "Berry" }), knobs = { noPermission = true } })
  local M = load()
  M._t.runExport()
  local hb = heartbeat()
  check(hb:find("画面収録", 1, true), "理由を書く: " .. hb)
  check(#W.clicks == 0, "何も押していない")
  check(W.synced == 1, "heartbeat は push する")
end)

test("runExport: 1件で想定外のエラーが出ても残りを続ける", function()
  reset()
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  local orig, n = hs.eventtap.leftClick, 0
  hs.eventtap.leftClick = function(pt)
    n = n + 1
    if n == 1 then error(HOME .. "/Document/line-dump/mac/line_export.lua:1: 想定外", 0) end
    return orig(pt)
  end
  M._t.runExport()
  hs.eventtap.leftClick = orig
  local hb = heartbeat()
  check(hb:find("[内部エラー]", 1, true), "内部エラーとして記録: \n" .. hb)
  check(not hb:find(HOME, 1, true) and hb:find("~/Document/line-dump", 1, true), "エラー文のホームのパスは ~ に: \n" .. hb)
  check(M._t.tidy(HOME .. "/a/b.lua:3: x " .. HOME) == "~/a/b.lua:3: x ~", "ホームのパスを ~ にする")
  check(line(hb, "ng: 1") and line(hb, "ok: " .. (#M._t.targets - 1)), "失敗は1件だけ: \n" .. hb)
end)

test("runExport: 人が戻ってきたら残りをやめ、heartbeat に中断と書く", function()
  reset()
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  W.knobs.userActsAtClick = 9                       -- 3件目の途中
  local r = M._t.runExport(true)
  local hb = heartbeat()
  check(r == "aborted", "中断として返す")
  check(hb:find("note: 中断: 人の操作を検知", 1, true), "中断と書く:\n" .. hb)
  check(line(hb, "ok: 2"), "それまでの2件は OK:\n" .. hb)
  check(W.clickN == 9, "中断後は押していない（" .. W.clickN .. " 回）")
  check(W.synced == 1, "結果は push する")
end)


test("maybeRun: 中断した日は、また離席したらやり直す（上限あり）", function()
  reset()
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  local state = REPO .. "/mac/.last_run"
  at9am(function()
    W.knobs.userActsAtClick = 3
    M._t.maybeRun()
    check((readfile(state) or ""):match("^" .. TODAY .. ":1"), "中断1回目を記録: " .. tostring(readfile(state)))
    W.knobs.userActsAtClick = nil; W.clickN = 0; W.lastHID = T - 999
    M._t.maybeRun()
    check((readfile(state) or ""):match("^" .. TODAY .. "%s*$"), "やり直して最後まで: " .. tostring(readfile(state)))
    local synced = W.synced
    W.lastHID = T - 999
    M._t.maybeRun()
    check(W.synced == synced, "済んだ日はもう走らない")
    writefile(state, TODAY .. ":3\n")
    M._t.maybeRun()
    check(W.synced == synced, "中断が上限に達した日はもう走らない")
  end)
end)

test("maybeRun: ビデオ会議・画面共有・動画の最中は見送る", function()
  reset({ chats = chats({ "Berry" }) })
  local M = load()
  at9am(function()
    W.knobs.cameraInUse = true
    M._t.maybeRun()
    check(#W.clicks == 0 and W.synced == 0, "カメラ使用中は走らない")
    W.knobs.cameraInUse = false
    W.knobs.pidNames = { [321] = "zoom.us", [55] = "Amphetamine" }
    W.knobs.assertions = { [321] = { { AssertType = "PreventUserIdleDisplaySleep" } } }
    M._t.maybeRun()
    check(#W.clicks == 0 and W.synced == 0, "画面スリープを止めているアプリがあれば走らない")
    W.knobs.assertions = { [55] = { { AssertType = "PreventUserIdleDisplaySleep" } } }
    M._t.maybeRun()
    check(W.synced == 1, "起こしておくだけの道具（Amphetamine）なら走る")
  end)
end)

-- ===================== 実機（2026-10-22）で見えた画面に合わせた所 =====================
test("メンバー数の後ろのアイコンの字・3字までの余りは落として照合する", function()
  reset()
  local M = load()
  local n, c, score = M._t.norm, M._t.countless, M._t.score
  check(c(n("Berry（5）→ ビ")) == "berry", "（5）→ ビ を落とす: " .. c(n("Berry（5）→ ビ")))
  check(c(n("家族(2)(5)")) == "家族(2)", "最後のメンバー数だけ落とす")
  check(c(n("ABC(2023)同窓会のみんな")) == n("ABC(2023)同窓会のみんな"), "後ろが長ければ名前の一部とみなして残す")
  check(score(n("Berry"), n("Berry（5）→ ビ")) == 3, "ヘッダの余りがあっても完全一致")
  check(score(n("家族(2)"), n("家族(2)")) == 3, "名前そのものに (2) が入っていても完全一致")
end)

test("伏せ字: TARGETS の名前と LINE の決まった表示以外は字数だけ", function()
  reset()
  local M = load()
  local m = M._t.masked
  check(m("Berry") == "〈Berry〉", "対象の名前は出す: " .. m("Berry"))
  check(m("パプリカ🌶️（82）") == "〈パプリカ🌶️〉", "絵文字・メンバー数付きでも: " .. m("パプリカ🌶️（82）"))
  check(m("かにっこにー3") == "〈かにっこにー〉＋1字", "前方一致は後ろの字数だけ: " .. m("かにっこにー3"))
  check(m("今日のごはんどうする？") == "■11字", "それ以外は字数だけ: " .. m("今日のごはんどうする？"))
  check(m("Berryに会った話なんだけど長くなる") == "■19字", "長い本文に名前が入っていても出さない: " .. m("Berryに会った話なんだけど長くなる"))
  check(m("トークを保存") == "トークを保存" and m("通知オフ") == "通知オフ", "メニュー項目は出す")
  check(m("12:34") == "［数字］", "時刻は［数字］")
  check(M._t.maskedSave("[LINE]直承Jikisho.txt") == "[LINE]■9字.txt", "保存名も字数だけ")
  check(M._t.maskedSave("[LINE]Berry.txt") == "[LINE]〈Berry〉", "対象の保存名は出す")
  check(M._t.maskedSave(HOME .. "/Downloads/[LINE]秘密.txt") == "~/Downloads/[LINE]■2字.txt", "パスはホームを ~ に")
end)

test("実機の画面: 検索欄の AX の枠が狭く、ヘッダのメンバー数の後ろにアイコンの字が付く", function()
  -- 10/22 の実機で「トーク確認」が3回続けて失敗した形
  reset({ chats = { { name = "直承Jikisho" }, { name = "Berry", ocrHeader = "Berry（5）→ ビ" } },
          knobs = { narrowField = true, listJunk = "編集" } })
  local ok, dst = exportOne("Berry")
  check(ok and dst == OUT .. "/[LINE]Berry_" .. TODAY .. ".txt", "成功する: " .. tostring(type(dst) == "table" and (dst.stage .. dst.msg .. tostring(dst.detail)) or dst))
  safe()
end)

test("一覧の境目は一覧の AX のセルから割り出す（トーク欄のメッセージのセルは数えない）", function()
  reset({ chats = chats({ "Berry" }), knobs = { narrowField = true } })
  local M = load()
  local trace = {}
  local app = assert(M._t.prepareApp())
  M._t.beginRun(app)
  W.open = "Berry"                                -- トーク欄にメッセージのセルがある状態
  local ok = M._t.exportOne(app, "Berry", { trace = trace })
  M._t.endRun()
  check(ok, "成功する")
  local seen
  for _, t in ipairs(trace) do if t.stage == "一覧" then seen = t.text end end
  check(seen and seen:find("一覧のセル 1 個の右端", 1, true) and seen:find("境目 x=370", 1, true),
    "セルの右端（最大化した窓 x=0 + 80 - 40 + 330 = 370）: " .. tostring(seen))
end)

test("セルが読めなければ仕切り（AXSplitter）で境目を決める", function()
  reset({ chats = { { name = "直承Jikisho", noAX = true }, { name = "Berry", noAX = true, ocrHeader = "Berry（5）→ ビ" } },
          knobs = { narrowField = true, listJunk = "編集", splitterX = 372 } })
  local ok, e = exportOne("Berry")
  check(ok, "成功する: " .. tostring(type(e) == "table" and e.msg or e))
  safe()
end)

test("境目が仕切りで分かれば、検索欄に打った名前をヘッダと取り違えない", function()
  -- 検索欄の AX の枠がとても狭く（100pt）、打った「Berry」が枠の右の先に見える。
  -- セルは読めず、仕切りだけある。別のトークが開いたら「トーク確認」で止まる
  reset({ chats = { { name = "直承Jikisho", noAX = true }, { name = "Berry", noAX = true, hidden = true } },
          knobs = { narrowField = 100, splitterX = 372, wrongChatOnClick = "直承Jikisho" } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "トーク確認", "トーク確認で止める: " .. tostring(e and e.stage))
  check(#W.menuClicked == 0, "メニューを押していない")
  safe()
end)

test("ヘッダより上にトーク欄の別の文字があっても、検索欄と同じ高さの行で確かめる", function()
  reset({ chats = chats({ "Berry" }), knobs = { paneTop = "ノート" } })
  local ok, e = exportOne("Berry")
  check(ok, "成功する: " .. tostring(type(e) == "table" and e.msg or e))
  safe()
end)

test("ヘッダの表示が遅れても、4秒までは読み直して確かめる", function()
  reset({ chats = chats({ "Berry" }), knobs = { headerDelay = 3 } })
  local ok, e = exportOne("Berry")
  check(ok, "成功する: " .. tostring(type(e) == "table" and e.msg or e))
  safe()
end)

test("ヘッダが検索欄と同じ高さに無い画面でも、帯の一番上の行で確かめる", function()
  reset({ chats = chats({ "Berry" }), knobs = { headerDY = 40 } })
  local ok, e = exportOne("Berry")
  check(ok, "成功する: " .. tostring(type(e) == "table" and e.msg or e))
  safe()
end)

test("一覧の行で別のトークが開いたら、検索して開き直す", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }), knobs = { wrongChatOnce = "直承Jikisho" } })
  local ok, e = exportOne("Berry")
  check(ok, "検索して開き直して成功: " .. tostring(type(e) == "table" and e.msg or e))
  check(W.search == "Berry", "検索した")
  check(W.saved and W.saved:find("[LINE]Berry_", 1, true), "Berry を保存した: " .. tostring(W.saved))
  safe()
end)

test("貼り付けの直前に一瞬前面が外れても、LINE を前に出し直して続ける", function()
  reset({ chats = { { name = "Berry", hidden = true } }, knobs = { stealOnPaste = true } })
  local ok, e = exportOne("Berry")
  check(ok, "成功する: " .. tostring(type(e) == "table" and e.msg or e))
  check((W.reactivated or 0) >= 1, "前に出し直した")
  check(not W.typedElsewhere, "他のアプリには打っていない")
  check(table.concat(W.logs, "\n"):find("前面: Finder", 1, true), "その時の前面のアプリをログに残す")
  safe()
end)

test("人の操作で止めた時は、理由の数字をログに残す", function()
  reset({ chats = chats({ "Berry" }), knobs = { userActsAtClick = 1 } })
  pcall(exportOne, "Berry")
  check(table.concat(W.logs, "\n"):find("見張り: 最後の自動操作から", 1, true), "無操作時間の数字をログに")
end)

-- ===================== 使う人向けのコマンド =====================
test("diag: 何も押さず、伏せ字で出し、コンソールを前に出す（会話の中身を出さない）", function()
  reset({ chats = { { name = "直承Jikisho", preview = "ひみつの話をしよう" },
                    { name = "Berry", preview = "明日の待ち合わせ場所" } } })
  W.open = "直承Jikisho"
  chat("直承Jikisho").messages = { { s = "誰にも言わないでね", dx = 500, dy = 200 } }
  local M = load()
  W.logs = {}
  M.diag()
  local out = table.concat(W.logs, "\n")
  for _, secret in ipairs({ "ひみつ", "待ち合わせ", "誰にも", "Jikisho" }) do
    check(not out:find(secret, 1, true), "コンソールに「" .. secret .. "」を出していない")
  end
  check(out:find("〈Berry〉", 1, true) and out:find("■", 1, true), "対象の名前と伏せ字:\n" .. out)
  check(out:find("✓ Berry", 1, true), "TARGETS が一覧に見えるかを出す")
  check(out:find("[ヘッダ行]", 1, true) and out:find("[一覧]", 1, true), "読めた文字の領域を出す")
  check(out:find("一覧とトーク欄の境目", 1, true) and out:find("⋮ を押す位置", 1, true), "境目と ⋮ の位置を出す")
  check(#W.clicks == 0 and #W.keys == 0, "何も押していない")
  check(W.consoleOpened, "コンソールを前に出した")
  local report = readfile(DEBUG .. "/latest.txt") or ""
  check(report:find("〈Berry〉", 1, true) and not report:find("ひみつ", 1, true), "診断ファイルも伏せ字")
end)

test("check: 保存ダイアログで保存名を確かめたらキャンセルし、段ごとに ✓ を出す（保存しない）", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }) })
  local M = load()
  W.logs = {}
  local ok = M.check("Berry")
  local out = table.concat(W.logs, "\n")
  check(ok, "OK を返す:\n" .. out)
  check(W.menuClicked[1] == "トークを保存" and W.cancelled and not W.pressedSave and not W.sheet and not W.saved,
    "保存ダイアログをキャンセルし、保存していない")
  for i = (W.keysAtSheet or 0) + 1, #W.keys do check(false, "保存ダイアログには何も打っていない: " .. W.keys[i]) end
  for _, st in ipairs({ "✓ 準備", "✓ 窓", "✓ 一覧", "✓ トーク選択", "✓ トーク確認", "✓ メニュー",
                        "✓ 保存ダイアログ: 保存名 [LINE]〈Berry〉 を確かめた" }) do
    check(out:find(st, 1, true), "段ごとの経過: " .. st)
  end
  check(not out:find("Jikisho", 1, true), "他のトーク名は出さない")
  check(W.consoleOpened, "コンソールを前に出した")
  check(W.synced == 0, "push しない")
  check((readfile(DEBUG .. "/latest.txt") or ""):find("確認（保存はしない）", 1, true), "診断ファイルを書いた")
  safe()
end)

test("check: 失敗したら ✗ と、詳しく（伏せ字）・画像・次にすることを出す", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }), knobs = { wrongChatOnClick = "直承Jikisho" } })
  local M = load()
  W.logs = {}
  local ok = M.check("Berry")
  local out = table.concat(W.logs, "\n")
  check(not ok, "NG を返す")
  check(out:find("✗ トーク確認", 1, true) and out:find("詳しく: ヘッダ行", 1, true)
        and out:find("画像: Dropbox の ", 1, true) and out:find("次にすること", 1, true), "失敗の中身:\n" .. out)
  check(not out:find("Jikisho", 1, true), "他のトーク名は出さない")
  safe()
end)

test("one: 1件書き出して push し、結果をコンソールに出す", function()
  reset({ chats = chats({ "Berry" }) })
  local M = load()
  W.logs = {}
  local ok = M.one("Berry")
  local out = table.concat(W.logs, "\n")
  check(ok and W.saved and W.synced == 1, "書き出して push した")
  check(out:find("=== OK: [LINE]Berry_" .. TODAY .. ".txt を書き出した", 1, true), "結果を出す:\n" .. out)
  check(W.consoleOpened, "コンソールを前に出した")
end)

test("status: 自動実行が走らない理由が分かる", function()
  reset({ chats = chats({ "Berry" }), knobs = { displaySleep = 2, locked = true, branch = "try-v4" } })
  local M = load()
  W.logs = {}
  M.status()
  local out = table.concat(W.logs, "\n")
  check(out:find("✗ リポジトリのブランチ: try-v4", 1, true), "main 以外のブランチ:\n" .. out)
  check(out:find("✗ 画面ロック: 中", 1, true), "ロック中")
  check(out:find("✗ 画面が 2 分で消える設定", 1, true), "画面が先に消える設定")
  check(out:find("今日の自動実行: まだ", 1, true), "今日の状態")
  check(out:find("次の確認: 約 42 秒後", 1, true), "次の確認")
  check(W.consoleOpened, "コンソールを前に出した")
  reset({ chats = chats({ "Berry" }) })
  M = load()
  at9am(function() W.lastHID = T - 30; M._t.maybeRun() end)
  W.logs = {}
  M.status()
  out = table.concat(W.logs, "\n")
  check(out:find("最後の確認: %d+:%d+ 使用中（無操作 30 秒"), "最後の確認で見送った理由:\n" .. out)
  check(out:find("✓ 画面が消えるまで: 10 分", 1, true), "画面が消えるまでの時間")
  W.knobs.cameraInUse = true
  W.logs = {}
  M.status()
  check(table.concat(W.logs, "\n"):find("✗ 見送りの理由: カメラ使用中", 1, true), "見送りの理由")
end)

test("help: 使い方を出す", function()
  reset()
  local M = load()
  W.logs = {}
  M.help()
  local out = table.concat(W.logs, "\n")
  check(out:find("__LINE_EXPORT.check", 1, true) and out:find("__LINE_EXPORT.status", 1, true), "コマンドの一覧")
  check(W.consoleOpened, "コンソールを前に出した")
end)

test("読み込み時: 新しい版なら、何も押さない診断を1回だけ自動で撮る", function()
  reset({ chats = chats({ "Berry" }) })
  local M = load()
  check(readfile(REPO .. "/mac/.loaded_version"):find(M._t.VERSION, 1, true), "読み込んだ版を残す")
  check(#W.after == 1, "診断を予約した")
  W.after[1]()
  check(exists(DEBUG .. "/latest.txt") and #W.clicks == 0, "診断を書いた（何も押していない）")
  check(not W.consoleOpened, "自動の診断ではコンソールを開かない")
  W.after = {}
  load()
  check(#W.after == 0, "同じ版をもう一度読み込んでも撮らない")
end)

test("maybeRun: 新しい版が入った日は、もう一度一覧を回し、保存済みのトークは保存し直さない（版ごとに1回）", function()
  reset({ chats = numbered(4) })
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  writefile(REPO .. "/mac/.last_result", "day=" .. TODAY .. "\nversion=v4.1-00000000\nng=1\n" ..
    "ok=トーク1番\nok=トーク2番\nok=トーク4番\n")
  local M = load()                                 -- 新しい版を読み込んだ
  at9am(function()
    M._t.maybeRun()
    check(#outFiles() == 1 and has("トーク3番"), "失敗していた1件だけ保存した: " .. table.concat(outFiles(), ","))
    check(line(heartbeat(), "ok: 4") and line(heartbeat(), "ng: 0"), "合わせて 4 件 OK:\n" .. heartbeat())
    local synced = W.synced
    W.lastHID = T - 999
    M._t.maybeRun()
    check(W.synced == synced, "同じ版ではもうやらない")
  end)
  safe()
end)

test("maybeRun: 前の版（v4）が失敗した日も、heartbeat から読んでやり直す", function()
  reset({ chats = chats({ "Berry" }) })
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  writefile(REPO .. "/mac/heartbeat.txt", "last_run: " .. os.date("%Y-%m-%d") .. " 07:12:03\nversion: v4 (OCR)\nok: 4\nng: 9\n")
  local M = load()
  at9am(function() M._t.maybeRun() end)
  check(W.synced == 1 and W.saved, "やり直した")
end)

test("maybeRun: 昼になってもロック中などで走れない日は、理由を1回だけ残す", function()
  reset({ chats = chats({ "Berry" }), knobs = { locked = true } })
  local M = load()
  local realdate = os.date
  os.date = function(fmt, ...)
    if fmt == "*t" then local t = realdate("*t", ...); t.hour = 13; return t end
    return realdate(fmt, ...)
  end
  local ok, err = pcall(function() M._t.maybeRun(); M._t.maybeRun() end)
  os.date = realdate
  if not ok then error(err, 0) end
  check(heartbeat():find("note: 見送り中: 画面がロック中", 1, true), "理由を書いた: " .. heartbeat())
  check(W.synced == 1 and #W.clicks == 0, "1回だけ push し、何も押していない")
end)

test("自動実行では、暗くなった画面を起こしてから始める", function()
  reset()
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  M._t.runExport(true)
  check(W.declared, "画面を起こした")
  check(W.displayIdle == false, "画面を消さない設定は元に戻した")
end)

-- ===================== Mac の眠り・ロックの記録 =====================
local DAY = os.date("%Y-%m-%d")
local function powerLog(lines) writefile(REPO .. "/mac/.power_log", table.concat(lines, "\n") .. "\n") end
local function latest() return readfile(DEBUG .. "/latest.txt") or "" end
-- 今日の h:m を「今」にして fn を動かす（os.time() と、時刻を渡さない os.date）
local function atClock(h, m, fn)
  local realdate, realtime = os.date, os.time
  local t0 = realdate("*t"); t0.hour, t0.min, t0.sec = h, m, 0
  local fake = realtime(t0)
  os.time = function(t) if t == nil then return fake end return realtime(t) end
  os.date = function(fmt, at) return realdate(fmt, at or fake) end
  local ok, err = pcall(fn)
  os.date, os.time = realdate, realtime
  if not ok then error(err, 0) end
end

test("眠り: 眠った・起きた・ロックを時刻つきで記録し、古いものは消す", function()
  reset({ knobs = { powerSource = "Battery Power" } })
  local M = load()
  local w = hs.caffeinate.watcher
  check(readfile(REPO .. "/mac/.power_log"):find(" load 電池\n", 1, true), "読み込みも記録")
  local base = #W.after
  W.watcherFn(w.systemWillSleep); W.watcherFn(w.screensDidSleep); W.watcherFn(w.screensDidLock)
  check(#W.after == base, "眠る・画面が消える・ロックでは確認を予約しない")
  W.watcherFn(w.systemDidWake)
  check(#W.after == base + 1, "起きた後の確認を今までどおり予約する")
  W.watcherFn(w.screensDidUnlock)
  check(#W.after == base + 2, "ロック解除の後の確認も今までどおり予約する")
  local log = readfile(REPO .. "/mac/.power_log")
  for _, ev in ipairs({ "sleep", "wake", "off", "lock", "unlock" }) do
    check(log:find(" " .. ev .. " 電池\n", 1, true), ev .. " を記録: " .. log)
  end
  W.knobs.powerSource = nil
  for _ = 1, 70 do M._t.notePower("on") end
  local n = 0
  for _ in readfile(REPO .. "/mac/.power_log"):gmatch("[^\n]+") do n = n + 1 end
  check(n == 60, "60行だけ残す: " .. n)
  check(readfile(REPO .. "/mac/.power_log"):find(" on %-\n$"), "電源が分からない時は -")
end)

test("眠り: 07:00 をまたいで眠っていた日は、起きて少し後の確認で理由を heartbeat に1回だけ残す", function()
  reset({ chats = chats({ "Berry" }), knobs = { powerSource = "Battery Power", systemSleep = 1 } })
  local M = load()
  powerLog({ DAY .. " 00:41:00 sleep 電池", DAY .. " 00:41:00 lock 電池", DAY .. " 09:52:00 wake 電池" })
  check(M._t.sleptThrough() == "00:41〜09:52", "眠っていた間: " .. tostring(M._t.sleptThrough()))
  W.lastHID = T - 5                                -- 起きてすぐ使っている
  atClock(9, 53, function() M._t.maybeRun() end)
  check(heartbeat() == "" and W.synced == 0, "起きた直後（ネットが戻る前）は push しない")
  atClock(9, 54, function() M._t.maybeRun(); M._t.maybeRun() end)
  local hb = heartbeat()
  check(hb:find("note: 見送り中: 使用中", 1, true) and hb:find("（07:00 は Mac が眠っていた: 00:41〜09:52）", 1, true),
    "理由と眠っていた間を書いた: " .. hb)
  check(W.synced == 1 and #W.clicks == 0, "1回だけ push し、何も押していない")
  local r = latest()
  check(r:find("✗ 07:00 は Mac が眠っていた（00:41〜09:52）", 1, true), "診断にも出す:\n" .. r)
  check(r:find("最近の眠り・ロック（新しい順）: 09:52 起きた（電池） / 00:41 ロック（電池） / 00:41 眠った（電池）", 1, true),
    "記録を新しい順に:\n" .. r)
  check(r:find("Mac が眠るまで: 1 分", 1, true) and r:find("電源: 電池", 1, true), "眠るまでの設定と電源:\n" .. r)
  -- 昼になっても走れていなければ、その時の理由をもう1回だけ残す（朝の分で止めない）
  W.knobs.locked = true
  atClock(12, 5, function() M._t.maybeRun(); M._t.maybeRun() end)
  hb = heartbeat()
  check(hb:find("note: 見送り中: 画面がロック中（07:00 は Mac が眠っていた: 00:41〜09:52）", 1, true), "昼の理由: " .. hb)
  check(W.synced == 2, "昼に1回だけ push: " .. W.synced)
  atClock(13, 0, function() M._t.maybeRun() end)
  check(W.synced == 2, "それ以上は書かない")
end)

test("眠り: 起きた記録が抜けている時は「眠っていた」と決めつけない", function()
  reset({ chats = chats({ "Berry" }) })
  local M = load()
  local cases = {
    { "07:00 より前に起きていた", { DAY .. " 00:41:00 sleep 電池", DAY .. " 06:30:00 wake 電源", DAY .. " 06:40:00 lock 電源" } },
    { "眠ったきり", { DAY .. " 00:41:00 sleep 電池" } },
    { "再起動して起きていた（起きた記録なし）", { DAY .. " 00:41:00 sleep 電池", DAY .. " 06:30:00 load 電池",
      DAY .. " 06:31:00 unlock 電池", DAY .. " 08:00:00 sleep 電池", DAY .. " 09:00:00 wake 電池" } },
    { "電源を切った", { DAY .. " 00:41:00 sleep 電池", DAY .. " 02:05:00 poweroff 電池", DAY .. " 09:52:00 load 電源",
      DAY .. " 10:30:00 sleep 電源", DAY .. " 11:00:00 wake 電源" } },
    { "前の日に寝て朝に再起動", { os.date("%Y-%m-%d", os.time() - 86400) .. " 23:00:00 sleep 電池",
      DAY .. " 06:00:00 load 電池", DAY .. " 07:30:00 sleep 電池", DAY .. " 08:00:00 wake 電池" } },
  }
  for _, c in ipairs(cases) do
    powerLog(c[2])
    check(M._t.sleptThrough() == nil, c[1] .. ": " .. tostring(M._t.sleptThrough()))
  end
  W.lastHID = T - 5
  atClock(9, 30, function() M._t.maybeRun() end)
  check(heartbeat() == "" and W.synced == 0, "朝のうちは書かない・push しない: " .. heartbeat())
  -- ロック解除・画面がついたは起きていないと出ない（起きた記録の代わりになる）
  powerLog({ DAY .. " 00:41:00 sleep 電池", DAY .. " 00:41:00 off 電池", DAY .. " 09:52:00 unlock 電池" })
  check(M._t.sleptThrough() == "00:41〜09:52", "ロック解除で眠りの終わり: " .. tostring(M._t.sleptThrough()))
  -- 前の日に寝て、07:00 を過ぎてから起きた（日をまたぐ）
  local y = os.date("%Y-%m-%d", os.time() - 86400)
  powerLog({ y .. " 23:50:00 sleep 電池", DAY .. " 08:05:00 wake 電池" })
  check(M._t.sleptThrough() == os.date("%m/%d", os.time() - 86400) .. " 23:50〜08:05",
    "日をまたいだ眠り: " .. tostring(M._t.sleptThrough()))
end)

test("眠り: 今日もう書き出した日は、眠っていたことを失敗として出さない", function()
  reset({ chats = chats({ "Berry" }) })
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  local M = load()
  powerLog({ DAY .. " 00:41:00 sleep 電池", DAY .. " 09:52:00 wake 電池" })
  local s = table.concat(M._t.statusLines(), "\n")
  check(not s:find("Mac が眠っていた", 1, true), "済んだ日は出さない:\n" .. s)
  check(s:find("最近の眠り・ロック", 1, true), "記録そのものは出す")
  atClock(10, 0, function() M._t.maybeRun() end)
  check(heartbeat() == "" and W.synced == 0, "heartbeat も書かない")
end)

test("眠り: 昼の見送りは、朝の「眠っていた」以外の heartbeat があれば書き直さない", function()
  reset({ chats = chats({ "Berry" }), knobs = { locked = true } })
  local M = load()
  writefile(REPO .. "/mac/heartbeat.txt", "last_run: " .. DAY .. " 09:10:00\nversion: x\nok: 0\nng: 1\n" ..
    "note: 全件: Hammerspoon に「画面収録」が許可されていない\n")
  atClock(12, 5, function() M._t.maybeRun() end)
  check(heartbeat():find("画面収録", 1, true) and W.synced == 0, "始められない理由を上書きしない: " .. heartbeat())
end)

test("眠り: 本体の眠りの設定が読めない・画面の設定しか無い時は、その行を出さない", function()
  reset()
  local M = load()
  local s = table.concat(M._t.statusLines(), "\n")
  check(not s:find("Mac が眠るまで", 1, true), "displaysleep を sleep と読み違えない:\n" .. s)
  check(not s:find("電源:", 1, true), "電源が分からなければ出さない")
end)

-- ===================== レビューで見つかった穴（v4.1）=====================
test("新しい版でのやり直しが始められなくても、毎分 heartbeat を書いて push しない", function()
  reset({ chats = chats({ "Berry" }), knobs = { noPermission = true } })
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  writefile(REPO .. "/mac/.last_result", "day=" .. TODAY .. "\nversion=v4.1-00000000\nng=2\n")
  local M = load()
  at9am(function()
    M._t.maybeRun(); W.lastHID = T - 999; M._t.maybeRun(); M._t.maybeRun()
  end)
  check(W.synced == 1, "1回だけ: " .. W.synced)
end)

test("トーク名の一覧（⌘⌥⌃J）は一覧の列だけを読み、トーク欄のメッセージを出さない", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }) })
  W.open = "Berry"                                -- トーク欄にメッセージのセルがある
  local M = load()
  W.logs = {}
  local names = M.names()
  local out = table.concat(W.logs, "\n")
  check(names and #names == 2 and names[1] == "直承Jikisho" and names[2] == "Berry",
    "一覧の2件だけ: " .. table.concat(names or {}, ","))
  check(not out:find("メッセージ", 1, true), "メッセージを出していない:\n" .. out)
  check(W.consoleOpened, "コンソールを前に出した")
end)

test("LINE を前に出し直している間に人が触ったら、そこで止める", function()
  reset({ chats = { { name = "Berry", hidden = true } }, knobs = { stealOnPaste = true, userActsAtActivate = true } })
  local ok, err = pcall(exportOne, "Berry")
  check(not ok and type(err) == "table" and err.abort, "中断した: " .. tostring(type(err) == "table" and (err.abort or err.blocked) or err))
  for _, k in ipairs(W.keys) do check(k ~= "cmd+v", "貼り付けていない") end
  check(W.clipboard == "ORIGINAL", "クリップボードは戻した")
end)

test("自動の診断は、最小化された LINE を戻さず、見られていそうな時は撮らない", function()
  reset({ chats = chats({ "Berry" }) })
  W.win.minimized = true
  local M = load()
  W.after[1]()
  check(W.win.minimized, "最小化のまま")
  check(#W.clicks == 0, "何も押していない")
  reset({ chats = chats({ "Berry" }), knobs = { cameraInUse = true } })
  M = load()
  W.after[1]()
  check(not exists(DEBUG .. "/latest.txt"), "カメラ使用中は撮らない")
end)

test("LINE が前に来ない時の失敗では、画面全体（他のアプリ）を撮らない", function()
  reset({ chats = chats({ "Berry" }), knobs = { frontIsOther = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "窓", "窓で失敗")
  for _, c in ipairs(W.cmds) do check(not c:find("screencapture -x -R", 1, true), "画面全体を撮っていない: " .. c) end
  check(e.imgPath == nil, "画像は残さない（LINE の窓が無い）")
  reset({ chats = chats({ "Berry" }) })
  W.overlays = { { dx = SCREEN.w - 360, dy = 20, w = 360, h = 90 } }
  ok, e = exportOne("Berry")
  check(not ok and e.stage == "クリック" and e.imgPath and exists(e.imgPath), "重なりの失敗は LINE の窓だけを撮った")
  local shots = {}
  for _, c in ipairs(W.cmds) do
    if c:find("screencapture", 1, true) and c:find("line_export_fail", 1, true) then shots[#shots + 1] = c end
  end
  check(#shots == 1 and shots[1]:find("screencapture -x -o -l", 1, true), "窓だけを撮った: " .. tostring(shots[1]))
end)

test("伏せ字: メニュー項目に字が付いた本文は、決まった文言と字数だけ", function()
  reset()
  local m = load()._t.masked
  check(m("退会した") == "退会＋2字", m("退会した"))
  check(m("Leave it") == "Leave＋2字", m("Leave it"))
  check(m("通知オフだよ") == "通知オフ＋2字", m("通知オフだよ"))
  check(m("卜ークを保存") == "トークを保存", "OCR の読み違いも決まった文言で: " .. m("卜ークを保存"))
end)

test("窓の下にはみ出した行は見えていないとみなし、検索して開く", function()
  -- 13件目の Berry は窓の下（Dock の上）にはみ出している。AX の行を押せない
  local list = {}
  for i = 1, 12 do list[#list + 1] = { name = "ほか" .. i } end
  list[#list + 1] = { name = "Berry" }
  reset({ chats = list, knobs = { axPressFails = true } })
  W.overlays = { { dx = 0, dy = SCREEN.h - 75, w = SCREEN.w, h = 200 } }   -- 窓の下の Dock
  local ok, e = exportOne("Berry")
  check(ok and W.search == "Berry", "検索して開いた: " .. tostring(type(e) == "table" and (e.stage .. e.msg) or e))
  safe()
end)

test("前の件の検索結果が残っていたら、その一覧からは選ばず検索し直す", function()
  reset({ chats = { { name = "パプリカ" }, { name = "Berry" } } })
  W.search = "パ"                                 -- 前の件の検索が残っている
  local ok = exportOne("パプリカ")
  check(ok and W.search == "パプリカ", "検索し直した: " .. W.search)
  safe()
end)

test("一覧に前方一致の別トークだけ見えていたら押さず、検索して完全一致を開く", function()
  reset({ chats = { { name = "村田研OB会" }, { name = "村田研", hidden = true } } })
  local ok = exportOne("村田研")
  check(ok and W.saved and W.saved:find("[LINE]村田研_", 1, true), "村田研 を保存: " .. tostring(W.saved))
  check(W.search == "村田研", "検索した")
  check(#W.openLog == 1 and W.openLog[1] == "村田研", "村田研だけを開いた: " .. table.concat(W.openLog, ","))
  safe()
end)

test("check: 一覧の前方一致の別トークを OK にしない", function()
  reset({ chats = { { name = "村田研OB会" }, { name = "村田研", hidden = true } } })
  local ok = load().check("村田研")
  check(ok and #W.openLog == 1 and W.openLog[1] == "村田研", "村田研を開いた: " .. table.concat(W.openLog, ","))
end)

-- ===================== 2回目のレビューで見つかった穴（v4.1）=====================
test("始められなかった日は済みにせず、直れば次の確認で自動で始める（理由は1日1回だけ残す）", function()
  reset({ chats = chats({ "Berry" }), knobs = { noPermission = true } })
  local M = load()
  at9am(function()
    M._t.maybeRun(); W.lastHID = T - 999; M._t.maybeRun()
    check(W.synced == 1 and #W.clicks == 0, "理由は1回だけ push し、何も押していない: " .. W.synced)
    check(heartbeat():find("全件: Hammerspoon に「画面収録」が許可されていない", 1, true), "理由を heartbeat に")
    W.logs = {}; M.status()
    local out = table.concat(W.logs, "\n")
    check(out:find("✗ 今日の自動実行: 始められない（Hammerspoon に「画面収録」が許可されていない", 1, true),
      "status に理由:\n" .. out)
    check(not out:find("済み", 1, true), "済みとは言わない")
    W.knobs.noPermission = false; W.lastHID = T - 999
    M = load()                                    -- 許可して Hammerspoon を再起動した
    M._t.maybeRun()
    check(W.saved and W.synced == 2, "自動で始めて書き出した")
    check(not (readfile(REPO .. "/mac/.last_result") or ""):find("failed=", 1, true), "始められなかった印は消えた")
  end)
end)

test("昼の「見送り中」は、読み込み直しても1日1回だけ", function()
  reset({ chats = chats({ "Berry" }), knobs = { locked = true } })
  local M = load()
  local realdate = os.date
  os.date = function(fmt, ...)
    if fmt == "*t" then local t = realdate("*t", ...); t.hour = 13; return t end
    return realdate(fmt, ...)
  end
  local ok, err = pcall(function()
    M._t.maybeRun()
    M = load(); M._t.maybeRun(); M._t.maybeRun()
  end)
  os.date = realdate
  if not ok then error(err, 0) end
  check(W.synced == 1, "1回だけ push: " .. W.synced)
end)

test("昼の「見送り中」は、今日もう走った日（中断を含む）には書かない", function()
  reset({ chats = chats({ "Berry" }) })
  writefile(REPO .. "/mac/.last_run", TODAY .. ":1\n")
  writefile(REPO .. "/mac/heartbeat.txt", "last_run: 2000-01-01 07:00:00\nok: 9\nng: 0\nnote: 中断\n")
  local M = load()
  local realdate = os.date
  os.date = function(fmt, ...)
    if fmt == "*t" then local t = realdate("*t", ...); t.hour = 13; return t end
    return realdate(fmt, ...)
  end
  W.lastHID = T - 30                              -- 使用中
  local ok, err = pcall(function() M._t.maybeRun() end)
  os.date = realdate
  if not ok then error(err, 0) end
  check(W.synced == 0 and heartbeat():find("ok: 9", 1, true), "heartbeat はそのまま")
end)

test("手動の ⌘⌥⌃L を途中で止めても、自動実行の失敗数と新しい版でのやり直しは残る", function()
  local list = numbered(5)
  list[2].noOpen = true; list[4].noOpen = true    -- 2件は開かない
  reset({ chats = list })
  local M = load()
  at9am(function() M._t.maybeRun() end)
  W.knobs.userActsAtClick = W.clickN + 1; W.lastHID = T - 999
  M._t.runExport(false)                           -- 手動で全件 → 触って中断
  W.logs = {}; M.status()
  local out = table.concat(W.logs, "\n")
  check(out:find("今日の書き出し: 済み（失敗 2 件）", 1, true), "失敗数はそのまま:\n" .. out)
  check(not out:find("失敗 -1", 1, true), "-1 と出さない")
end)

test("新しい版でやり直す時に LINE が起動していなくても、「中断」と数えない", function()
  reset({ chats = chats({ "Berry" }) })
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  writefile(REPO .. "/mac/.last_result", "day=" .. TODAY .. "\nversion=v4.1-00000000\nng=1\n")
  W.running = false
  local M = load()
  at9am(function() M._t.maybeRun() end)
  check(W.opens == 1, "LINE を起動した")
  check((readfile(REPO .. "/mac/.last_run") or ""):match("^" .. TODAY .. "%s*$"), "状態は元のまま: " .. tostring(readfile(REPO .. "/mac/.last_run")))
  W.logs = {}; M.status()
  local out = table.concat(W.logs, "\n")
  check(not out:find("中断", 1, true), "中断と言わない:\n" .. out)
  check(out:find("最後の確認: %d+:%d+ LINE を起動した"), "最後の確認:\n" .. out)
  W.running = true; W.lastHID = T - 999
  at9am(function() M._t.maybeRun() end)
  check(W.saved, "次の確認でやり直した")
end)

test("中断した理由を status に出す（人の操作と時間切れを分ける）", function()
  reset()
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  at9am(function() W.knobs.userActsAtClick = 4; M._t.maybeRun() end)
  W.logs = {}; M.status()
  local out = table.concat(W.logs, "\n")
  check(out:find("今日の自動実行: 1 回中断（最後: 人の操作を検知", 1, true), "理由:\n" .. out)
end)

test("伏せ字: 名前欄の値に / があっても、前の部分をそのまま出さない", function()
  reset()
  local M = load()
  check(M._t.maskedSave("[LINE]田中/秘密の会.txt") == "[LINE]■7字.txt", M._t.maskedSave("[LINE]田中/秘密の会.txt"))
  check(M._t.maskedSave("[LINE]オーチュー/小林央忠.txt") == "[LINE]〈オーチュー/小林央忠〉", "対象の名前は出す")
end)

test("撮影画像の置き場の一覧が取れなくても、止まらずに書き出す", function()
  reset({ chats = chats({ "Berry" }), knobs = { dirThrows = true } })
  run("mkdir -p " .. sh(DEBUG))
  local ok = exportOne("Berry")
  check(ok, "成功する")
end)

test("次にすること: OCR・保存名・push の失敗ごとに、やることを出す", function()
  reset({ chats = chats({ "Berry" }), knobs = { ocrFails = true } })
  local M = load(); W.logs = {}
  M.check("Berry")
  local out = table.concat(W.logs, "\n")
  check(out:find("次にすること: OCR（mac/ocr.applescript）が動かない。ターミナルで osascript", 1, true), "OCR:\n" .. out)
  reset({ chats = chats({ "Berry" }), knobs = { noCapture = true } })
  M = load(); W.logs = {}
  M.check("Berry")
  out = table.concat(W.logs, "\n")
  check(out:find("次にすること: 画面収録の許可を確かめる", 1, true), "撮れない:\n" .. out)
  reset({ chats = chats({ "Berry" }), knobs = { defaultName = "[LINE]Berry Smith.txt" } })
  M = load(); W.logs = {}
  M.check("Berry")
  out = table.concat(W.logs, "\n")
  check(out:find("次にすること: トーク名が変わったのかもしれない", 1, true), "保存名:\n" .. out)
  reset({ chats = chats({ "Berry" }), knobs = { syncFails = true } })
  M = load(); W.logs = {}
  M.one("Berry")
  out = table.concat(W.logs, "\n")
  check(out:find("/ push できず ===", 1, true) and out:find("push できなかった", 1, true), "push:\n" .. out)
  check(not out:find("push 完了", 1, true) and not out:find("error: push", 1, true), "sync.sh の出力そのものは出さない")
end)

test("check: 部分一致の別トークしか無ければ、保存名で NG にする（OK と言わない）", function()
  reset({ chats = { { name = "村田研OB会" } } })
  local M = load(); W.logs = {}
  local ok = M.check("村田研")
  local out = table.concat(W.logs, "\n")
  check(not ok and out:find("✗ 保存ダイアログ: 保存名がトーク名と合わない", 1, true), "NG:\n" .. out)
  check(out:find("〈村田研〉＋3字", 1, true) and not out:find("村田研OB会", 1, true), "ヘッダの名前も伏せ字:\n" .. out)
  check(not W.saved and W.cancelled, "保存していない")
end)

test("diag: 検索欄に残っている文字も伏せ字", function()
  reset({ chats = chats({ "Berry" }) })
  W.search = "元カノの誕生日"
  local M = load(); W.logs = {}
  M.diag()
  local out = table.concat(W.logs, "\n")
  check(out:find("中身: ■7字", 1, true) and not out:find("元カノ", 1, true), "伏せ字:\n" .. out)
end)

test("保存ダイアログに見えない時の名前欄も伏せ字", function()
  reset({ chats = chats({ "Berry" }), knobs = { saveTitle = "OK", defaultName = "[LINE]直承Jikisho.txt" } })
  local ok, e = exportOne("Berry")
  check(not ok and e.detail == "名前欄: [LINE]■9字.txt", "伏せ字: " .. tostring(e and e.detail))
end)

test("自動の診断は、画面ロック中は撮らない", function()
  reset({ chats = chats({ "Berry" }), knobs = { locked = true } })
  load()
  W.after[1]()
  check(not exists(DEBUG .. "/latest.txt"), "撮らない")
end)

test("update: git pull がうまくいった時だけ読み込み直す", function()
  reset()
  local M = load()
  check(M.update() and W.pulled and W.reloaded, "読み込み直した")
  reset({ knobs = { pullFails = true } })
  M = load(); W.logs = {}
  check(not M.update() and not W.reloaded, "失敗したら読み込み直さない")
  local out = table.concat(W.logs, "\n")
  check(out:find("最新にできなかった", 1, true) and out:find("git status", 1, true) and W.consoleOpened, "理由と次にすること:\n" .. out)
end)

-- ===================== 3回目のレビューで見つかった穴（v4.1）=====================
test("日をまたいで終わった実行の結果は、始めた日の分として残す（次の日に全部飛ばさない）", function()
  reset()
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  local realdate = os.date
  local shift = 0
  os.date = function(fmt, t, ...)
    if W.clickN >= 6 then shift = 86400 end      -- 6回押したところで日付が変わる
    local tt = t or (os.time() + shift)
    if fmt == "*t" then local r = realdate("*t", tt); r.hour = 9; return r end
    return realdate(fmt, tt, ...)
  end
  local ok, err = pcall(function()
    M._t.maybeRun()
    local res = M._t.readResult()
    check(res.day == TODAY, "始めた日の分: " .. res.day)
    M = load()                                    -- 次の日にログインし直した
    W.openLog = {}; W.lastHID = T - 999
    M._t.maybeRun()
  end)
  os.date = realdate
  if not ok then error(err, 0) end
  check(#W.openLog == #M._t.targets, "次の日も全件を開いた: " .. #W.openLog)
end)

test("始められなかった後に始めて中断したら、「始められない」と言わない", function()
  reset({ knobs = { noPermission = true } })
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  at9am(function()
    M._t.maybeRun()
    W.knobs.noPermission = false; W.lastHID = T - 999
    M = load()
    W.knobs.userActsAtClick = W.clickN + 4
    M._t.maybeRun()
  end)
  W.logs = {}; M.status()
  local out = table.concat(W.logs, "\n")
  check(out:find("1 回中断", 1, true), "中断:\n" .. out)
  check(not out:find("始められない", 1, true), "始められないと言わない:\n" .. out)
end)

test("自動実行が済んだ日に ⌘⌥⌃L が始められなくても、「自動で始める」とは言わない", function()
  reset({ chats = chats({ "Berry" }) })
  local M = load()
  at9am(function() M._t.maybeRun() end)
  W.knobs.noPermission = true
  check(M._t.runExport(false) == "failed", "手動は始められない")
  W.logs = {}; M.status()
  local out = table.concat(W.logs, "\n")
  check(not out:find("自動で始める", 1, true), "自動で始めるとは言わない:\n" .. out)
end)

test("自動実行が理由を残した後でも、⌘⌥⌃L は同じ理由をアラートで知らせて push する", function()
  reset({ chats = chats({ "Berry" }), knobs = { noPermission = true } })
  local M = load()
  at9am(function() M._t.maybeRun() end)
  check(W.synced == 1, "自動実行で1回 push: " .. W.synced)
  W.alerts = {}
  check(M._t.runExport(false) == "failed", "failed")
  check(table.concat(W.alerts, "\n"):find("LINE書き出し中止", 1, true), "アラートを出す")
  check(W.synced == 2, "手動でも push する: " .. W.synced)
end)

test("昨日と同じ理由で今日も始められない時も、今日の分は1回残す", function()
  reset({ chats = chats({ "Berry" }), knobs = { noPermission = true } })
  writefile(REPO .. "/mac/.last_result", "day=20000101\nversion=v4.1-00000000\nng=0\n" ..
    "failed=Hammerspoon に「画面収録」が許可されていない（docs/setup-mac-auto.md）\n")
  local M = load()
  at9am(function() M._t.maybeRun() end)
  check(W.synced == 1 and heartbeat():find("last_run: " .. os.date("%Y-%m-%d"), 1, true), "今日の理由を push した")
  W.logs = {}; M.status()
  check(not table.concat(W.logs, "\n"):find("今日の自動実行: まだ", 1, true), "「まだ」と並べて出さない")
end)

test("窓を前に出している間に人が戻ったら、窓を動かさずに止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { userActsAtFirstActivate = true } })
  W.win.w = 800                                   -- 画面いっぱいにする必要がある窓
  local ok, err = pcall(exportOne, "Berry")
  check(not ok and type(err) == "table" and err.abort, "中断した: " .. tostring(type(err) == "table" and (err.abort or err.blocked) or err))
  check((W.focusCalls or 0) == 0 and W.opens == 0 and W.win.w == 800, "窓を動かしていない")
end)

test("保存名の照合は OCR 向けの読み替えをしない（「村田研一」は「村田研」ではない）", function()
  reset()
  local nm = load()._t.nameMatches
  check(not nm("[LINE]村田研一.txt", "村田研"), "村田研一")
  check(not nm("[LINE]村田研ー.txt", "村田研"), "村田研ー")
  check(not nm("[LINE](Berry).txt", "Berry"), "(Berry)")
  check(nm("[LINE]ＢＥＲＲＹ.txt", "Berry"), "全角英字は同じとみなす")
  reset({ chats = { { name = "村田研一" } } })
  local ok, e = exportOne("村田研")
  check(not ok and e.stage == "保存ダイアログ" and not W.saved, "保存せずに止めた: " .. tostring(e and e.stage))
end)

test("check: 保存ダイアログを閉じられなかったら、手で閉じるよう言う", function()
  reset({ chats = chats({ "Berry" }), knobs = { cancelIgnored = true } })
  local M = load(); W.logs = {}
  check(not M.check("Berry"), "NG")
  local out = table.concat(W.logs, "\n")
  check(out:find("次にすること: LINE に保存ダイアログが出たまま", 1, true), "手で閉じる:\n" .. out)
  check(not W.saved and not W.pressedSave, "保存していない")
end)

test("自動実行で想定外のエラーが出ても、今日を済みにせず、画面を消さない設定を戻す", function()
  reset({ chats = chats({ "Berry" }), knobs = { syncThrows = true } })
  local M = load()
  local ok, err = pcall(function() at9am(function() M._t.maybeRun() end) end)
  check(ok, "maybeRun はエラーを外に出さない: " .. tostring(err))
  local st = (readfile(REPO .. "/mac/.last_run") or ""):gsub("%s", "")
  check(st ~= TODAY, "今日を済みにしない: " .. st)
  check(M.lastCheck and tostring(M.lastCheck.why):find("想定外", 1, true), "理由: " .. tostring(M.lastCheck and M.lastCheck.why))
  check(W.displayIdle == false, "画面を消さない設定を戻した")
end)

test("maybeRun: 自動で始める時に手が動いていたら、中断に数えない", function()
  reset({ chats = chats({ "Berry" }) })
  local M = load()
  at9am(function() W.knobs.userBusy = true; M._t.maybeRun() end)
  local st = readfile(REPO .. "/mac/.last_run") or ""
  check(W.synced == 0 and #W.clicks == 0, "何もしていない")
  check(not st:find(TODAY, 1, true), "今日の回数を使っていない: " .. st)
  W.logs = {}; M.status()
  local out = table.concat(W.logs, "\n")
  check(not out:find("中断", 1, true) and out:find("手が動いていたので始めなかった", 1, true), "状態:\n" .. out)
end)

test("手動の中断は、自動実行の版と失敗数を書き換えない（新しい版でのやり直しが残る）", function()
  reset()
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  writefile(REPO .. "/mac/.last_result", "day=" .. TODAY .. "\nversion=v4.1-00000000\nng=2\n")
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  W.knobs.userActsAtClick = W.clickN + 1; W.lastHID = T - 999
  check(M._t.runExport(false) == "aborted", "中断した")
  local res = M._t.readResult()
  check(res.version == "v4.1-00000000" and res.ng == 2, "版と失敗数はそのまま: " .. res.version .. " " .. res.ng)
  W.logs = {}; M.status()
  check(table.concat(W.logs, "\n"):find("済み（失敗 2 件）。新しい版が入ったので", 1, true), "やり直す")
end)

test("時間切れで止めた時は、status に時間切れと出し、「触らない」とは言わない", function()
  reset()
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  at9am(function() W.knobs.jumpAtClick = 2; M._t.maybeRun() end)
  W.logs = {}; M.status()
  check(table.concat(W.logs, "\n"):find("1 回中断（最後: 時間切れ", 1, true), "理由")
  reset({ chats = chats({ "Berry" }), knobs = { jumpAtClick = 1 } })
  local M2 = load(); W.logs = {}
  M2.check("Berry")
  local o2 = table.concat(W.logs, "\n")
  check(o2:find("✗ 中断: 時間切れ", 1, true) and not o2:find("触らない", 1, true), "check:\n" .. o2)
end)

test("push: 変更なし・txt が無い時は「push できず」と言わない", function()
  for _, so in ipairs({ "2026-10-23 07:05:00 変更なし（push不要）\n", "2026-10-23 07:05:00 取り込む txt が無い: /x\n" }) do
    reset({ chats = chats({ "Berry" }), knobs = { syncOut = so } })
    local M = load(); W.logs = {}
    M.one("Berry")
    local out = table.concat(W.logs, "\n")
    check(out:find("/ 変更なし ===", 1, true) and not out:find("push できなかった", 1, true), "変更なし:\n" .. out)
  end
end)

-- ===================== 4回目のレビューで見つかった穴（v4.1）=====================
test("窓を探している間に人が戻ったら、窓を前に出したり大きさを変えたりしない", function()
  for _, w in ipairs({ SCREEN.w, 800 }) do
    reset({ chats = chats({ "Berry" }), knobs = { userActsInFindMain = true } })
    W.win.x, W.win.y, W.win.w, W.win.h = SCREEN.x, SCREEN.y, w, SCREEN.h
    local ok, err = pcall(exportOne, "Berry")
    check(not ok and type(err) == "table" and err.abort, "中断した（幅 " .. w .. "）")
    check((W.focusCalls or 0) == 0 and W.win.w == w, "前に出さず大きさも変えていない（幅 " .. w .. "）")
  end
end)

-- ===================== 自動更新（2026-10-23 了承）=====================
-- スクリプトの写しを読み込む（自動更新は自分のファイルを読み直すので、本物を書き換えないため）
local SELF_COPY = ROOT .. "/self/line_export.lua"
local function loadCopy(extra)
  run("mkdir -p " .. sh(ROOT .. "/self"))
  writefile(SELF_COPY, readfile(SCRIPT) .. (extra or ""))
  _G.__LINE_EXPORT, _G.__LINE_EXPORT_BAD, _G.__LINE_EXPORT_SRC = nil, nil, nil
  return dofile(SELF_COPY)
end
local function appendCopy(s) writefile(SELF_COPY, readfile(SELF_COPY) .. s) end

test("自動更新: 新しい版が無ければ git pull だけして、読み込み直さない", function()
  reset()
  local M = loadCopy()
  check(M._t.selfUpdate("テスト") == "same" and W.pulled, "pull して変わらず")
  check(_G.__LINE_EXPORT == M, "読み込み直していない")
  W.logs = {}; M.status()
  check(table.concat(W.logs, "\n"):find("自動更新: オン（30 分ごとに GitHub の main を見る）。最後: %d+:%d+ 新しい版なし"),
    "status に出す:\n" .. table.concat(W.logs, "\n"))
end)

test("自動更新: 新しい版が来たら読み込み直し、版が変わる", function()
  reset()
  local M = loadCopy()
  local old = M._t.VERSION
  appendCopy("\n-- 直した版\n")
  check(M._t.selfUpdate("テスト") == "reloaded", "読み込み直した")
  local M2 = _G.__LINE_EXPORT
  check(M2 ~= M and M2._t.VERSION ~= old, "新しい版: " .. tostring(M2 and M2._t.VERSION))
  local again = loadCopy(readfile(SELF_COPY):sub(#readfile(SCRIPT) + 1))
  check(again._t.VERSION == M2._t.VERSION, "版はファイルの中身から作る（普通に読み込んだ時と同じ）")
  check(M2._t.selfUpdate("テスト") == "same", "読み込んだ後は同じ版")
end)

test("自動更新: 新しい版に文法の誤りがあれば読み込まず、今の版のまま動く（同じ中身では2度試さない）", function()
  reset()
  local M = loadCopy()
  appendCopy("\nthis is not lua (\n")
  W.logs = {}
  check(M._t.selfUpdate("テスト") == "bad" and _G.__LINE_EXPORT == M, "読み込まない")
  check(table.concat(W.logs, "\n"):find("文法の誤り", 1, true), "ログに残す")
  check(M._t.selfUpdate("テスト") == "same" and _G.__LINE_EXPORT == M, "同じ中身は2度試さない")
end)

test("自動更新: 新しい版の読み込みに失敗したら、元の版に戻す", function()
  reset()
  local M = loadCopy()
  local old = M._t.VERSION
  -- 読み込みの最後（return M の前）で失敗する版
  local src = readfile(SELF_COPY)
  writefile(SELF_COPY, (src:gsub("\nreturn M%s*$", "\nerror('新しい版の読み込みで失敗')\nreturn M\n")))
  W.logs = {}
  check(M._t.selfUpdate("テスト") == "failed", "失敗を返す")
  local M2 = _G.__LINE_EXPORT
  check(M2 and M2._t and M2._t.VERSION == old, "元の版で動いている: " .. tostring(M2 and M2._t and M2._t.VERSION))
  check(table.concat(W.logs, "\n"):find("元の版に戻す", 1, true), "ログに残す")
  check(M2._t.selfUpdate("テスト") == "same", "同じ中身は2度試さない")
end)

test("自動更新: 書き出しの実行中・main 以外のブランチでは何もしない", function()
  reset({ chats = chats({ "Berry" }) })
  local M = loadCopy()
  local app = assert(M._t.prepareApp())
  M._t.beginRun(app)
  check(M._t.selfUpdate("テスト") == "skip" and not W.pulled, "実行中は何もしない")
  M._t.endRun()
  reset({ knobs = { branch = "try-v4" } })
  M = loadCopy()
  check(M._t.selfUpdate("テスト") == "notmain" and not W.pulled, "main 以外では pull しない")
end)

test("自動更新: git pull に失敗しても今の版のまま動き、同じ失敗は1回だけログに書く", function()
  reset({ knobs = { pullFails = true } })
  local M = loadCopy()
  W.logs = {}
  check(M._t.selfUpdate("テスト") == "pullfail" and M._t.selfUpdate("テスト") == "pullfail", "pullfail")
  local n = 0
  for _, l in ipairs(W.logs) do if l:find("自動更新の git pull に失敗", 1, true) then n = n + 1 end end
  check(n == 1 and _G.__LINE_EXPORT == M, "1回だけ: " .. n)
end)

test("自動更新: 手元に送れなかった取り込みがあって早送りできない時は、積み直して新しい版を読み込む", function()
  reset({ knobs = { pullDiverged = true, newSourceOnRebase = "\n-- GitHub の新しい版\n" } })
  local M = loadCopy()
  local old = M._t.VERSION
  W.logs = {}
  check(M._t.selfUpdate("テスト") == "reloaded", "読み込み直した")
  check(W.rebased and W.pushedAfterRebase and not W.rebaseAborted, "積み直して送った")
  check(_G.__LINE_EXPORT._t.VERSION ~= old, "新しい版")
  check(table.concat(W.logs, "\n"):find("積み直した", 1, true), "ログに残す")
end)

test("自動更新: 積み直しもできなければ元に戻し、今の版のまま動く", function()
  reset({ knobs = { pullDiverged = true, rebaseFails = true } })
  local M = loadCopy()
  W.logs = {}
  check(M._t.selfUpdate("テスト") == "pullfail" and _G.__LINE_EXPORT == M, "今の版のまま")
  check(W.rebaseAborted and not W.pushedAfterRebase, "積み直しを取り消した")
end)

test("自動更新: 手元に書き換えがある時は積み直さない（ぶつかった印を残さない）", function()
  reset({ knobs = { pullDiverged = true, dirty = " M mac/line_export.lua\n" } })
  local M = loadCopy()
  check(M._t.selfUpdate("テスト") == "pullfail" and not W.rebased, "積み直していない")
end)

test("自動更新: 前の回の積み直しが途中で止まっていたら取り消してから取り込む", function()
  reset({ knobs = { newSourceOnRebase = "\n-- x\n" } })
  run("mkdir -p " .. sh(REPO .. "/.git/rebase-merge"))
  local M = loadCopy()
  W.logs = {}
  M._t.selfUpdate("テスト")
  check(W.rebaseAborted and not exists(REPO .. "/.git/rebase-merge"), "取り消した")
  check(table.concat(W.logs, "\n"):find("途中で止まっていた積み直しを取り消した", 1, true), "ログに残す")
end)

test("手動の update() も、早送りできない時は積み直して最新にする", function()
  reset({ knobs = { pullDiverged = true } })
  local M = load()
  check(M.update() and W.rebased and W.reloaded, "積み直して読み込み直した")
end)

test("自動更新: 自動実行の後にも新しい版を確かめる", function()
  reset({ chats = chats({ "Berry" }) })
  local M = loadCopy()
  at9am(function() M._t.maybeRun() end)
  check(W.saved and W.pulled, "書き出した後に pull した")
end)

-- ===================== 実機（10/23 17:27）の自動の診断で見えたこと =====================
test("自動の診断: LINE の窓が見えない時は、理由を分けて出す", function()
  for _, case in ipairs({
    { setup = function() W.win.exists = false end, want = "この画面（デスクトップ）に LINE の窓が無い" },
    { setup = function() W.win.minimized = true end, want = "最小化されている" },
    { setup = function() W.knobs.appHidden = true end, want = "隠されている" },
  }) do
    reset({ chats = chats({ "Berry" }) })
    case.setup()
    local M = load()
    M.diag(true)                                  -- 自動の診断（実機で「見えない」と出た所）
    local out = readfile(DEBUG .. "/latest.txt") or ""
    check(out:find(case.want, 1, true), case.want .. ":\n" .. out)
    check(#W.clicks == 0 and W.win.minimized == (case.want == "最小化されている"), "何も押さず、最小化も戻さない")
  end
end)

test("昼の「見送り中」の診断ファイルには、その時の理由を「最後の確認」に出す", function()
  reset({ chats = chats({ "Berry" }) })
  local M = load()
  local realdate = os.date
  os.date = function(fmt, ...)
    if fmt == "*t" then local t = realdate("*t", ...); t.hour = 17; return t end
    return realdate(fmt, ...)
  end
  W.lastHID = T - 5
  local ok, err = pcall(function() M._t.maybeRun() end)
  os.date = realdate
  if not ok then error(err, 0) end
  local rep = readfile(DEBUG .. "/latest.txt") or ""
  check(rep:find("最後の確認: %d+:%d+ 使用中"), "最後の確認:\n" .. rep)
  check(not rep:find("秒後", 1, true) or not rep:find("約 %-"), "負の秒数を出さない")
end)

-- ===================== 状態ファイル（status.txt。2026-10-24 追加）=====================
-- 10:58 の後、Mac から何も届かず、走らない理由がこちらから見えなかった
local function status() return readfile(DEBUG .. "/status.txt") or "" end

test("状態: 読み込んだらすぐ status.txt を書く（版・読み込んだ記録・状態）", function()
  reset({ chats = chats({ "Berry" }) })
  local M = load()
  local st = status()
  check(st:find("why: 読み込んだ直後", 1, true) and st:find("version: " .. M._t.VERSION, 1, true), "見出し:\n" .. st)
  check(st:find("== 状態", 1, true) and st:find("最後の確認: まだ", 1, true), "状態の行:\n" .. st)
  check(st:find("== 自動更新の記録（古い順）\n  %d+:%d+ 読み込んだ: " .. M._t.VERSION:gsub("%-", "%%-")), "読み込んだ記録:\n" .. st)
  check(not st:find("Berry", 1, true), "トーク名を入れない")
end)

test("状態: 1分ごとの確認の理由を記録し、同じ理由が続く間は1行にまとめる。書き直すのは10分ごと", function()
  reset({ chats = chats({ "Berry" }) })
  local M
  atClock(6, 45, function() M = load() end)
  atClock(6, 50, function() M._t.tick(); M._t.tick(); M._t.tick() end)
  check(status():find("why: 読み込んだ直後", 1, true), "10分経つまでは書き直さない")
  W.lastHID = T - 5                                -- 07:00 を過ぎたら使用中
  atClock(9, 0, function() M._t.tick() end)
  local st = status()
  check(st:find("why: 定期（10 分ごと）", 1, true), "10分経ったら書き直す:\n" .. st)
  check(st:find("\n  06:50〜06:50（3 回） 07:00 より前\n", 1, true), "同じ理由は1行（回数つき）:\n" .. st)
  check(st:find("\n  09:00 使用中（無操作 5 秒。180 秒で始める）\n", 1, true), "理由が変わったら次の行:\n" .. st)
end)

test("状態: 時計が戻っても（時刻合わせ等）status.txt を書き続ける", function()
  reset({ chats = chats({ "Berry" }) })
  local M
  atClock(15, 0, function() M = load() end)
  atClock(9, 0, function() M._t.tick() end)
  check(status():find("why: 定期", 1, true), "書き直した:\n" .. status())
end)

test("状態: 今日は済み（失敗あり）で新しい版が来た日に、使用中で見送り続けても理由が残る", function()
  reset({ chats = chats({ "Berry" }) })
  writefile(REPO .. "/mac/.last_run", os.date("%Y%m%d") .. "\n")
  writefile(REPO .. "/mac/.last_result", "day=" .. os.date("%Y%m%d") .. "\nversion=v4.1-old\nng=8\n")
  local M
  atClock(13, 50, function() M = load() end)
  W.lastHID = T - 5
  atClock(14, 0, function() M._t.tick() end)
  atClock(14, 11, function() M._t.tick() end)
  local st = status()
  check(st:find("今日の書き出し: 済み（失敗 8 件）。新しい版が入ったので、離席したら失敗分をやり直す", 1, true), "状態:\n" .. st)
  check(st:find("14:00〜14:11（2 回） 使用中", 1, true), "見送りの理由:\n" .. st)
  check(heartbeat() == "" and W.synced == 0 and #W.clicks == 0, "公開の heartbeat には書かず、何も押さない")
end)

test("状態: 確認の途中で想定外のエラーが出ても止まらず、理由を残す", function()
  reset({ chats = chats({ "Berry" }) })
  local M = load()
  local real = hs.caffeinate.sessionProperties
  hs.caffeinate.sessionProperties = function() error("壊れた") end
  local ok, err = pcall(function() atClock(9, 30, function() M._t.tick() end) end)
  hs.caffeinate.sessionProperties = real
  check(ok, "tick は例外を外に出さない: " .. tostring(err))
  check(M.lastCheck and M.lastCheck.why:find("確認の途中で想定外のエラー", 1, true), "最後の確認に残す")
  check(table.concat(W.logs, "\n"):find("error: 確認の途中で想定外のエラー", 1, true), "ログにも出す")
end)

test("状態: 自動更新で読み込み直しても、確認と自動更新の記録を引き継ぐ", function()
  reset({ chats = chats({ "Berry" }) })
  local M = loadCopy()
  atClock(6, 10, function() M._t.tick() end)
  check(M._t.selfUpdate("テスト") == "same", "まず新しい版なし")
  appendCopy("\n-- 直した版\n")
  check(M._t.selfUpdate("テスト") == "reloaded", "読み込み直した")
  local M2 = _G.__LINE_EXPORT
  local st = status()
  check(st:find("version: " .. M2._t.VERSION, 1, true) and st:find("why: 読み込んだ直後", 1, true), "新しい版で書き直す:\n" .. st)
  check(st:find("06:10 07:00 より前", 1, true), "前の版の確認の記録:\n" .. st)
  local a = st:find("読み込んだ: " .. M._t.VERSION, 1, true)
  local b = st:find("新しい版なし", 1, true)
  local c = st:find("読み込んだ: " .. M2._t.VERSION, 1, true)
  check(a and b and c and a < b and b < c, "自動更新の記録（前の版を読み込んだ → 新しい版なし → 新しい版を読み込んだ）:\n" .. st)
end)

test("状態: 続けて新しい版を読み込んでも、版ごとに別の行に残す（版の名前はまとめない）", function()
  reset({ chats = chats({ "Berry" }) })
  local M = loadCopy()
  local seen = { M._t.VERSION }
  for i = 1, 3 do
    appendCopy("\n-- 直した版 " .. i .. "\n")
    check(_G.__LINE_EXPORT._t.selfUpdate("テスト") == "reloaded", "読み込み直した " .. i)
    seen[#seen + 1] = _G.__LINE_EXPORT._t.VERSION
  end
  local st = status()
  for _, v in ipairs(seen) do check(st:find("読み込んだ: " .. v, 1, true), v .. " の行:\n" .. st) end
  check(not st:find("回） 読み込んだ", 1, true), "まとめていない:\n" .. st)
end)

test("状態: 確認の理由は数字の違いをまとめ、自動更新の記録はまとめない", function()
  reset()
  local M = load()
  M.checkLog, M.updateLog = nil, nil
  M._t.remember("checkLog", "使用中（無操作 5 秒。180 秒で始める）", true)
  M._t.remember("checkLog", "使用中（無操作 65 秒。180 秒で始める）", true)
  M._t.remember("checkLog", "画面がロック中", true)
  check(#M.checkLog == 2 and M.checkLog[1].n == 2 and M.checkLog[1].text:find("65 秒", 1, true),
    "使用中は1行（最後の値）: " .. #M.checkLog)
  M._t.remember("updateLog", "読み込んだ: v4.1-11111111")
  M._t.remember("updateLog", "読み込んだ: v4.1-22222222")
  M._t.remember("updateLog", "読み込んだ: v4.1-22222222")
  check(#M.updateLog == 2 and M.updateLog[2].n == 2, "版ごとに別の行: " .. #M.updateLog)
  for i = 1, 50 do M._t.remember("checkLog", "理由" .. string.rep("あ", i)) end
  check(#M.checkLog == 40 and M.checkLog[40].text == "理由" .. string.rep("あ", 50), "最後の 40 行だけ持つ: " .. #M.checkLog)
end)

test("状態: 再起動・Reload Config で読み込んだ時は、前の status.txt を status.prev.txt に残す", function()
  reset({ chats = chats({ "Berry" }) })
  local M
  atClock(6, 0, function() M = load() end)
  W.lastHID = T - 5
  atClock(9, 0, function() M._t.tick() end)
  check(status():find("09:00 使用中", 1, true), "前の記録:\n" .. status())
  load()                                        -- 前の版が居ない読み込み（hs.reload と同じ）
  local prev = readfile(DEBUG .. "/status.prev.txt") or ""
  check(prev:find("09:00 使用中", 1, true), "前の status.txt を残した:\n" .. prev)
  check(status():find("why: 読み込んだ直後", 1, true) and not status():find("09:00 使用中", 1, true),
    "新しい status.txt は読み込んだ直後のもの")
  -- 自動更新の読み込み直し（前の版が居る）では残さない（記録を引き継ぐので要らない）
  local M2 = loadCopy()
  run("rm -f " .. sh(DEBUG .. "/status.prev.txt"))
  appendCopy("\n-- 直した版\n")
  check(M2._t.selfUpdate("テスト") == "reloaded", "読み込み直した")
  check(not readfile(DEBUG .. "/status.prev.txt"), "自動更新では status.prev.txt を作らない")
end)

test("状態: 自動実行の後に新しい版を読み込んだら、古い版の確認は status.txt を上書きしない", function()
  reset({ chats = chats({ "Berry" }), knobs = { appendOnPull = "\n-- 直した版\n" } })
  local M
  atClock(8, 45, function() M = loadCopy() end)
  atClock(9, 0, function() M._t.tick() end)
  local M2 = _G.__LINE_EXPORT
  check(W.saved and M2 ~= M, "書き出して、新しい版を読み込んだ")
  local st = status()
  check(st:find("version: " .. M2._t.VERSION, 1, true) and st:find("why: 読み込んだ直後", 1, true),
    "status.txt は新しい版のまま:\n" .. st)
  local clicks, lastCheck = #W.clicks, M.lastCheck
  local logN = #(M2.checkLog or {})
  local lastN = logN > 0 and M2.checkLog[logN].n or 0
  atClock(9, 30, function() M._t.tick() end)    -- 止め損ねた古いタイマーが動いても何もしない
  check(#W.clicks == clicks and _G.__LINE_EXPORT == M2 and status():find("version: " .. M2._t.VERSION, 1, true),
    "古い版の tick は何もしない")
  check(M.lastCheck == lastCheck and #(M2.checkLog or {}) == logN and (logN == 0 or M2.checkLog[logN].n == lastN),
    "古い版は確認もしない（記録を増やさない）")
end)

test("状態: 自動更新の失敗も記録に残す（git pull の失敗・読み込みの失敗）", function()
  reset({ chats = chats({ "Berry" }), knobs = { pullFails = true } })
  local M = loadCopy()
  check(M._t.selfUpdate("テスト") == "pullfail", "pull に失敗")
  M._t.writeStatus("テスト")
  check(status():find("== 自動更新の記録（古い順）\n[^=]*git pull に失敗"), "pull の失敗を記録に:\n" .. status())
  reset({ chats = chats({ "Berry" }) })
  M = loadCopy()
  local src = readfile(SELF_COPY)
  writefile(SELF_COPY, (src:gsub("\nreturn M%s*$", "\nerror('新しい版の読み込みで失敗')\nreturn M\n")))
  check(M._t.selfUpdate("テスト") == "failed", "読み込みに失敗")
  _G.__LINE_EXPORT._t.writeStatus("テスト")
  check(status():find("== 自動更新の記録（古い順）\n[^=]*新しい版の読み込みに失敗したので元の版に戻した"), "読み込みの失敗:\n" .. status())
end)

test("状態: 書き出した後の status.txt にもトーク名を入れない", function()
  reset({ chats = chats({ "Berry", "Cherry Pie", "Dango" }) })
  local M = load()
  at9am(function() M._t.maybeRun() end)
  check(W.saved, "書き出した")
  M.statusAt = nil
  at9am(function() M._t.tick() end)
  local st = status()
  check(st:find("why: 定期", 1, true) and st:find("今日の書き出し: 済み", 1, true), "書き出し後の状態:\n" .. st)
  for _, n in ipairs({ "Berry", "Cherry", "Dango" }) do check(not st:find(n, 1, true), n .. " を入れない:\n" .. st) end
end)

-- ===================== ネットにつなぐ処理の時間の上限（2026-10-26）=====================
-- 実機 10/25: Mac は起きていたのに 04:01 を最後に止まった。自動更新の git pull が
-- 通信の止まったまま返らず、Hammerspoon 全体が止まったとみられる
-- hs.execute(cmd)（第2引数なし）と同じく io.popen で動かす。対話のログインシェルの
-- 警告（標準エラー）は見ない
local function realRun(c)
  local t0 = os.time()
  local p = io.popen(c .. " 2>/dev/null"); local o = p:read("a"); local _, _, code = p:close()
  return o, code, os.time() - t0
end

test("時間の上限: 本物のシェルで、時間切れなら孫のプロセスごと打ち切って戻る", function()
  reset()
  local M = load()
  local NET = M._t.NET
  local o, code, dt = realRun("unset GIT_TERMINAL_PROMPT GIT_HTTP_LOW_SPEED_TIME; " ..
    NET.limited("echo hi; echo \"$GIT_TERMINAL_PROMPT/$GIT_HTTP_LOW_SPEED_TIME\"; exit 3", 5))
  check(o == "hi\n0/30\n" and code == 3, "普通に終われば出力と終わり方はそのまま（git の設定も渡す）: " .. o .. " " .. tostring(code))
  local pidf = ROOT .. "/grandchild.pid"
  os.remove(pidf)
  o, code, dt = realRun(NET.limited("(sleep 30 & echo $! > " .. sh(pidf) .. "); echo $$ >> " .. sh(pidf) .. "; sleep 30", 2))
  check(NET.timedOut(o) and code == 124 and dt <= 4, "時間切れで戻る（出力を握った孫がいても）: " .. o .. " " .. tostring(code) .. " " .. dt .. "s")
  local left = realRun("for i in 1 2 3 4 5 6; do alive=; for p in $(cat " .. sh(pidf) .. "); do kill -0 $p 2>/dev/null && alive=\"$alive $p\"; done; " ..
    "[ -z \"$alive\" ] && { echo none; exit; }; sleep 0.5; done; echo \"left:$alive\"")
  check((readfile(pidf) or ""):match("%d+%s+%d+") and left == "none\n", "孫のプロセスも残さない: " .. left .. " / " .. tostring(readfile(pidf)))
  o = realRun(NET.limited("echo \"$GIT_SSH_COMMAND\"", 5))
  check(o:find("BatchMode=yes", 1, true) and o:find("ConnectTimeout=20", 1, true), "ssh も止まったら諦める: " .. o)
  o, code = realRun(NET.limited("printf '%s\\n' \"it's ok\"", 5))
  check(o == "it's ok\n" and code == 0, "引用符を含む命令もそのまま: " .. o)
end)

test("時間の上限: 本物の git で、上限つきの pull が取り込める（ログインシェル経由・第2引数なし）", function()
  reset()
  local M = load()
  local base = ROOT .. "/realgit"
  run("rm -rf " .. sh(base) .. " && mkdir -p " .. sh(base))
  local g = "cd " .. sh(base) .. " && git init -q --bare -b main origin.git && git clone -q origin.git a && " ..
    "cd a && git -c user.name=t -c user.email=t@e commit -q --allow-empty -m one && git push -q origin main && " ..
    "cd .. && git clone -q origin.git b && cd a && git -c user.name=t -c user.email=t@e commit -q --allow-empty -m two && git push -q origin main"
  run("{ export GIT_CONFIG_GLOBAL=/dev/null; " .. g .. "; } >/dev/null 2>&1")   -- 走らせる人の ~/.gitconfig に左右されない
  local before = run("git -C " .. sh(base .. "/b") .. " rev-parse HEAD")
  local o, code = realRun("GIT_ALLOW_PROTOCOL=file " ..
    M._t.NET.limited("git -C " .. sh(base .. "/b") .. " pull --ff-only -q origin main 2>&1", 30))
  local after = run("git -C " .. sh(base .. "/b") .. " rev-parse HEAD")
  check(code == 0 and before ~= after and after == run("git -C " .. sh(base .. "/a") .. " rev-parse HEAD"),
    "取り込めた: " .. tostring(code) .. " " .. o)
end)

test("時間の上限: 自動更新の git pull・積み直し・push と sync.sh は、時間を区切って呼ぶ", function()
  reset({ chats = chats({ "Berry" }), knobs = { pullDiverged = true } })
  local M = load()
  check(M._t.pullLatest() == true, "積み直して取り込んだ")
  at9am(function() M._t.maybeRun() end)
  local wrapped = { pull = false, rebase = false, push = false, sync = false, branch = false }
  for _, c in ipairs(W.cmds) do
    local lim = c:find("/usr/bin/perl -e", 1, true) and c:find("GIT_HTTP_LOW_SPEED_TIME=30", 1, true)
    if c:find("pull --ff-only", 1, true) then wrapped.pull = lim and true or false end
    if c:find("pull --rebase", 1, true) then wrapped.rebase = lim and true or false end
    if c:find("push -q origin main", 1, true) then wrapped.push = lim and true or false end
    if c:find("sync.sh", 1, true) then wrapped.sync = lim and true or false end
    if c:find("symbolic-ref", 1, true) then wrapped.branch = lim and true or false end
  end
  for k, v in pairs(wrapped) do check(v, k .. " を時間の上限つきで呼ぶ") end
  check(not W.brokenUserEnv, "hs.execute の第2引数 true で壊れる命令を渡していない: " .. tostring(W.brokenUserEnv))
end)

test("時間の上限: git pull を打ち切ったら、残った鍵を消して今の版のまま動き、記録に残す", function()
  reset({ chats = chats({ "Berry" }), knobs = { pullTimeout = true } })
  local M = loadCopy()
  run("mkdir -p " .. sh(REPO .. "/.git")); writefile(REPO .. "/.git/index.lock", "")
  check(M._t.selfUpdate("テスト") == "pullfail" and _G.__LINE_EXPORT == M, "今の版のまま")
  check(not readfile(REPO .. "/.git/index.lock"), "打ち切った git の鍵を消した")
  M._t.writeStatus("テスト")
  check(status():find("== 自動更新の記録（古い順）\n[^=]*git pull に失敗"), "記録に残す:\n" .. status())
  check(M.lastUpdate.err:find("打ち切った", 1, true), "理由: " .. tostring(M.lastUpdate.err))
  W.knobs.pullTimeout = nil
  check(M._t.selfUpdate("テスト") == "same", "通信が戻れば次の確認でまた取り込める")
end)

test("時間の上限: git pull が時間切れでなく失敗した時は、.git/index.lock を消さない（人の git が使っている）", function()
  reset({ chats = chats({ "Berry" }), knobs = { pullFails = true } })
  local M = loadCopy()
  run("mkdir -p " .. sh(REPO .. "/.git")); writefile(REPO .. "/.git/index.lock", "")
  check(M._t.selfUpdate("テスト") == "pullfail", "pull に失敗")
  check(readfile(REPO .. "/.git/index.lock") == "", "鍵は残す")
end)

test("時間の上限: sync.sh を打ち切ったら「push できず」と分かる形で返し、鍵を消す", function()
  reset({ chats = chats({ "Berry" }), knobs = { syncTimeout = true } })
  local M = load()
  run("mkdir -p " .. sh(REPO .. "/.git")); writefile(REPO .. "/.git/index.lock", "")
  local r = M._t.runSync()
  check(r == "push できず（10 分で打ち切った）", "結果: " .. tostring(r))
  check(not readfile(REPO .. "/.git/index.lock"), "鍵を消した")
  check(table.concat(W.logs, "\n"):find("sync: push できず（10 分で打ち切った）（理由は", 1, true), "ログ:\n" .. table.concat(W.logs, "\n"))
end)

test("時間の上限: sync.sh を打ち切った時も、1件の書き出しと手動の実行では「push できなかった」と出す", function()
  reset({ chats = chats({ "Berry" }), knobs = { syncTimeout = true } })
  local M = load()
  W.logs = {}
  M.one("Berry")
  local out = table.concat(W.logs, "\n")
  check(out:find("/ push できず（10 分で打ち切った） ===", 1, true) and out:find("push できなかった", 1, true), "1件:\n" .. out)
  reset({ chats = chats({ "Berry" }), knobs = { syncTimeout = true } })
  M = load()
  M._t.runExport(false)
  check(W.consoleOpened, "手動の実行ではコンソールを前に出す")
end)

-- ===================== 開始の時刻（2026-10-25: 07:00 → 00:00）=====================
-- 実機 10/25: 03:03 に離れて 03:23 にロック、03:52 に離れて 03:57 にロック。
-- 07:00 より前だったので走れず、その後は朝までロックか眠りだった
local function withDefaultRunAt(fn)
  local keep = ENV.LINE_DUMP_RUN_AT
  ENV.LINE_DUMP_RUN_AT = nil
  local ok, err = pcall(fn)
  ENV.LINE_DUMP_RUN_AT = keep
  if not ok then error(err, 0) end
end

test("開始の時刻: 既定は 00:00。夜中に離れてロックされるまでの間に走る", function()
  withDefaultRunAt(function()
    reset({ chats = chats({ "Berry", "Cherry Pie" }) })
    local M = load()
    atClock(3, 6, function() M._t.tick() end)
    check(W.saved, "03:06 の離席で書き出した")
    check(M.lastCheck and M.lastCheck.why:find("自動実行: 最後まで", 1, true), "最後の確認: " .. tostring(M.lastCheck and M.lastCheck.why))
    check(heartbeat():find("last_run: ", 1, true) and W.synced >= 1, "heartbeat を書いて push した")
    local st = status()
    check(st:find("自動実行の条件: 毎日 00:00 以降", 1, true), "状態に条件:\n" .. st)
  end)
end)

test("開始の時刻: 既定（00:00）でも、使用中・ロック中は始めない", function()
  withDefaultRunAt(function()
    reset({ chats = chats({ "Berry" }) })
    local M = load()
    W.lastHID = T - 30
    atClock(0, 30, function() M._t.tick() end)
    check(not W.saved and #W.clicks == 0, "使用中は始めない")
    W.lastHID = T - 999; W.knobs.locked = true
    atClock(0, 40, function() M._t.tick() end)
    check(not W.saved and #W.clicks == 0, "ロック中は始めない")
    check(M.lastCheck.why == "画面がロック中", "理由: " .. tostring(M.lastCheck.why))
  end)
end)

if ROOT:match("^/.+/[^/]+$") then run("rm -rf " .. sh(ROOT)) end
realprint(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
