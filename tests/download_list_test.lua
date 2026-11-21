-- Download manifest/list_books/list_downloaded_chapters 的主机测（SPOOL 注入 tmp）。
--
-- 为什么值得写：「已下载书目」和「运行状态」两屏的数据全部出自这三个函数。它们的
-- 故障面在过滤语义上：list_books 只认纯数字目录（垃圾目录不得混入）、
-- list_downloaded_chapters 必须是 manifest ∩ spool（manifest 有但没落盘的章不算
-- 已下载）、排序口径是 last_download 降序（最近下载的排最上）。这些错了，
-- 用户看到的是假清单——比空清单更误导。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL download_list_test: " .. msg)
        fails = fails + 1
    end
end

local DIR = "/tmp/wr_dl_list_test_" .. tostring(os.time())
os.execute("mkdir -p '" .. DIR .. "'")
os.execute("rm -rf '" .. DIR .. "'/*")

package.loaded.download = nil
local Download = require("download")
Download.SPOOL = DIR

local CHS = {
    { chapterIdx = 1, chapterUid = "u1", title = "第一章", wordCount = 100 },
    { chapterIdx = 2, chapterUid = "u2", title = "第二章", wordCount = 200 },
    { chapterIdx = 3, chapterUid = "u3", title = "第三章", wordCount = 300 },
}

-- 1) save_manifest → load_manifest 回读（含 last_download 与裁剪后的章表）
check(Download.save_manifest("10101", "测试书甲", CHS), "save_manifest 应返回真")
local m = Download.load_manifest("10101")
check(m ~= nil, "load_manifest 应能回读")
check(m.bookId == "10101" and m.title == "测试书甲", "bookId/title 应原样保存")
check(#m.chapters == 3 and m.chapters[2].title == "第二章", "章表应完整保存")
check(m.chapters[1].chapterUid == "u1", "chapterUid 应保存（离线阅读不需要重新拉目录）")
check(type(m.last_download) == "number", "last_download 应是时间戳")

-- 2) save_chapter 落盘 → list_books 计数/字节/排序
local time_orig = os.time
local fake_t = time_orig()
os.time = function() fake_t = fake_t + 10; return fake_t end   -- 每次保存错开 10 秒
Download.save_manifest("20202", "测试书乙", CHS)
local ok = Download.save_chapter("10101", 1, "第一章", "正文甲一")
check(ok, "save_chapter 应成功")
Download.save_chapter("10101", 3, "第三章", "正文甲三")

-- 3) list_books：只认纯数字目录；10101 = 2 章、字节为正文和
local books = Download.list_books()
check(#books == 2, "10101+20202 两个数字目录都应列出，实得 " .. #books)
local b1
for _, b in ipairs(books) do if b.bookId == "10101" then b1 = b end end
check(b1 ~= nil, "10101 应在列")
check(b1.title == "测试书甲", "title 应取 manifest")
check(b1.chapters_total == 3, "chapters_total 应取 manifest 章数，实得 " .. tostring(b1.chapters_total))
check(b1.chapters_down == 2, "chapters_down 应数 spool 文件，实得 " .. tostring(b1.chapters_down))
check(b1.bytes == #("正文甲一") + #("正文甲三"), "bytes 应为正文文件大小和，实得 " .. tostring(b1.bytes))

-- 4) 非 manifest 目录（无 bookId 键）不得崩溃：load_manifest 返回 nil → title 回退 id
os.execute("mkdir -p '" .. DIR .. "/999' && echo x > '" .. DIR .. "/999/001.txt'")
books = Download.list_books()
check(#books == 3, "无 manifest 的数字目录也应列出（回退显示），实得 " .. #books)
local b999
for _, b in ipairs(books) do if b.bookId == "999" then b999 = b end end
check(b999 ~= nil and b999.title == "999", "无 manifest 时 title 应回退为目录 id")
check(b999.chapters_down == 1, "无 manifest 但有 spool 文件仍应计数")

-- 5) list_downloaded_chapters = manifest ∩ spool（按 chapterIdx 升序，带 manifest 标题）
local dls = Download.list_downloaded_chapters("10101")
check(#dls == 2, "manifest 3 章 ∩ spool 2 章 = 2，实得 " .. #dls)
check(dls[1].chapterIdx == 1 and dls[1].title == "第一章", "升序排列且标题来自 manifest")
check(dls[2].text == "正文甲三", "text 应为 spool 原文")
check(Download.list_downloaded_chapters("20202") ~= nil and
    #Download.list_downloaded_chapters("20202") == 0, "B2 有 manifest 无 spool = 空清单")

-- 6) 排序口径：last_download 降序（B3 写在最晚 → 排最前）
Download.save_manifest("30303", "测试书丙", CHS)   -- 时间错开 → 必然最新
Download.save_chapter("30303", 2, "第二章", "正文丙二")
books = Download.list_books()
check(books[1].bookId == "30303", "最近下载的应排最前，实得 " .. tostring(books[1].bookId))
check(books[#books].bookId == "999", "无 manifest（last_download=0）排末尾")

os.execute("rm -rf '" .. DIR .. "'")
print("download_list_test done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails) .. " (fails=" .. fails .. ")")
return fails
