-- menu.lua — DK-1 step2 中文菜单（freetype 主路径 + 8x16 点阵回退）。
--
-- 字体：vendor/duokan/fonts/wqy-microhei.ttc（多看固件抽取，GPLv2+FE，见 vendor/duokan/README.md）。
-- 缺字体文件时自动回退 step1 点阵路径（英文）——功能不劣化。
-- 交互：Up/Down 移动，中键(Press) 选择，Back/Menu/Home 退出。
-- SMOKE=true 时只渲染一帧 + 像素自检（采样字形区最小灰度）即退出（自动化验收）。

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path

local Api = require("api")
local Auth = require("auth")
local Shelf = require("shelf")

local FONT_PATH = os.getenv("WR_FONT") or "/mnt/us/weread/fonts/wqy-microhei.ttc"

-- 菜单项随登录态变化（shelf/阅读在登录后可用）
local function build_items()
    if Api.has_login() then
        local auth = Api.load_auth()
        local name = tostring(auth.account.name or auth.account.user_vid or "已登录")
        return { "继续阅读", "书架", "同步进度", "设置", "退出" }, name
    end
    return { "登录", "书架(需登录)", "设置", "退出" }, nil
end

local items, account_name = build_items()

local sel = 1
local running = true

assert(wr.fb_open(), "fb_open failed")
-- SMOKE 允许输入被占用（KOReader EVIOCGRAB 独占时仍可自动验收渲染）；
-- 交互模式必须拿到输入。
local ok_in = wr.input_open()
if not SMOKE then assert(ok_in, "input_open failed (KOReader 独占中?)") end

local W, H = wr.fb_w(), wr.fb_h()

-- freetype 字体：主字号 30 + 小字号 20；加载失败回退点阵
local ft_main = wr.font_load(FONT_PATH, 30)
local ft_small = ft_main and wr.font_load(FONT_PATH, 20) or nil
local FT_MODE = (ft_main ~= nil)

local ITEM_H   = FT_MODE and 46 or (16 * 2)      -- 行高
local TITLE_H  = FT_MODE and 44 or (16 * 2)
local Y0       = 84

local function text(x, y, s, fg, font_id)
    if FT_MODE and font_id then
        local endx = wr.fb_text_ft(font_id, x, y, s, fg)
        if endx then return endx end
    end
    return wr.fb_text(x, y, s, 2, fg)   -- 点阵回退（scale=2）
end

local function draw()
    items, account_name = build_items()
    if sel > #items then sel = #items end
    wr.fb_fill(0, 0, W, H, 0xFF)                            -- 白底
    local title = "微信读书 K4" .. (account_name and ("  " .. account_name) or "")
    text(16, 14, title, 0x00, ft_main)                      -- 标题（含账号名）
    wr.fb_fill(16, 14 + TITLE_H, W - 32, 2, 0x00)           -- 分隔线

    for i, name in ipairs(items) do
        local y = Y0 + (i - 1) * ITEM_H
        if i == sel then
            wr.fb_fill(12, y - 6, W - 24, ITEM_H - 6, 0x00) -- 黑底高亮
            text(22, y, name, 0xFF, ft_main)                -- 白字
        else
            text(22, y, name, 0x00, ft_main)                -- 黑字
        end
    end

    if ft_small then
        wr.fb_text_ft(ft_small, 16, H - 40, "上下移动  中键选择  返回退出", 0x60)
    else
        wr.fb_text(16, H - 26, "Up/Down:move  Center:select  Back:exit", 1, 0x60)
    end
    wr.fb_quant()      -- Duokan 16 级量化（幂等，绘制期统一收敛）
    wr.fb_refresh(0)   -- partial 不闪
end

-- 选中非 Exit 项：显示提示，等任意键回到菜单
local function show(msg)
    wr.fb_fill(0, 0, W, H, 0xFF)
    text(16, 14, "微信读书 K4", 0x00, ft_main)
    wr.fb_fill(16, 14 + TITLE_H, W - 32, 2, 0x00)
    text(22, Y0 + 20, msg, 0x00, ft_main)
    if ft_small then
        wr.fb_text_ft(ft_small, 16, H - 40, "按任意键返回", 0x60)
    else
        wr.fb_text(16, H - 26, "press any key to go back", 1, 0x60)
    end
    wr.fb_quant()
    wr.fb_refresh(0)
    while wr.input_poll(-1, true) == nil do end
    draw()
end

draw()

-- SMOKE 像素自检：字形区应有深色像素（<200），全白说明渲染失败
if SMOKE then
    local function region_min(x0, y0, x1, y1)
        local m = 255
        for yy = y0, y1 do
            for xx = x0, x1 do
                local v = wr.fb_get(xx, yy)
                if v >= 0 and v < m then m = v end
            end
        end
        return m
    end
    local title_min = region_min(18, 16, 300, 14 + TITLE_H)
    local item1_min = region_min(22, Y0, 260, Y0 + ITEM_H - 10)
    local footer_min = region_min(16, H - 44, 400, H - 10)
    print(string.format("pixel-check title=%d item1=%d footer=%d", title_min, item1_min, footer_min))
    if title_min > 200 or item1_min > 200 then
        print("PIXEL-CHECK FAIL: glyph region empty")
    else
        print("PIXEL-CHECK PASS")
    end
end

if not SMOKE then
    while running do
        local key = wr.input_poll(1000, true)
        if key == "Up" then
            sel = sel - 1; if sel < 1 then sel = #items end; draw()
        elseif key == "Down" then
            sel = sel + 1; if sel > #items then sel = 1 end; draw()
        elseif key == "Press" then
            if items[sel] == "退出" then
                running = false
            elseif items[sel] == "登录" then
                local account, lerr = Auth.login(
                    function(url) Auth.draw_login_screen(url, "微信扫码登录", "手机微信扫码 · Back 取消") end,
                    function(msg) Auth.clear_screen(msg) end)
                if account then
                    Auth.clear_screen("登录成功: " .. tostring(account.name or account.user_vid))
                    local t0 = wr.millis()
                    while wr.millis() - t0 < 1500 do end
                else
                    Auth.clear_screen("登录未完成: " .. tostring(lerr):sub(1, 50))
                    local t0 = wr.millis()
                    while wr.millis() - t0 < 2500 do end
                end
                sel = 1
                draw()
            elseif items[sel] == "书架" then
                sel = 1
                local book_id, book = Shelf.run()
                if book_id then
                    assert(wr.fb_open(), "fb_open failed")
                    show("阅读器开发中: " .. tostring(book.title or book_id))
                end
                draw()
            else
                show("已选择: " .. items[sel])
            end
        elseif key == "Back" or key == "Menu" or key == "Home" then
            running = false
        end
    end
end

if ft_main then wr.font_close(ft_main) end
if ft_small then wr.font_close(ft_small) end
wr.input_close()
wr.fb_close()
print("menu done, sel=" .. sel .. (SMOKE and " (smoke)" or "") .. (FT_MODE and " ft=on" or " ft=off"))
