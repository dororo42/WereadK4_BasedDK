-- fonts.lua — 字体选择的唯一决策点（设置里的「字体」→ 各屏加载）。
--
-- 为什么需要这一层：字体路径原先硬编码在 4 个文件里（menu/shelf/reader/auth 各写
-- 一份 wqy 绝对路径），换字体因此变成改 4 处 + 重装。现在只有本模块知道候选与
-- 回退，调用方一律 Fonts.load(px)。
--
-- 候选是**固定清单 + 存在性探测**，不是运行时目录扫描：K4 上没有可靠的目录遍历
-- （无 popen/scandir 绑定），而扫描会把「装了什么」当成「能用什么」——freetype
-- 打不开的文件（损坏、非字体）在扫描方案里要到渲染时才暴露。清单里的路径都是本机
-- 实测存在的中文字体，缺文件即不列出（KOReader 字体目录可能不存在）；探测点做成
-- Fonts.probe 字段，主机侧单测直接替换它。
--
-- 只读复用他人安装的字体文件，绝不写入或改动那些目录（用户约束）。

local Config = require("config")

local Fonts = {}

-- 首项 = 出厂默认（随本包部署，见 tools/deploy-weread.sh），永远可选。
Fonts.CANDIDATES = {
    { label = "文泉驿微米黑", path = "/mnt/us/weread/fonts/wqy-microhei.ttc" },
    { label = "霞鹜文楷",     path = "/mnt/us/fonts/LXGWWenKai-Regular.ttf" },
    { label = "阿里巴巴普惠体", path = "/mnt/us/fonts/AlibabaPuHuiTi-3-55-Regular.ttf" },
    { label = "思源黑体",     path = "/mnt/us/fonts/noto/NotoSansCJKsc-Regular.otf" },
    { label = "仓耳今楷",     path = "/mnt/us/koreader/fonts/cangerjinkai/cangerjinkai03-W04-1000.ttf" },
    { label = "方正滕黑",     path = "/mnt/us/koreader/fonts/fangzheng/FZTengZMZKJW.TTF" },
}

Fonts.DEFAULT = Fonts.CANDIDATES[1].path

-- 存在性探测（可被单测替换的缝）。
function Fonts.probe(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

-- 当前生效路径：config.font_path 缺省或为空 → 默认。
-- 只认非空字符串：配置文件被手写成一个数字或表时，路径不能带着坏值进 freetype。
function Fonts.path()
    local p = Config.load().font_path
    if type(p) == "string" and p ~= "" then return p end
    return Fonts.DEFAULT
end

-- 设置屏用的候选：存在即列出；默认项永远在列（用户换了坏字体后还能回得来）。
function Fonts.list()
    local out = {}
    for _, c in ipairs(Fonts.CANDIDATES) do
        if c.path == Fonts.DEFAULT or Fonts.probe(c.path) then
            out[#out + 1] = c
        end
    end
    return out
end

-- 中文名（未知/已卸载的路径原样显示，便于排错）。
function Fonts.label(path)
    for _, c in ipairs(Fonts.CANDIDATES) do
        if c.path == path then return c.label end
    end
    return tostring(path)
end

-- 原始加载：不打回退。设置屏用它验证"这个 face 到底能不能开"再决定保存，
-- 因为回退会掩盖坏文件（Loads 成功但用的其实是默认字体）。调用方负责 font_close。
function Fonts.open(path, px)
    return wr.font_load(path, px)
end

-- 按设置加载；非默认字体加载失败时自动退回默认（换字体不该让人读不了书）。
-- 回退成功的返回值仍是合法句柄，调用方无需处理 nil 之外的情况。
function Fonts.load(px)
    local p = Fonts.path()
    local ft = Fonts.open(p, px)
    if ft or p == Fonts.DEFAULT then return ft end
    return Fonts.open(Fonts.DEFAULT, px)
end

return Fonts
