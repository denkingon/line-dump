-- =====================================================================
-- LINE 自動エクスポート → line-dump リポジトリへ push（Hammerspoon）
--
--   毎日 RUN_AT に、TARGETS のトークを Mac 版 LINE から書き出し、
--   mac/sync.sh を呼んでリポジトリに取り込み・push する。
--
--   AX で押せる所は AX、⋮と「トークを保存」だけ座標。
--   座標はウィンドウ右上角からの相対（2026-07-28 実機較正）。
--   ズレたら ⌘⌥⇧K で測り直して CALIBRATION を書き換える。
--
--   手動実行: ⌘⌥⇧L / 座標測定: ⌘⌥⇧K
-- =====================================================================
local M = {}

-- ===================== 設定（ここだけ書き換える）=====================
local REPO    = os.getenv("HOME") .. "/Document/line-dump"
local OUT_DIR = os.getenv("HOME") ..
  "/Library/CloudStorage/Dropbox-SFC-CNS/Ryo Murata/Backups/Linetxt"

-- 書き出す対象: {検索名, メニュー型}
--   full     = 1:1 / グループ（「トークを保存」は8番目）
--   official = 公式アカウント（4番目）
--
-- 検索欄に入れて先頭候補を開くので、名前は一意に絞れる範囲で短くてよい
-- （絵文字や全角スペースは入力が不安定なので、その手前まででよい）。
--
-- ★ 型は迷ったら "full" にすること。公式アカウントを full で開いた場合、
--    クリックはメニューの外に落ちて何も起きず、ログに NG が出るだけ。
--    逆に通常のトークを official 指定にすると、短いメニューの4番目＝
--    別の項目（退出・削除など）を押してしまう危険がある。
--    NG が出たトークだけ official に変えるのが安全な進め方。
--
-- 一覧を作り直したいときは ⌘⌥⇧J（この形式でコンソールに出力される）。
local TARGETS = {
  { "オーチュー/小林央忠", "full" },
  { "3日後 ハートランド",  "full" },
  { "かにっこにー",        "full" },
  { "山脇開生",            "full" },
  { "Berry",               "full" },
  { "パプリカ",            "full" },
  { "p Koyo",              "full" },
  { "H Village",           "full" },
  { "np 雄太",             "full" },
  { "il 石川ありがとう",   "full" },
  { "いりべひでなり",      "full" },
  { "村田研",              "full" },
  { "mP-廣瀬舞",           "full" },
}

local RUN_AT = "07:30"

-- ▼ 較正値（ウィンドウ右上角からの論理座標オフセット）
local MENU_DX, MENU_DY = -24, 80    -- 「⋮」
local SAVE_DX          = -70        -- 「トークを保存」x
local SAVE_DY_FULL     = 326        -- full 型の y
local SAVE_DY_OFFICIAL = 207        -- official 型の y
-- ▲

-- ===================== 実装 ==========================================
local LINE_BUNDLE = "jp.naver.line.mac"
local function log(s) print(os.date("%H:%M:%S ") .. "[line-dump] " .. s) end
local function clickAt(x, y)
  hs.eventtap.leftClick(hs.geometry.point(x, y)); hs.timer.usleep(300000)
end

local function findAX(el, pred, depth)
  if not el or (depth or 0) > 30 then return nil end
  if pred(el) then return el end
  for _, c in ipairs(el:attributeValue("AXChildren") or {}) do
    local r = findAX(c, pred, (depth or 0) + 1)
    if r then return r end
  end
  return nil
end
local function role(el)  return el:attributeValue("AXRole") end
local function title(el) return tostring(el:attributeValue("AXTitle") or "") end

-- 検索欄に名前を入れて先頭候補を開く（リストは並び替わるので毎回検索する）
local function openChat(app, name)
  local win = app:focusedWindow() or app:mainWindow()
  if not win then return false, "no window" end
  local axwin = hs.axuielement.windowElement(win)
  local field = findAX(axwin, function(e) return role(e) == "AXTextField" end)
  if not field then return false, "search field not found" end
  field:setAttributeValue("AXFocused", true); hs.timer.usleep(200000)
  hs.eventtap.keyStroke({"cmd"}, "a"); hs.timer.usleep(100000)
  hs.eventtap.keyStrokes(name); hs.timer.usleep(1200000)
  local cell = findAX(axwin, function(e) return role(e) == "AXCell" end)
  if not cell then return false, "no search result" end
  cell:performAction("AXPress"); hs.timer.usleep(1200000)
  hs.eventtap.keyStroke({}, "escape"); hs.timer.usleep(200000)
  return true
end

-- 保存ダイアログ: 保存先を明示（日をまたぐと既定に戻るため毎回指定）
local function setSaveLocation()
  hs.eventtap.keyStroke({"cmd", "shift"}, "g"); hs.timer.usleep(500000)
  hs.eventtap.keyStrokes(OUT_DIR); hs.timer.usleep(400000)
  hs.eventtap.keyStroke({}, "return"); hs.timer.usleep(700000)
end

-- ファイル名に書き出し日を付ける（[LINE]○○_20260803.txt）。
-- LINE の既定名は毎回同じで、そのままだと前回分を上書きしてしまう。
-- 書き出しは「画面に読み込まれている範囲」しか取れないため、後から
-- 少ないファイルで上書きすると履歴を失う。日付を付けて日ごとに残す。
local function stampFilename(app)
  local axapp = hs.axuielement.applicationElement(app)
  -- 保存シート内の名前欄を探す（メインウィンドウの検索欄と混同しないよう
  -- シートの内側だけを見る）
  local sheet = findAX(axapp, function(e)
    local r = role(e); return r == "AXSheet" or r == "AXDialog"
  end)
  local field = sheet and findAX(sheet, function(e) return role(e) == "AXTextField" end)
  if not field then return false end

  local cur = tostring(field:attributeValue("AXValue") or "")
  if cur == "" then return false end
  local stem = cur:gsub("%.txt$", "")
  if stem:match("_%d%d%d%d%d%d%d%d$") then return true end   -- 既に付いている
  local stamped = stem .. "_" .. os.date("%Y%m%d") .. ".txt"

  field:setAttributeValue("AXValue", stamped)
  hs.timer.usleep(200000)
  -- 反映されない実装のときはキー入力で置き換える（IME を避けるため最終手段）
  if tostring(field:attributeValue("AXValue") or "") ~= stamped then
    field:setAttributeValue("AXFocused", true); hs.timer.usleep(150000)
    hs.eventtap.keyStroke({"cmd"}, "a"); hs.timer.usleep(100000)
    hs.eventtap.keyStrokes(stamped); hs.timer.usleep(300000)
  end
  return true
end

-- 保存シートが実際に開いたか。開いていないのに次の操作へ進むと、
-- 想定外の画面をキー入力で叩いてしまうので、必ずここで確認する。
local function saveSheetOpen(app)
  local axapp = hs.axuielement.applicationElement(app)
  return findAX(axapp, function(e)
    local r = role(e); return r == "AXSheet" or r == "AXDialog"
  end) ~= nil
end

-- 「保存」→（同名があれば）「置き換え」
local function pressSaveButtons(app)
  local axapp = hs.axuielement.applicationElement(app)
  local save = findAX(axapp, function(e)
    return role(e) == "AXButton" and (title(e) == "保存" or title(e) == "Save")
  end)
  if not save then return false, "save button not found" end
  save:performAction("AXPress"); hs.timer.usleep(900000)
  local repl = findAX(axapp, function(e)
    return role(e) == "AXButton" and (title(e) == "置き換え" or title(e) == "Replace")
  end)
  if repl then repl:performAction("AXPress"); hs.timer.usleep(700000) end
  return true
end

local function exportOne(app, name, kind)
  local ok, err = openChat(app, name)
  if not ok then return false, err end
  local f = (app:focusedWindow() or app:mainWindow()):frame()
  clickAt(f.x + f.w + MENU_DX, f.y + MENU_DY)                    -- ⋮
  hs.timer.usleep(700000)
  local dy = (kind == "official") and SAVE_DY_OFFICIAL or SAVE_DY_FULL
  clickAt(f.x + f.w + SAVE_DX, f.y + dy)                         -- トークを保存
  hs.timer.usleep(1300000)

  -- 保存シートが出ていなければ、型違いか座標ズレ。ここで打ち切る。
  -- 別の y を当てずっぽうで押すと、短いメニューでは退出・削除などの
  -- 項目に当たりうるので、自動での再試行はしない。
  if not saveSheetOpen(app) then
    hs.eventtap.keyStroke({}, "escape"); hs.timer.usleep(400000)
    local other = (kind == "official") and "full" or "official"
    return false, "保存ダイアログが出ない（型が \"" .. other ..
                  "\" か、座標ズレ。⌘⌥⇧K で測り直す）"
  end

  setSaveLocation()
  if not stampFilename(app) then
    log("warn: " .. name .. " のファイル名に日付を付けられず（既定名のまま保存）")
  end
  return pressSaveButtons(app)
end

local function runExport()
  if #TARGETS == 0 then
    hs.alert.show("TARGETS が空です。line_export.lua を編集してください", 4)
    log("TARGETS が空"); return
  end

  local app = hs.application.find(LINE_BUNDLE)
  if not app then
    hs.application.open(LINE_BUNDLE); hs.timer.usleep(4000000)
    app = hs.application.find(LINE_BUNDLE)
  end
  if not app then log("LINEを起動できない"); return end
  app:activate(true); hs.timer.usleep(1000000)
  local win = app:focusedWindow() or app:mainWindow()
  if not win then log("LINEウィンドウ無し（最小化?）"); return end
  win:setFrame(hs.screen.primaryScreen():frame())   -- 座標の基準をそろえる
  hs.timer.usleep(800000)

  local okN, ngN = 0, 0
  for _, t in ipairs(TARGETS) do
    local ok, err = exportOne(app, t[1], t[2])
    if ok then
      okN = okN + 1; log("OK  " .. t[1])
    else
      ngN = ngN + 1; log("NG  " .. t[1] .. "  (" .. tostring(err) .. ")")
      hs.eventtap.keyStroke({}, "escape"); hs.timer.usleep(300000)
    end
    hs.timer.usleep(800000)
  end

  -- 書き出した txt をリポジトリに取り込んで push
  local out = hs.execute('/bin/bash "' .. REPO .. '/mac/sync.sh" 2>&1')
  log("sync:\n" .. (out or ""))
  local pushed = (out or ""):match("push 完了") and "push済" or "push無し"
  hs.alert.show(string.format("LINE書き出し OK:%d NG:%d / %s", okN, ngN, pushed), 4)
end

-- 二重読み込み対策。init.lua に dofile 行が複数入っていたり、Reload を
-- 繰り返したりしても、タイマーとホットキーが多重にならないようにする。
-- （多重になると 07:00 に自動操作が同時に2本走り、LINE の画面を奪い合う）
if _G.__LINE_EXPORT then
  local prev = _G.__LINE_EXPORT
  if prev.timer then prev.timer:stop() end
  for _, hk in ipairs(prev.hotkeys or {}) do hk:delete() end
  log("前回の読み込み分を解除して張り直します")
end
M.hotkeys = {}

M.timer = hs.timer.doAt(RUN_AT, "1d", runExport)              -- 毎日
M.hotkeys[#M.hotkeys + 1] =
  hs.hotkey.bind({"cmd","alt","shift"}, "L", runExport)        -- 手動実行
M.hotkeys[#M.hotkeys + 1] =
  hs.hotkey.bind({"cmd","alt","shift"}, "K", function()        -- 座標測定
  local p = hs.mouse.absolutePosition()
  local app = hs.application.find(LINE_BUNDLE)
  local w = app and (app:focusedWindow() or app:mainWindow())
  if w then
    local f = w:frame()
    hs.alert.show(string.format("dx=%d dy=%d (右上基準)",
      p.x - (f.x + f.w), p.y - f.y), 3)
  else
    hs.alert.show(string.format("x=%d y=%d", p.x, p.y), 3)
  end
end)

M.hotkeys[#M.hotkeys + 1] =
  hs.hotkey.bind({"cmd","alt","shift"}, "J", function()        -- トーク名を一括取得
  local app = hs.application.find(LINE_BUNDLE)
  if not app then hs.alert.show("LINEが見つからない", 3); return end
  app:activate(true); hs.timer.usleep(400000)
  local win = app:focusedWindow() or app:mainWindow()
  if not win then hs.alert.show("LINEウィンドウ無し", 3); return end

  -- トークリストの行は AX で取れる（⋮ と違ってツリーに乗っている）。
  -- ただし表示中の行しか取れないので、全部欲しければリストをスクロールしてから押す。
  local names, seen = {}, {}
  local function walk(el, depth)
    if not el or depth > 30 then return end
    if role(el) == "AXCell" then
      local t = findAX(el, function(e)
        return role(e) == "AXStaticText"
           and tostring(e:attributeValue("AXValue") or "") ~= ""
      end)
      if t then
        local v = tostring(t:attributeValue("AXValue"))
        if not seen[v] then seen[v] = true; names[#names + 1] = v end
      end
    end
    for _, c in ipairs(el:attributeValue("AXChildren") or {}) do walk(c, depth + 1) end
  end
  walk(hs.axuielement.windowElement(win), 0)

  print("=== LINE トーク一覧 " .. #names .. "件（TARGETS にそのまま貼れる形式）===")
  for _, n in ipairs(names) do
    print(string.format('  { "%s", "full" },', n))
  end
  print("=== ここまで。表示中の行のみ。足りなければリストをスクロールして再度 ⌘⌥⇧J ===")
  hs.alert.show(string.format("%d件をコンソールに出力", #names), 3)
end)

_G.__LINE_EXPORT = M

log(string.format(
  "読込完了 / 対象%d件 / 毎日%s 自動実行 / 手動 ⌘⌥⇧L / 一覧 ⌘⌥⇧J / 座標測定 ⌘⌥⇧K",
  #TARGETS, RUN_AT))
return M
