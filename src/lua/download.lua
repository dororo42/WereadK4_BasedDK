-- download.lua — 章节目录 + 正文下载 spool。
--
-- 管线移植自 weread_K4.koplugin weread/lib/content.lua（2026-11 现行）：
--   gateway /book/chapterinfo（Bearer）→ 目录
--   GET reader 页 → 抽 psvts（内容签名参数）
--   POST /web/book/chapter/t_0（+t_1 可选）→ shard 解码 → 纯文本行
-- spool：/mnt/us/weread/books/<bookId>/<chapterIdx>.txt（UTF-8 纯文本）。
-- 图片/epub 样式分片（chapter.tar、e_*）DK-2 简版不含，阅读器按纯文本渲染。

local Api = require("api")
local WeRead = require("protocol")
local Shard = require("shard")
local Json = require("json")
local Cookie = require("cookie")

local Download = {}

Download.SPOOL = "/mnt/us/weread/books"

------------------------------------------------------------------ 目录

-- 目录（gateway first）：{ {chapterUid=, chapterIdx=, title=, wordCount=}, ... }
function Download.fetch_catalog(book_id)
    local data, err = Api.gateway("/book/chapterinfo", { bookId = tostring(book_id) })
    if not data then
        return nil, err
    end
    -- normalize_chapters 同款展开：{data={...}} / {updated=} / 数组
    local records = data
    if type(records.data) == "table" then records = records.data end
    if type(records) ~= "table" then return {} end
    if records.bookId or records.updated then records = { records } end
    local chapters
    for _, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            chapters = record.updated or record.chapterInfos or record.chapters
            break
        end
    end
    if type(chapters) ~= "table" then chapters = {} end
    -- 过滤不可读章节（插件 readable_chapters 语义：可试读/已购/无付费墙由服务端控制，这里保留全部，读取失败时报错）
    local out = {}
    for _, ch in ipairs(chapters) do
        if type(ch) == "table" and ch.chapterUid then
            out[#out + 1] = {
                chapterUid = tostring(ch.chapterUid),
                chapterIdx = tonumber(ch.chapterIdx) or #out + 1,
                title = tostring(ch.title or ""),
                wordCount = tonumber(ch.wordCount) or 0,
                tar = ch.tar,
            }
        end
    end
    table.sort(out, function(a, b) return a.chapterIdx < b.chapterIdx end)
    return out
end

------------------------------------------------------------------ psvts（reader 页会话参数）

function Download.fetch_psvts(book_id)
    local auth = Api.load_auth()
    local html, status = wr.http_req({
        url = WeRead.reader_url(book_id),
        headers = {
            -- UA 必须与正文 POST 同源：此前这里不带 UA，落到 net.c 的默认值
            -- "WereadK4/0.1"，于是同一会话在服务端呈现两种客户端身份——插件
            -- migrations.lua:11 明确把这种不一致列为风控触发面。
            ["User-Agent"] = WeRead.USER_AGENT,
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = Api.BASE_URL .. "/",
            ["Cookie"] = Cookie.to_header(auth.cookies or {}),
        },
        timeout = 20,
    })
    if not html then
        return nil, status
    end
    -- 此处**不**再合并响应 cookie / 落盘：reader 页是只读派生请求，却曾用一次
    -- 匿名响应清空整个登录 jar。会话 cookie 的写入权归 Api.request 的门禁与
    -- Auth.renew 两处，别的地方一律只读。
    -- ReaderState.extract 的 psvts 字段（window.__INITIAL_STATE__ 内嵌 JSON 或裸正则兜底）
    -- 第三个返回值是整份 reader state：上报（report.lua）还需要 pclts 与 token，
    -- 少抽一个就得靠猜——插件 reader_state.lua:29-31 是三个一起抽的。
    local state = {
        psvts = html:match([["psvts"%s*:%s*"([^"]+)"]]),
        pclts = html:match([["pclts"%s*:%s*"([^"]+)"]]),
        token = html:match([["token"%s*:%s*"([^"]+)"]]),
    }
    return state.psvts, status, state
end

------------------------------------------------------------------ 正文

-- 单章纯文本（t_0 + 可选 t_1 shard 解码合并）。失败返回 nil, err。
function Download.fetch_chapter_text(book_id, chapter_uid, psvts)
    local params = WeRead.make_content_params(book_id, chapter_uid, psvts, { sc = 1 })
    local auth = Api.load_auth()
    local HtmlText = require("html_text")

    local function fetch_shard(endpoint)
        local body, status = wr.http_req({
            url = "https://weread.qq.com" .. endpoint,
            method = "POST",
            headers = {
                ["User-Agent"] = WeRead.USER_AGENT,
                ["Accept"] = "application/json, text/plain, */*",
                ["Content-Type"] = "application/json;charset=UTF-8",
                ["Origin"] = "https://weread.qq.com",
                ["Referer"] = WeRead.reader_url(book_id, chapter_uid),
                ["Cookie"] = Cookie.to_header(auth.cookies or {}),
            },
            body = Json.encode(params),
            timeout = 30,
        })
        return body, status
    end

    -- txt 分片抓取（t_0 + 可选 t_1）。**空分片不当成功**：真机实测服务端对失效
    -- 会话回 200 + 0 字节，按原样返回会让整本书静默降级成只有标题（假绿）。
    local function grab_txt()
        local t0, st0 = fetch_shard("/web/book/chapter/t_0")
        if not t0 then
            return nil, "t_0 failed: " .. tostring(st0)
        end
        if t0 == "{}" then
            return nil, "t_0 empty（可能未购/不可试读）"
        end
        if t0:sub(1, 1) == "{" and t0:find('"bookId"', 1, true) then
            local j = Json.decode(t0)
            return nil, "t_0 json: errCode=" .. tostring(j and j.errCode)
        end
        if t0 == "" then
            return nil, "EMPTY-SHARD"
        end
        -- 跨分片必须拼接后**单次解码**（plugin decode_content_shards 语义）：
        -- 各分片只是同一 base64 流的切段，逐片独立解码会从第二片起全错位
        -- （真机"大范围乱码"根因）。t_1 可选，有则并入同一解码流。
        local ok1, t1 = pcall(fetch_shard, "/web/book/chapter/t_1")
        if not ok1 then t1 = nil end
        local ok, decoded = pcall(Shard.decode_shards, t0, (t1 and t1 ~= "{}" and #t1 > 32) and t1 or nil)
        if not ok then
            return nil, "shard decode: " .. tostring(decoded)
        end
        if decoded == "" then
            return nil, "EMPTY-SHARD"
        end
        return decoded
    end

    -- 格式探测（plugin fetch_chapter_xhtml 语义）：先 POST e_0——
    --   返回 JSON+bookId        = txt 排版 → t_0/t_1 纯文本分片
    --   其它（200 + xhtml 分片）= epub 排版 → e_0(+e_1/e_3 可选) 解码 → 剥标签
    -- 真机实证：epub 书走 t_0 会拿到错位内容（用户报"乱码"；probe_fmt 取证
    -- e_0 返回 base64('<?xml…')）。
    local e0, e0st = fetch_shard("/web/book/chapter/e_0")
    if not e0 then
        return nil, "e_0 failed: " .. tostring(e0st)
    end
    if e0 == "{}" or e0 == "" then
        return nil, "EMPTY-SHARD"
    end

    if e0:sub(1, 1) == "{" and e0:find('"bookId"', 1, true) then
        -- txt 书：t_0 为主分片；空分片先免扫码续期再重试一次（真机会话失效形态）
        local text, err = grab_txt()
        if err == "EMPTY-SHARD" then
            local Auth = require("auth")
            local renew_status = Auth.renew()
            text, err = grab_txt()
            if not text then
                return nil, "正文为空（会话续期: " .. tostring(renew_status) .. "）"
            end
        end
        return text, err
    end

    -- epub 书：e_0 必有 + e_1/e_3 可选；跨分片拼接后**单次解码**（同 txt 路教训，
    -- 逐片独立解码从第二片起全错位=大范围乱码）。
    local raws = { e0 }
    for _, ep in ipairs({ "/web/book/chapter/e_1", "/web/book/chapter/e_3" }) do
        local okx, rawx = pcall(fetch_shard, ep)
        if okx and rawx and rawx ~= "{}" and #rawx > 32 then
            raws[#raws + 1] = rawx
        end
    end
    local ok, decoded = pcall(Shard.decode_shards, unpack(raws))
    if not ok then
        return nil, "shard decode: " .. tostring(decoded)
    end

    local text = HtmlText.to_text(decoded)
    if text == "" then
        -- 纯图片/封面页：剥标签后无文本
        return "[图片页——简版暂不支持图片]"
    end
    return text
end

------------------------------------------------------------------ spool

local function spool_path(book_id, chapter_idx)
    return string.format("%s/%s/%03d.txt", Download.SPOOL, tostring(book_id), chapter_idx)
end

-- 是否已有可用缓存（空文件不算：那是一次失败下载的残留，应当重下）。
function Download.is_spooled(book_id, chapter_idx)
    local f = io.open(spool_path(book_id, chapter_idx), "r")
    if not f then return false end
    local size = f:seek("end") or 0
    f:close()
    return size > 0
end

-- 目录数组下标（进度存的是服务端 chapterIdx，预取要按数组连续取 N 章）。
-- fetch_catalog 已按 chapterIdx 升序排序，但服务端值不保证从 1 连续，故两者不能混用。
function Download.chapter_pos(chapters, chapter_idx)
    local want = tonumber(chapter_idx)
    if type(chapters) ~= "table" or not want then return nil end
    for i, ch in ipairs(chapters) do
        if ch.chapterIdx == want then return i end
    end
    return nil
end

function Download.find_chapter(chapters, chapter_idx)
    local pos = Download.chapter_pos(chapters, chapter_idx)
    return pos and chapters[pos] or nil
end

-- spool 只存章节正文原样（epub 自带 h2 章题 / txt 无题），**不拼标题头**——
-- 否则 epub 书阅读页标题双显（spool 头 + xhtml h2 各一次，真机用户实证）。
-- 章节标题由 Reader.open 的 chapter_title 参数独立提供（页脚用）。
function Download.save_chapter(book_id, chapter_idx, title, text)
    local dir = Download.SPOOL .. "/" .. tostring(book_id)
    os.execute("mkdir -p '" .. dir .. "'")   -- BusyBox mkdir；路径自控无注入面
    local f = io.open(spool_path(book_id, chapter_idx), "w")
    if not f then return nil, "open spool failed" end
    f:write(text)
    f:close()
    return spool_path(book_id, chapter_idx)
end

function Download.read_chapter(book_id, chapter_idx)
    local f = io.open(spool_path(book_id, chapter_idx), "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

------------------------------------------------------------------ 按需取章

-- 会话参数：psvts 是单书生命周期内有效的会话参数，每本书只抽一次（换书必须重抽）。
-- 懒取：全部章节都命中缓存时一次网络请求都不发。
function Download.new_session()
    return { psvts = nil, perr = nil, tried = false }
end

local function session_psvts(book_id, sess)
    if not sess.tried then
        sess.tried = true
        local psvts, perr, state = Download.fetch_psvts(book_id)
        sess.psvts, sess.perr = psvts, perr
        -- 上报用的另外两个会话参数，随同一次 reader 页请求一起留存
        sess.pclts = state and state.pclts
        sess.token = state and state.token
    end
    return sess.psvts, sess.perr
end

-- 取某章纯文本：命中 spool 直接读盘，否则下载并落盘后回读。
-- 返回值统一是「章节正文原样」（无标题头——标题由调用方经 chapter_title 参数提供）。
-- 返回 text | nil, err
function Download.ensure_chapter(book_id, chapters, chapter_idx, sess)
    local cached = Download.read_chapter(book_id, chapter_idx)
    if cached and #cached > 0 then
        return cached
    end
    local ch = Download.find_chapter(chapters, chapter_idx)
    if not ch then
        return nil, "chapter not in catalog: " .. tostring(chapter_idx)
    end
    sess = sess or Download.new_session()
    local psvts, perr = session_psvts(book_id, sess)
    if not psvts then
        return nil, "psvts failed: " .. tostring(perr or "no psvts")
    end
    local text, terr = Download.fetch_chapter_text(book_id, ch.chapterUid, psvts)
    if not text then
        return nil, terr
    end
    local path, serr = Download.save_chapter(book_id, ch.chapterIdx, ch.title, text)
    if not path then
        return nil, serr
    end
    return Download.read_chapter(book_id, ch.chapterIdx)
end

-- 批量预取：从目录第 start_pos 项起最多 max_chapters 章；已 spool 的跳过 → 重跑幂等。
-- on_progress(i_done, total, ch_title) 可选：UI 进度屏回调（菜单"下载后面5章"用）。
-- 单章失败不中断（后续章节可能正常），失败原因写在该项的 _err 上，reader 缺章时提示。
-- 返回 chapters | nil, err
function Download.book(book_id, max_chapters, start_pos, on_progress)
    local chapters, err = Download.fetch_catalog(book_id)
    if not chapters or #chapters == 0 then
        return nil, "catalog failed: " .. tostring(err or "empty")
    end
    local from = math.min(math.max(tonumber(start_pos) or 1, 1), #chapters)
    local last = math.min(from + math.max(tonumber(max_chapters) or 1, 1) - 1, #chapters)
    local sess = Download.new_session()
    local total = last - from + 1
    local done = 0
    for i = from, last do
        local ch = chapters[i]
        if Download.is_spooled(book_id, ch.chapterIdx) then
            ch._err = nil
        else
            local text, terr = Download.ensure_chapter(book_id, chapters, ch.chapterIdx, sess)
            ch._err = text and nil or terr
        end
        done = done + 1
        if on_progress then
            pcall(on_progress, done, total, ch.title)
        end
    end
    return chapters
end

return Download
