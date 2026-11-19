-- progress.lua 主机单测：进度往返、缺文件降级、原子写不留 .tmp、last_book_id 指针。
-- 运行入口：make host-lua-test（package.path 由 tests/run.lua 设好）。
local Progress = require("progress")

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL progress: " .. msg)
        fails = fails + 1
    end
end

local dir = os.getenv("TMPDIR") or "/tmp"
local path = dir .. "/wr_progress_test_" .. tostring(os.time()) .. "_" ..
             tostring(math.floor(math.random() * 100000)) .. ".json"
os.remove(path)
os.remove(path .. ".tmp")
Progress.PATH = path   -- 覆写到临时路径：单测绝不碰设备文件或仓库工作区

-- 缺文件 → 空结构，不报错
local data = Progress.load()
check(type(data) == "table" and type(data.books) == "table", "load on missing file")
check(next(data.books) == nil, "missing file yields empty books")
check(Progress.get("123") == nil, "get on missing file")
check(Progress.get_last() == nil, "get_last on missing file")

-- set → get 往返
check(Progress.set("123", 4, 7, "第四章") == true, "set returns true")
local rec = Progress.get("123")
check(type(rec) == "table", "get after set")
check(rec and rec.chapter_idx == 4, "chapter_idx round-trip")
check(rec and rec.page == 7, "page round-trip")
check(rec and rec.title == "第四章", "title round-trip")
check(type(rec and rec.updated) == "number", "updated is a timestamp")
check(Progress.get_last() == "123", "last_book_id points at written book")

-- 数字 book_id 与字符串同键（JSON 对象键天然是字符串，不该裂成两条记录）
check(Progress.set(123, 5, 1) == true, "set with numeric id")
local rec2 = Progress.get("123")
check(rec2 and rec2.chapter_idx == 5 and rec2.page == 1, "numeric id maps to same record")
check(rec2 and rec2.title == "第四章", "omitted title keeps previous value")

-- 多本互不覆盖
check(Progress.set("999", 1, 2, "另一本") == true, "set second book")
check(Progress.get("123").chapter_idx == 5, "first book untouched")
check(Progress.get_last() == "999", "last points to newest write")

-- 原子写：成功后不留 .tmp
local tmpf = io.open(path .. ".tmp", "r")
check(tmpf == nil, "no leftover .tmp after successful write")
if tmpf then tmpf:close() end

-- 损坏文件 → 降级为空（不抛错，不阻断阅读）
local f = io.open(path, "w")
f:write("{ not json at all")
f:close()
local ok, d = pcall(Progress.load)
check(ok, "corrupt file does not raise")
check(ok and type(d) == "table" and next(d.books) == nil, "corrupt file degrades to empty")
check(Progress.get("123") == nil, "corrupt file: get returns nil")
check(Progress.get_last() == nil, "corrupt file: get_last returns nil")

-- 损坏后仍可写（一次 set 即修复文件）
check(Progress.set("1", 2, 3, "恢复") == true, "set after corrupt recovers file")
local rec3 = Progress.get("1")
check(rec3 and rec3.chapter_idx == 2 and rec3.page == 3, "readable after recovery")

-- 越界/异常入参：page 为 nil 时保留旧值而不是写入 nil
Progress.set("1", 9, nil)
local rec4 = Progress.get("1")
check(rec4 and rec4.chapter_idx == 9, "chapter_idx updated")
check(rec4 and rec4.page == 3, "nil page keeps previous page")

os.remove(path)
print(string.format("progress_test: %d failure(s)", fails))
return fails
