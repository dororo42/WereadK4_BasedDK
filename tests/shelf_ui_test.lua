-- shelf.lua 的按键循环 UI 回环主机测（wr.* 用 mock 驱动，不需要设备）。
--
-- 为什么值得写：书架的故障面只在两处——(1) draw_page 引用改名后遗留的全局；
-- (2) 展示集与选择集的下标域不一致（选中项与高亮行错位）。设备 SMOKE 只渲染
-- 一帧、不进循环，纯逻辑单测碰不到 UI，两者都漏。本测试把 _G 装上 __index 拦截：
-- 读未定义全局当场报错，「字段被改名而函数体还在用旧名」这类回归在主机上就死。
--
-- 极简书架契约（用户口径 2026-11-20「书架极简，仅显示 10 项最近阅读书目即可」）：
-- 书架 = 服务端 books 按 readUpdateTime 降序的**前 10 本**，单屏无翻页；Up/Down
-- 在 10 本内回卷；Press 打开；Back 退出。旧的全量分页契约（10185 本×翻页）已废弃，
-- 由本测试的断言变化强制（旧分页断言见 git 历史）。
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
local MAX_ITEMS = 10                -- 与 shelf.lua 同口径
local books = {}                    -- 服务端 books（原始序，非最近阅读序）
local function set_books(n, with_times)
    books = {}
    for i = 1, n do
        books[i] = {
            bookId = "B" .. i,
            title = "书" .. i,
            author = "作者",
            -- 服务端原始序刻意与时间戳序相反：书 i 的时间 = 1000+i，
            -- 于是「最近阅读前 10 本」= 书 n-9..n（验证排序而非原始序）
            readUpdateTime = with_times and (1000 + i) or nil,
        }
    end
end
set_books(10185, true)              -- 真机量级（books 序 ≠ 最近阅读序）

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
local stubs = {
    api = { get_shelf = function() return { books = books } end },
    auth = { clear_screen = function() return true end },
}
local loaded_saved = {}
for _, m in ipairs({ "api", "auth", "shelf", "fonts", "config" }) do
    loaded_saved[m] = package.loaded[m]
end
package.loaded.api, package.loaded.auth = stubs.api, stubs.auth
package.loaded.shelf, package.loaded.fonts, package.loaded.config = nil, nil, nil

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

-- 帧里挑出书名行（页脚/页眉文案不参与行计数）
local function row_titles(frame)
    local out = {}
    for _, s in ipairs(frame or {}) do
        if s:match("^书%d+$") then out[#out + 1] = s end
    end
    return out
end

local function brief(frame)
    local caption = table.concat(frame or {}, "|")
    -- 失败信息只截 80 字：失败模式是"整架 10185 行都画"，全文打印会淹掉日志。
    return caption:len() > 80 and caption:sub(1, 80) .. "…" or caption
end

------------------------------------------------------------------ 用例
-- 1) 唯一一屏 = 最近阅读前 10 本（readUpdateTime 降序，非服务端原始序）
--    set_books(10185, times=1000+i) → 最近阅读前 10 本 = 书 n-9..n（n=10185 → 书10176..书10185）
script_keys("Back")
local ok, bid, why = run_shelf()
check(ok, "Back 退出应无错，实得 " .. tostring(why))
check(draws >= 1, "至少渲染一帧（实得 " .. draws .. "）")
local rows = row_titles(frames[1])
check(#rows == MAX_ITEMS,
    "极简书架应只画 " .. MAX_ITEMS .. " 行，实得 " .. #rows .. " 行（" .. brief(frames[1]) .. "）")
check(rows[1] == "书10185" and rows[MAX_ITEMS] == "书10176",
    "应按 readUpdateTime 降序显示（最新在最上）书10185..书10176，实得 " ..
    tostring(rows[1]) .. "…" .. tostring(rows[MAX_ITEMS]))
local foot = brief(frames[1])
local caption = table.concat(frames[1], "|")
check(caption:find("最近阅读 10 本", 1, true) ~= nil,
    "页脚应显示最近阅读口径，实得 " .. foot)
check(caption:find("翻页", 1, true) == nil,
    "极简书架不得提示翻页，实得 " .. foot)

-- 2) Up/Down 在 10 本内回卷（末本再 Down → 第 1 本）
script_keys("Down", "Down", "Press")
ok, bid, why = run_shelf()
check(ok, "Down×2+Press 应无错，实得 " .. tostring(why))
check(bid == "B10183", "两次 Down 应选中第 3 行（书10183），实得 " .. tostring(bid))
script_keys("Up", "Press")
ok, bid, why = run_shelf()
check(ok, "Up+Press 应无错，实得 " .. tostring(why))
check(bid == "B10176", "首屏 Up 应回卷到屏内最末（书10176），实得 " .. tostring(bid))

-- 3) Left/Right 在极简契约下无分页语义：不影响选择（单屏）
script_keys("Right", "Press")
ok, bid, why = run_shelf()
check(ok, "Right+Press 应无错，实得 " .. tostring(why))
check(bid == "B10185", "Right 不得改变选择（单屏无翻页），实得 " .. tostring(bid))

-- 4) 不足 10 本（4 本）：只画实际本数
set_books(4, true)
script_keys("Back")
ok, bid, why = run_shelf()
check(ok, "小书架应无错，实得 " .. tostring(why))
rows = row_titles(frames[1])
check(#rows == 4, "4 本时应画 4 行，实得 " .. #rows)

-- 5) 无 readUpdateTime（从未读过）：排在有记录的书之后
set_books(3, false)
books[3].readUpdateTime = 500          -- 仅书3 读过
script_keys("Back")
ok, bid, why = run_shelf()
check(ok, "无时间戳书架应无错，实得 " .. tostring(why))
rows = row_titles(frames[1])
check(rows[1] == "书3", "唯一有 readUpdateTime 的书应排首，实得 " .. tostring(rows[1]))

-- 6) 书架拉取失败：退出但不崩（该路径含 while millis 忙等，mock 时钟必须推进）
--    改的是 stub 表内的函数字段，不是 package.loaded——shelf 在加载期就把表存成了 upvalue。
stubs.api.get_shelf = function() return nil, "boom" end
script_keys("Back")
ok, bid, why = run_shelf()
check(ok, "书架失败路径应无错，实得 " .. tostring(why))
check(bid == nil, "书架失败应返回 nil，实得 " .. tostring(bid))

------------------------------------------------------------------ 还原
setmetatable(_G, nil)
for _, m in ipairs({ "api", "auth", "shelf", "fonts", "config" }) do
    package.loaded[m] = loaded_saved[m]
end
_G.wr = nil
_G.SMOKE = nil

print("shelf_ui done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails)
    .. " (fails=" .. fails .. ")")
return fails
