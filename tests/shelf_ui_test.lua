-- shelf.lua 的按键循环 UI 回环主机测（wr.* 用 mock 驱动，不需要设备）。
--
-- 为什么值得写：书架的故障面只在两处——(1) draw_page 引用改名后遗留的全局；
-- (2) 展示集与选择集的下标域不一致（翻页后选中项与高亮行错位）。设备 SMOKE 只渲染
-- 一帧、不进循环，纯逻辑单测碰不到 UI，两者都漏。本测试把 _G 装上 __index 拦截：
-- 读未定义全局当场报错，「PAGE 被改名成 MAX_ITEMS 而函数体还在用 PAGE」这类回归在
-- 主机上就死。
--
-- 分页契约（用户口径「首批只显示最近 10 本」）：一页 10 行，首页 = 服务端 books 序
-- 前 10 本（≈最近阅读）；Up/Down 在全集内移动并跨页，Left/Right 整页翻，页首页
-- 高亮第一行；不足一页时不得提示翻页。
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
local ROWS = 10                    -- 一页行数（本测试自己按同一口径断言）
local books = {}
local function set_books(n)
    books = {}
    for i = 1, n do
        books[i] = { bookId = "B" .. i, title = "书" .. i, author = "作者" }
    end
end
set_books(10185)                   -- 真机量级（服务端 books 序）

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
    -- 失败信息只截 80 字：本测试的失败模式恰是"整架 10185 行都画"，全文打印会淹掉日志。
    return caption:len() > 80 and caption:sub(1, 80) .. "…" or caption
end

local function pages_of(n)
    return math.max(1, math.ceil(n / ROWS))
end

------------------------------------------------------------------ 用例
-- 1) 首页 = 最近 10 本 + 页码 + 翻页提示
script_keys("Back")
local ok, bid, why = run_shelf()
check(ok, "Back 退出应无错，实得 " .. tostring(why))
check(draws >= 1, "至少渲染一帧（实得 " .. draws .. "）")
local rows = row_titles(frames[1])
check(#rows == ROWS,
    "一页应只画 " .. ROWS .. " 行，实得 " .. #rows .. " 行（" .. brief(frames[1]) .. "）")
check(rows[1] == "书1" and rows[ROWS] == "书" .. ROWS,
    "首页应为最近 " .. ROWS .. " 本 书1..书" .. ROWS ..
    "，实得 " .. tostring(rows[1]) .. "…" .. tostring(rows[ROWS]))
local foot = brief(frames[1])
local caption = table.concat(frames[1], "|")
check(caption:find("1/" .. pages_of(10185), 1, true) ~= nil,
    "页脚应显示 当前页/总页数（1/" .. pages_of(10185) .. "），实得 " .. foot)
check(caption:find("10185", 1, true) ~= nil, "页脚应显示全集本数，实得 " .. foot)
check(caption:find("左右翻页", 1, true) ~= nil, "多页时必须提示左右翻页，实得 " .. foot)

-- 2) Up/Down 跨页移动：首页光标向下 10 次 → 第 2 页第 1 行（书11）
script_keys("Down", "Down", "Down", "Down", "Down", "Down",
            "Down", "Down", "Down", "Down", "Press")
ok, bid, why = run_shelf()
check(ok, "Down×10+Press 应无错，实得 " .. tostring(why))
check(bid == "B11", "第 10 次 Down 应进入第 2 页并停在书11，实得 " .. tostring(bid))
rows = row_titles(frames[#frames])
check(rows[1] == "书11", "跨页后首行应是书11，实得 " .. tostring(rows[1]))

-- 3) 首页光标按 Up：在全集内回卷到真正末本（第 1019 页只有 5 行）
script_keys("Up", "Press")
ok, bid, why = run_shelf()
check(ok, "Up 回卷应无错，实得 " .. tostring(why))
check(bid == "B10185", "Up 回卷应到全集末本 B10185，实得 " .. tostring(bid))
rows = row_titles(frames[#frames])
check(#rows == 5, "末页应只画剩余 5 行（10185 = 1018×10 + 5），实得 " .. #rows)
check(rows[1] == "书10181" and rows[5] == "书10185",
    "末页行应为书10181..书10185，实得 " .. tostring(rows[1]) .. "…" .. tostring(rows[#rows]))

-- 4) 末本按 Down：在全集内回卷到第 1 本（Up/Down 的卷绕必须对称，否则末页卡死）
script_keys("Up", "Down", "Down", "Press")
ok, bid, why = run_shelf()
check(ok, "Up+Down+Down+Press 应无错，实得 " .. tostring(why))
check(bid == "B2", "末本再 Down 应回卷到 B2（1→10185→1→2），实得 " .. tostring(bid))

-- 5) Left/Right 整页翻：Right 两次 → 第 3 页首行（书21）；Left 回退同样按页
script_keys("Right", "Right", "Press")
ok, bid, why = run_shelf()
check(ok, "Right×2+Press 应无错，实得 " .. tostring(why))
check(bid == "B21", "Right 应整页翻（2 页 → 书21），实得 " .. tostring(bid))
script_keys("Right", "Left", "Press")
ok, bid, why = run_shelf()
check(ok, "Right+Left+Press 应无错，实得 " .. tostring(why))
check(bid == "B1", "Right 后 Left 应回到第 1 页首行 B1，实得 " .. tostring(bid))

-- 6) 第 1 页按 Left：页间回卷到末页首行（书10181）
script_keys("Left", "Press")
ok, bid, why = run_shelf()
check(ok, "Left 回卷应无错，实得 " .. tostring(why))
check(bid == "B10181", "首页 Left 应回卷到末页首行 B10181，实得 " .. tostring(bid))

-- 7) 不满一页（4 本）：不画超行数、页码 1/1、不得提示翻页
set_books(4)
script_keys("Back")
ok, bid, why = run_shelf()
check(ok, "小书架应无错，实得 " .. tostring(why))
rows = row_titles(frames[1])
check(#rows == 4, "4 本时应画 4 行，实得 " .. #rows)
caption = table.concat(frames[1], "|")
check(caption:find("1/1", 1, true) ~= nil, "单页应显示 1/1，实得 " .. brief(frames[1]))
check(caption:find("左右翻页", 1, true) == nil,
    "单页不得提示左右翻页，实得 " .. brief(frames[1]))
set_books(10185)

-- 8) 书架拉取失败：退出但不崩（该路径含 while millis 忙等，mock 时钟必须推进）
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
