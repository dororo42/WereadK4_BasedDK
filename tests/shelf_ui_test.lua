-- shelf.lua 的按键循环 UI 回环主机测（wr.* 用 mock 驱动，不需要设备）。
--
-- 为什么值得写：书架的故障面只在两处——(1) draw_page 引用改名后遗留的全局；
-- (2) 展示集与选择集的下标域不一致。设备 SMOKE 只渲染一帧、不进循环，纯逻辑单测
-- 碰不到 UI，两者都漏。本测试把 _G 装上 __index 拦截：读未定义全局当场报错，
-- 「PAGE 被改名成 MAX_ITEMS 而函数体还在用 PAGE」这类回归在主机上就死。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

package.path = "src/lua/lib/?.lua;src/lua/?.lua;" .. package.path

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL shelf_ui: " .. msg)
        fails = fails + 1
    end
end

------------------------------------------------------------------ mock 环境
local TOTAL_BOOKS = 10185          -- 真机量级（服务端 books 序）
local CAP = 10                     -- shelf.lua 的 MAX_ITEMS 上限
local frames, cur_frame, draws
local clock

local function new_frame_capture()
    frames, cur_frame, draws = {}, {}, 0
end

local key_scripts = {}
local function script_keys(...)
    key_scripts = { ... }
end

local function fb_text_ft(_ft, _x, _y, s)
    cur_frame[#cur_frame + 1] = tostring(s)
end

wr = {
    fb_open = function() return true end,
    fb_close = function() end,
    fb_w = function() return 600 end,
    fb_h = function() return 800 end,
    fb_fill = function() end,
    fb_text = function(_x, _y, s) cur_frame[#cur_frame + 1] = tostring(s) end,
    fb_text_ft = fb_text_ft,
    fb_get = function() return 255 end,
    fb_quant = function() draws = draws + 1; frames[#frames + 1] = cur_frame; cur_frame = {} end,
    fb_refresh = function() end,
    font_load = function() return 1 end,
    font_close = function() end,
    font_width = function(_, s) return #tostring(s) * 12 end,
    input_open = function() return true end,
    input_close = function() end,
    input_poll = function() return table.remove(key_scripts, 1) or "Back" end,
    -- 每次多走 10 秒：任何 while 忙等都能退出，不会把测试挂住
    millis = function() clock = clock + 10000; return clock end,
}
clock = 0

------------------------------------------------------------------ 严格全局
-- 先登记本测试自己引入的名字，再装拦截：此后读任何未定义全局即 error。
local books = {}
for i = 1, TOTAL_BOOKS do
    books[i] = { bookId = "B" .. i, title = "书" .. i, author = "作者" }
end
local stubs = {
    api = { get_shelf = function() return { books = books } end },
    auth = { clear_screen = function() return true end },
}
local loaded_saved = {}
for _, m in ipairs({ "api", "auth", "shelf" }) do loaded_saved[m] = package.loaded[m] end
package.loaded.api, package.loaded.auth, package.loaded.shelf = stubs.api, stubs.auth, nil

SMOKE = false
local trace
setmetatable(_G, {
    __index = function(_, k)
        trace = "undefined global read: " .. tostring(k)
        error(trace, 0)
    end,
})

local function run_shelf()
    trace = nil
    new_frame_capture()
    local Shelf = require("shelf")
    local ok, book_id = pcall(Shelf.run)
    return ok, book_id, trace
end

------------------------------------------------------------------ 用例
-- 1) 空按键（立即 Back）：一帧渲染 + 无未定义全局
script_keys("Back")
local ok, bid, why = run_shelf()
check(ok, "Back 退出应无错，实得 " .. tostring(why))
check(draws >= 1, "至少渲染一帧（实得 " .. draws .. "）")
local f1 = frames[1] or {}
local rows = {}
for _, s in ipairs(f1) do
    if s:match("^书%d+$") then rows[#rows + 1] = s end
end
check(#rows == CAP,
    "首屏应只列 " .. CAP .. " 本（极简书架），实得 " .. #rows .. " 行")
check(rows[1] == "书1" and rows[CAP] == "书" .. CAP,
    "首屏应为最近 " .. CAP .. " 本 书1..书" .. CAP ..
    "，实得 " .. tostring(rows[1]) .. "…" .. tostring(rows[CAP]))
local caption = table.concat(f1, "|")
-- 失败信息只截 80 字：本用例的失败模式恰是"整架 10185 行都画"，全文打印会淹掉日志。
local brief = caption:len() > 80 and caption:sub(1, 80) .. "…" or caption
check(caption:find("最近 " .. CAP .. " 本", 1, true) ~= nil,
    "截断时必须自报上限（首屏文案 " .. #f1 .. " 段：" .. brief .. "）")
check(caption:find("左右翻页", 1, true) == nil,
    "无翻页就不要提示左右翻页（首屏文案 " .. #f1 .. " 段：" .. brief .. "）")

-- 2) 光标从第 1 行按 Up：在裁剪集内回卷到第 10 行，而不是全量的第 10185 行
script_keys("Up", "Press")
ok, bid, why = run_shelf()
check(ok, "Up+Press 应无错，实得 " .. tostring(why))
check(bid == "B" .. CAP,
    "Up 回卷应选中裁剪集末本 B" .. CAP .. "，实得 " .. tostring(bid))

-- 3) 光标从第 10 行按 Down：回卷到第 1 本（选择集 == 展示集）
script_keys("Up", "Down", "Down", "Press")
ok, bid, why = run_shelf()
check(ok, "Up+Down+Down+Press 应无错，实得 " .. tostring(why))
check(bid == "B2", "末本再 Down 应回卷到 B2（10→1→2），实得 " .. tostring(bid))

-- 4) 翻页键已废除：按它不得改变选中项，也不得报错
script_keys("Left", "Right", "Press")
ok, bid, why = run_shelf()
check(ok, "Left/Right 应无害，实得 " .. tostring(why))
check(bid == "B1", "Left/Right 不该动选中项，实得 " .. tostring(bid))

-- 5) 书架拉取失败：退出但不崩（该路径含 while millis 忙等，mock 时钟必须推进）
--    改的是 stub 表内的函数字段，不是 package.loaded——shelf 在加载期就把表存成了 upvalue。
stubs.api.get_shelf = function() return nil, "boom" end
script_keys("Back")
ok, bid, why = run_shelf()
check(ok, "书架失败路径应无错，实得 " .. tostring(why))
check(bid == nil, "书架失败应返回 nil，实得 " .. tostring(bid))

------------------------------------------------------------------ 还原
setmetatable(_G, nil)
for _, m in ipairs({ "api", "auth", "shelf" }) do package.loaded[m] = loaded_saved[m] end
_G.wr = nil
_G.SMOKE = nil

print("shelf_ui done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails)
    .. " (fails=" .. fails .. ")")
return fails
