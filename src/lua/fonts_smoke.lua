-- fonts_smoke.lua — 字体清单真机取证：清单里每项必须存在且 freetype 真能打开。
--
-- 为什么值得写：候选路径是设备文件系统的事实，主机测不出来（主机上 probe 一律假）。
-- 设置屏只列"打得开"的项，所以这里等于在验设置屏的可选集合；同时验 WR_FT_MAX_FONTS
-- 扩容后的多 face 常驻（菜单 2 + 书架 2 + 清屏 1 一起开着不空白）。
package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path
local Fonts = require("fonts")

assert(wr.fb_open(), "fb_open failed")
local fails = 0
print("default=" .. Fonts.DEFAULT)

local list = Fonts.list()
print("listable=" .. #list)
if #list < 1 then
    print("FONTS-FAIL 清单为空（设置屏将没有可选项）")
    fails = fails + 1
end

-- 全部候选都开一遍：路径写错/文件损坏/格式不认，都在这里现形
for _, c in ipairs(Fonts.CANDIDATES) do
    local face = Fonts.open(c.path, 30)
    local found = Fonts.probe(c.path) and "yes" or "no"
    print(string.format("%-8s exists=%-3s open=%s  %s", c.label, found,
        face and "ok" or "FAIL", c.path))
    if face == nil and found == "yes" then
        print("FONTS-FAIL 文件在但打不开，却进了清单: " .. c.path)
        fails = fails + 1
    end
    if face then wr.font_close(face) end
end

-- 同时常驻 5 个 face：超过旧上限 4 才算扩容生效（层叠 UI 的真实用量）
local held = {}
for i = 1, 5 do
    held[i] = Fonts.load(20 + i)
    if not held[i] then
        print("FONTS-FAIL 第 " .. i .. " 个 face 打开失败（槽位上限没生效？）")
        fails = fails + 1
    end
end
for i = 1, 5 do if held[i] then wr.font_close(held[i]) end end

wr.fb_close()
print(fails == 0 and "FONTS-SMOKE-PASS" or "FONTS-SMOKE-FAIL fails=" .. fails)
os.exit(fails == 0 and 0 or 1)
