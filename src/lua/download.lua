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
local Log = require("log")

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
        return text, err, text     -- txt 书：raw=同文本（无 xhtml 结构）
    end

    -- epub 书：e_0 是可解码的 xhtml 分片（>32 字节）+ e_1/e_3 可选；
    -- 跨分片拼接后**单次解码**（同 txt 路教训，逐片独立解码从第二片起全错位）。
    if #e0 > 32 then
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

        Download.save_raw(book_id, chapter_uid, decoded)
        local text = HtmlText.to_text(decoded)
        if text == "" then
            -- 纯图片/封面页：剥标签后无文本（阅读占位；epub 导出用 raw）
            return "[图片页——简版暂不支持图片]"
        end
        return text
    end

    -- 剩余情形：e_0 = "{}"/短响应 → txt 书的正常形态（e_* 为 epub 分片端点），
    -- 走 t_0/t_1；t_0 空说明会话失效 → 续期重试（真机实证 200+0 字节形态）。
    local text, err = grab_txt()
    if err == "EMPTY-SHARD" then
        local Auth = require("auth")
        local renew_status = Auth.renew()
        text, err = grab_txt()
        if not text then
            return nil, "正文为空（会话续期: " .. tostring(renew_status) .. "）"
        end
    elseif not text then
        return nil, err
    end
    return text, nil, text
end

------------------------------------------------------------------ spool

-- 路径分量来自服务端（bookId / chapterUid）：既进 io.open，也进 os.execute 的单引号里
-- （mkdir -p / rm -f）。只留 [%w%.%-_]，其余（' ; $ ` 空白 / 等）一律换成 '_'；
-- 纯 "." / ".." 分量整体换成 '_' —— shell 注入与路径穿越由同一个护栏解决。
local function path_safe(s)
    local t = tostring(s or ""):gsub("[^%w%.%-_]", "_")
    if t == "" or t == "." or t == ".." then t = "_" end
    return t
end
Download._path_safe = path_safe

local function spool_path(book_id, chapter_idx)
    return string.format("%s/%s/%03d.txt", Download.SPOOL, path_safe(book_id), chapter_idx)
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
    Log.info(string.format("spool %s ch%d bytes=%d", book_id, chapter_idx, #text))
    return spool_path(book_id, chapter_idx)
end

function Download.read_chapter(book_id, chapter_idx)
    local f = io.open(spool_path(book_id, chapter_idx), "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

------------------------------------------------------------------ manifest（书目元数据，供"已下载书目"离线浏览）

-- manifest: books/<id>/manifest.json
--   { bookId=, title=, last_download=, chapters={ {chapterIdx=,chapterUid=,title=} } }
-- fetch_catalog 成功即全量写入（chapters 与 spool 解耦：manifest=目录，spool=已下正文）。

local function manifest_path(book_id)
    return Download.SPOOL .. "/" .. path_safe(book_id) .. "/manifest.json"
end

function Download.save_manifest(book_id, title, chapters)
    local dir = Download.SPOOL .. "/" .. path_safe(book_id)
    os.execute("mkdir -p '" .. dir .. "'")
    local list = {}
    for _, ch in ipairs(chapters or {}) do
        list[#list + 1] = {
            chapterIdx = ch.chapterIdx, chapterUid = ch.chapterUid,
            title = ch.title, wordCount = ch.wordCount,
        }
    end
    return Json.write_atomic(manifest_path(book_id), {
        bookId = tostring(book_id), title = tostring(title or ""),
        last_download = os.time(), chapters = list,
    })
end

function Download.load_manifest(book_id)
    local f = io.open(manifest_path(book_id), "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local m = Json.decode(text or "")
    if type(m) ~= "table" or type(m.chapters) ~= "table" then return nil end
    return m
end

-- 已下载书目清单：books/ 下每个含 manifest 的目录一项。
-- { bookId=, title=, chapters_total=, chapters_downloaded=, bytes=, last_download= } 按
-- last_download 降序。Log.error_count 由调用方单独取（状态屏）。
function Download.list_books()
    local out = {}
    local dirs = {}
    local p = io.popen("ls -1 '" .. Download.SPOOL .. "' 2>/dev/null")
    if not p then return out end
    for id in p:lines() do dirs[#dirs + 1] = id end
    p:close()
    for _, id in ipairs(dirs) do
        if id ~= "." and id ~= ".." then
            local m = Download.load_manifest(id)
            local chapters_down, bytes = 0, 0
            local dp = Download.SPOOL .. "/" .. path_safe(id)
            local pp = io.popen("ls -1 '" .. dp .. "'/*.txt 2>/dev/null")
            if pp then
                for fn in pp:lines() do
                    chapters_down = chapters_down + 1
                    local tf = io.open(fn, "rb")
                    if tf then
                        bytes = bytes + (tf:seek("end") or 0)
                        tf:close()
                    end
                end
                pp:close()
            end
            -- 收录判据 = 有 manifest，**或**数字书目录且真有 spool 正文（manifest 写失败的
            -- 残留也得看得见、删得掉）。旧判据"只认纯数字目录"把 CB_2H6B… 这类真书整个从
            -- 「已下载」抹掉（用户实证：图片书不在列表里、也删不掉），而垃圾目录两条都不满足。
            if m or (id:match("^%d+$") and chapters_down > 0) then
                local last_dl = m and tonumber(m.last_download) or 0
                out[#out + 1] = {
                    bookId = id,
                    title = (m and m.title or "") ~= "" and m.title or id,
                    chapters_total = m and m.chapters and #m.chapters or 0,
                    chapters_down = chapters_down,
                    bytes = bytes,
                    last_download = last_dl,
                }
            end
        end
    end
    table.sort(out, function(a, b) return (a.last_download or 0) > (b.last_download or 0) end)
    return out
end

-- 某书"已下载章节"清单（manifest.chapters ∩ spool 文件，按 chapterIdx 升序）。
-- 返回 { {chapterIdx=, title=, text=} } | {}
function Download.list_downloaded_chapters(book_id)
    local m = Download.load_manifest(book_id)
    local by_idx = {}
    if m then
        for _, ch in ipairs(m.chapters) do
            by_idx[tonumber(ch.chapterIdx)] = { title = ch.title, chapterUid = ch.chapterUid }
        end
    end
    local out = {}
    local dp = Download.SPOOL .. "/" .. path_safe(book_id)
    local pp = io.popen("ls -1 '" .. dp .. "'/*.txt 2>/dev/null")
    if pp then
        for fn in pp:lines() do
            local idx = tonumber(fn:match("(%d+)%.txt$"))
            if idx then
                local tf = io.open(fn, "r")
                if tf then
                    local text = tf:read("*a")
                    tf:close()
                    local meta = by_idx[idx] or {}
                    out[#out + 1] = {
                        chapterIdx = idx,
                        title = meta.title or ("第" .. idx .. "章"),
                        -- chapterUid 必须带出去：图片资产目录以 uid 为键，离线阅读要靠它
                        -- 定位 asset_dir；少了它，「已下载」屏打开的章一律降级成 [图片]。
                        chapterUid = meta.chapterUid,
                        text = text,
                    }
                end
            end
        end
        pp:close()
    end
    table.sort(out, function(a, b) return a.chapterIdx < b.chapterIdx end)
    return out
end

------------------------------------------------------------------ 原始 xhtml 落盘（epub 导出素材）

-- 按 uid 存解码后的原始内容：epub 书 = xhtml（保结构保图标记）；
-- txt 书 = 同正文文本。best-effort：写盘失败不影响阅读路径。
local function raw_path(book_id, chapter_uid)
    return string.format("%s/%s/xhtml/%s.xhtml",
        Download.SPOOL, path_safe(book_id), path_safe(chapter_uid))
end

function Download.save_raw(book_id, chapter_uid, raw)
    local path = raw_path(book_id, chapter_uid)
    os.execute("mkdir -p '" .. path:match("^(.*)/[^/]+$") .. "'")
    local f = io.open(path, "w")
    if not f then return false end
    f:write(raw or "")
    f:close()
    return true
end

function Download.read_raw(book_id, chapter_uid)
    local f = io.open(raw_path(book_id, chapter_uid), "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s ~= "" and s or nil
end

------------------------------------------------------------------ 章图片资产（chapter.tar）

-- epub 章内 <img src="../Images/x.png"> 是包内相对路径，正文分片不含图片数据；
-- 真实资源在 web chapterInfos 给出的章 tar 包里（真机实证：
-- tar = https://res.weread.qq.com/wrco/tar_CB_<bookId>_<chapterIdx>）。
Download.ASSET_DIR = "/mnt/us/weread/data/imgcache"

-- 解析 tar（512B 头 POSIX ustar：name[100]，size 八进制@124，typeflag@156，body 512 对齐）。
-- 只取有内容的常规文件；返回 { name=bytes }。语义与插件 tar_entries 对齐
-- （weread_K4.koplugin/weread/lib/content.lua:195）——三处差异都曾让我们整包解出 0 个成员：
--   · 结束判定是**整块全零**，不是"头以 NUL 开头"（空名成员会误判成归档结束）；
--   · size 字段解析不出来按 0 处理并继续，不是整包 break（一个坏头不该毁掉后面的图）；
--   · 目录项（typeflag '5'）与零长项不进结果。
local function trim_tail_nulls(s) return (s:gsub("%z+$", "")) end

local function tar_entries(data)
    local out = {}
    local offset = 1
    while offset + 511 <= #data do
        local hdr = data:sub(offset, offset + 511)
        if hdr:match("^%z+$") then break end            -- 整块全零 = 归档结束
        local name = trim_tail_nulls(hdr:sub(1, 100))
        local size = tonumber(trim_tail_nulls(hdr:sub(125, 136)):gsub("%s", ""), 8) or 0
        if size < 0 then break end                      -- 只有负 size 能让 offset 倒退
        local typeflag = hdr:sub(157, 157)
        local body_start = offset + 512
        if name ~= "" and size > 0
            and (typeflag == "0" or typeflag == "" or typeflag == "\0") then
            out[#out + 1] = { name = name, data = data:sub(body_start, body_start + size - 1) }
        end
        offset = body_start + math.ceil(size / 512) * 512
    end
    return out
end
Download._tar_entries = tar_entries          -- 主机测试可注入

-- 载荷不是 tar 时给出可定位的判定：真机取证里最贵的一种失败是
-- "assets … 0 files 1196446B"——抓到了 1.2MB 却一个成员都没解出，日志里看不出载荷是什么。
local function payload_verdict(body)
    local b1, b2, b3, b4 = body:byte(1, 4)
    if b1 == 0x1f and b2 == 0x8b then return "gzip(1f8b)" end
    if body:sub(258, 262) == "ustar" then return "ustar-magic-ok" end
    local head = body:sub(1, 24):gsub("[^\32-\126]", ".")
    if head:match("^<") then return "html(" .. head .. ")" end
    if head:match("^%{") then return "json(" .. head .. ")" end
    return string.format("unknown(%02x%02x%02x%02x)", b1 or 0, b2 or 0, b3 or 0, b4 or 0)
end
Download._payload_verdict = payload_verdict

local tar_map_cache = {}                      -- book_id -> { chapterIdx = tar_url }

function Download.asset_dir(book_id, chapter_uid)
    return string.format("%s/%s/%s", Download.ASSET_DIR, path_safe(book_id), path_safe(chapter_uid))
end

-- web chapterInfos → { chapterIdx = tar_url }（每书会话内缓存一次）。
-- 只是**回退**：gateway 目录（fetch_catalog）里的 chapter.tar 优先，见 ensure_chapter_assets。
-- 返回 map | nil, err —— errCode 必须说出来：静默返回空表会让调用方把"接口被拒"
-- 误判成"这本书没有图"（真机 2026-11-22 取证：该接口返回 errCode=-2012）。
function Download.fetch_tar_map(book_id)
    local cached = tar_map_cache[tostring(book_id)]
    if cached then return cached end
    local body = wr.http_req({
        url = "https://weread.qq.com/web/book/chapterInfos",
        method = "POST",
        headers = {
            ["User-Agent"] = WeRead.USER_AGENT,
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
            -- 插件口径（content.lua:1465）：Referer = 本书 reader_url，不是裸站首页。
            ["Referer"] = WeRead.reader_url(book_id),
            ["Cookie"] = Cookie.to_header(Api.load_auth().cookies or {}),
        },
        body = Json.encode({ bookIds = { tostring(book_id) } }),
        timeout = 30,
    })
    local data = body and Json.decode(body)
    if type(data) == "table" then
        local code = data.errCode or data.errcode
        if code ~= nil and tostring(code) ~= "0" then
            return nil, "chapterInfos errCode=" .. tostring(code)
        end
    end
    local map = {}
    if type(data) == "table" then
        for _, wrap in pairs(data) do
            if type(wrap) == "table" then
                for _, rec in pairs(wrap) do
                    if type(rec) == "table" and type(rec.updated) == "table" then
                        for _, ch in ipairs(rec.updated) do
                            if ch.chapterIdx and ch.tar then
                                map[tonumber(ch.chapterIdx)] = tostring(ch.tar)
                            end
                        end
                    end
                end
            end
        end
    end
    tar_map_cache[tostring(book_id)] = map
    return map
end

-- `.done` 只是"上次成功过"的记号。真机上有一批**化石目录**：旧实现解出 0 个成员也照写
-- `.done`（app.log 实证 `assets CB_… ch1: 0 files 1196446B`），只看记号就等于永久放弃这些章。
-- 故完备判据 = 记号在 **且** 目录里真有图；数不出来时保守当成完备（别反复重下）。
local function assets_complete(dir)
    local probe = io.open(dir .. "/.done")
    if not probe then return false end
    probe:close()
    local pp = io.popen("ls -1a '" .. dir .. "' 2>/dev/null")
    if not pp then return true end
    local n = 0
    for fn in pp:lines() do
        if fn ~= "." and fn ~= ".." and fn ~= ".done" then n = n + 1 end
    end
    pp:close()
    return n > 0
end
Download._assets_complete = assets_complete

-- 带跳转的 GET：res.weread.qq.com 会 302 到腾讯 CDN（真机实证 2026-11-23：
-- location=https://wrco-40036.sh.gfp.tencent-cloud.com/<book>/img09.jpg?sign=…），
-- 而传输层不跟随（net.c 的 http_req 没设 FOLLOWLOCATION）→ 手动跟 ≤3 跳。
-- tar 与远端图片两条通道**共用这一个实现**：漏跟跳转的表现是"拿到 0 字节"而不是报错，
-- 最容易静默退化成"这本书没图"（本轮就是这么漏的）。
local function http_get_follow(url, referer, timeout)
    local auth = Api.load_auth()
    local body, status
    for _ = 1, 3 do
        local headers
        body, status, headers = wr.http_req({
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = WeRead.USER_AGENT,
                ["Referer"] = referer,
                ["Cookie"] = Cookie.to_header(auth.cookies or {}),
            },
            timeout = timeout or 60,
        })
        local code = tonumber(status)
        if not (code and code >= 300 and code < 400) then break end
        local loc = headers and (headers["location"] or headers["Location"])
        if not loc or loc == "" then break end
        url = loc:match("^//") and ("https:" .. loc)
            or (loc:match("^/") and ("https://weread.qq.com" .. loc) or loc)
    end
    return body, status
end
Download._http_get_follow = http_get_follow

-- 确保某章图片资产已解包落盘（幂等：只在**成功**后写 .done）。失败不致命——
-- 调用方只记日志，reader 对缺图降级 [图片]。
-- tar_url 由调用方从目录记录（gateway 的 chapter.tar）带入；缺失才回退 web chapterInfos。
function Download.ensure_chapter_assets(book_id, chapter_uid, chapter_idx, tar_url)
    local dir = Download.asset_dir(book_id, chapter_uid)
    if assets_complete(dir) then return dir end
    local url = tar_url
    if not url or url == "" then
        local tars, terr = Download.fetch_tar_map(book_id)
        if not tars then return nil, terr end
        url = tars[tonumber(chapter_idx)]
    end
    if not url then return nil, "no tar" end
    local body, status = http_get_follow(url, WeRead.reader_url(book_id, chapter_uid), 60)
    if not body or #body < 512 then
        Log.error(string.format("tar fetch %s ch%d: %s %s", book_id, chapter_idx,
            tostring(status), body and tostring(#body) or "empty"))
        return nil, "tar fetch failed"
    end
    local entries = tar_entries(body)
    if #entries == 0 then
        -- 不写 .done：0 成员是**失败**，不是"这章没图"。写了 .done，幂等探针就把失败
        -- 永久固化——重下、重开都不再试（真机实证：CB_ 书 6 章全部 "0 files" 后再没恢复）。
        local verdict = payload_verdict(body)
        Log.error(string.format("tar parse %s ch%d: 0 entries in %dB payload=%s",
            tostring(book_id), tonumber(chapter_idx) or 0, #body, verdict))
        return nil, "tar parsed 0 entries (" .. verdict .. ")"
    end
    os.execute("mkdir -p '" .. dir .. "'")
    local prefix = "CB_" .. tostring(book_id) .. "_"
    local written = 0
    for _, e in ipairs(entries) do
        local name = e.name:match("([^/]+)$")     -- ../Images/x.png → x.png
        -- tar 成员名带 CB_<bookId>_ 前缀（真机实证 CB_3300057890_note.png），而正文 xhtml
        -- 的 src 是裸 basename（note.png）→ 剥前缀对齐。bookId 本身可能不是纯数字
        -- （CB_2H6B… 这类），所以按实际 bookId 精确剥，数字式再用通配兜底。
        if name:sub(1, #prefix) == prefix then
            name = name:sub(#prefix + 1)
        else
            local stripped = name:match("^CB_%d+_(.+)$")
            if stripped then name = stripped end
        end
        if name and name ~= "" then
            local f = io.open(dir .. "/" .. path_safe(name), "wb")
            if f then f:write(e.data) f:close() written = written + 1 end
        end
    end
    if written == 0 then return nil, "no writable file in tar" end
    local done = io.open(dir .. "/.done", "w")
    if done then done:write("1") done:close() end
    Log.info(string.format("assets %s ch%d: %d files %dB",
        tostring(book_id), tonumber(chapter_idx) or 0, written, #body))
    return dir
end

------------------------------------------------------------------ 无 tar 时的远端图片通道

-- 正文 xhtml 里的 <img src> 常是**绝对 URL**（真机实证 2026-11-23：CB_2H6B… 书 72 章
-- gateway 全无 tar、web chapterInfos 又返回 errCode=-2012，而 src 是
-- https://res.weread.qq.com/wrepub/CB_<book>_img03.jpg）。这类书没有 tar 可解，只能按 URL
-- 逐张取——插件 content.lua:1215 download_remote_images 的同款通道。
-- 宿主白名单是安全边界：没有它，一本被投毒的书就能把阅读器变成任意地址抓取器。
Download.TRUSTED_IMAGE_HOSTS = { "weread.qq.com", "mmbiz.qpic.cn", "mmbiz.qlogo.cn" }
Download.MAX_CHAPTER_IMAGES = 200               -- 插件同款上限（256MB 设备防 OOM）
Download.MAX_IMAGE_BYTES = 8 * 1024 * 1024

function Download.trusted_image_url(src)
    local url = tostring(src or "")
    if url:match("^//") then url = "https:" .. url end
    local host = url:match("^https?://([^/]+)")
    if not host then return nil end
    host = host:lower():gsub(":%d+$", "")
    for _, suffix in ipairs(Download.TRUSTED_IMAGE_HOSTS) do
        if host == suffix or host:sub(-(#suffix + 1)) == "." .. suffix then return url end
    end
    return nil
end

-- xhtml → { 标记名 = url }。键必须与 html_text 的标记同源（src 的 basename、去 query），
-- 否则 reader 按标记找文件永远找不到——这正是"图在盘上却不显示"的一种成因。
function Download.image_urls_from_raw(raw)
    local out = {}
    for src in tostring(raw or ""):gmatch('<%s*img[^>]-src%s*=%s*"([^"]+)"') do
        local url = Download.trusted_image_url(src)
        if url then
            local base = tostring(src):match("([^/]+)$")
            local name = base and base:match("^[^?]+")   -- 与 html_text 的标记同源（去 query）
            if name and name ~= "" then out[path_safe(name)] = url end
        end
    end
    return out
end

-- 按 URL 补齐本章图片。幂等：已落盘的不重取；一张都没取到就不写 .done（失败不得固化）。
function Download.ensure_chapter_images(book_id, chapter_uid)
    local dir = Download.asset_dir(book_id, chapter_uid)
    local raw = Download.read_raw(book_id, chapter_uid)
    if not raw then return nil, "no raw xhtml" end
    local urls = Download.image_urls_from_raw(raw)
    local fetched, cached = 0, 0
    for name, url in pairs(urls) do
        local path = dir .. "/" .. name
        local probe = io.open(path, "rb")
        if probe then
            probe:close()
            cached = cached + 1
        elseif fetched < Download.MAX_CHAPTER_IMAGES then
            -- 必须跟跳转：src 指向 res.weread.qq.com，真身在其 302 的腾讯 CDN 上
            local body, status = http_get_follow(
                url, WeRead.reader_url(book_id, chapter_uid), 30)
            local code = tonumber(status)
            if body and #body > 0 and #body <= Download.MAX_IMAGE_BYTES
                and (not code or (code >= 200 and code < 300)) then
                os.execute("mkdir -p '" .. dir .. "'")
                local f = io.open(path, "wb")
                if f then f:write(body) f:close() fetched = fetched + 1 end
            end
        end
    end
    if fetched == 0 and cached == 0 then return nil, "no trusted image url" end
    if fetched > 0 then
        local done = io.open(dir .. "/.done", "w")
        if done then done:write("1") done:close() end
    end
    Log.info(string.format("images %s: fetched=%d cached=%d",
        tostring(book_id), fetched, cached))
    return dir
end

-- 正文里带图标记（\1IMG:）却缺资产 → 补一次。已 spool 的章也要走这里：
-- 早于图片功能落盘的书，重下时被 is_spooled 跳过、打开时被缓存早退跳过，
-- 于是没有任何路径能补图（用户实证「新下载的书还是没有图片」的另一半成因）。
-- 两条通道按序试：chapter.tar（gateway/web 给 URL）→ 正文 xhtml 里的绝对 URL。
local function backfill_assets(book_id, ch, text)
    if not ch or not text or not text:find("\1IMG:") then return end
    local dir, aerr = Download.ensure_chapter_assets(
        book_id, ch.chapterUid, ch.chapterIdx, ch.tar)
    if dir then return end
    local _, ierr = Download.ensure_chapter_images(book_id, ch.chapterUid)
    Log.info(string.format("assets ch%s: %s / images: %s",
        tostring(ch.chapterIdx), tostring(aerr), tostring(ierr)))
end

------------------------------------------------------------------ 删除（已下载管理）

-- 删除单章 spool 文件（manifest 不动：章数口径不变，下次浏览该章显示未下载）。
function Download.delete_chapter(book_id, chapter_idx)
    if not Download.is_spooled(book_id, chapter_idx) then return false end
    os.execute("rm -f '" .. spool_path(book_id, chapter_idx) .. "'")
    Log.info(string.format("delete chapter: %s ch%d", tostring(book_id), chapter_idx))
    return true
end

-- 删除整书（spool + manifest + 图片资产）。守卫从"纯数字"升级为"路径安全 + 确实下载过"：
-- 纯数字判据会把 CB_2H6B… 这类真书的删除入口一并堵死（用户只剩"清空全部"）。
-- 路径分量仍必须过 path_safe——它要拼进 rm -rf 的单引号里。
function Download.delete_book(book_id)
    local raw = tostring(book_id)
    local id = path_safe(raw)
    if id ~= raw or id == "" then return false, "bad book id" end
    if not Download.load_manifest(raw) then
        local pp = io.popen("ls -1 '" .. Download.SPOOL .. "/" .. id .. "'/*.txt 2>/dev/null")
        local one = pp and pp:read("*l")
        if pp then pp:close() end
        if not one then return false, "not downloaded" end
    end
    os.execute("rm -rf '" .. Download.SPOOL .. "/" .. id .. "'")
    os.execute("rm -rf '" .. Download.ASSET_DIR .. "/" .. id .. "'")
    Log.info("delete book: " .. id)
    return true
end

-- 清空全部已下载（含 manifest；下次进「已下载」在线时回填会重建书目信息）。
function Download.delete_all()
    os.execute("rm -rf '" .. Download.SPOOL .. "'/*")
    os.execute("rm -rf '" .. Download.ASSET_DIR .. "'/*")
    Log.info("delete all downloads")
    return true
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
        backfill_assets(book_id, Download.find_chapter(chapters, chapter_idx), cached)
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
    local t0 = os.time()
    local text, terr = Download.fetch_chapter_text(book_id, ch.chapterUid, psvts)
    if not text then
        Log.error(string.format("download %s ch%d: %s", book_id, ch.chapterIdx, tostring(terr)))
        return nil, terr
    end
    Log.info(string.format("download %s ch%d bytes=%d %ds",
        book_id, ch.chapterIdx, #text, os.time() - t0))
    backfill_assets(book_id, ch, text)   -- 章内有图：确保 tar 资产解包（失败只留 [图片] 占位）
    local path, serr = Download.save_chapter(book_id, ch.chapterIdx, ch.title, text)
    if not path then
        return nil, serr
    end
    return Download.read_chapter(book_id, ch.chapterIdx)
end

-- 批量预取：从目录第 start_pos 项起最多 max_chapters 章；已 spool 的跳过 → 重跑幂等。
-- on_progress(done, total, ch_title) 可选：UI 进度屏回调（菜单"下载全本/后 5 章"用）。
-- 回调**返回 false 即取消**（单进程无异步，回调是批量下载里唯一的按键时机）；
-- 取消时已落盘的章保留，下次重跑从这些章直接跳过——幂等就是续传。
-- 单章失败不中断（后续章节可能正常），失败原因写在该项的 _err 上，reader 缺章时提示。
-- 返回 chapters | nil, err；成功时第三个返回值是汇总 { total, done, ok, fail, cancelled }。
-- 汇总必须由本模块给：调用方自己数 _err 只能数它那份目录，而 _err 写在返回的那份上。
function Download.book(book_id, max_chapters, start_pos, on_progress)
    local chapters, err = Download.fetch_catalog(book_id)
    if not chapters or #chapters == 0 then
        return nil, "catalog failed: " .. tostring(err or "empty")
    end
    local from = math.min(math.max(tonumber(start_pos) or 1, 1), #chapters)
    local last = math.min(from + math.max(tonumber(max_chapters) or 1, 1) - 1, #chapters)
    local sess = Download.new_session()
    local stats = { total = last - from + 1, done = 0, ok = 0, fail = 0, cancelled = false }
    for i = from, last do
        local ch = chapters[i]
        if Download.is_spooled(book_id, ch.chapterIdx) then
            ch._err = nil
            -- 已 spool ≠ 已完备：图片资产可能从没抓过（或上次抓失败后没留 .done），
            -- 重下全本正是补图的机会——否则老书永远没图。
            backfill_assets(book_id, ch, Download.read_chapter(book_id, ch.chapterIdx))
        else
            local text, terr = Download.ensure_chapter(book_id, chapters, ch.chapterIdx, sess)
            ch._err = text and nil or terr
        end
        if ch._err then stats.fail = stats.fail + 1 else stats.ok = stats.ok + 1 end
        stats.done = stats.done + 1
        if on_progress then
            local ok_cb, cont = pcall(on_progress, stats.done, stats.total, ch.title)
            if ok_cb and cont == false then
                stats.cancelled = true
                break
            end
        end
    end
    return chapters, nil, stats
end

return Download
