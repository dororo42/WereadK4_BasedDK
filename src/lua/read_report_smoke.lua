-- read_report_smoke.lua — DK-3.5 阅读上报的真机验收（零位移）。
--
-- 覆盖三件事，每件都指向一个真实风险：
--   1) 签名面（sg=sha256(ts..rn..token) + s=sign(sorted_query)）服务端收不收——
--      这条离线证不了，是 DK-3.5 唯一剩下的未知。
--   2) 收下之后必须证明**真的落盘**：只断言 accepted 会被「回 succ 但不写」糊过去
--      （net.c 那次假绿的教训）。所以报完再读一次 /book/getprogress 对账。
--   3) 本仓「页码 → 字数偏移/百分比」的换算与服务端 progress 是否同一量级。
--   4) 上报走 Api.request 的门禁写入口（它有权写 jar），所以必须证明跑完一遍
--      has_login 仍 true、wr_rt 仍在——登录态是用户明令不可丢的东西，不能靠推断。
--
-- 零位移纪律：上报用的是**服务端当前的位置**（不是本地进度），所以整个过程不会
-- 把用户的阅读位置挪走。全程不扫码。
--
-- 用法：. tools/k4-env.local.sh && ssh -p "$K4_PORT" "$K4_HOST"
--       'cd /mnt/us/weread && ./weread-dyn lua/read_report_smoke.lua'

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path

local Api = require("api")
local Cookie = require("cookie")
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

-- 凭据盘面的可比指纹：只取名/长度/布尔，值一律不外印。
-- 上报走的是 Api.request 的门禁写入口，它**有权**写 jar，所以「会话没被弄坏」
-- 不能靠推断——用 cmp 比字节更不行（Json.encode 的键序随 pairs 抖动，同一份会话
-- 也能比出 DIFF；本批就被这条误导过一次）。
local function jar_state()
    local jar = Cookie.sanitize(Api.load_auth().cookies or {})
    local names, n = {}, 0
    for k in pairs(jar) do names[#names + 1] = tostring(k); n = n + 1 end
    table.sort(names)
    return {
        items = n,
        login = Cookie.has_login_cookie(jar),
        rt = jar.wr_rt and #jar.wr_rt or 0,
        skey = jar.wr_skey and #jar.wr_skey or 0,
        header = Cookie.to_header(jar),
        names = table.concat(names, ","),
    }
end

assert(Api.has_login(), "需要登录态（本脚本不扫码：登录态没了就停下来交给人工）")
local before = jar_state()

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

------------------------------------------------------------------ 3) 页码换算：真机目录上每页可算、单调、有界

-- 这里过去拿服务端的 chapterOffset 反推页码再比 percent——已删：标定证明服务端的 co
-- 不是本仓这套字数约定（171 本里 97 本的 co 大于本章 wordCount），拿它当基准得到的
-- 贴近纯属巧合，而且当时 co/words=1.87 被 math.min(10,…) 夹成末页，把反例吞成了 PASS。
local chapters = Download.fetch_catalog(book.bookId)
if type(chapters) == "table" and #chapters > 0 then
    local prev, monotone, bounded, first, last, refuse = -1, true, true, nil, nil, nil
    for page = 1, 10 do
        local q, qerr = Report.position_of(chapters, pos.chapter_idx, page, 10)
        if not q then
            monotone = false
            refuse = "page " .. page .. " 拒答: " .. tostring(qerr)
            break
        end
        first = first or q.percent
        last = q.percent
        if q.percent < prev then monotone = false end
        if q.percent < 0 or q.percent > 100 then bounded = false end
        prev = q.percent
    end
    step(monotone, "position_of 每页可算且随翻页不减（字数换算在这本真书目录上成立）", refuse)
    step(bounded, "percent 始终落在 0..100",
        type(first) == "number" and string.format("%d%% -> %d%%", first, last) or nil)
else
    step(false, "position_of 每页可算且随翻页不减", "catalog failed")
end

------------------------------------------------------------------ 4) 会话盘面：上报没把登录态换掉

local after = jar_state()
step(after.login == true, "上报全程后 has_login 仍为 true（绝不把登录态弄丢）",
    string.format("skey=%d items=%d", after.skey, after.items))
-- wr_rt 是免扫码续期的唯一凭据：它一旦丢，恢复手段只剩重扫二维码（用户明令不得重复扫）
step(after.rt >= 8, "wr_rt 仍在（丢了就只剩重扫码）", after.rt)
print(string.format("  jar: items %d->%d  rt %d->%d  header_unchanged=%s  names=%s",
    before.items, after.items, before.rt, after.rt,
    tostring(before.header == after.header), after.names))

print(fails == 0 and "read_report smoke: 0 failure(s)"
    or ("read_report smoke: " .. fails .. " failure(s)"))
os.exit(fails == 0 and 0 or 1)
