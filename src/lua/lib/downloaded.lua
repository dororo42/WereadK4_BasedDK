-- downloaded.lua — 已下载书目浏览（书 → 章 → 阅读），主菜单「已下载」入口。
--
-- 数据源：Download.list_books()（books/<id>/manifest.json + spool 文件）——
-- **纯离线**，不触网不登录。流程：书列表 → 章列表（已下载的章）→ Reader 单章阅读。
-- 跨章导航在此层（Back 回章列表 → 回书列表 → 回主菜单），不复用 read_book 的
-- 章间续读（那是书架在线流程）。
--
-- UI 复用 menu.lua 的字体句柄由调用方传入（ft_main/ft_small/text），保持单一渲染决策。

local Api = require("api")
local Auth = require("auth")
local Log = require("log")
local Epub = require("epub")
local Download = require("download")
local Fonts = require("fonts")
local Progress = require("progress")
local Reader = require("reader")

local DL = {}

local FT_MAIN_PX = 24
local FT_SMALL_PX = 16
local ITEM_H = 38
local Y0 = 76
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

-- 确认屏（删除等破坏性操作统一走这里）：中键确认，Back 取消。
local function confirm(ft_main, ft_small, title, msg)
    local y = 200
    wr.fb_fill(0, 0, wr.fb_w(), wr.fb_h(), 0x00)
    ft_text(ft_main, 16, 14, title, 0xFF)
    wr.fb_fill(16, 14 + 40, wr.fb_w() - 32, 2, 0xFF)
    ft_text(ft_main, 24, y, msg, 0xFF)
    if ft_small then
        wr.fb_text_ft(ft_small, 24, y + 60, "中键确认删除 · Back 取消", 0x60)
    end
    wr.fb_quant()
    wr.fb_refresh(0)
    while true do
        local key = wr.input_poll(1000, true)
        if key == "Press" then return true end
        if key == "Back" or key == "Menu" or key == "Home" then return false end
    end
end

-- 删除后提示（1.2s 停留）
local function toast(ft_main, ft_small, msg)
    wr.fb_fill(0, 0, wr.fb_w(), wr.fb_h(), 0x00)
    ft_text(ft_main, 24, 200, msg, 0xFF)
    if ft_small then
        wr.fb_text_ft(ft_small, 24, 260, "任意键返回", 0x60)
    end
    wr.fb_quant()
    wr.fb_refresh(0)
    local t0 = wr.millis()
    while wr.millis() - t0 < 1200 do
        local key = wr.input_poll(0, true)
        if key then return end
    end
end

-- 章条目构造（纯函数，主机可测）：list_loop 需要 label，阅读需要原章数据——
-- 两者都挂在同一包装表上，取章数据必须走 .chapter（曾因直取包装表把 nil text
-- 传进 Reader.open 崩掉整个应用：reader.lua layout 对 nil gsub）。
function DL._chapter_entries(chs)
    local out = {}
    for _, c in ipairs(chs) do
        out[#out + 1] = {
            label = string.format("%d. %s", c.chapterIdx, c.title),
            chapter = c,
        }
    end
    return out
end

-- 旧书回填（manifest 体系之前落的 spool 只有书号）：shelf 查书名 + catalog 拉
-- 目录 → save_manifest。一次性（manifest 落盘后 list_books 不再报缺）；未登录或
-- 任一网络失败 → 静默保留现状（title=id），离线浏览不因此不可用。
-- notify(msg) 用于过程提示（browse 传屏提示；主机测试传 nil）。
function DL._backfill(all, notify)
    local missing = {}
    for _, b in ipairs(all) do
        if (b.chapters_total or 0) == 0 then missing[#missing + 1] = b end
    end
    if #missing == 0 or not Api.has_login() then return 0 end
    if notify then notify("正在补全书目信息（" .. #missing .. " 本）…") end
    local shelf = Api.get_shelf()
    local by_id = {}
    if shelf and type(shelf.books) == "table" then
        for _, s in ipairs(shelf.books) do by_id[tostring(s.bookId)] = s end
    end
    local done = 0
    for _, b in ipairs(missing) do
        local s = by_id[tostring(b.bookId)]
        local title = s and tostring(s.title or "") or ""
        if title ~= "" and title ~= tostring(b.bookId) then
            local chapters = Download.fetch_catalog(b.bookId)
            if chapters and #chapters > 0 then
                Download.save_manifest(b.bookId, title, chapters)
                Log.info("backfill manifest: " .. b.bookId .. " " .. title)
                done = done + 1
            end
        end
    end
    return done
end

-- 整本 epub 导出：在线补齐缺 xhtml 的章（复用 ensure_chapter 的抓取与资产
-- 路径），然后组装。进度屏 3s 限流 + Back 取消（下载屏同款交互）。
function DL._export_book(book, chs, ft_main, ft_small)
    local manifest = Download.load_manifest(book.bookId)
    local chapters = manifest and manifest.chapters or chs
    local title = (manifest and manifest.title) or book.title
    if not chapters or #chapters == 0 then
        toast(ft_main, ft_small, "无章节数据，无法导出")
        return nil, "no chapters"
    end
    Auth.clear_screen("正在导出 epub（0/" .. #chapters .. "）…")
    local sess = Download.new_session()
    local last_shown = 0
    local ok, err = pcall(function()
        for i, ch in ipairs(chapters) do
            -- 取消：网络往返间隙 poll(0)
            local k = wr.input_poll(0, true)
            if k == "Back" then error({ cancelled = true }) end
            if not Download.read_raw(book.bookId, ch.chapterUid) then
                Download.ensure_chapter(book.bookId, chapters, ch.chapterIdx, sess)
            end
            local now = wr.millis()
            if now - last_shown >= 3000 or i == #chapters then
                last_shown = now
                Auth.clear_screen(string.format("正在导出 epub（%d/%d）…", i, #chapters))
            end
        end
    end)
    if not ok and type(err) == "table" and err.cancelled then
        toast(ft_main, ft_small, "已取消导出")
        return nil, "cancelled"
    end
    local path, xerr = Epub.export(book.bookId, chapters, title,
        (manifest and manifest.author) or "", nil)
    if not path then
        toast(ft_main, ft_small, "导出失败: " .. tostring(xerr):sub(1, 30))
        Log.error("epub export " .. book.bookId .. ": " .. tostring(xerr))
        return nil, xerr
    end
    return path
end

-- 入口：已下载书目 → 章 → 阅读。需 fb/input 已开（menu 级联共享）。
-- 返回 nil（Back 层层退出）。
function DL.browse()
    local ft_main = Fonts.load(FT_MAIN_PX)
    local ft_small = Fonts.load(FT_SMALL_PX)

    local all = Download.list_books()
    if #all > 0 then
        local n = DL._backfill(all, function(msg)
            Auth.clear_screen(msg)
        end)
        if n > 0 then
            all = Download.list_books()      -- 回填成功 → 标题/章数立即生效
        end
    end
    Log.info(string.format("downloaded browse: %d books", #all))

    -- 结构：书目层（可重扫）→ 章层（可重扫）。任何删除动作后回上一层并重新
    -- list_books——列表不是一次构造的快照，删除后空目录/空书自然消失。
    while true do
        if #all == 0 then
            wr.fb_fill(0, 0, wr.fb_w(), wr.fb_h(), 0x00)
            ft_text(ft_main, 40, 200, "暂无下载内容", 0xFF)
            wr.fb_quant()
            wr.fb_refresh(0)
            local t0 = wr.millis()
            while wr.millis() - t0 < 1200 do end
            break
        end

        -- 层 1：书目（label = 标题 + 已下载章数/大小）+ 批量删除动作行
        local book_entries = {}
        for _, b in ipairs(all) do
            book_entries[#book_entries + 1] = {
                label = string.format("%s（%d章 %s）", b.title, b.chapters_down, fmt_bytes(b.bytes)),
                bookId = b.bookId,
                title = b.title,
            }
        end
        book_entries[#book_entries + 1] = { label = "─ 批量删除（清空已下载）", action = "del_all" }
        local pick = list_loop(ft_main, ft_small, book_entries, "已下载书目")
        if not pick then break end
        local book = book_entries[pick]

        if book.action == "del_all" then
            if confirm(ft_main, ft_small, "批量删除",
                "清空全部已下载内容（共 " .. #all .. " 本）？") then
                Download.delete_all()
                toast(ft_main, ft_small, "已清空全部下载")
            end
            all = Download.list_books()      -- 重扫（可能已空）
        else
            -- 层 2：该书已下载章节 + 删除本书动作行
            local chs = Download.list_downloaded_chapters(book.bookId)
            if #chs == 0 then
                toast(ft_main, ft_small, "该书无已下载章节")
            else
                local ch_entries = DL._chapter_entries(chs)
                ch_entries[#ch_entries + 1] = { label = "─ 导出整本 epub", action = "export" }
                ch_entries[#ch_entries + 1] = { label = "─ 删除本书下载", action = "del_book" }
                local sel_ch = list_loop(ft_main, ft_small, ch_entries,
                    book.title .. " · 已下载 " .. #chs .. " 章")
                if sel_ch then
                    local entry = ch_entries[sel_ch]
                    if entry.action == "export" then
                        local path = DL._export_book(book, chs, ft_main, ft_small)
                        if path then
                            toast(ft_main, ft_small, "已导出: " .. tostring(path):match("([^/]+)$"))
                        elseif path == nil then
                            -- err 由 _export_book 内部展示过
                        end
                    elseif entry.action == "del_book" then
                        if confirm(ft_main, ft_small, "删除本书",
                            "删除《" .. tostring(book.title) .. "》全部下载内容？") then
                            Download.delete_book(book.bookId)
                            toast(ft_main, ft_small, "已删除本书")
                        end
                        all = Download.list_books()   -- 重扫书目
                    else
                        local c = entry.chapter
                        local rec = Progress.get(book.bookId)
                        local page = (rec and rec.chapter_idx == c.chapterIdx and rec.page) or 1
                        Log.info(string.format("offline open: %s ch%d", book.bookId, c.chapterIdx))
                        Reader.open(c.text, c.title, page)
                    end
                end
            end
        end
    end

    if ft_main then wr.font_close(ft_main) end
    if ft_small then wr.font_close(ft_small) end
end

return DL
