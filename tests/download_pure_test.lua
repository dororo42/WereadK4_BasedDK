-- download.lua 主机单测：只覆盖不触网的纯逻辑（目录查找 / spool 命中判断 / 缓存命中取章）。
-- 触网路径（fetch_catalog / fetch_psvts / fetch_chapter_text）归真机验收 dk3_smoke.lua。
-- 运行入口：make host-lua-test（package.path 由 tests/run.lua 设好）。
local Download = require("download")

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL download: " .. msg)
        fails = fails + 1
    end
end

local dir = (os.getenv("TMPDIR") or "/tmp") .. "/wr_spool_test_" .. tostring(os.time()) ..
            "_" .. tostring(math.floor(math.random() * 100000))
os.execute("mkdir -p '" .. dir .. "'")
Download.SPOOL = dir   -- 覆写到临时目录：单测绝不碰设备 spool 或仓库工作区

-- 服务端 chapterIdx 不保证从 1 连续，这里故意留空洞（10/11/13）
local chapters = {
    { chapterUid = "u10", chapterIdx = 10, title = "第十章",   wordCount = 100 },
    { chapterUid = "u11", chapterIdx = 11, title = "第十一章", wordCount = 100 },
    { chapterUid = "u13", chapterIdx = 13, title = "第十三章", wordCount = 100 },
}

-- chapter_pos / find_chapter：按 chapterIdx 查，返回数组下标
check(Download.chapter_pos(chapters, 10) == 1, "chapter_pos first entry")
check(Download.chapter_pos(chapters, 13) == 3, "chapter_pos with non-contiguous idx")
check(Download.chapter_pos(chapters, 12) == nil, "chapter_pos missing idx")
check(Download.chapter_pos(chapters, "11") == 2, "chapter_pos accepts numeric string")
check(Download.chapter_pos(nil, 10) == nil, "chapter_pos nil catalog")
check(Download.chapter_pos(chapters, nil) == nil, "chapter_pos nil idx")
local ch = Download.find_chapter(chapters, 11)
check(ch ~= nil and ch.chapterUid == "u11", "find_chapter hit")
check(Download.find_chapter(chapters, 99) == nil, "find_chapter miss")

-- spool：未写盘 → false；写盘 → true；路径格式 <SPOOL>/<bookId>/<idx %03d>.txt
check(Download.is_spooled("b1", 10) == false, "is_spooled before save")
local p = Download.save_chapter("b1", 10, "第十章", "正文内容")
check(type(p) == "string", "save_chapter returns path")
check(p == dir .. "/b1/010.txt", "spool path format, got " .. tostring(p))
check(Download.is_spooled("b1", 10) == true, "is_spooled after save")
check(Download.read_chapter("b1", 10) == "正文内容",
      "read_chapter returns chapter body as-is (no title header)")
check(Download.read_chapter("b1", 12) == nil, "read_chapter of missing spool is nil")

-- 空文件不算已缓存（失败下载的残留应当重下）
local ef = io.open(dir .. "/b1/011.txt", "w")
if ef then ef:close() end
check(Download.is_spooled("b1", 11) == false, "empty spool file does not count as spooled")

-- ensure_chapter：缓存命中直接返回 spool 内容，全程不触网
check(Download.ensure_chapter("b1", chapters, 10) == "正文内容",
      "ensure_chapter cache hit returns spool content")

-- ensure_chapter：目录里没这一章 → 触网前就拦下并给明确错误
local nt, nerr = Download.ensure_chapter("b1", chapters, 99)
check(nt == nil, "ensure_chapter unknown chapter returns nil")
check(type(nerr) == "string" and nerr:find("not in catalog", 1, true) ~= nil,
      "ensure_chapter unknown chapter errors before any network call, got " .. tostring(nerr))

os.execute("rm -rf '" .. dir .. "'")
print(string.format("download_pure_test: %d failure(s)", fails))
return fails
