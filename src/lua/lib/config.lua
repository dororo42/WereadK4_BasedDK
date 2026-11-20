-- config.lua — 用户设置持久化（/mnt/us/weread/data/config.json）。
--
-- 单一写者 = 菜单「设置」项；reader 每次打开时读取（改设置下次阅读生效）。
-- 落盘走 Json.write_atomic（tmp+rename+sync，掉电安全）。损坏/缺失回默认值。

local Json = require("json")

local Config = {}

Config.PATH = "/mnt/us/weread/data/config.json"

-- 默认值集中一处：新键只在这里加，旧 config.json 自动补默认。
Config.DEFAULTS = { font_size = 26, line_factor = 1.54 }   -- 行高 = 字号 × line_factor

function Config.load()
    local data = {}
    local f = io.open(Config.PATH, "r")
    if f then
        local text = f:read("*a")
        f:close()
        local parsed = Json.decode(text or "")
        if type(parsed) == "table" then data = parsed end
    end
    -- 补默认：显式区分「用户设为 false/0」与「未设置」——只补 nil 键。
    for key, def in pairs(Config.DEFAULTS) do
        if data[key] == nil then data[key] = def end
    end
    return data
end

function Config.set(key, value)
    local data = Config.load()
    data[key] = value
    return Json.write_atomic(Config.PATH, data)
end

return Config
