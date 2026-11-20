-- fonts.lua 的主机单测：字体路径的解析、候选过滤、加载回退。
--
-- 为什么值得写：字体是设备侧资源，路径写错或设备没装 KOReader 字体的表现是
-- 「屏幕空白 + 无报错」（freetype 失败只返回 nil），设备 SMOKE 的像素自检能抓到
-- 全空，抓不到"选了坏字体就再也进不去设置"。这条回退线必须有护栏。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

package.path = "src/lua/lib/?.lua;src/lua/?.lua;" .. package.path

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL fonts: " .. msg)
        fails = fails + 1
    end
end

------------------------------------------------------------------ mock 环境
local CFG = "/tmp/wr_fonts_test_config.json"
local probes = {}          -- path -> true/false
local loaded = {}          -- 记录 wr.font_load 调用序列
local fail_paths = {}      -- 这些路径加载失败

local saved_loaded = { config = package.loaded.config, fonts = package.loaded.fonts }
package.loaded.config, package.loaded.fonts = nil, nil
os.remove(CFG)

local Config = require("config")
Config.PATH = CFG
local Fonts = require("fonts")

Fonts.probe = function(path) return probes[path] == true end
wr = {
    font_load = function(path, px)
        loaded[#loaded + 1] = { path = path, px = px }
        if fail_paths[path] then return nil end
        return 1
    end,
}
local function reset()
    loaded = {}
end

------------------------------------------------------------------ 用例
-- 1) 未设置 → 默认路径；默认项永远在候选里（否则换了坏字体就回不来）
check(Fonts.path() == Fonts.DEFAULT,
    "无配置应回落默认，实得 " .. tostring(Fonts.path()))
probes = {}
check(#Fonts.list() == 1 and Fonts.list()[1].path == Fonts.DEFAULT,
    "全设备无字体时只应列默认项，实得 " .. #Fonts.list() .. " 项")

-- 2) 存在性过滤：只列出探测到的字体，顺序按候选表
probes = { [Fonts.CANDIDATES[2].path] = true, [Fonts.CANDIDATES[5].path] = true }
local list = Fonts.list()
check(#list == 3, "默认 + 2 个存在 = 3 项，实得 " .. #list)
check(list[2].path == Fonts.CANDIDATES[2].path and list[3].path == Fonts.CANDIDATES[5].path,
    "候选顺序应跟随 CANDIDATES（默认在首，其余按清单序）")

-- 3) 设置生效：先按设置加载，命中即用，不多开一个 face（font slot 只有几个）
Config.set("font_path", Fonts.CANDIDATES[2].path)
reset()
check(Fonts.path() == Fonts.CANDIDATES[2].path, "设置后 path 应返回设置值")
local ft = Fonts.load(30)
check(ft ~= nil, "加载应成功")
check(#loaded == 1 and loaded[1].path == Fonts.CANDIDATES[2].path and loaded[1].px == 30,
    "成功时应只调用一次 font_load(设置路径, 30)，实得 " .. #loaded .. " 次")

-- 4) 坏字体回退：非默认路径加载失败 → 退回默认并返回默认句柄
fail_paths[Fonts.CANDIDATES[2].path] = true
reset()
ft = Fonts.load(18)
check(ft ~= nil, "自定义字体打不开时必须仍能加载")
check(#loaded == 2 and loaded[1].path == Fonts.CANDIDATES[2].path
      and loaded[2].path == Fonts.DEFAULT and loaded[2].px == 18,
    "应先试设置路径再回退默认（同字号），实得 " ..
    tostring(loaded[1] and loaded[1].path) .. " → " .. tostring(loaded[2] and loaded[2].path))

-- 5) 默认字体本身打不开：不重复尝试，如实返回 nil（调用方保留点阵回退）
Config.set("font_path", Fonts.DEFAULT)
fail_paths[Fonts.DEFAULT] = true
reset()
ft = Fonts.load(30)
check(ft == nil, "默认字体打不开应返回 nil")
check(#loaded == 1, "默认失败不该再试第二个路径，实得 " .. #loaded .. " 次")
fail_paths[Fonts.DEFAULT] = nil

-- 6) Fonts.open 不打回退（设置屏靠它判真伪：回退会把坏文件伪装成好文件）
Config.set("font_path", Fonts.DEFAULT)
reset()
check(Fonts.open(Fonts.CANDIDATES[2].path, 20) == nil,
    "坏路径的 open 必须返回 nil（不得静默换成默认）")
check(#loaded == 1, "open 只应发一次 font_load，实得 " .. #loaded .. " 次")
check(Fonts.open(Fonts.DEFAULT, 20) ~= nil, "默认路径的 open 应成功")

-- 7) 手写坏值不得进 freetype：font_path 是数字/空串/表 → 一律用默认
for _, bad in ipairs({ 42, "" }) do
    Config.set("font_path", bad)
    check(Fonts.path() == Fonts.DEFAULT,
        "坏值 " .. tostring(bad) .. " 应被忽略并回落默认，实得 " .. tostring(Fonts.path()))
end
Config.set("font_path", { "a" })
check(Fonts.path() == Fonts.DEFAULT, "表值应被忽略，实得 " .. tostring(Fonts.path()))

-- 7) 标签：已知路径给中文名，未知给原样（设置屏与排错都要能看出是哪个文件）
check(Fonts.label(Fonts.CANDIDATES[2].path) == Fonts.CANDIDATES[2].label,
    "已知路径应给 label，实得 " .. tostring(Fonts.label(Fonts.CANDIDATES[2].path)))
check(Fonts.label("/mnt/us/nope.ttf") == "/mnt/us/nope.ttf",
    "未知路径应原样显示，实得 " .. tostring(Fonts.label("/mnt/us/nope.ttf")))
check(Fonts.label(nil) ~= nil, "label(nil) 不应报错或返回 nil")

------------------------------------------------------------------ 还原
os.remove(CFG)
package.loaded.config, package.loaded.fonts = saved_loaded.config, saved_loaded.fonts
_G.wr = nil

print("fonts done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails)
    .. " (fails=" .. fails .. ")")
return fails
