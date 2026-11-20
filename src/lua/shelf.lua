-- shelf.lua — 书架列表视图（gateway /shelf/sync → 中文列表 → 五向键导航）。
-- 用法：menu.lua 级联进入；也可独立 weread-dyn lua/shelf.lua（登录态必需）。
-- 交互：Up/Down 移动，中键选择（阅读占位屏），Back 返回（返回 nil）。
-- 无翻页：列表上限 MAX_ITEMS（详见 Shelf.run 的裁剪注释），所以只有一屏可导航。

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path

local Api = require("api")
local Auth = require("auth")

local Shelf = {}

local MAX_ITEMS = 10              -- 极简书架：仅 10 项最近阅读书目（服务端 books 序）
local FT_PATH = "/mnt/us/weread/fonts/wqy-microhei.ttc"

local function ft_text(ft, x, y, s, fg)
    if ft then return wr.fb_text_ft(ft, x, y, s, fg) end
    return wr.fb_text(x, y, s, 2, fg)
end

local function ft_center(ft, y, s, fg)
    local w = ft and wr.font_width(ft, s) or (#s * 16)
    ft_text(ft, math.floor((wr.fb_w() - w) / 2), y, s, fg)
end

-- 单页渲染：books 即展示全集（已按 MAX_ITEMS 裁剪），页内下标 == 绝对下标
local function draw_page(books, sel_abs, ft_main, ft_small, header)
    local W, H = wr.fb_w(), wr.fb_h()
    wr.fb_fill(0, 0, W, H, 0x00)
    ft_center(ft_main, 14, header or "书架", 0xFF)
    wr.fb_fill(16, 14 + 40, W - 32, 2, 0xFF)

    for idx = 1, #books do
        local book = books[idx]
        local y = 70 + (idx - 1) * 46
        if idx == sel_abs then
            wr.fb_fill(12, y - 6, W - 24, 40, 0xFF)
            ft_text(ft_main, 22, y, tostring(book.title or "未命名"), 0x00)
        else
            ft_text(ft_main, 22, y, tostring(book.title or "未命名"), 0xFF)
        end
        local author = tostring(book.author or "")
        if author ~= "" and idx ~= sel_abs then
            ft_text(ft_small, 400, y + 4, author, 0x60)
        end
    end

    ft_center(ft_small, H - 44,
        string.format("%d 本 · 上下移动 中键选择 返回", #books), 0x60)
    wr.fb_quant()
    wr.fb_refresh(0)
end

-- 主循环：返回选中 bookId | nil(Back 退出)
function Shelf.run()
    assert(wr.fb_open(), "fb_open failed")
    local ft_main = wr.font_load(FT_PATH, 30)
    local ft_small = wr.font_load(FT_PATH, 18)

    Auth.clear_screen("正在同步书架…")
    local data, err = Api.get_shelf()
    local books = (data and type(data.books) == "table") and data.books or nil
    if not books then
        Auth.clear_screen("书架拉取失败: " .. tostring(err or "empty"):sub(1, 50))
        local t0 = wr.millis()
        while wr.millis() - t0 < 2500 do end
        if ft_main then wr.font_close(ft_main) end
        if ft_small then wr.font_close(ft_small) end
        wr.fb_close()
        return nil, "shelf fetch failed"
    end

    -- 极简裁剪：仅前 MAX_ITEMS 项（服务端 books 序≈最近阅读序）
    local shown = {}
    for i = 1, math.min(MAX_ITEMS, #books) do
        shown[#shown + 1] = books[i]
    end
    local header = #shown < #books
        and string.format("书架 · 最近 %d 本", #shown) or "书架"
    local sel_abs = 1
    draw_page(shown, sel_abs, ft_main, ft_small, header)

    -- SMOKE：渲染一帧 + 像素自检即退（自动化验收）
    if SMOKE then
        local m = 0
        for yy = 20, 60 do
            for xx = 200, 400 do
                local v = wr.fb_get(xx, yy)
                if v > m then m = v end
            end
        end
        print("shelf pixel-check header=" .. tostring(m))
        if ft_main then wr.font_close(ft_main) end
        if ft_small then wr.font_close(ft_small) end
        if m < 55 then print("SHELF-PIXEL-FAIL") else print("SHELF-PIXEL-PASS") end
        return nil, "smoke done, shown=" .. #shown .. " books=" .. #books
    end

    local running = true
    local selected
    while running do
        local key = wr.input_poll(1000, true)
        if key == "Up" then
            sel_abs = sel_abs - 1
            if sel_abs < 1 then sel_abs = #shown end
            draw_page(shown, sel_abs, ft_main, ft_small, header)
        elseif key == "Down" then
            sel_abs = sel_abs + 1
            if sel_abs > #shown then sel_abs = 1 end
            draw_page(shown, sel_abs, ft_main, ft_small, header)
        elseif key == "Press" then
            selected = shown[sel_abs]
            running = false
        elseif key == "Back" or key == "Menu" or key == "Home" then
            running = false
        end
    end
    if ft_main then wr.font_close(ft_main) end
    if ft_small then wr.font_close(ft_small) end
    -- fb 不在此关闭：menu 级联共享同一 fb（调用方负责生命周期）
    if selected then
        print("selected book: " .. tostring(selected.bookId) .. " " .. tostring(selected.title))
        return selected.bookId, selected
    end
    return nil
end

return Shelf
