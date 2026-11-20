-- reader.lua 排版回环主机测：设置的字号/行距是否真的进到分页。
--
-- 为什么值得写：行距是这一批新加的设置项，但它只影响一个 local 算出的 lh。
-- 一旦有人把 line_h 改成不被 Reader.open 用、或把系数读错键名，屏上照样有字、
-- 主机纯逻辑测试全绿——只有"同一章文本、不同设置 → 页数/每页行数变化"才是用户视角的证据。
-- 锚点：行距=标准(1.54) 必须等于改造前的固定行高（40/26×26=40px，每页 18 行），
-- 这条是历史事实，不是把代码重述一遍。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

package.path = "src/lua/lib/?.lua;src/lua/?.lua;tests/?.lua;" .. package.path

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL reader_layout: " .. msg)
        fails = fails + 1
    end
end

local Config = require("config")
local TMP = os.tmpname()
local path_saved = Config.PATH
Config.PATH = TMP

------------------------------------------------------------------ wr mock
-- 宽度按字节算：汉字 3 字节 → 39px，540px 行宽固定 13 字/行（折行结果可预测）。
local drawn, keys
wr = {
    fb_open = function() return true end,
    fb_close = function() end,
    fb_w = function() return 600 end,
    fb_h = function() return 800 end,
    fb_fill = function() end,
    fb_text = function() end,
    fb_text_ft = function(_, _, y, s) drawn[#drawn + 1] = { y = y, s = tostring(s) } end,
    fb_quant = function() end,
    fb_refresh = function() end,
    font_load = function() return 1 end,
    font_close = function() end,
    font_width = function(_, s) return #tostring(s) * 13 end,
    input_open = function() return true end,
    input_close = function() end,
    input_poll = function() return table.remove(keys, 1) or "Back" end,
    millis = function() return 0 end,
}

local Reader = require("reader")

-- 26 段 × 39 字（≈ 每段折 3 行 + 段间空行 → 行数远超一页，必然多页）
local text = {}
for i = 1, 26 do text[i] = ("字"):rep(39) end
local TEXT = table.concat(text, "\n")

local function open(fs, factor)
    Config.set("font_size", fs)
    Config.set("line_factor", factor)
    drawn, keys = {}, { "Back" }
    local ret = Reader.open(TEXT, "标题", 1)
    -- 正文行以"字"开头；页脚是"标题  页/总页"，据此区分（不靠像素坐标猜）
    local body = 0
    for _, d in ipairs(drawn) do
        if d.s:sub(1, 3) == "字" then body = body + 1 end
    end
    return ret.total_pages, body
end

-- 1) 标准档 = 改造前的固定行高（40px → 每页 18 行）；78 行正文 → 5 页
local pages_std, body_std = open(26, 1.54)
check(body_std == 18, "行距=标准每页应 18 行（旧固定行高 40px），实得 " .. body_std)
check(pages_std == 5, "行距=标准全书应 5 页（78 行正文），实得 " .. pages_std)

-- 2) 行距单调：紧凑页多、宽松页少，且每页行数就是公式值
local pages_tight, body_tight = open(26, 1.3)     -- lh=floor(33.8+0.5)=34 → 21 行/页 → 4 页
local pages_loose, body_loose = open(26, 1.8)     -- lh=floor(46.8+0.5)=47 → 15 行/页 → 6 页
check(body_tight == 21 and body_loose == 15,
    "紧凑/宽松每页行数应为 21/15，实得 " .. body_tight .. "/" .. body_loose)
check(pages_tight == 4 and pages_std == 5 and pages_loose == 6,
    "页数应随行距单调递增：" .. pages_tight .. " < " .. pages_std .. " < " .. pages_loose)

-- 3) 字号也进到行高（同一行距系数）：20pt 每页 23 行，30pt 每页 15 行
local pages_fs20, body_fs20 = open(20, 1.54)
local pages_fs30, body_fs30 = open(30, 1.54)
check(body_fs20 == 23 and body_fs30 == 15,
    "20/30pt 每页行数应为 23/15，实得 " .. body_fs20 .. "/" .. body_fs30)
check(pages_fs20 < pages_fs30,
    "字号越大页数越多：" .. pages_fs20 .. " < " .. pages_fs30)

-- 4) 旧版 config.json（没有 line_factor 键）→ 必须等同标准档，不崩、不改变版式
local f = assert(io.open(TMP, "w"))
f:write('{"font_size": 26}')
f:close()
drawn, keys = {}, { "Back" }
local ret_old_cfg = Reader.open(TEXT, "标题", 1)
local body_missing = 0
for _, d in ipairs(drawn) do if d.s:sub(1, 3) == "字" then body_missing = body_missing + 1 end end
check(ret_old_cfg.total_pages == pages_std and body_missing == body_std,
    "缺 line_factor 应等同标准档，实得 " .. body_missing .. " 行/"
        .. ret_old_cfg.total_pages .. " 页")

-- 5) 末页边界按新的 rows_per_page 算：宽松档 6 页，翻到第 6 页再往前 = 换章信号
Config.set("font_size", 26)
Config.set("line_factor", 1.8)
drawn, keys = {}, { "Down", "Down", "Down", "Down", "Down", "Down", "Back" }
local ret = Reader.open(TEXT, "标题", 1)
check(ret.page == pages_loose and ret.action == "next_chapter",
    "宽松档连翻 6 次应停在末页(" .. pages_loose .. ")并给出 next_chapter，实得 page="
        .. tostring(ret.page) .. " action=" .. tostring(ret.action))

Config.PATH = path_saved
os.remove(TMP)
_G.wr = nil

print("reader_layout done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails)
    .. " (fails=" .. fails .. ")")
return fails
