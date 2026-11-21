-- log.lua — 运行日志（调试面）：反映实际加载/占用/错误。
--
-- 设计：append 到 /mnt/us/weread/data/app.log（设备）；PATH 可注入（主机测试用
-- 临时文件）。容量上限 MAX_BYTES，超限截半（保留较新一半，按行边界）——调试日志
-- 允许丢最老的，不允许无限增长吃满 /mnt/us。error 计数随进程存活（状态屏显示）。
-- 约定级别：D=debug（默认不落盘） I=info E=error。

local Log = {}

Log.PATH = "/mnt/us/weread/data/app.log"
Log.MAX_BYTES = 200 * 1024
Log.enabled = true              -- 主机测试可关
Log.errors = 0                  -- 本进程 error 计数（状态屏）

local LEVEL_ORDER = { D = 0, I = 1, E = 2 }
Log.level = "I"                 -- 低于此级别不落盘

local function size_of(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end") or 0
    f:close()
    return size
end

-- 超限截半：按行边界保留较新一半（调试日志允许丢最老，不允许无限增长）
local function rotate_if_needed()
    if size_of(Log.PATH) <= Log.MAX_BYTES then return end
    local f = io.open(Log.PATH, "rb")
    if not f then return end
    local data = f:read("*a")
    f:close()
    local half = data:sub(math.floor(#data / 2))
    local nl = half:find("\n", 1, true)
    if nl then half = half:sub(nl + 1) end
    local w = io.open(Log.PATH, "w")
    if w then w:write(half); w:close() end
end

function Log.write(level, msg)
    if not Log.enabled then return end
    if (LEVEL_ORDER[level] or 1) < (LEVEL_ORDER[Log.level] or 1) then return end
    if level == "E" then Log.errors = Log.errors + 1 end
    local line = os.date("%m-%d %H:%M:%S") .. " [" .. level .. "] " .. tostring(msg) .. "\n"
    local f = io.open(Log.PATH, "a")
    if not f then return end
    f:write(line)
    f:close()
    rotate_if_needed()
end

function Log.debug(msg) Log.write("D", msg) end
function Log.info(msg)  Log.write("I", msg) end
function Log.error(msg) Log.write("E", msg) end

-- 读尾部 n 行（状态屏展示用）
function Log.tail(n)
    local f = io.open(Log.PATH, "rb")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    local lines = {}
    -- 文件本身以 \n 结尾是正常形态，不能因此多出一条空"行"
    local src = data:sub(-1) == "\n" and data or data .. "\n"
    for line in src:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    local out = {}
    for i = math.max(1, #lines - n + 1), #lines do
        out[#out + 1] = lines[i]
    end
    return out
end

-- 全日志中 [E] 行计数（跨进程累计的错误总数）
function Log.error_count()
    local f = io.open(Log.PATH, "rb")
    if not f then return 0 end
    local data = f:read("*a")
    f:close()
    local n = 0
    for _ in data:gmatch("%[E%]") do n = n + 1 end
    return n
end

return Log
