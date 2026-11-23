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

-- 6) 按比例定位（云端进度跳转的入口）：标准档 5 页，fraction 决定落在哪一页。
--    这一条是"调用方算不出页码"的唯一出口——reader 不把总页数漏出去，
--    所以跳转必须能吃比例；能吃比例就必须证明它和整数页码、负数末页约定互不干扰。
Config.set("font_size", 26)
Config.set("line_factor", 1.54)
local function open_at(start)
    drawn, keys = {}, { "Back" }
    local r = Reader.open(TEXT, "标题", start)
    return r.page, r.total_pages
end
local p_half, tot = open_at({ fraction = 0.5 })
check(tot == pages_std, "fraction 用例的分母应仍是标准档 5 页，实得 " .. tostring(tot))
check(p_half == 3, "fraction 0.5 应落第 3 页，实得 " .. p_half)
check(open_at({ fraction = 0 }) == 1, "fraction 0 应落首页")
check(open_at({ fraction = 0.99 }) == 5, "fraction 0.99 应落末页")
check(open_at({ fraction = 5 }) == 5, "fraction 越界必须夹到末页而非溢出页码")
check(open_at({ fraction = -1 }) == 1, "fraction 负值必须夹到首页")
check(open_at({}) == 1, "空表（无 fraction）视为首页，不该当成负数末页")
check(open_at(4) == 4, "整数页码约定不受影响")
check(open_at(-1) == tot, "负数仍是「从末页开始」约定")

------------------------------------------------------------------ 7) 图片块：页高钳制 + 推页后画在新页首行
-- 图片尺寸是服务端来的、不受控：整宽缩放会造出比一页还高的块，跨页绘制必然
-- 裁切并压过页脚（真机用户实证「裁剪/遮挡」）。这里钉三件事：超页高图等比钳进
-- 页框；被推页的块画在新页 slot 1 的 y（旧实现画在 top_pad 个行槽之后=压到正文）；
-- 常规图不缩放变形。坐标全部可从 mock 精确推出：26pt/1.54 → lh=40、每页 18 行。
Config.set("font_size", 26)
Config.set("line_factor", 1.54)
local IMG_DIR = "/tmp/wr_reader_img_test_" .. tostring(os.time())
os.execute("mkdir -p '" .. IMG_DIR .. "'")
local IMG1, IMG2 = IMG_DIR .. "/img1.jpg", IMG_DIR .. "/img2.jpg"
for _, p in ipairs({ IMG1, IMG2 }) do
    local fi = assert(io.open(p, "wb")); fi:write(p == IMG1 and "JPEG1" or "JPEG2"); fi:close()
end
local img_draws = {}
wr.image_decode = function(data)
    if data == "JPEG1" then return "G1", 600, 2400 end   -- 整宽缩放后 2160px：必触发页高钳制
    if data == "JPEG2" then return "G2", 600, 400 end    -- 常规图：不钳
    return nil
end
wr.image_scale = function(gray, _w, _h, dw, dh) return gray .. "@" .. dw .. "x" .. dh end
wr.fb_image = function(x, y, w, h, gray)
    img_draws[#img_draws + 1] = { x = x, y = y, w = w, h = h, gray = tostring(gray) }
end

-- 7a) 推页：5 段文本（15 行）+ 空行 = 16 行，块 18 行装不下 → 垫 2 行推到第 2 页首
-- （图在推后的第 2 页：必须真的翻一页才画得出来，Back 直退只画第 1 页）
local lines_push = {}
for i = 1, 5 do lines_push[i] = ("字"):rep(39) end
lines_push[6] = ""
lines_push[7] = "\1IMG:img1.jpg\1"
drawn, keys = {}, { "Down", "Back" }
img_draws = {}
local ret_push = Reader.open(table.concat(lines_push, "\n"), "标题", 1, IMG_DIR)
check(#img_draws == 1, "推页图片只画一次，实得 " .. #img_draws)
local d1 = img_draws[1]
check(d1.y == 24, "被推页的图必须画在新页首行 y=24（旧实现 y=104 压到正文），实得 "
    .. tostring(d1 and d1.y))
check(d1.w == 170 and d1.h == 680, "超页高图必须等比钳进页框 170x680，实得 "
    .. tostring(d1 and d1.w) .. "x" .. tostring(d1 and d1.h))
check(d1.x == 215, "图片应水平居中，实得 x=" .. tostring(d1 and d1.x))
check(d1.y + d1.h <= 800 - 44, "图片不得压页脚，实得 bottom=" .. tostring(d1 and d1.y + d1.h))
check(ret_push.total_pages == 2, "36 行（含垫行）应恰好 2 页，实得 " .. ret_push.total_pages)

-- 7b) 不推页：文本 3 行后跟常规图，slot 1 紧跟文本行，整宽等比不变形
drawn, keys = {}, { "Back" }
img_draws = {}
Reader.open(("字"):rep(39) .. "\n\1IMG:img2.jpg\1", "标题", 1, IMG_DIR)
check(#img_draws == 1, "常规图只画一次，实得 " .. #img_draws)
local d2 = img_draws[1]
check(d2.y == 24 + 3 * 40, "未推页的图应画在其行槽首（文本 3 行之后 y=144），实得 "
    .. tostring(d2 and d2.y))
check(d2.w == 540 and d2.h == 360, "常规图整宽等比缩放 540x360，实得 "
    .. tostring(d2 and d2.w) .. "x" .. tostring(d2 and d2.h))

os.remove(IMG1)
os.remove(IMG2)
os.execute("rmdir '" .. IMG_DIR .. "'")
wr.image_decode = nil
wr.image_scale = nil
wr.fb_image = nil

Config.PATH = path_saved
os.remove(TMP)
_G.wr = nil

print("reader_layout done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails)
    .. " (fails=" .. fails .. ")")
return fails
