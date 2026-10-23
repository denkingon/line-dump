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
local ENV = {
  HOME = ROOT .. "/home", LINE_DUMP_REPO = ROOT .. "/repo",
  LINE_DUMP_RAW_DIR = ROOT .. "/out", TMPDIR = ROOT .. "/tmp",
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
local LINE_PID, OTHER_PID = 4242, 999
local T = 1000000                     -- 偽の時計（usleep で進む）

local function reset(opts)
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

local function chat(name) for _, c in ipairs(W.chats) do if c.name == name then return c end end end

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
  return W.knobs.menuItems or { "通知オフ", "トークを保存", "トーク履歴を削除", "退会" }
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
    if not W.knobs.ocrDropRows then add(c.ocrRow or c.name, L.rowX, L.rowY(i)) end
    -- 最後のメッセージ。実機では時刻の 20pt 下（名前の 11pt 下）のこともある: previewDY
    add(c.preview or "最後のメッセージ", L.rowX, L.rowY(i) + (W.knobs.previewDY or 18))
    -- 行の右上に最後のメッセージの時刻（実機と同じく名前より少し上）
    if not W.knobs.noRowTimes then add(c.time or "12:34", L.field.x + 250, L.rowY(i) - 9) end
    ::hidden::
  end
  if W.open then
    local c = chat(W.open) or { name = W.open }
    -- ヘッダは開いてから headerDelay 秒たって出る（読み込みが遅い時）
    if not W.knobs.headerDelay or T - (W.openedAt or 0) >= W.knobs.headerDelay then
      add(c.ocrHeader or c.name, L.header.x, L.header.y)
    end
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
end

local function doSave(p)
  writefile(p, "2026.10.20 火曜日\n10:00 誰か テスト\n")
  if W.knobs.mtimeAgo then age(p, W.knobs.mtimeAgo) end
  W.saved = p; W.sheet = nil; W.focus = nil
end

-- 行を押した時に開くトーク（wrongChatOnce は最初の1回だけ別のトークが開く）
local function opened(c)
  if W.knobs.wrongChatOnce and not W.wrongDone then W.wrongDone = true; return W.knobs.wrongChatOnce end
  return W.knobs.wrongChatOnClick or c.name
end

-- 押した所に重なっている物（通知バナーなど）
local function overlayAt(pt)
  for _, o in ipairs(W.overlays or {}) do
    local x, y = W.win.x + o.dx, W.win.y + o.dy
    if pt.x >= x and pt.x <= x + o.w and pt.y >= y and pt.y <= y + o.h then return o end
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
  if W.open and not W.knobs.menuBroken
     and math.abs(pt.x - L.dots.x) < 5 and math.abs(pt.y - L.dots.y) < 5 then
    W.menuOpen = true; return
  end
  local f = L.field
  if pt.x >= f.x and pt.x <= f.x + f.w and pt.y >= f.y and pt.y <= f.y + f.h then
    if not W.knobs.clickNoFocus then W.focus = "search" end
    return
  end
  for i, c in ipairs(results()) do
    if L.rowY(i) >= L.listTop and math.abs(pt.y - L.rowY(i)) < 28
       and pt.x > L.field.x - 60 and pt.x < L.field.x + L.field.w + 10 then
      W.open = opened(c); W.openedAt = T
      W.openLog[#W.openLog + 1] = c.name
      W.focus = "input"
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
      W.pressedSave = true
      if exists(p) then W.sheet.confirm = p; return end
      doSave(p)
    end }),
    el({ AXRole = "AXButton", AXTitle = "キャンセル" }, { AXPress = function()
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
    if W.knobs.userActsAtFirstActivate and not W.actDone then
      W.actDone = true; W.pendingUser = "key"; W.knobs.frontIsOther = true   -- 人が戻って別のアプリを押した
    end
    if W.stolen then
      W.stolen = false; W.reactivated = (W.reactivated or 0) + 1
      if W.knobs.userActsAtActivate then W.pendingUser = "key" end   -- 前に出し直している間に人が触った
    end
  end,
}

local function execute(cmd)
  W.cmds[#W.cmds + 1] = cmd
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
    if W.knobs.syncThrows then error("sync boom", 0) end
    if W.knobs.syncOut then return W.knobs.syncOut, true end
    if W.knobs.syncFails then return "error: push に失敗。ネットワークか認証を確認する\n", true end
    return "push 完了\n", true
  end
  if cmd:match("symbolic%-ref") then return (W.knobs.branch or "main") .. "\n", true end
  if cmd:match("pull %-%-ff%-only") then
    W.pulled = true
    if W.knobs.pullFails then return "error: Your local changes to the following files would be overwritten by merge:\n", false end
    return "", true
  end
  if cmd:match("pmset %-g") then return " displaysleep         " .. (W.knobs.displaySleep or 10) .. "\n", true end
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
    watcher = { new = function() return { start = function() end, stop = function() end } end,
                systemDidWake = 1, screensDidUnlock = 2, sessionDidBecomeActive = 3 },
  },
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
      if W.sheet then return end                     -- シートが出ている間は一覧も動かない
      off = { off[1], amount }
      if W.knobs.userActsAtScroll == W.scrolls then W.pendingUser = "key" end
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
  reload = function() W.reloaded = true end,
  application = {
    find = function() return W.running and appObj or nil end,
    -- 本物は処理の途中では更新されない（コンソールから実行すると Hammerspoon のまま）
    frontmostApplication = function()
      return { bundleID = function() return "org.hammerspoon.Hammerspoon" end }
    end,
    applicationForPID = function(pid)
      local names = W.knobs.pidNames or {}
      if names[pid] then return { name = function() return names[pid] end } end
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
      if overlayAt({ x = x, y = y }) then return el({ pid = OTHER_PID }) end
      return el({ pid = LINE_PID })
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
local function test(name, fn)
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
  check(#W.openLog == 1 and W.openLog[1] == "パプリカ🌶️", "別のトークは開いていない: " .. table.concat(W.openLog, ","))
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

test("AX で完全一致の行を開いたのに別トークが開いたら止める", function()
  reset({ chats = chats({ "かにっこにー3", "かにっこにー" }),
          knobs = { ocrDropRows = true, wrongChatOnClick = "かにっこにー3" } })
  local ok, e = exportOne("かにっこにー")
  check(not ok and e.stage == "トーク確認", "トーク確認で失敗: " .. tostring(e and e.stage))
  check(not W.saved, "保存していない")
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

test("「かにっこにー」を押したのに「かにっこにー3」が開いたら止める", function()
  reset({ chats = chats({ "かにっこにー3", "かにっこにー" }), knobs = { wrongChatOnClick = "かにっこにー3" } })
  local ok, e = exportOne("かにっこにー")
  check(not ok and e.stage == "トーク確認", "トーク確認で失敗: " .. tostring(e and e.stage))
  check(not W.saved, "保存していない")
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

-- ===================== 今のトーク名を集める =====================
local function namesTxt() return readfile(DEBUG .. "/names.txt") or "" end
local function withTargets(extra)
  local M = load()
  local list = {}
  for _, c in ipairs(extra or {}) do list[#list + 1] = c end
  W.chats = list
  return M
end

test("1日1回、書き出しの前に一覧を上から下まで読んで今のトーク名を集め、names.txt に名前だけを書く", function()
  reset()
  local list = {}
  for i = 1, 40 do list[#list + 1] = { name = "トーク" .. i .. "番", preview = "秘密のメッセージ" .. i } end
  list[#list + 1] = { name = "Berry", preview = "秘密のメッセージB" }
  local M = withTargets(list)
  W.search = "前の検索"
  M._t.runExport()
  local nt = namesTxt()
  local all = true
  for i = 1, 40 do if not nt:find("\nトーク" .. i .. "番\n", 1, true) then all = false end end
  check(all and nt:find("\nBerry\n", 1, true), "41件とも集めた:\n" .. nt)
  check(nt:find("一覧の終わりまで読んだ", 1, true), "終わりまで読んだと書く:\n" .. nt)
  check(not nt:find("秘密", 1, true), "最後のメッセージは書かない")
  check(nt:find("Berry → Berry（同じ名前）", 1, true), "TARGETS ごとの近い名前:\n" .. nt)
  check((W.scrolls or 0) >= 3 and (W.listScroll or 0) == 0, "スクロールして読み、一番上に戻した（" .. tostring(W.scrolls) .. " 回）")
  check(W.saved and W.saved:find("[LINE]Berry_", 1, true), "Berry は書き出した")
  local scrolls = W.scrolls
  M._t.runExport()
  check(W.scrolls == scrolls, "同じ日の2回目は集め直さない")
  safe()
end)

test("名前が似ているだけのトーク（Berry と Berry2）は書き出さず、names.txt に候補として書くだけ", function()
  reset()
  local M = withTargets({ { name = "直承Jikisho" }, { name = "Berry2" } })
  M._t.runExport()
  check(not W.saved, "Berry2 を書き出していない: " .. tostring(W.saved))
  check(namesTxt():find("Berry → Berry2（0.92）", 1, true), "候補として書く:\n" .. namesTxt())
  safe()
end)

test("名前が変わったトーク（il 石川ありがとう → il 石川ありがとう!）も自動では書き出さない（TARGETS を直す）", function()
  reset()
  local M = withTargets({ { name = "直承Jikisho" }, { name = "il 石川ありがとう!" } })
  M._t.runExport()
  check(not W.saved, "書き出していない")
  check(namesTxt():find("il 石川ありがとう → il 石川ありがとう!（0.95）", 1, true), "候補:\n" .. namesTxt())
  safe()
end)

test("名前の絵文字を OCR が別の字に読んだ行は、OCR で読んだ文字だと分かるように書く", function()
  reset()
  local M = withTargets({ { name = "パプリカ🌶️", ocrRow = "パプリカ》", ocrHeader = "パプリカ》", noAX = true } })
  M._t.runExport()
  check(namesTxt():find("パプリカ》\t（OCR で読んだ文字）", 1, true), "OCR の印:\n" .. namesTxt())
  check(W.saved and W.saved:find("[LINE]パプリカ🌶️_", 1, true), "パプリカ🌶️ は今までどおり書き出す: " .. tostring(W.saved))
  safe()
end)

test("実機の行の並び（最後のメッセージが時刻の 20pt 下）でも、1字・絵文字だけの名前の行で最後のメッセージを名前として書かない", function()
  reset({ knobs = { previewDY = 11 } })
  local M = withTargets({ { name = "母", preview = "秘密のメッセージ1" }, { name = "🐱", preview = "秘密のメッセージ2" },
                          { name = "Berry", preview = "秘密のメッセージ3" } })
  M._t.runExport()
  local nt = namesTxt()
  check(nt:find("\n母\n", 1, true) and nt:find("\nBerry\n", 1, true), "名前は集めた:\n" .. nt)
  check(not nt:find("秘密", 1, true), "最後のメッセージは書かない:\n" .. nt)
  safe()
end)

test("ずれが 0.5pt でも、スクロールの量を整数で渡して一覧を最後まで読む", function()
  reset({ knobs = { ocrHalf = true } })
  local list = {}
  for i = 1, 30 do list[#list + 1] = { name = "トーク" .. i .. "番" } end
  local M = withTargets(list)
  M._t.runExport()
  check(not W.fractionalScroll, "小数の量を渡していない")
  check(namesTxt():find("\nトーク30番\n", 1, true), "最後の行まで集めた:\n" .. namesTxt())
  safe()
end)

test("似ているだけの名前（村田研 と 村田研OB会）は、近さ付きの候補として書く", function()
  reset()
  local M = withTargets({ { name = "直承Jikisho" }, { name = "村田研OB会" } })
  M._t.runExport()
  check(not W.saved, "書き出さない")
  check(namesTxt():find("村田研 → 村田研OB会（0.75）", 1, true), "候補:\n" .. namesTxt())
  safe()
end)

test("名前を集めている時に人が触ったら、全体を止めて何も開かず、理由を診断ファイルに書く", function()
  reset({ knobs = { userActsAtScroll = 2 } })
  local M = withTargets({ { name = "Berry" }, { name = "直承Jikisho" } })
  local r = M._t.runExport()
  check(r == "aborted", "中断: " .. tostring(r))
  check(#W.openLog == 0 and not W.saved, "何も開いていない")
  check(heartbeat():find("今のトーク名を集めている時に中断", 1, true), "heartbeat に中断:\n" .. heartbeat())
  local rep = readfile(DEBUG .. "/latest.txt") or ""
  check(rep:find("今のトーク名を集める", 1, true) and rep:find("人の操作", 1, true), "診断ファイルに理由:\n" .. rep)
end)

test("検索欄にフォーカスが入らない時は、キーを送らずに AX で消してから名前を集める", function()
  reset({ knobs = { focusIgnored = true, clickNoFocus = true } })
  local M = withTargets({ { name = "Berry" }, { name = "直承Jikisho" } })
  W.search = "前の検索"
  M._t.runExport()
  check(W.draft == nil, "入力欄に何も打っていない・消していない: " .. tostring(W.draft))
  check(namesTxt():find("\nBerry\n", 1, true), "名前を集めた:\n" .. namesTxt())
  safe()
end)

test("フルスクリーン（AX が 30pt 下）でも名前を集める", function()
  reset({ knobs = { axDY = 30 } })
  local M = withTargets({ { name = "直承Jikisho" }, { name = "Berry" } })
  W.search = "前の検索"
  M._t.runExport()
  check(namesTxt():find("\nBerry\n", 1, true) and W.saved, "集めて書き出した:\n" .. namesTxt())
  safe()
end)

test("前の件の保存ダイアログが残っていたら、閉じてから名前を集める", function()
  reset()
  local M = withTargets({ { name = "Berry" }, { name = "直承Jikisho" } })
  W.open = "直承Jikisho"; W.sheet = { value = "[LINE]直承Jikisho.txt" }; W.focus = "sheet"
  M._t.runExport()
  check(W.cancelled and W.scrollsAtCancel == 0, "スクロールより先に閉じた: " .. tostring(W.scrollsAtCancel))
  check(namesTxt():find("\nBerry\n", 1, true), "集めた:\n" .. namesTxt())
  safe()
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

test("中断した日のやり直しは、済んだトークを飛ばして残りから進める", function()
  reset()
  local M = load()
  for _, t in ipairs(M._t.targets) do W.chats[#W.chats + 1] = { name = type(t) == "table" and t[1] or t } end
  local first = type(M._t.targets[1]) == "table" and M._t.targets[1][1] or M._t.targets[1]
  local saves = 0
  local origSet = hs.pasteboard.setContents
  at9am(function()
    W.knobs.userActsAtClick = 30
    M._t.maybeRun()
    local hb1 = heartbeat()
    check(hb1:find("中断", 1, true), "1回目は中断: \n" .. hb1)
    W.knobs.userActsAtClick = nil; W.clickN = 0; W.lastHID = T - 999
    W.search = ""; W.saved = nil
    check(W.openLog[1] == first, "1回目は " .. first .. " から開いた")
    W.openLog = {}
    M._t.maybeRun()
    check(#W.openLog > 0, "2回目も開いた")
    for _, n in ipairs(W.openLog) do check(n ~= first, "済んだ " .. first .. " は開き直していない") end
    local hb2 = heartbeat()
    check(line(hb2, "ok: " .. #M._t.targets), "合わせて全件 OK: \n" .. hb2)
  end)
  hs.pasteboard.setContents = origSet
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
test("runExport: 全件を回し、heartbeat に段と画像を書いて push する", function()
  reset()
  local M = load()
  for _, t in ipairs(M._t.targets) do
    local name = type(t) == "table" and t[1] or t
    if name ~= "村田研" then W.chats[#W.chats + 1] = { name = name } end
  end
  M._t.runExport()
  local hb = heartbeat()
  local n = #M._t.targets
  check(hb:find("\nversion: v4%.1%-%x+\n"), "heartbeat に版（v4.1-中身から作る印）")
  check(line(hb, "ok: " .. (n - 1)) and line(hb, "ng: 1"), "ok/ng の数: \n" .. hb)
  check(hb:find("村田研: [トーク選択]", 1, true), "失敗した段を書く")
  check(hb:find("（画像: Dropbox の ", 1, true) and hb:find("\ndebug: Dropbox の ", 1, true), "画像の置き場を書く（Dropbox）")
  check(exists(DEBUG .. "/latest.txt"), "診断ファイルを Dropbox に書いた")
  check(not hb:find(HOME, 1, true), "heartbeat にユーザー名入りのパスを書かない")
  check(W.synced == 1, "sync.sh を1回呼んだ")
  local files = run("ls " .. sh(OUT))
  check(select(2, files:gsub("_" .. TODAY .. "%.txt", "")) == n - 1, "OUT_DIR に今日付きが " .. (n - 1) .. " 件")
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
  check(m("パプリカ🌶️（82）") == "〈パプリカ〉", "絵文字・メンバー数付きでも: " .. m("パプリカ🌶️（82）"))
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

test("maybeRun: 新しい版が入った日は、失敗していた分だけもう一度試す（版ごとに1回）", function()
  reset()
  local M = load()
  local names = {}
  for _, t in ipairs(M._t.targets) do names[#names + 1] = type(t) == "table" and t[1] or t end
  -- 1件目は今回も一覧に無い（失敗が残る）。それでも同じ版では2度やらない
  for i = 2, #names do W.chats[#W.chats + 1] = { name = names[i] } end
  writefile(REPO .. "/mac/.last_run", TODAY .. "\n")
  local res = { "day=" .. TODAY, "version=v4.1-00000000", "ng=2" }
  for i = 3, #names do res[#res + 1] = "ok=" .. names[i] end
  writefile(REPO .. "/mac/.last_result", table.concat(res, "\n") .. "\n")
  M = load()                                       -- 新しい版を読み込んだ
  at9am(function()
    M._t.maybeRun()
    check(#W.openLog == 1 and W.openLog[1] == names[2],
      "失敗していた2件だけ試した（1件目は見つからず、2件目を開いた）: " .. table.concat(W.openLog, ","))
    check(line(heartbeat(), "ok: " .. (#names - 1)) and line(heartbeat(), "ng: 1"), "合わせて1件だけ NG:\n" .. heartbeat())
    local synced = W.synced
    W.lastHID = T - 999
    M._t.maybeRun()
    check(W.synced == synced, "同じ版ではもうやらない")
  end)
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
  reset()
  local M = load()
  local names = {}
  for _, t in ipairs(M._t.targets) do names[#names + 1] = type(t) == "table" and t[1] or t end
  for i = 3, #names do W.chats[#W.chats + 1] = { name = names[i] } end   -- 2件は見つからない
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

test("TARGETS が空なら、毎分アラートを出さず、理由を1日1回だけ残す", function()
  reset({ chats = chats({ "Berry" }) })
  local M = load()
  for i = #M._t.targets, 1, -1 do table.remove(M._t.targets, i) end
  at9am(function() for _ = 1, 4 do W.lastHID = T - 999; M._t.maybeRun() end end)
  local n = 0
  for _, a in ipairs(W.alerts) do if a:find("TARGETS が空", 1, true) then n = n + 1 end end
  check(n == 1 and W.synced == 1, "1回だけ: alerts=" .. n .. " synced=" .. W.synced)
  check(heartbeat():find("TARGETS が空", 1, true), "heartbeat に理由")
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

run("rm -rf " .. sh(ROOT))
realprint(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
