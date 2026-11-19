-- read_report_smoke.lua — DK-3.5 阅读上报的真机验收（零位移）。
--
-- 覆盖三件事，每件都指向一个真实风险：
--   1) 签名面（sg=sha256(ts..rn..token) + s=sign(sorted_query)）服务端收不收——
--      这条离线证不了，是 DK-3.5 唯一剩下的未知。
--   2) 收下之后必须证明**真的落盘**：只断言 accepted 会被「回 succ 但不写」糊过去
--      （net.c 那次假绿的教训）。所以报完再读一次 /book/getprogress 对账。
--   3) 本仓「页码 → 字数偏移/百分比」的换算与服务端 progress 是否同一量级。
--
-- 零位移纪律：上报用的是**服务端当前的位置**（不是本地进度），所以整个过程不会
-- 把用户的阅读位置挪走。全程不扫码。
--
-- 用法：. tools/k4-env.local.sh && ssh -p "$K4_PORT" "$K4_HOST"
--       'cd /mnt/us/weread && ./weread-dyn lua/read_report_smoke.lua'

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path

local Api = require("api")
local Download = require("download")
local Report = require("report")

local fails = 0
local function step(ok, name, detail)
    print(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name,
        detail and ("  -- " .. tostring(detail)) or ""))
    if not ok then fails = fails + 1 end
    return ok
end

local function body_of(data)
    if type(data) ~= "table" then return nil end
    return type(data.book) == "table" and data.book or data
end

assert(Api.has_login(), "需要登录态（本脚本不扫码：登录态没了就停下来交给人工）")

------------------------------------------------------------------ 选一本服务端已有位置的书

local shelf = Api.get_shelf()
local books = shelf and shelf.books
assert(type(books) == "table" and #books > 0, "书架为空")

local book, remote
for _, b in ipairs(books) do
    if b.bookId and tostring(b.title or "") ~= "" then
        local p = body_of(Api.get_progress(b.bookId))
        local uid = p and (p.chapterUid or p.chapterId)
        if uid and tostring(uid) ~= "" then
            book, remote = b, p
            break
        end
    end
end
if not step(book ~= nil, "shelf has a book with server progress") then
    print("read_report smoke: 没有一本书带服务端位置，无从零位移验证，提前退出")
    os.exit(1)
end

local pos = {
    chapter_uid = tostring(remote.chapterUid or remote.chapterId),
    chapter_idx = tonumber(remote.chapterIdx) or 0,
    chapter_offset = math.floor(tonumber(remote.chapterOffset) or 0),
    percent = math.floor(tonumber(remote.progress) or 0),
}
print(string.format("book=%s id=%s  server pos: ci=%s co=%s pr=%s (raw=%s)",
    tostring(book.title), tostring(book.bookId), tostring(pos.chapter_idx),
    tostring(pos.chapter_offset), tostring(pos.percent),
    tostring(remote.progress)))

------------------------------------------------------------------ 会话参数

local psvts, perr, state = Download.fetch_psvts(book.bookId)
step(psvts ~= nil and psvts ~= "", "reader state has psvts", perr)
-- pclts 缺失不算失败：payload 回退 e(now)（插件 content.lua:1577 同款兜底）
print(string.format("  pclts_len=%s  token_len=%s",
    tostring(state and state.pclts and #state.pclts or 0),
    tostring(state and state.token and #state.token or 0)))

------------------------------------------------------------------ 1+2) 上报并回读对账

local rep, err = Report.send({
    book_id = book.bookId,
    psvts = psvts,
    pclts = state and state.pclts,
    token = state and state.token,
    position = pos,
    elapsed_seconds = 30,
})
if not step(rep and rep.accepted == true, "read report accepted", err) then
    print("read_report smoke: 服务端未收下上报，回读对账无意义，提前退出")
    os.exit(1)
end
print(string.format("  http=%s rt=%s percent=%s",
    tostring(rep.status), tostring(rep.rt), tostring(rep.percent)))

local after = body_of(Api.get_progress(book.bookId))
if not step(after ~= nil, "getprogress readable after report") then
    print("read_report smoke: 回读失败，无法证明落盘")
    os.exit(1)
end
local after_uid = tostring(after.chapterUid or after.chapterId or "")
local after_co = tonumber(after.chapterOffset) or -1
local after_pr = tonumber(after.progress) or -1
step(after_uid == pos.chapter_uid, "server chapter is what we reported",
    after_uid)
step(math.abs(after_co - pos.chapter_offset) <= 1, "server offset landed",
    string.format("sent=%d got=%.3f", pos.chapter_offset, after_co))
step(math.abs(after_pr - pos.percent) <= 2, "server percent landed",
    string.format("sent=%d got=%.3f", pos.percent, after_pr))

------------------------------------------------------------------ 3) 页码换算与服务端同一量级

local chapters = Download.fetch_catalog(book.bookId)
if type(chapters) == "table" and #chapters > 0 then
    local ch = Download.find_chapter(chapters, pos.chapter_idx)
    local words = ch and tonumber(ch.wordCount) or 0
    if ch and words > 0 then
        -- 服务端偏移折成 10 页制的页码，再用本仓换算算回去；两边百分比应当贴近
        local page = math.min(10, math.floor(pos.chapter_offset / words * 10) + 1)
        local local_pos = Report.position_of(chapters, pos.chapter_idx, page, 10)
        step(local_pos ~= nil and math.abs(local_pos.percent - pos.percent) <= 6,
            "local page->percent matches server percent",
            local_pos and string.format("local=%d server=%d (page %d/10, words %d)",
                local_pos.percent, pos.percent, page, words) or "nil")
    else
        step(false, "local page->percent matches server percent",
            "上报的章不在目录里或 wordCount=0，无法比对")
    end
else
    step(false, "local page->percent matches server percent", "catalog failed")
end

print(fails == 0 and "read_report smoke: 0 failure(s)"
    or ("read_report smoke: " .. fails .. " failure(s)"))
os.exit(fails == 0 and 0 or 1)
