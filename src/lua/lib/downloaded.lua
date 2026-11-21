-- downloaded.lua — 已下载书目浏览（书 → 章 → 阅读），主菜单「已下载」入口。
--
-- 数据源：Download.list_books()（books/<id>/manifest.json + spool 文件）——
-- **纯离线**，不触网不登录。流程：书列表 → 章列表（已下载的章）→ Reader 单章阅读。
-- 跨章导航在此层（Back 回章列表 → 回书列表 → 回主菜单），不复用 read_book 的
-- 章间续读（那是书架在线流程）。
--
-- UI 复用 menu.lua 的字体句柄由调用方传入（ft_main/ft_small/text），保持单一渲染决策。

local Download = require("download")
local Fonts = require("fonts")
local Progress = require("progress")
local Reader = require("reader")

local DL = {}

local FT_MAIN_PX = 30
local FT_SMALL_PX = 18
local ITEM_H = 46
local Y0 = 84
local ROWS = 12                     -- 12 行/屏（书目与章列表共用）

local function ft_text(ft, x, y, s, fg)
    if ft then return wr.fb_text_ft(ft, x, y, s, fg) end
    return wr.fb_text(x, y, s, 2, fg)
end

-- 列表屏通用循环：items 绘制+导航，Press 返回下标，Back 返回 nil。
-- entries = { label=, payload= }；header=屏标题。
local function list_loop(ft_main, ft_small, entries, header, sel_init)
    local sel = sel_init or 1
    local offset = 0                -- 首行在 entries 中的下标（1 起）
    local function draw()
        wr.fb_fill(0, 0, wr.fb_w(), wr.fb_h(), 0x00)
        ft_text(ft_main, 16, 14, header, 0xFF)
        wr.fb_fill(16, 14 + 40, wr.fb_w() - 32, 2, 0xFF)
        local rows = math.floor((wr.fb_h() - Y0 - 56) / ITEM_H)
        offset = math.floor((sel - 1) / rows) * rows
        for i = 1, math.min(rows, #entries - offset) do
            local e = entries[offset + i]
            local y = Y0 + (i - 1) * ITEM_H
            if offset + i == sel then
                wr.fb_fill(12, y - 6, wr.fb_w() - 24, ITEM_H - 6, 0xFF)
                ft_text(ft_main, 22, y, e.label, 0x00)
            else
                ft_text(ft_main, 22, y, e.label, 0xFF)
            end
        end
        if ft_small then
            local pages = math.max(1, math.ceil(#entries / rows))
            local pg = math.floor((sel - 1) / rows) + 1
            wr.fb_text_ft(ft_small, 16, wr.fb_h() - 40,
                string.format("%d/%d 页 · %d 项 · 上下移动 左右翻页 中键选择 返回",
                    pg, pages, #entries), 0x60)
        end
        wr.fb_quant()
        wr.fb_refresh(0)
    end

    draw()
    while true do
        local rows = math.floor((wr.fb_h() - Y0 - 56) / ITEM_H)
        local pages = math.max(1, math.ceil(#entries / rows))
        local key = wr.input_poll(1000, true)
        if key == "Up" then
            sel = sel - 1; if sel < 1 then sel = #entries end; draw()
        elseif key == "Down" then
            sel = sel + 1; if sel > #entries then sel = 1 end; draw()
        elseif key == "Left" then
            local pg = math.floor((sel - 1) / rows) - 1
            if pg < 0 then pg = pages - 1 end
            sel = pg * rows + 1; draw()
        elseif key == "Right" then
            local pg = math.floor((sel - 1) / rows) + 1
            if pg > pages - 1 then pg = 0 end
            sel = pg * rows + 1; draw()
        elseif key == "Press" then
            return sel
        elseif key == "Back" or key == "Menu" or key == "Home" then
            return nil
        end
    end
end

-- 书目字节摘要（K4 用户口径：MB 两位小数）
local function fmt_bytes(b)
    if b >= 1024 * 1024 then
        return string.format("%.1fMB", b / 1024 / 1024)
    end
    return string.format("%dKB", math.floor(b / 1024))
end

-- 入口：已下载书目 → 章 → 阅读。需 fb/input 已开（menu 级联共享）。
-- 返回 nil（Back 层层退出）。
function DL.browse()
    local ft_main = Fonts.load(FT_MAIN_PX)
    local ft_small = Fonts.load(FT_SMALL_PX)

    local all = Download.list_books()
    if #all == 0 and ft_main then
        wr.fb_fill(0, 0, wr.fb_w(), wr.fb_h(), 0x00)
        ft_text(ft_main, 40, 200, "暂无下载内容", 0xFF)
        wr.fb_quant()
        wr.fb_refresh(0)
        local t0 = wr.millis()
        while wr.millis() - t0 < 1500 do end
        if ft_main then wr.font_close(ft_main) end
        if ft_small then wr.font_close(ft_small) end
        return
    end

    -- 层 1：书目（label = 标题 + 已下载章数/大小）
    local book_entries = {}
    for _, b in ipairs(all) do
        book_entries[#book_entries + 1] = {
            label = string.format("%s（%d章 %s）", b.title, b.chapters_down, fmt_bytes(b.bytes)),
            bookId = b.bookId,
            title = b.title,
        }
    end
    while true do
        local pick = list_loop(ft_main, ft_small, book_entries, "已下载书目")
        if not pick then break end
        local book = book_entries[pick]

        -- 层 2：该书已下载章节
        local chs = Download.list_downloaded_chapters(book.bookId)
        if #chs == 0 and ft_main then
            ft_text(ft_main, 40, 200, "该书无已下载章节", 0xFF)
            wr.fb_quant(); wr.fb_refresh(0)
            local t0 = wr.millis()
            while wr.millis() - t0 < 1200 do end
        else
            local ch_entries = {}
            for _, c in ipairs(chs) do
                ch_entries[#ch_entries + 1] = {
                    label = string.format("%d. %s", c.chapterIdx, c.title),
                    chapter = c,
                }
            end
            local sel_ch = list_loop(ft_main, ft_small, ch_entries,
                book.title .. " · 已下载 " .. #chs .. " 章")
            if sel_ch then
                local c = ch_entries[sel_ch]
                local rec = Progress.get(book.bookId)
                local page = (rec and rec.chapter_idx == c.chapterIdx and rec.page) or 1
                Reader.open(c.text, c.title, page)
            end
        end
        -- 回书目层（重画由 list_loop 的 draw 完成）
    end

    if ft_main then wr.font_close(ft_main) end
    if ft_small then wr.font_close(ft_small) end
end

return DL
