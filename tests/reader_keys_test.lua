-- reader.lua 键位表主机单测：钉住 KOReader + weread_K4 在 K4 上的按键习惯
-- （出处：weread_K4.koplugin/README.md:70-88；偏离项说明见 docs/keymap-k4.md）。
-- 键位是用户肌肉记忆的直接对象，错一个键就是一次可感知的回归；此测试不需要设备。
local Reader = require("reader")

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL reader_keys: " .. msg)
        fails = fails + 1
    end
end

-- 1. 翻页：bezel 左右翻页键 + Up/Down/Press
for _, k in ipairs({ "LPgFwd", "RPgFwd", "Down", "Press" }) do
    check(Reader.KEY_NEXT_PAGE[k] == true, k .. " 应为下一页")
end
for _, k in ipairs({ "LPgBack", "RPgBack", "Up" }) do
    check(Reader.KEY_PREV_PAGE[k] == true, k .. " 应为上一页")
end

-- 2. Left/Right = 换章，不是翻页（DK-2 把它们当翻页，本批次修的核心回归）
check(Reader.KEY_NEXT_CH.Right == true, "Right 应为下一章")
check(Reader.KEY_PREV_CH.Left == true, "Left 应为上一章")
check(Reader.KEY_NEXT_PAGE.Right == nil, "Right 不得同时绑为下一页")
check(Reader.KEY_PREV_PAGE.Left == nil, "Left 不得同时绑为上一页")
check(Reader.KEY_NEXT_PAGE.LPgFwd == true and Reader.KEY_NEXT_CH.LPgFwd == nil,
      "翻页键不得被当成换章键")

-- 3. 快捷菜单 vs 目录：Menu/ScreenKB+Down=快捷菜单，ScreenKB+Up=目录（真机拆分修复）
check(Reader.KEY_QUICKMENU.Menu == true, "Menu 应为快捷菜单")
check(Reader.KEY_QUICKMENU.ScreenKBPlusDown == true, "ScreenKB+Down 应为快捷菜单")
check(Reader.KEY_TOC.ScreenKBPlusUp == true, "ScreenKB+Up 应为目录")
check(Reader.KEY_TOC.Menu == nil, "Menu 不得同时绑为目录")
check(Reader.KEY_TOC.ScreenKBPlusDown == nil, "ScreenKB+Down 不得同时绑为目录")
check(Reader.KEY_QUICKMENU.ScreenKBPlusUp == nil, "ScreenKB+Up 不得同时绑为快捷菜单")
check(Reader.KEY_TOC.ScreenKBPlusUp == true, "ScreenKBPlusUp 应为目录")

-- 4. 退出：Back / Home（进度由调用方保存）
check(Reader.KEY_EXIT.Back == true, "Back 应为退出")
check(Reader.KEY_EXIT.Home == true, "Home 应为退出")

-- 5. 一键一义：任何键不得同时出现在两张表里（否则 dispatch 顺序决定行为）
local groups = {
    { "KEY_NEXT_PAGE", Reader.KEY_NEXT_PAGE },
    { "KEY_PREV_PAGE", Reader.KEY_PREV_PAGE },
    { "KEY_NEXT_CH",   Reader.KEY_NEXT_CH },
    { "KEY_PREV_CH",   Reader.KEY_PREV_CH },
    { "KEY_TOC",       Reader.KEY_TOC },
    { "KEY_EXIT",      Reader.KEY_EXIT },
}
local seen = {}
for _, g in ipairs(groups) do
    check(type(g[2]) == "table", g[1] .. " 必须存在")
    for k in pairs(g[2] or {}) do
        check(seen[k] == nil,
              "键 " .. k .. " 被 " .. tostring(seen[k]) .. " 与 " .. g[1] .. " 重复绑定")
        seen[k] = g[1]
    end
end

-- 6. 拼写护栏：表里的键名必须是 C 输入层能产出的名字
--    （镜像 src/device/input.c 的 kMap 基名 + "ScreenKBPlus" 组合前缀）
local KNOWN = {
    Press = true, Up = true, Down = true, Left = true, Right = true,
    Home = true, Menu = true, Back = true,
    LPgFwd = true, RPgBack = true, RPgFwd = true, LPgBack = true, ScreenKB = true,
}
for k in pairs(seen) do
    local base = k:match("^ScreenKBPlus(.+)$") or k
    check(KNOWN[base] == true, "键名 " .. k .. " 不在 input.c 键名集合内（拼写错误？）")
end

-- 7. 修饰键自身不应被绑成任何动作（C 层 latch 消费它，永不产出 "ScreenKB" 事件）
check(seen["ScreenKB"] == nil, "ScreenKB 自身不应绑动作")

print(string.format("reader_keys_test: %d failure(s)", fails))
return fails
