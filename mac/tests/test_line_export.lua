-- line_export.lua（v4）のテスト。Mac も Hammerspoon も無い所で流れを検証する。
--
--   lua mac/tests/test_line_export.lua        （Lua 5.4。-v で途中ログも出す）
--
-- hs.* を偽物に差し替え、画面・AX・保存シート・クリック・OCR 出力を持つ
-- 「偽の LINE」を動かす。OCR は偽の画面の文字と位置をそのまま返すので、
-- ここで確かめられるのは「読んだ結果からどこを押すか・どう止まるか」の
-- 判断と座標換算まで。実機の OCR 精度や LINE の見た目は ⌘⌥⌃K の診断で確かめる。
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

-- ===================== 偽の世界 =====================
local W
local SCALE = 2
local SCREEN = { x = 0, y = 25, w = 1440, h = 875 }

local function reset(opts)
  run("rm -rf " .. sh(ROOT .. "/home") .. " " .. sh(ROOT .. "/repo") .. " " ..
      sh(ROOT .. "/out") .. " " .. sh(ROOT .. "/tmp"))
  for _, d in ipairs({ HOME .. "/Downloads", HOME .. "/Desktop", HOME .. "/Documents",
                       REPO .. "/mac", OUT, ENV.TMPDIR }) do
    run("mkdir -p " .. sh(d))
  end
  writefile(REPO .. "/mac/ocr.applescript", "-- 偽物（osascript は hs.execute の偽物が受ける）\n")
  W = {
    running = true,
    win = { x = 100, y = 100, w = 1000, h = 700, visible = true, minimized = false, exists = true },
    chats = {}, search = "", open = nil, menuOpen = false, sheet = nil,
    focus = nil, clipboard = "ORIGINAL", knobs = {}, axCalls = 0,
    clicks = {}, keys = {}, cmds = {}, caps = {}, alerts = {}, logs = {},
    opens = 0, synced = 0, escape = false, called = false, menuClicked = {},
  }
  for k, v in pairs(opts or {}) do W[k] = v end
end

local function chat(name) for _, c in ipairs(W.chats) do if c.name == name then return c end end end

local function layout()
  local f = W.win
  local field = { x = f.x + 80, y = f.y + 50, w = 260, h = 28 }
  local hy = f.y + 66
  local k = W.knobs
  return {
    field = field,
    rowY = function(i) return field.y + field.h + 40 + (i - 1) * 64 end,
    rowX = field.x + 130,
    header = { x = f.x + 430, y = hy },
    dots = { x = f.x + f.w - 24 + (k.menuDX or 0), y = hy + (k.menuDY or 0) },
    call = { x = f.x + f.w - 60, y = hy },
    menuItem = function(i) return { x = f.x + f.w - 90, y = hy + 40 + i * 32 } end,
    input = { x = f.x + 360, y = f.y + f.h - 60, w = 600, h = 40 },
  }
end

local function results()
  local r = {}
  for _, c in ipairs(W.chats) do
    if W.search == "" or c.name:find(W.search, 1, true) then r[#r + 1] = c end
  end
  return r
end

local function menuItems()
  return W.knobs.menuItems or { "通知オフ", "トークを保存", "トーク履歴を削除", "退会" }
end

-- 画面に見えている文字（論理座標）
local function visibleTexts()
  local L, t = layout(), {}
  local function add(s, x, y) t[#t + 1] = { s = s, x = x, y = y } end
  if not W.win.visible then return t end
  add(W.search ~= "" and W.search or "検索", L.field.x + L.field.w / 2, L.field.y + L.field.h / 2)
  for i, c in ipairs(results()) do
    if not W.knobs.ocrDropRows then add(c.ocrRow or c.name, L.rowX, L.rowY(i)) end
    add("最後のメッセージ", L.rowX, L.rowY(i) + 18)
  end
  if W.open then
    local c = chat(W.open) or { name = W.open }
    add(c.ocrHeader or c.name, L.header.x, L.header.y)
    for _, m in ipairs(c.messages or {}) do add(m.s, W.win.x + m.dx, W.win.y + m.dy) end
  end
  if W.menuOpen then
    for i, s in ipairs(menuItems()) do
      if not (W.knobs.ocrDrop and W.knobs.ocrDrop[s]) then
        local p = L.menuItem(i); add(s, p.x, p.y)
      end
    end
  end
  return t
end

local function ocrOutput(cap)
  local lines = {}
  local texts = visibleTexts()
  -- 通知バナーなど LINE の窓の外のものは、画面を撮った時だけ写る
  if cap.screen then
    for _, b in ipairs(W.banners or {}) do texts[#texts + 1] = { s = b.s, x = W.win.x + b.dx, y = W.win.y + b.dy } end
  end
  for _, it in ipairs(texts) do
    if it.x >= cap.x and it.x <= cap.x + cap.w and it.y >= cap.y and it.y <= cap.y + cap.h then
      lines[#lines + 1] = string.format("%s\t%d\t%d\t%d\t%d", it.s,
        math.floor((it.x - cap.x) * SCALE + 0.5), math.floor((it.y - cap.y) * SCALE + 0.5),
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
  W.sheet = { value = W.knobs.defaultName or ("[LINE]" .. W.open .. ".txt"), cursorEnd = false }
  W.focus = "sheet"
end

local function doSave(p)
  writefile(p, "2026.10.20 火曜日\n10:00 誰か テスト\n")
  if W.knobs.mtime then run("touch -d " .. sh(W.knobs.mtime) .. " " .. sh(p)) end
  W.saved = p; W.sheet = nil; W.focus = nil
end

local function click(pt)
  W.clicks[#W.clicks + 1] = { x = pt.x, y = pt.y }
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
  if W.open and not W.knobs.menuBroken
     and math.abs(pt.x - L.dots.x) < 5 and math.abs(pt.y - L.dots.y) < 5 then
    W.menuOpen = true; return
  end
  for i, c in ipairs(results()) do
    if math.abs(pt.y - L.rowY(i)) < 28 and pt.x > L.field.x - 60 and pt.x < L.field.x + L.field.w + 10 then
      W.open = W.knobs.wrongChatOnClick or c.name
      W.focus = nil
      return
    end
  end
end

local function paste()
  local clip = W.clipboard
  if W.focus == "search" then
    if not W.knobs.searchIgnoresPaste then W.search = clip end
  elseif W.focus == "sheet" and W.sheet and not W.knobs.sheetIgnoresPaste then
    local v = W.sheet.value
    if W.sheet.cursorEnd then
      W.sheet.value = v:match("%.txt$") and (v:gsub("%.txt$", "") .. clip .. ".txt") or (v .. clip)
    else
      W.sheet.value = clip .. (v:match("%.txt$") and ".txt" or "")
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
  }
end
local function frameAttrs(t, r)
  t.AXPosition = { x = r.x, y = r.y }; t.AXSize = { w = r.w, h = r.h }; return t
end

local function sheetEl()
  local s = W.sheet
  local kids = {
    el({ AXRole = "AXStaticText", AXValue = "名前:" }),
    el({ AXRole = "AXTextField", AXValue = function() return W.sheet and W.sheet.value end },
       { set = function(k, v)
           if k == "AXValue" and not W.knobs.sheetIgnoresAXSet then W.sheet.value = v end
         end }),
    el({ AXRole = "AXButton", AXTitle = "保存" }, { AXPress = function()
      local final = W.sheet.value
      if not final:match("%.txt$") then final = final .. ".txt" end
      -- 名前欄の「/」は POSIX のファイル名では「:」になる（macOS の仕様）
      local p = (W.knobs.saveDir or (HOME .. "/Downloads")) .. "/" .. final:gsub("/", ":")
      if W.knobs.saveFails then return end
      if exists(p) then W.sheet.confirm = p; return end
      doSave(p)
    end }),
    el({ AXRole = "AXButton", AXTitle = "キャンセル" }, { AXPress = function()
      if W.sheet.confirm then return end            -- 上書き確認が出ている間は効かない
      W.sheet = nil; W.focus = nil; W.cancelled = true
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

local function winEl()
  W.axCalls = W.axCalls + 1
  local hideField = W.knobs.fieldHiddenUntil and W.axCalls <= W.knobs.fieldHiddenUntil
  local L = layout()
  return el({
    AXRole = "AXWindow", AXSubrole = "AXStandardWindow",
    AXChildren = function()
      -- メッセージ入力欄（窓の下の方の AXTextField）を検索欄より先に置き、
      -- 「上の方の AXTextField＝検索欄」の絞り込みが効くかを試す
      local pane = el({ AXRole = "AXGroup", AXChildren = {
        el(frameAttrs({ AXRole = "AXTextField", AXValue = "" }, L.input),
           { set = function(k) if k == "AXFocused" then W.focus = "input" end end }),
      } })
      local cells = {}
      for i, c in ipairs(results()) do
        cells[#cells + 1] = el(frameAttrs({ AXRole = "AXCell", AXChildren = {
          el({ AXRole = "AXStaticText", AXValue = c.name }),
        } }, { x = L.field.x - 40, y = L.rowY(i) - 30, w = 330, h = 60 }),
          { AXPress = function()
              if W.knobs.axPressFails then return "fail" end
              W.open = W.knobs.wrongChatOnClick or c.name; W.axPressed = c.name
            end })
      end
      local left = { el({ AXRole = "AXList", AXChildren = cells }) }
      if not hideField then
        table.insert(left, 1, el(frameAttrs({ AXRole = "AXTextField",
          AXValue = function() return W.search end }, L.field),
          { set = function(k) if k == "AXFocused" then W.focus = "search" end end }))
      end
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
  isVisible = function() return W.win.visible end,
  isMinimized = function() return W.win.minimized end,
  unminimize = function() W.win.minimized = false; W.win.visible = true end,
  id = function() return 42 end,
  screen = function() return screenObj end,
  setFrame = function(_, r) if not W.knobs.noResize then W.win.x, W.win.y, W.win.w, W.win.h = r.x, r.y, r.w, r.h end end,
  snapshot = function() return nil end,
  focus = function() if not W.knobs.cannotFocus then W.focusedOther = false end end,
}
local otherWin = { id = function() return 77 end }
local appObj = {
  bundleID = function() return "jp.naver.line.mac" end,
  allWindows = function() return W.win.exists and { winObj } or {} end,
  focusedWindow = function()
    if W.focusedOther then return otherWin end
    return W.win.visible and winObj or nil
  end,
  mainWindow = function() return W.win.exists and winObj or nil end,
  activate = function() end,
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
  if src then os.rename(src, dst); return "", true end
  if cmd:match("mdfind") then return W.knobs.mdfind or "", true end
  if cmd:match("sync%.sh") then W.synced = W.synced + 1; return "push 完了\n", true end
  return "", true
end

local function stat(path)
  local out = run("stat -c '%F|%s|%Y' " .. sh(path) .. " 2>/dev/null")
  local typ, size, mt = out:match("^(.-)|(%d+)|(%d+)")
  if not typ then return nil end
  return { mode = typ == "directory" and "directory" or "file", size = tonumber(size), modification = tonumber(mt) }
end

hs = {
  timer = {
    usleep = function() end,
    doEvery = function() return { stop = function() end } end,
    doAfter = function() return { stop = function() end } end,
  },
  caffeinate = {
    sessionProperties = function() return {} end,
    watcher = { new = function() return { start = function() end, stop = function() end } end,
                systemDidWake = 1, screensDidUnlock = 2, sessionDidBecomeActive = 3 },
  },
  host = { idleTime = function() return 999 end },
  hotkey = { bind = function() return { delete = function() end } end },
  alert = { show = function(s) W.alerts[#W.alerts + 1] = s end },
  geometry = { point = function(x, y) return { x = x, y = y } end },
  eventtap = {
    leftClick = click,
    keyStroke = function(mods, key)
      W.keys[#W.keys + 1] = table.concat(mods, "+") .. "+" .. key
      if W.knobs.frontIsOther then W.typedElsewhere = true; return end
      if key == "escape" then W.escape = true; W.win.visible = false; W.open = nil end
      if key == "v" and mods[1] == "cmd" then paste() end
      if key == "right" and W.sheet and W.focus == "sheet" then W.sheet.cursorEnd = true end
    end,
    keyStrokes = function(s)
      W.keys[#W.keys + 1] = "type:" .. s
      if W.knobs.frontIsOther then W.typedElsewhere = true; return end
      if W.focus == "search" then W.search = s end
    end,
  },
  pasteboard = {
    setContents = function(s) W.clipboard = s end,
    readAllData = function() return { ["public.utf8-plain-text"] = W.clipboard } end,
    writeAllData = function(t) W.clipboard = t["public.utf8-plain-text"]; return true end,
    clearContents = function() W.clipboard = "" end,
  },
  screen = { primaryScreen = function() return screenObj end },
  screenRecordingState = function() return not W.knobs.noPermission end,
  application = {
    find = function() return W.running and appObj or nil end,
    frontmostApplication = function()
      if W.knobs.frontIsOther then return { bundleID = function() return "com.apple.Notes" end } end
      return appObj
    end,
  },
  axuielement = {
    windowElement = function() return winEl() end,
    applicationElement = function()
      return el({ AXRole = "AXApplication", AXWindows = function() return { winEl() } end })
    end,
  },
  execute = execute,
  fs = {
    attributes = function(p, a) local t = stat(p); if not t then return nil end; return a and t[a] or t end,
    mkdir = function(p) run("mkdir -p " .. sh(p)); return true end,
    dir = function(p)
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
    realprint("  NG: [" .. name .. "] 例外: " .. tostring(err))
    if W then for _, l in ipairs(W.logs) do realprint("      " .. l) end end
  end
end
-- どのシナリオでも守ること（危ない操作をしていない）
local function safe()
  check(not W.escape, "Escape を押していない")
  check(not W.called, "通話ボタンを押していない")
  for _, s in ipairs(W.menuClicked) do
    check(s == "トークを保存", "メニューで「トークを保存」以外を押していない（押したのは " .. s .. "）")
  end
  check(W.clipboard == "ORIGINAL", "クリップボードを元に戻している（今: " .. tostring(W.clipboard) .. "）")
end

local TODAY = os.date("%Y%m%d")
local function chats(list)
  local t = {}
  for _, c in ipairs(list) do t[#t + 1] = type(c) == "table" and c or { name = c } end
  return t
end
local function exportOne(name)
  local M = load()
  local app = assert(M._t.prepareApp())
  return M._t.exportOne(app, name)
end

-- ===================== 純粋な関数 =====================
test("正規化と照合", function()
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
  check(score(n("il 石川ありがとう"), n("il…")) == 0, "切れた前半が短すぎれば不一致")
  check(score(n("Berry"), n("Cherry")) == 0, "不一致=0")
  check(score("", n("何か")) == 0, "空の名前は何にも一致しない")
  check(M._t.loose("オーチュー/小林央忠") == M._t.loose("オーチュー_小林央忠"), "保存名照合では / と _ を無視")
end)

test("メニュー項目の判定", function()
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
test("正常: 検索→行→ヘッダ確認→⋮→トークを保存→保存→OUT_DIRへ移動", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }) })
  local ok, dst = exportOne("Berry")
  check(ok, "成功する: " .. tostring(type(dst) == "table" and dst.msg or dst))
  local want = OUT .. "/[LINE]Berry_" .. TODAY .. ".txt"
  check(dst == want, "保存先は OUT_DIR/[LINE]Berry_今日.txt: " .. tostring(dst))
  check(exists(want), "ファイルがある")
  check(not exists(HOME .. "/Downloads/[LINE]Berry_" .. TODAY .. ".txt"), "既定の保存先からは移した")
  check(W.win.w == SCREEN.w and W.win.h == SCREEN.h, "窓を画面いっぱいにした")
  check(W.search == "Berry", "検索欄に名前が入った")
  check(W.menuClicked[1] == "トークを保存", "「トークを保存」を押した")
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

test("完全一致が無ければ前方一致の一番上（かにっこにー3）", function()
  reset({ chats = chats({ "直承Jikisho", "かにっこにー3", "かにっこにー4" }) })
  local ok = exportOne("かにっこにー")
  check(ok and W.saved:find("[LINE]かにっこにー3_", 1, true), "かにっこにー3 を保存: " .. tostring(W.saved))
  safe()
end)

test("前の件の保存ダイアログが残っていたらキャンセルしてから進む", function()
  reset({ chats = chats({ "Berry", "直承Jikisho" }) })
  W.open = "直承Jikisho"; W.sheet = { value = "[LINE]直承Jikisho.txt" }; W.focus = "sheet"
  local ok = exportOne("Berry")
  check(W.cancelled, "残っていたダイアログをキャンセルした")
  check(ok and W.saved:find("[LINE]Berry_", 1, true), "Berry を保存した")
  safe()
end)

test("別のトークが開いたらヘッダ確認で止める", function()
  reset({ chats = chats({ "Berry", "直承Jikisho" }), knobs = { wrongChatOnClick = "直承Jikisho" } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "トーク確認", "トーク確認で失敗: " .. tostring(e and e.stage))
  check(e.msg:find("直承Jikisho", 1, true), "ヘッダに見えた名前を伝える: " .. tostring(e.msg))
  check(e.img and exists(REPO .. "/" .. e.img), "撮影画像を mac/debug に残す: " .. tostring(e.img))
  check(#W.menuClicked == 0 and not W.menuOpen and not W.sheet, "メニューも保存も触っていない")
  safe()
end)

test("⋮ が少しずれていたら1回だけずらして押し直す", function()
  reset({ chats = chats({ "Berry" }), knobs = { menuDX = -6, menuDY = 6 } })
  local ok = exportOne("Berry")
  check(ok, "2回目で成功")
  safe()
end)

test("⋮ でメニューが出なければ止める（本文の「トークを保存」は押さない）", function()
  reset({ chats = { { name = "Berry", messages = { { s = "トークを保存", dx = 700, dy = 300 } } } },
          knobs = { menuBroken = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "メニュー", "メニューで失敗: " .. tostring(e and e.stage))
  check(e.msg:find("メニューが出ない", 1, true), "メニューが出ない旨: " .. tostring(e.msg))
  for _, c in ipairs(W.clicks) do
    check(not (math.abs(c.x - (W.win.x + 700)) < 30 and math.abs(c.y - (W.win.y + 300)) < 20),
      "本文の「トークを保存」を押していない")
  end
  safe()
end)

test("本文に「トークを保存」があっても、メニューの方を押す", function()
  reset({ chats = { { name = "Berry", messages = { { s = "トークを保存", dx = 700, dy = 120 } } } } })
  local ok = exportOne("Berry")
  check(ok, "成功する")
  check(W.menuClicked[1] == "トークを保存", "メニューの項目を押した")
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

test("保存先が OUT_DIR ならそのまま", function()
  reset({ chats = chats({ "Berry" }), knobs = { saveDir = OUT } })
  local ok, dst = exportOne("Berry")
  check(ok and dst == OUT .. "/[LINE]Berry_" .. TODAY .. ".txt" and exists(dst), "OUT_DIR に今日付き")
  safe()
end)

test("同名があれば「置き換え」を押す", function()
  reset({ chats = chats({ "Berry" }) })
  writefile(HOME .. "/Downloads/[LINE]Berry_" .. TODAY .. ".txt", "前回分")
  local ok = exportOne("Berry")
  check(ok and W.replaced, "置き換えて成功")
  safe()
end)

test("古い同名ファイルより、今保存した方を拾う", function()
  reset({ chats = chats({ "Berry" }), knobs = { saveDir = HOME .. "/Desktop" } })
  local stale = HOME .. "/Downloads/[LINE]Berry_" .. TODAY .. ".txt"
  writefile(stale, "古い")
  run("touch -d '2 days ago' " .. sh(stale))
  local ok, dst = exportOne("Berry")
  check(ok, "成功する")
  check(readfile(dst) and readfile(dst):find("テスト", 1, true), "Desktop の新しい方を移した")
  check(exists(stale), "古い方には触らない")
  safe()
end)

test("保存してもファイルが見つからなければ止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { mtime = "2 days ago" } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "移動", "移動で失敗: " .. tostring(e and e.stage))
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
  reset({ chats = chats({ "Berry" }), knobs = { fieldHiddenUntil = 1 } })
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

test("貼り付けが効かない検索欄にはキー入力で入れる", function()
  reset({ chats = chats({ "Berry" }), knobs = { searchIgnoresPaste = true } })
  local ok = exportOne("Berry")
  check(ok, "成功する")
  check(W.keys[#W.keys] ~= nil, "キー入力した")
  safe()
end)

test("OCR で行が読めなければ AX のセルで開く（ヘッダ確認は通す）", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }), knobs = { ocrDropRows = true } })
  local ok = exportOne("Berry")
  check(ok and W.axPressed == "Berry", "AX で Berry を開いた")
  safe()
end)

test("検索結果に無ければトーク選択で止める", function()
  reset({ chats = chats({ "直承Jikisho" }) })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "トーク選択", "トーク選択で失敗: " .. tostring(e and e.stage))
  check(e.img and exists(REPO .. "/" .. e.img), "撮影画像を残す")
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

-- ===================== レビューで見つかった穴 =====================
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
  check(e.img and exists(REPO .. "/" .. e.img), "閉じる前の画面を残した")
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

test("LINE が前面に来なければ、何も打ち込まずに止める", function()
  reset({ chats = chats({ "Berry" }), knobs = { frontIsOther = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "窓", "窓で失敗: " .. tostring(e and e.stage))
  check(not W.typedElsewhere, "他のアプリにキーを送っていない")
  check(W.clipboard == "ORIGINAL", "クリップボードにも触っていない")
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

test("AX の行を押せなければ、その行の位置をクリックする", function()
  reset({ chats = chats({ "直承Jikisho", "Berry" }), knobs = { ocrDropRows = true, axPressFails = true } })
  local ok = exportOne("Berry")
  check(ok, "クリックで開いて成功")
  safe()
end)

test("OCR が動かなければ「OCR」の段で止める（別トーク扱いにしない）", function()
  reset({ chats = chats({ "Berry" }), knobs = { ocrFails = true } })
  local ok, e = exportOne("Berry")
  check(not ok and e.stage == "OCR", "OCR で失敗: " .. tostring(e and e.stage))
  check(e.msg:find("Vision", 1, true), "osascript のエラーを伝える: " .. tostring(e.msg))
  safe()
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
  local hb = readfile(REPO .. "/mac/heartbeat.txt") or ""
  local n = #M._t.targets
  check(hb:find("version: v4", 1, true), "heartbeat に v4")
  check(hb:find("ok: " .. (n - 1), 1, true) and hb:find("ng: 1", 1, true), "ok/ng の数: \n" .. hb)
  check(hb:find("村田研: [トーク選択]", 1, true), "失敗した段を書く")
  check(hb:find("mac/debug/", 1, true), "画像のパスを書く")
  check(W.synced == 1, "sync.sh を1回呼んだ")
  local files = run("ls " .. sh(OUT))
  check(select(2, files:gsub("_" .. TODAY .. "%.txt", "")) == n - 1, "OUT_DIR に今日付きが " .. (n - 1) .. " 件")
  safe()
end)

test("runExport: 画面収録が未許可なら操作せず、理由を heartbeat に書く", function()
  reset({ chats = chats({ "Berry" }), knobs = { noPermission = true } })
  local M = load()
  M._t.runExport()
  local hb = readfile(REPO .. "/mac/heartbeat.txt") or ""
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
    if n == 1 then error("想定外") end
    return orig(pt)
  end
  M._t.runExport()
  hs.eventtap.leftClick = orig
  local hb = readfile(REPO .. "/mac/heartbeat.txt") or ""
  check(hb:find("[内部エラー]", 1, true), "内部エラーとして記録: \n" .. hb)
  check(hb:find("ng: 1", 1, true), "失敗は1件だけ")
end)

run("rm -rf " .. sh(ROOT))
realprint(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
