-- download_smoke.lua — 下载管线冒烟：书架第一本 → 目录 → 下载前 2 章 → spool → 预览。
package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path
local Api = require("api")
local Download = require("download")

assert(Api.has_login(), "需要登录态（先 lua/login.lua）")
local shelf = Api.get_shelf()
local books = shelf and shelf.books
assert(type(books) == "table" and #books > 0, "书架为空")

local book
for _, b in ipairs(books) do
    if b.bookId and (b.title or "") ~= "" then book = b break end
end
print("book: " .. tostring(book.title) .. "  id=" .. tostring(book.bookId))

local chapters, err = Download.book(book.bookId, 2)
if not chapters then
    print("FAIL catalog: " .. tostring(err))
    os.exit(1)
end
print("catalog OK: " .. #chapters .. " chapters")
for i = 1, math.min(2, #chapters) do
    local ch = chapters[i]
    print(string.format("  ch[%d] %s -> %s", ch.chapterIdx, ch.title, ch._err or "OK"))
end
local text = Download.read_chapter(book.bookId, chapters[1].chapterIdx)
if text then
    print("ch1 bytes=" .. #text)
    print("head: " .. text:sub(1, 100):gsub("[\n\r]+", " "))
else
    print("ch1 missing from spool")
end
print("download smoke done")
