-- reader.lua — 简版阅读器：freetype 排版 + 五向翻页 + 进度显示。
--
-- DK-2 简版口径（方案 §八）：纯文本段落渲染（spool txt），无图片/样式；
-- 排版引擎（crengine 级）后续独立迭代。UTF-8 安全折行用 protocol.utf8_substr。
-- 交互：Right/Down=下一页，Left/Up=上一页，Back=退出；页脚 "章节标题 页码/总页"。

local WeRead = require("protocol")

local Reader = {}

local FT_PATH = "/mnt/us/weread/fonts/wqy-microhei.ttc"
local FONT_SIZE = 26
local LINE_H = 40
local MARGIN_X = 30
local MARGIN_TOP = 24
local MARGIN_BOTTOM = 56          -- 页脚区

-- UTF-8 安全折行：贪心填行（font_width 逐前缀测量）
local function wrap_line(ft, maxw, line)
    local rows = {}
    local pos = 1
    local n = #line
    while pos <= n do
        local lo, hi = pos, n
        -- 二分找最大可容纳 UTF-8 前缀
        local fit = pos
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local head = WeRead.utf8_substr(line:sub(pos), mid - pos + 1)
            local w = wr.font_width(ft, head)
            if w and w <= maxw then
                fit = mid
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
        local head = WeRead.utf8_substr(line:sub(pos), fit - pos + 1)
        rows[#rows + 1] = head
        pos = fit + 1
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
            for _, r in ipairs(wrap_line(ft, maxw, line)) do
                rows[#rows + 1] = r
            end
        end
    end
    return rows
end

function Reader.open(chapter_text, chapter_title, start_page)
    assert(wr.fb_open(), "fb_open failed")
    assert(wr.input_open(), "input_open failed")
    local ft = wr.font_load(FT_PATH, FONT_SIZE)
    if not ft then
        wr.fb_close()
        return nil, "font load failed"
    end

    local W, H = wr.fb_w(), wr.fb_h()
    local maxw = W - MARGIN_X * 2
    local rows = Reader.layout(ft, maxw, chapter_text)
    local rows_per_page = math.floor((H - MARGIN_TOP - MARGIN_BOTTOM) / LINE_H)
    local total_pages = math.max(1, math.ceil(#rows / rows_per_page))
    local page = math.min(start_page or 1, total_pages)

    local function draw()
        wr.fb_fill(0, 0, W, H, 0xFF)
        local first = (page - 1) * rows_per_page
        local y = MARGIN_TOP
        for i = first + 1, math.min(first + rows_per_page, #rows) do
            local row = rows[i]
            if row ~= "" then
                wr.fb_text_ft(ft, MARGIN_X, y, row, 0x00)
            end
            y = y + LINE_H
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
    local running = true
    while running do
        local key = wr.input_poll(1000, true)
        if key == "Right" or key == "Down" or key == "Press" then
            if page < total_pages then
                page = page + 1
                draw()
            end
        elseif key == "Left" or key == "Up" then
            if page > 1 then
                page = page - 1
                draw()
            end
        elseif key == "Back" or key == "Menu" or key == "Home" then
            running = false
        end
    end

    wr.font_close(ft)
    -- fb/input 不在此关闭：menu 级联共享（调用方管理生命周期）
    return { page = page, total_pages = total_pages }
end

return Reader
