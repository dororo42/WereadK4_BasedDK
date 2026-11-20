-- config_test.lua — 设置持久化回归：默认值/写入回读/损坏回退/路径可注入。
package.path = "src/lua/lib/?.lua;src/lua/?.lua;tests/?.lua;" .. package.path
local Json = require("json")

local fails = 0
local function check(name, ok, detail)
    print((ok and "PASS " or "FAIL ") .. name .. (detail and ("  " .. detail) or ""))
    if not ok then fails = fails + 1 end
end

local TMP = os.tmpname()
local Config = require("config")
Config.PATH = TMP

-- 1) 缺失文件 → 全默认
local c = Config.load()
check("defaults.on_missing", c.font_size == 26)

-- 2) set → load 回读
check("set.ok", Config.set("font_size", 30))
check("load.roundtrip", Config.load().font_size == 30)

-- 3) 保留用户键 + 补默认
check("set.extra_key", Config.set("theme", "dark") and Config.load().theme == "dark")
check("defaults.filled", Config.load().font_size == 30)
check("line_factor.default", Config.load().line_factor == 1.54)

-- 4) 损坏文件 → 回默认（不崩溃）
local f = io.open(TMP, "w"); f:write("{broken"); f:close()
check("corrupt.fallback", Config.load().font_size == 26)

-- 5) 原子写不留 .tmp
Config.set("font_size", 22)
local hf = io.open(TMP .. ".tmp", "r")
check("atomic.no_tmp_left", hf == nil)
if hf then hf:close() end

os.remove(TMP)
os.remove(TMP .. ".tmp")
print(string.format("config_test done: %s (fails=%d)",
      fails == 0 and "ALL PASS" or "HAS FAILURES", fails))
return fails
