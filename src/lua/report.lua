-- report.lua — 阅读位置/时长上报（DK-3.5）。
--
-- 语义取自 weread_K4.koplugin：weread/lib/position_mapper.lua（章内字数偏移 +
-- 累计字数百分比的位置换算）、weread/lib/read_report.lua:1008-1016（端点
-- POST https://weread.qq.com/web/book/read，没有独立的 setprogress——位置随时报
-- 一起落，服务端据此更新书架「读到哪里」）。
--
-- 真机标定改写了这条认知（lua/report_calib.lua）：服务端把 co 与 pr 各自原样存，
-- 不从 co 反推 pr（97/171 本书的 co 大于本章 wordCount；43 个可判定点仅 2 个自洽）。
-- 所以「字数偏移」是客户端之间的约定而不是服务端的算法——照插件的约定发才能和手机端
-- 互认，而 pr 一旦算错就被记住，因此换算不可信时拒发（见 MIN_AVG_WORDS）。
--
-- 与插件刻意不同：插件是 30s 心跳 + 调度器 + 离线积压补报。本客户端单进程无异步，
-- 心跳会把网络请求打进翻页的关键路径（K4 弱网一次往返数秒，手感直接变卡），且定时
-- 心跳在服务端形成异常规律流量。这里只在**离开一章**时发一次，rt 取该段墙上时间；
-- 位置准确优先，时长少报不影响阅读。
--
-- 会话参数不齐时一律不发（见 send 里的 NO-PSVTS）：没有 psvts 的时报是匿名写，
-- 与「派生请求只读」是同一条纪律的两面。

local Api = require("api")
local Auth = require("auth")
local Download = require("download")
local WeRead = require("protocol")
local Json = require("json")

local Report = {}

-- 服务端只吃小步 rt（插件同值 read_report.lua:100），大值被静默丢弃
Report.MAX_SINGLE_SECONDS = 30
Report.URL = "https://weread.qq.com/web/book/read"
-- 目录字数可信度的下限：平均每章少于 20 字就不可能是真字数。
-- 真机标定（lua/report_calib.lua，171 本）里有整本书每章 wordCount=1~4 的占位目录，
-- 拿它换算会把服务端 pr=97 的书报成 8——而服务端对 pr 原样存、不由 co 反推（实测 43 个
-- 可判定点里只有 2 个自洽），所以错的换算会直接被记住。宁可不上报，本地进度照旧。
-- 第三轮标定（151 本）量出这条线在真书架上只挡 8 本（5.3%），而「改用章序百分比」兜底只能把其中
-- 1 本补进服务端 ±5 点内，另 7 本差得更远——兜底换来的是「按错误的位置被服务端记住」，不可逆，
-- 所以**不加**。想重新论证这件事先读 report_calib.lua 的头注释，别凭感觉再写一版。
Report.MIN_AVG_WORDS = 20

local function word_count(ch)
    return math.max(0, math.floor(tonumber(ch and ch.wordCount) or 0))
end

-- 本地页码 → 服务端进度语义（纯函数，主机单测直接打它）。
-- chapters 来自 Download.fetch_catalog（chapterIdx/chapterUid/wordCount）。
-- 返回 { chapter_uid, chapter_idx, chapter_offset, percent } | nil, err。
-- chapter_offset 按「章内字数」发（插件 position_mapper.lua:186-209 同款约定）：服务端
-- 不校验也不解释它，只有按同一套约定写的客户端（本仓、插件）会在恢复位置时读它。
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
    if total_words / #chapters < Report.MIN_AVG_WORDS then
        return nil, "catalog_words_unusable"
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

local function read_payload(opts, p, rt)
    return WeRead.make_read_payload({
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
end

local function post_read(opts, payload)
    return Api.request({
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
end

local function err_code(data)
    if type(data) ~= "table" then return nil end
    local code = data.errCode or data.errcode
    return code ~= nil and tostring(code) or nil
end

-- 服务端会话失效时对 /web/book/read 回 HTTP 200 + 这两个 errCode（插件同判据
-- read_report.lua:173-180）。只有这一类值得自愈：参数被拒（其它 errCode）续期也没用，
-- 连不上（data==nil）则凭据未知，不许据此猜会话已死。
local AUTH_ERRCODES = { ["-2012"] = true, ["-2013"] = true }

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

    local data, status = post_read(opts, read_payload(opts, p, rt))
    local code = err_code(data)
    if code and AUTH_ERRCODES[code] then
        -- 本仓阅读侧不做心跳（见文件头），一章读完再报时 wr_skey 常常已经过龄，
        -- 所以 -2012 是常态路径而不是异常。续一次、试一次：走 Auth.renew 的非 force
        -- 分支，它自带的 600s 冷却就是重试上限——冷却挡住即收手，绝不把 /regenerate 打成心跳。
        if Auth.renew() == "replaced" then
            data, status = post_read(opts, read_payload(opts, p, rt))
            code = err_code(data)
        end
    end
    if data == nil then
        return nil, "request failed: " .. tostring(status)
    end
    -- 插件 response_accepted 同款判据：succ 或 synckey 才算服务端收下
    if WeRead.is_success_response(data) or data.synckey ~= nil then
        return { accepted = true, rt = rt, percent = p.percent, status = status }
    end
    return nil, "errCode=" .. tostring(code) .. " status=" .. tostring(status)
end

return Report
