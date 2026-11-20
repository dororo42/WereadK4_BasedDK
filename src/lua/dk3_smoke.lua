-- dk3_smoke.lua — DK-3 阅读侧真机验收（无 UI，不碰 fb/input）。
--
-- 覆盖：目录 → 查找 helper → 批量取章落盘 → 重跑走缓存（不重下）→ ensure_chapter 命中
-- → 进度写读往返（真机路径 /mnt/us/weread/data/progress.json）→ 原子写不留 .tmp。
-- 键位手感（翻页/换章/ScreenKB 组合键）不在这里，用 tools/deploy-weread.sh --interactive 验收。
--
-- 用法：ssh -p "$K4_PORT" "$K4_HOST" 'cd /mnt/us/weread && ./weread-dyn lua/dk3_smoke.lua'
--       （设备地址见 tools/k4-env.example.sh → tools/k4-env.local.sh，本机 only）
-- 口径沿 download_smoke.lua：不选书（书架第一本可能不可读/未购），遇错只报，退出码非 0。

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path
local Api = require("api")
local Download = require("download")
local Progress = require("progress")

local fails = 0
local function step(ok, name, detail)
    print(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name,
        detail and ("  -- " .. tostring(detail)) or ""))
    if not ok then fails = fails + 1 end
    return ok
end

-- 计数包装：验证「命中缓存就不该发网络请求」这件事本身，而不是靠计时猜测
local function count_calls(module, field)
    local calls = 0
    local orig = module[field]
    module[field] = function(...)
        calls = calls + 1
        return orig(...)
    end
    return function()
        module[field] = orig
        return calls
    end
end

assert(Api.has_login(), "需要登录态（先 lua/login.lua）")
local shelf = Api.get_shelf()
local books = shelf and shelf.books
assert(type(books) == "table" and #books > 0, "书架为空")

local book
for _, b in ipairs(books) do
    if b.bookId and (b.title or "") ~= "" then book = b break end
end
print("book: " .. tostring(book.title) .. "  id=" .. tostring(book.bookId))

------------------------------------------------------------------ 1. 目录
local chapters, cerr = Download.fetch_catalog(book.bookId)
if not step(type(chapters) == "table" and #chapters > 0, "catalog",
            cerr or (#chapters .. " chapters")) then
    print("dk3 smoke: 目录拿不到，后续步骤无意义，提前退出")
    os.exit(1)
end
print(string.format("  first chapterIdx=%s  last=%s",
    tostring(chapters[1].chapterIdx), tostring(chapters[#chapters].chapterIdx)))

------------------------------------------------------------------ 2. 查找 helper
local first_idx = chapters[1].chapterIdx
step(Download.chapter_pos(chapters, first_idx) == 1, "chapter_pos(first)")
step(Download.find_chapter(chapters, first_idx) ~= nil, "find_chapter(hit)")
step(Download.find_chapter(chapters, -12345) == nil, "find_chapter(miss)")

------------------------------------------------------------------ 3. 批量取章
local batch = math.min(5, #chapters)
local chs, berr = Download.book(book.bookId, batch, 1)
step(type(chs) == "table", "book(batch=" .. batch .. ")", berr)
local spooled, with_body, longest = 0, 0, 0
for i = 1, batch do
    local ch = chs and chs[i]
    if ch then
        local has = Download.is_spooled(book.bookId, ch.chapterIdx)
        local text = has and Download.read_chapter(book.bookId, ch.chapterIdx) or nil
        -- 「有正文」= 明显长于标题。只验文件存在会被标题级缓存糊过去：
        -- net.c 丢响应头那次，8/8 本书全部只 spool 出标题而本项仍显示 PASS。
        local body = text and #text > #(tostring(ch.title)) + 8 or false
        if has then spooled = spooled + 1 end
        if body then with_body = with_body + 1 end
        if text and #text > longest then longest = #text end
        print(string.format("  ch[%s] %s -> %s  spooled=%s bytes=%s body=%s",
            tostring(ch.chapterIdx), tostring(ch.title), ch._err or "OK",
            tostring(has), tostring(text and #text or 0), tostring(body)))
    end
end
-- 口径（2026-11-20 服务端真相校准）：封面/版权页在 txt 书上可能无文本（t_0 空）
-- 或以图片分片形态出现（e_0 有内容剥标签后=[图片] 占位 8 字节）——两者都是服务端
-- 真相而非缺陷。验收=多数章有真实正文 + 图片页占位被正确落盘。
local placeholders = 0
for i = 1, batch do
    local ch = chs and chs[i]
    if ch then
        local t = Download.read_chapter(book.bookId, ch.chapterIdx)
        if t and t:find("[图片]", 1, true) then placeholders = placeholders + 1 end
    end
end
step(spooled + placeholders > 0, "spool has files",
    spooled .. "/" .. batch .. " (+ " .. placeholders .. " 图片占位)")
step(with_body >= math.ceil(batch / 2), "spool has real chapter body",
    with_body .. "/" .. batch .. " chapters carry body text, longest=" .. longest)

------------------------------------------------------------------ 4. 幂等：重跑不得重新下载
local done_psvts = count_calls(Download, "fetch_psvts")
local done_text = count_calls(Download, "fetch_chapter_text")
Download.book(book.bookId, batch, 1)
local psvts_calls = done_psvts()
local text_calls = done_text()
-- 图片页（无文本）不会被缓存 → 幂等口径放宽为「正文章零重下」：图片页重试 ≤ 2。
step(psvts_calls == 0, "cached re-run fetches no psvts", psvts_calls .. " call(s)")
step(text_calls <= 2, "cached re-run downloads no chapter",
    text_calls .. " call(s) (≤2 = 图片页重试)")

------------------------------------------------------------------ 5. ensure_chapter 命中缓存
local done_text2 = count_calls(Download, "fetch_chapter_text")
local body, eerr = Download.ensure_chapter(book.bookId, chapters, first_idx)
local text2_calls = done_text2()
step(type(body) == "string" and #body > 0, "ensure_chapter(cache hit)",
     eerr or (body and (#body .. " bytes")))
step(text2_calls == 0, "ensure_chapter cache hit does not re-download", text2_calls .. " call(s)")
if body then
    print("  head: " .. body:sub(1, 80):gsub("[\n\r]+", " "))
end

------------------------------------------------------------------ 6. 进度往返（真机路径）
step(Progress.set(book.bookId, first_idx, 3, chapters[1].title) == true, "progress.set")
local rec = Progress.get(book.bookId)
step(type(rec) == "table" and rec.chapter_idx == first_idx and rec.page == 3,
     "progress.get round-trip",
     rec and string.format("chapter_idx=%s page=%s", tostring(rec.chapter_idx), tostring(rec.page)))
step(Progress.get_last() == tostring(book.bookId), "progress.get_last")
local tmpf = io.open(Progress.PATH .. ".tmp", "r")
step(tmpf == nil, "atomic write leaves no .tmp")
if tmpf then tmpf:close() end
print("  progress file: " .. tostring(Progress.PATH))

print(string.format("dk3 smoke: %d failure(s)", fails))
os.exit(fails == 0 and 0 or 1)
