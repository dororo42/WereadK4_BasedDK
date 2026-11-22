-- 阅读时长钟主机测（isword dwell 语义：活动窗口内计秒，静默超限停计）。
--
-- 为什么值得写：这是"在线阅读多少报多少"的核心语义——静默开着不翻页不计时、
-- 排水只出 ≤30s 整块（服务端对大 rt 静默丢弃）、离章余量有界。逻辑错了，
-- 服务端时长要么虚增（静默也计）要么丢失（>30s 整块被丢）。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL clock_test: " .. msg)
        fails = fails + 1
    end
end

package.path = "src/lua/?.lua;" .. package.path
-- 先保存后安装（否则存进 saved 的是桩本身，还原等于没还原——污染后续套件）
local saved_loaded = {}
for _, name in ipairs({ "reader", "protocol", "config", "fonts", "log" }) do
    saved_loaded[name] = package.loaded[name]
end
local function restore_loaded()
    for name, v in pairs(saved_loaded) do
        if v == nil then package.loaded[name] = nil else package.loaded[name] = v end
    end
end
package.loaded.protocol = { stubs = true }
package.loaded.config = { load = function() return {} end }
package.loaded.fonts = { load = function() return nil end, DEFAULT = "x", probe = function() return true end }
package.loaded.log = {
    info = function() end, error = function() end, debug = function() end,
    tail = function() return {} end, error_count = function() return 0 end, errors = 0,
}
package.loaded.reader = nil
local Reader = require("reader")

local S = 1000   -- ms

-- 1) 活动窗口内计秒：翻页间隔 20s × 3 次 = 60s
local clk = Reader.new_clock()
Reader.clock_activity(clk, 0)
Reader.clock_activity(clk, 20 * S)
Reader.clock_activity(clk, 40 * S)
Reader.clock_activity(clk, 60 * S)
local got = Reader.clock_take(clk, 60 * S)
check(got == 60, "60s 应一次排空（2×30s），实得 " .. got)
check(Reader.clock_remainder_s(clk) == 0, "排空后余 0，实得 " .. Reader.clock_remainder_s(clk))

-- 2) 静默超限不计：翻页间隔 > DWELL_LIMIT_S 的间隙不累计
clk = Reader.new_clock()
Reader.clock_activity(clk, 0)
Reader.clock_activity(clk, 5 * S)                 -- 5s
Reader.clock_activity(clk, 5 * S + 200 * S)       -- 静默 200s（超 dwell 90s）→ 不计
Reader.clock_activity(clk, 5 * S + 210 * S)       -- 恢复活动 10s
got = Reader.clock_take(clk, 5 * S + 210 * S)
check(got == 0, "dwell 外间隙不应累计（15s < 30s），实得 " .. got)
check(Reader.clock_remainder_s(clk) == 15, "只应累计 5+10=15s，实得 " .. Reader.clock_remainder_s(clk))

-- 3) 单次排空 ≤3 块（90s 封顶），残量留钟内
clk = Reader.new_clock()
Reader.clock_activity(clk, 0)
Reader.clock_activity(clk, 200 * S)               -- dwell 内 200s？>90s 不计！
check(Reader.clock_remainder_s(clk) == 0, "200s 间隔超 dwell 不应计入，实得 " .. Reader.clock_remainder_s(clk))
-- 构造 95s（dwell 内）→ take 应给 3 块（90s），残 5s
clk = Reader.new_clock()
Reader.clock_activity(clk, 0)
Reader.clock_activity(clk, 60 * S)                -- 60s
Reader.clock_activity(clk, 120 * S)               -- +60s = 120s 累计
Reader.clock_activity(clk, 180 * S)               -- +60s = 180s 累计（每窗 60s ≤ 90s dwell）
got = Reader.clock_take(clk, 180 * S)
check(got == 90, "180s 应排 3×30s=90s 封顶，实得 " .. got)
check(Reader.clock_remainder_s(clk) == 90, "残 90s 留钟内，实得 " .. Reader.clock_remainder_s(clk))
got = Reader.clock_take(clk, 180 * S)
check(got == 90, "再次 take 排下一批 90s，实得 " .. got)
check(Reader.clock_remainder_s(clk) == 0, "排空后余 0，实得 " .. Reader.clock_remainder_s(clk))

-- 4) 离章余量有界：dwell(90) + 排水残量(30) → 永远 < 120s（send_reading 4 片覆盖）
clk = Reader.new_clock()
Reader.clock_activity(clk, 0)
Reader.clock_activity(clk, 89 * S)                -- 89s 窗口（dwell 内极限）
local rem = Reader.clock_remainder_s(clk)
check(rem == 89 and rem < 120, "离章余量应 <120s，实得 " .. rem)

-- 5) 首次活动：last 未设不崩溃
clk = Reader.new_clock()
Reader.clock_activity(clk, 123 * S)
check(Reader.clock_remainder_s(clk) == 0, "仅一次活动应余 0")

restore_loaded()

print("clock_test done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails) .. " (fails=" .. fails .. ")")
return fails
