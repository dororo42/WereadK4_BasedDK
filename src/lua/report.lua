-- report.lua — 阅读位置/时长上报（DK-3.5）。
--
-- 语义取自 weread_K4.koplugin：weread/lib/position_mapper.lua（章内字数偏移 +
-- 累计字数百分比的位置换算）、weread/lib/read_report.lua:1008-1016（端点
-- POST https://weread.qq.com/web/book/read，没有独立的 setprogress——位置随时报
-- 一起落，服务端据此更新书架「读到哪里」）。
--
-- 与插件刻意不同：插件是 30s 心跳 + 调度器 + 离线积压补报。本客户端单进程无异步，
-- 心跳会把网络请求打进翻页的关键路径（K4 弱网一次往返数秒，手感直接变卡），且定时
-- 心跳在服务端形成异常规律流量。这里只在**离开一章**时发一次，rt 取该段墙上时间；
-- 位置准确优先，时长少报不影响阅读。
--
-- 会话参数不齐时一律不发（见 send 里的 NO-PSVTS）：没有 psvts 的时报是匿名写，
-- 与「派生请求只读」是同一条纪律的两面。

local Api = require("api")
local Download = require("download")
local WeRead = require("protocol")
local Json = require("json")

local Report = {}

-- 服务端只吃小步 rt（插件同值 read_report.lua:100），大值被静默丢弃
Report.MAX_SINGLE_SECONDS = 30
Report.URL = "https://weread.qq.com/web/book/read"

local function word_count(ch)
    return math.max(0, math.floor(tonumber(ch and ch.wordCount) or 0))
end

-- 本地页码 → 服务端进度语义（纯函数，主机单测直接打它）。
-- chapters 来自 Download.fetch_catalog（chapterIdx/chapterUid/wordCount）。
-- 返回 { chapter_uid, chapter_idx, chapter_offset, percent } | nil, err。
function Report.position_of(chapters, chapter_idx, page, total_pages)
    if type(chapters) ~= "table" or #chapters == 0 then
        return nil, "catalog_missing"
    end
    local pos = Download.chapter_pos(chapters, chapter_idx)
    if not pos then return nil, "chapter_not_in_catalog" end

    local total_words, before = 0, 0
    for i, ch in ipairs(chapters) do
        local w = word_count(ch)
        total_words = total_words + w
        if i < pos then before = before + w end
    end
    local words = word_count(chapters[pos])

    -- page 是「正在看的那一页」，所以已读完的页数是 page-1
    local pages = math.max(1, math.floor(tonumber(total_pages) or 1))
    local fraction = (math.floor(tonumber(page) or 1) - 1) / pages
    fraction = math.min(math.max(fraction, 0), 1)

    local offset = 0
    if words > 0 then
        offset = math.min(math.floor(fraction * words), words)
    end
    local percent = 0
    if total_words > 0 then
        local overall = (before + offset) / total_words
        percent = math.floor(math.min(math.max(overall, 0), 1) * 100 + 0.5)
    end

    return {
        chapter_uid = tostring(chapters[pos].chapterUid),
        chapter_idx = tonumber(chapters[pos].chapterIdx) or 0,
        chapter_offset = offset,
        percent = percent,
    }
end

-- opts = { book_id, chapters, chapter_idx, page, total_pages, psvts,
--          pclts, token, elapsed_seconds, summary, position }
-- position 可显式给定（验收脚本用它把服务端当前位置原样回写，做零位移验证），
-- 否则由 chapters + 页码换算。
-- 返回 { accepted, rt, percent, status } | nil, err
function Report.send(opts)
    opts = opts or {}
    if opts.psvts == nil or opts.psvts == "" then
        return nil, "NO-PSVTS"
    end
    local p, perr = opts.position, nil
    if not p then
        p, perr = Report.position_of(opts.chapters, opts.chapter_idx,
                                     opts.page, opts.total_pages)
    end
    if not p then return nil, perr end

    local rt = math.max(0, math.min(Report.MAX_SINGLE_SECONDS,
        math.floor(tonumber(opts.elapsed_seconds) or 0)))

    local payload = WeRead.make_read_payload({
        book_id = opts.book_id,
        chapter_uid = p.chapter_uid,
        chapter_idx = p.chapter_idx,
        chapter_offset = p.chapter_offset,
        progress = p.percent,
        summary = opts.summary or "",
        elapsed_seconds = rt,
        app_id = WeRead.web_app_id(),
        psvts = opts.psvts,
        pclts = opts.pclts,
        token = opts.token,
    })

    local data, status = Api.request({
        url = Report.URL,
        method = "POST",
        body = Json.encode(payload),
        headers = {
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
            ["Referer"] = WeRead.reader_url(opts.book_id),
        },
        timeout = 8,          -- 插件同款上限：这是同步请求，卡在阅读退出/换章的路径上
    })
    if data == nil then
        return nil, "request failed: " .. tostring(status)
    end
    -- 插件 response_accepted 同款判据：succ 或 synckey 才算服务端收下
    if WeRead.is_success_response(data) or data.synckey ~= nil then
        return { accepted = true, rt = rt, percent = p.percent, status = status }
    end
    return nil, "errCode=" .. tostring(data.errCode or data.errcode)
        .. " status=" .. tostring(status)
end

return Report
