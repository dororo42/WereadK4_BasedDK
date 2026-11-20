-- progress.lua — 阅读进度存储（断点续读）。
--
-- 单一写者：只有 menu.read_book 在翻页/换章/退出时调 set()。落盘
-- /mnt/us/weread/data/progress.json，写路径统一走 Json.write_atomic
-- （tmp + rename，掉电/kill 打断不会留下半截文件）。
-- 结构: { last_book_id = "<id>",
--         books = { ["<id>"] = { chapter_idx=, page=, total_pages=, title=, updated= } } }
-- total_pages 是算本地百分比的分母：没有它，本地进度与云端进度根本没法比大小
-- （页码本身跨书跨字号无量纲），同步判异就只能降级成"比章序"。
-- book_id 一律 tostring 后作键：JSON 对象的键天然是字符串，避免 1234 与 "1234" 两份记录。

local Json = require("json")

local Progress = {}

Progress.PATH = "/mnt/us/weread/data/progress.json"

local function empty()
    return { books = {} }
end

-- 文件缺失 / 内容损坏 → 空结构，不报错：续读是便利功能，不该阻断阅读。
function Progress.load()
    local f = io.open(Progress.PATH, "r")
    if not f then return empty() end
    local text = f:read("*a")
    f:close()
    local data = Json.decode(text or "")
    if type(data) ~= "table" or type(data.books) ~= "table" then
        return empty()
    end
    return data
end

-- 单本进度记录 { chapter_idx=, page=, total_pages=, title=, updated= } | nil（无记录）
function Progress.get(book_id)
    if book_id == nil then return nil end
    local rec = Progress.load().books[tostring(book_id)]
    if type(rec) ~= "table" then return nil end
    return rec
end

-- 写单本进度并把它记为最近阅读。返回 true | nil, err。
function Progress.set(book_id, chapter_idx, page, title, total_pages)
    local data = Progress.load()
    local id = tostring(book_id)
    local rec = data.books[id]
    if type(rec) ~= "table" then
        rec = {}
        data.books[id] = rec
    end
    rec.chapter_idx = tonumber(chapter_idx) or rec.chapter_idx or 1
    rec.page = tonumber(page) or rec.page or 1
    -- 可选参数：nil 时保留旧值（老记录不该被一次翻页清空分母）
    if tonumber(total_pages) then rec.total_pages = math.floor(tonumber(total_pages)) end
    if title ~= nil then rec.title = tostring(title) end
    rec.updated = os.time()
    data.last_book_id = id
    return Json.write_atomic(Progress.PATH, data)
end

-- 最近阅读的书 id（「继续阅读」入口）；无记录返回 nil。
function Progress.get_last()
    return Progress.load().last_book_id
end

return Progress
