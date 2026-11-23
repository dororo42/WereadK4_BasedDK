-- shelf.lua — 书架列表视图（gateway /shelf/sync → 最近阅读 10 本 → 五向键导航）。
-- 用法：menu.lua 级联进入；也可独立 weread-dyn lua/shelf.lua（登录态必需）。
-- 交互：Up/Down 移动（10 本内回卷），中键选择，Back 返回（返回 nil）；Left/Right 无语义。
-- 为什么仍要拉全量元数据：/shelf/sync **没有分页参数**，一次响应就带回全部书目
-- （真机实测 13.9s / 4.88MB / 10187 本）；"只看最近 10 本"是用户口径，在客户端按
-- readUpdateTime 降序取前 10。元数据必须一次拉全，正文才是按章 spool。

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path

local Api = require("api")
local Auth = require("auth")
local Fonts = require("fonts")

local Shelf = {}

local MAX_ITEMS = 10        -- 极简书架：仅显示最近阅读的 10 本（用户口径）
local ROWS = MAX_ITEMS      -- 单屏 10 行（无翻页）
local ROW_H = 52

-- 最近阅读排序（纯函数，主机单测直接打）：readUpdateTime 降序，0/缺失排最后。
-- 服务端 books 原始序 ≠ 最近阅读序（probe_shelf 实证：前 10 本是调试期旧书）。
function Shelf.by_recent(books)
    local out = {}
    for i, b in ipairs(books or {}) do out[i] = b end
    table.sort(out, function(a, b)
        local ta = tonumber(a.readUpdateTime) or 0
        local tb = tonumber(b.readUpdateTime) or 0
        return ta > tb
    end)
    return out
end

local function ft_text(ft, x, y, s, fg)
    if ft then return wr.fb_text_ft(ft, x, y, s, fg) end
    return wr.fb_text(x, y, s, 2, fg)
end

local function ft_center(ft, y, s, fg)
    local w = ft and wr.font_width(ft, s) or (#s * 16)
    ft_text(ft, math.floor((wr.fb_w() - w) / 2), y, s, fg)
end

-- 单页渲染：sel 是全集绝对下标（唯一状态），页号与行区间都从它导出。
local function draw_page(books, sel, ft_main, ft_small)
    local W, H = wr.fb_w(), wr.fb_h()
    local n = #books
    -- 单屏契约：books 已在 run() 里 trim 到 MAX_ITEMS(=ROWS)，行区间恒为 1..n。
    local first = 1
    local last = math.min(n, ROWS)

    wr.fb_fill(0, 0, W, H, 0x00)
    ft_center(ft_main, 14, "书架", 0xFF)
    wr.fb_fill(16, 14 + 40, W - 32, 2, 0xFF)

    for idx = first, last do
        local book = books[idx]
        local y = 70 + (idx - first) * ROW_H
        if idx == sel then
            wr.fb_fill(12, y - 6, W - 24, 40, 0xFF)
            ft_text(ft_main, 22, y, tostring(book.title or "未命名"), 0x00)
        else
            ft_text(ft_main, 22, y, tostring(book.title or "未命名"), 0xFF)
        end
        local author = tostring(book.author or "")
        if author ~= "" and idx ~= sel then
            ft_text(ft_small, 440, y + 4, author, 0x60)
        end
    end

    ft_center(ft_small, H - 44, string.format("最近阅读 %d 本 · 上下移动 中键选择 返回", n), 0x60)
    wr.fb_quant()
    wr.fb_refresh(0)
    return last - first + 1
end

-- 主循环：返回选中 bookId | nil(Back 退出)
function Shelf.run()
    assert(wr.fb_open(), "fb_open failed")
    local ft_main = Fonts.load(24)
    local ft_small = Fonts.load(16)

    Auth.clear_screen("正在同步书架…")
    local data, err = Api.get_shelf()
    local books = (data and type(data.books) == "table") and data.books or nil
    if books then
        books = Shelf.by_recent(books)          -- 最近阅读排序
        local trimmed = {}
        for i = 1, math.min(MAX_ITEMS, #books) do trimmed[i] = books[i] end
        books = trimmed                         -- 极简：仅前 10 本
    end
    if not books then
        Auth.clear_screen("书架拉取失败: " .. tostring(err or "empty"):sub(1, 50))
        local t0 = wr.millis()
        while wr.millis() - t0 < 2500 do end
        if ft_main then wr.font_close(ft_main) end
        if ft_small then wr.font_close(ft_small) end
        wr.fb_close()
        return nil, "shelf fetch failed"
    end

    local sel = 1
    local shown = draw_page(books, sel, ft_main, ft_small)

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
        return nil, "smoke done, shown=" .. shown .. " books=" .. #books
    end

    local running = true
    local selected
    -- Left/Right 在单屏契约下无语义（books 恒 ≤ ROWS）：翻页分支留着就是死代码——
    -- 按下去只白刷一次屏，而"死键"在真机上的表现和坏键一模一样。
    while running do
        local key = wr.input_poll(1000, true)
        if key == "Up" then
            sel = sel - 1
            if sel < 1 then sel = #books end
            draw_page(books, sel, ft_main, ft_small)
        elseif key == "Down" then
            sel = sel + 1
            if sel > #books then sel = 1 end
            draw_page(books, sel, ft_main, ft_small)
        elseif key == "Press" then
            selected = books[sel]
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

