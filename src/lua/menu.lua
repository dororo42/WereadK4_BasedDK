-- menu.lua — DK-1 step1 五向键菜单（ASCII + 8x16 点阵字体）。
-- freetype 接入后（DK-1 step2）升级为中文 + 真实排版；本步只验证 LuaJIT+FFI桥+输入回路。
--
-- 交互：Up/Down 移动，中键(Press) 选择，Back/Menu/Home 退出。
-- SMOKE=true 时只渲染一帧即退出（自动化验收，不进按键循环）。

local items = {
    "Continue Reading",
    "Bookshelf",
    "Search",
    "Sync Progress",
    "Settings",
    "Exit",
}

local sel = 1
local running = true

assert(wr.fb_open(), "fb_open failed")
assert(wr.input_open(), "input_open failed")

local W, H = wr.fb_w(), wr.fb_h()
local SCALE = 2                 -- 8x16 字形放大 2 倍 -> 16x32，600x800 上可读
local GLYPH_H = 16 * SCALE
local LH = GLYPH_H + 14         -- 行高
local Y0 = 84                   -- 首个菜单项 y

local function draw()
    wr.fb_fill(0, 0, W, H, 0xFF)                       -- 白底
    wr.fb_text(16, 14, "WereadK4  DK-1", SCALE, 0x00)  -- 标题（黑字）
    wr.fb_fill(16, 14 + GLYPH_H + 6, W - 32, 2, 0x00)  -- 分隔线

    for i, name in ipairs(items) do
        local y = Y0 + (i - 1) * LH
        if i == sel then
            wr.fb_fill(12, y - 5, W - 24, GLYPH_H + 10, 0x00)  -- 黑底高亮
            wr.fb_text(22, y, name, SCALE, 0xFF)               -- 白字
        else
            wr.fb_text(22, y, name, SCALE, 0x00)               -- 黑字
        end
    end

    wr.fb_text(16, H - 26, "Up/Down:move  Center:select  Back:exit", 1, 0x60)
    wr.fb_refresh(0)   -- partial 不闪
end

-- 选中非 Exit 项：显示提示，等任意键回到菜单
local function show(msg)
    wr.fb_fill(0, 0, W, H, 0xFF)
    wr.fb_text(16, 14, "WereadK4  DK-1", SCALE, 0x00)
    wr.fb_fill(16, 14 + GLYPH_H + 6, W - 32, 2, 0x00)
    wr.fb_text(22, Y0 + 20, msg, SCALE, 0x00)
    wr.fb_text(16, H - 26, "press any key to go back", 1, 0x60)
    wr.fb_refresh(0)
    -- 阻塞等一个真实新按键：ignore_repeat=true 跳过选中键长按的 auto-repeat，
    -- 循环直到拿到首次按下，避免消息被同一按键的 repeat 立即关闭（闪现）。
    while wr.input_poll(-1, true) == nil do end
    draw()
end

draw()

if not SMOKE then
    while running do
        local key = wr.input_poll(1000, true)   -- 1s 超时 + 忽略 repeat（离散按键，防长按重复触发）
        if key == "Up" then
            sel = sel - 1; if sel < 1 then sel = #items end; draw()
        elseif key == "Down" then
            sel = sel + 1; if sel > #items then sel = 1 end; draw()
        elseif key == "Press" then
            if items[sel] == "Exit" then
                running = false
            else
                show("Selected: " .. items[sel])
            end
        elseif key == "Back" or key == "Menu" or key == "Home" then
            running = false
        end
    end
end

wr.input_close()
wr.fb_close()
print("menu done, sel=" .. sel .. (SMOKE and " (smoke)" or ""))
