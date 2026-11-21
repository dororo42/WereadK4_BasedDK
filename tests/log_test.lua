-- log.lua 的主机测：PATH 注入 tmp 目录，验证写入/级别过滤/轮转/计数/tail。
--
-- 为什么值得写：log 是「调试面」——出问题时它是唯一的现场证据。轮转截半按行边界、
-- [E] 计数、tail 取行数这些逻辑错了，用户看到的要么是丢日志要么是假计数，
-- 两者都比没有日志更误导。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL log_test: " .. msg)
        fails = fails + 1
    end
end

-- 每个用例一份干净实例（Log.errors 计数和 PATH 都是模块级状态）
local function fresh(path)
    package.loaded.log = nil
    local Log = require("log")
    Log.PATH = path or "/tmp/wr_log_test_" .. tostring(os.time()) .. ".log"
    Log.enabled = true
    Log.level = "I"
    Log.errors = 0
    return Log
end
local function rm(path) os.remove(path) end

-- 1) 写入 + 读回 + 时间戳/级别前缀
local Log = fresh()
os.remove(Log.PATH)
Log.info("hello world")
local lines = Log.tail(10)
check(#lines == 1, "info 应落盘 1 行，实得 " .. #lines)
check(lines[1]:find("hello world", 1, true) ~= nil, "内容应原样写入")
check(lines[1]:match("^%d%d%-%d%d %d%d:%d%d:%d%d %[I%]") ~= nil,
    "行格式应为 'MM-DD HH:MM:SS [I] msg'，实得 " .. tostring(lines[1]))

-- 2) 级别过滤：level=I 时 debug 不落盘；E 落盘且计数
Log.debug("noisy")
check(#Log.tail(10) == 1, "level=I 时 debug 不应落盘")
Log.error("boom")
check(#Log.tail(10) == 2, "error 应落盘")
check(Log.errors == 1, "error 应使本进程计数+1，实得 " .. Log.errors)
check(Log.error_count() == 1, "error_count 应统计 [E] 行，实得 " .. Log.error_count())

-- 3) tail(n) 取最近 n 行且按原序
for i = 1, 5 do Log.info("line" .. i) end
lines = Log.tail(3)
check(#lines == 3 and lines[1]:find("line3", 1, true) and lines[3]:find("line5", 1, true),
    "tail(3) 应取最近 3 行按原序，实得 " .. table.concat(lines, " | "))

-- 4) 轮转：超过 MAX_BYTES 截半，保留较新一半，且按行边界（不切出残行）
Log = fresh()
Log.MAX_BYTES = 150
for i = 1, 12 do Log.info(string.format("x%02d", i)) end
local data = io.open(Log.PATH, "rb"):read("*a")
io.open(Log.PATH, "rb"):close()
local n_lines = 0
for _ in data:gmatch("[^\n]+\n") do n_lines = n_lines + 1 end
check(#data <= Log.MAX_BYTES + 1, "轮转后不得超限，实得 " .. #data)
check(n_lines >= 1, "轮转后必须还有内容（截半不是清空）")
check(data:sub(-1) == "\n", "轮转按行边界截断，末尾不得是残行")
check(data:find("x12", 1, true) ~= nil, "必须保留最新的行（x12）")
check(data:find("x01", 1, true) == nil, "最老的行应当被丢（x01）")
rm(Log.PATH)

-- 5) PATH 不可写（目录不存在）：静默不崩，错误计数仍然走
Log = fresh("/nonexistent_dir_xyz/app.log")
Log.error("no disk")
check(Log.errors == 1, "写盘失败不影响进程内错误计数，实得 " .. Log.errors)
check(#Log.tail(5) == 0, "读不存在的日志返回空表")

-- 6) Log.enabled=false 全关（主机测试静音用）
Log = fresh()
Log.enabled = false
Log.error("muted")
check(Log.errors == 0, "enabled=false 时连计数都不应走，实得 " .. Log.errors)
rm(Log.PATH)

print("log_test done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails) .. " (fails=" .. fails .. ")")
return fails
