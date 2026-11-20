-- reader.lua — 简版阅读器：freetype 排版 + KOReader 习惯键位 + 进度显示。
--
-- DK-2 简版口径（方案 §八）：纯文本段落渲染（spool txt），无图片/样式；
-- 排版引擎（crengine 级）后续独立迭代。UTF-8 安全折行用 protocol.utf8_substr。
--
-- 键位对齐 KOReader + weread_K4 插件在 K4 上的习惯（出处与两处偏离见 docs/keymap-k4.md）：
--   LPgFwd / RPgFwd / Down / Press = 下一页（末页再往前 → 下一章，自动续读）
--   LPgBack / RPgBack / Up         = 上一页（首页再往后 → 上一章）
--   Right = 下一章，Left = 上一章
--   Menu / ScreenKB+Down = 快捷菜单，ScreenKB+Up = 目录（三者都交调用方处理）
--   Back / Home = 退出（进度由调用方保存）
-- 组合键名 "ScreenKBPlusX" 由 C 输入层 latch 产出（src/device/input.c）。
--
-- 本模块只管「单章渲染 + 翻页」，不持有目录：跨章动作以 action 信号交回调用方
-- （menu.read_book 是唯一的跨章决策点）。
-- 返回 { page=, total_pages=, action= }，action ∈ next_chapter|prev_chapter|toc|exit。

local WeRead = require("protocol")
local Config = require("config")

local Reader = {}

local FT_PATH = "/mnt/us/weread/fonts/wqy-microhei.ttc"
Reader.FONT_MIN, Reader.FONT_MAX = 18, 40       -- 字号钳制边界（设置 UI 与钳制共用）

local function font_size()
    local fs = tonumber(Config.load().font_size) or 26
    if fs < Reader.FONT_MIN then fs = Reader.FONT_MIN end
    if fs > Reader.FONT_MAX then fs = Reader.FONT_MAX end
    return fs
end

-- 行高 = 字号 × 行距系数（设置"行距"档位：紧凑 1.3 / 标准 1.54 / 宽松 1.8）
local function line_h(fs)
    local factor = tonumber(Config.load().line_factor) or 1.54
    return math.floor(fs * factor + 0.5)
end
local MARGIN_X = 30
local MARGIN_TOP = 24
local MARGIN_BOTTOM = 56          -- 页脚区

-- 键位表：一处声明，dispatch 只做查表（改键位不动控制流）。
-- 导出为模块字段，使键位本身可在主机侧被单测钉住（tests/reader_keys_test.lua）——
-- 键位是用户肌肉记忆的直接对象，值得一个不依赖设备的回归护栏。
Reader.KEY_NEXT_PAGE = { LPgFwd = true, RPgFwd = true, Down = true, Press = true }
Reader.KEY_PREV_PAGE = { LPgBack = true, RPgBack = true, Up = true }
Reader.KEY_NEXT_CH   = { Right = true }
Reader.KEY_PREV_CH   = { Left = true }
-- docs/keymap-k4.md §二：Menu / ScreenKB+Down = 快捷菜单；ScreenKB+Up = 目录。
-- 三键曾经全绑 toc（真机 bug：快捷菜单键打开的都是目录）→ 拆成两组。
Reader.KEY_QUICKMENU = { Menu = true, ScreenKBPlusDown = true }
Reader.KEY_TOC       = { ScreenKBPlusUp = true }
Reader.KEY_EXIT      = { Back = true, Home = true }

-- UTF-8 按字符切分（宽松版：非法序列按 1 字节吞掉，保证永远前进不丢字节）。
-- 宽度首字节判长与 protocol.utf8_substr 同源。
local function utf8_chars(line)
    local chars = {}
    local i, n = 1, #line
    while i <= n do
        local b = line:byte(i)
        local w = 1
        if b >= 0xF0 then w = 4
        elseif b >= 0xE0 then w = 3
        elseif b >= 0xC2 and b <= 0xDF then w = 2
        end
        chars[#chars + 1] = line:sub(i, i + w - 1)
        i = i + w
    end
    return chars
end

-- UTF-8 安全折行：字符域贪心（measure 依赖注入，主机侧可测）。
-- 历史 bug（code review 🔴）：旧版 pos 按字节推进、fit 按字符计数，中文行超宽时
-- 切进多字节字符中间——ASCII 恰好字节=字符而漏过测试。本版在字符数组上工作，
-- 单字符超宽也强制收进一行（不死循环、不丢字）。
-- measure(candidate_string) 返回像素宽度；设备路径传 wr.font_width 绑定。
function Reader.wrap_line(measure, maxw, line)
    local rows = {}
    local chars = utf8_chars(line)
    local i = 1
    while i <= #chars do
        local j = i
        local last_fit = i
        while j <= #chars do
            local cand = table.concat(chars, "", i, j)
            local w = measure(cand)
            if w and w <= maxw then
                last_fit = j
                j = j + 1
            else
                break
            end
        end
        rows[#rows + 1] = table.concat(chars, "", i, last_fit)
        i = last_fit + 1
    end
    return rows
end

-- 章节 → 屏幕行数组（段落间空行）
function Reader.layout(ft, maxw, text)
    local rows = {}
    for line in (text:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"):gmatch("(.-)\n") do
        line = line:match("^(.-)%s*$") or ""
        if line == "" then
            rows[#rows + 1] = ""
        else
            for _, r in ipairs(Reader.wrap_line(function(s)
                    return wr.font_width(ft, s)
                end, maxw, line)) do
                rows[#rows + 1] = r
            end
        end
    end
    return rows
end

-- start_page: 起始页（1 起）；传负数表示「从末页开始」——上一章回退时用。
function Reader.open(chapter_text, chapter_title, start_page)
    assert(wr.fb_open(), "fb_open failed")
    assert(wr.input_open(), "input_open failed")
    local fs = font_size()
    local lh = line_h(fs)
    local ft = wr.font_load(FT_PATH, fs)
    if not ft then
        wr.fb_close()
        return nil, "font load failed"
    end

    local W, H = wr.fb_w(), wr.fb_h()
    local maxw = W - MARGIN_X * 2
    local rows = Reader.layout(ft, maxw, chapter_text)
    local rows_per_page = math.floor((H - MARGIN_TOP - MARGIN_BOTTOM) / lh)
    local total_pages = math.max(1, math.ceil(#rows / rows_per_page))
    local page = tonumber(start_page) or 1
    if page < 1 then page = total_pages end
    page = math.min(page, total_pages)

    local function draw()
        wr.fb_fill(0, 0, W, H, 0x00)
        local first = (page - 1) * rows_per_page
        local y = MARGIN_TOP
        for i = first + 1, math.min(first + rows_per_page, #rows) do
            local row = rows[i]
            if row ~= "" then
                wr.fb_text_ft(ft, MARGIN_X, y, row, 0xFF)
            end
            y = y + lh
        end
        -- 页脚：标题 + 进度
        if ft then
            local footer = string.format("%s  %d/%d", chapter_title or "", page, total_pages)
            local w = wr.font_width(ft, footer) or #footer * 13
            wr.fb_text_ft(ft, math.floor((W - math.min(w, maxw)) / 2), H - MARGIN_BOTTOM + 12,
                footer, 0x60)
        end
        wr.fb_quant()
        wr.fb_refresh(0)
    end

    draw()
    local action
    while true do
        local key = wr.input_poll(1000, true)
        -- 未绑定的键（含 ScreenKB 自身、其它组合键）静默忽略；nil = 超时
        if key and Reader.KEY_NEXT_PAGE[key] then
            if page < total_pages then
                page = page + 1
                draw()
            else
                action = "next_chapter"   -- 章末再往前翻 → 自动续读
                break
            end
        elseif key and Reader.KEY_PREV_PAGE[key] then
            if page > 1 then
                page = page - 1
                draw()
            else
                action = "prev_chapter"   -- 首页再往后翻 → 回上一章（调用方决定停在末页）
                break
            end
        elseif key and Reader.KEY_NEXT_CH[key] then
            action = "next_chapter"
            break
        elseif key and Reader.KEY_PREV_CH[key] then
            action = "prev_chapter"
            break
        elseif key and Reader.KEY_QUICKMENU[key] then
            action = "quickmenu"
            break
        elseif key and Reader.KEY_TOC[key] then
            action = "toc"
            break
        elseif key and Reader.KEY_EXIT[key] then
            action = "exit"
            break
        end
    end

    wr.font_close(ft)
    -- fb/input 不在此关闭：menu 级联共享（调用方管理生命周期）
    return { page = page, total_pages = total_pages, action = action }
end

return Reader
