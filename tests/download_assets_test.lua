-- Download 章图片资产（chapter.tar）链路的主机测。
--
-- 为什么值得写：用户实证「新下载的书还是没有图片」。取证链（真机 2026-11-22）：
--   · app.log `assets CB_… ch1: 0 files 1196446B` —— tar 抓到了 1.2MB 却解出 0 个文件；
--   · 解出 0 个也照写 `.done`，而幂等探针见 `.done` 即永久跳过 ⇒ 失败被固化，
--     重下、重开都不会再试（这正是「还是没有」的机制）；
--   · gateway 目录对这本书 72 章 **0 个带 tar**，只能走 web `/web/book/chapterInfos`，
--     而该接口当天已返回 `errCode=-2012` ⇒ 连 tar URL 都拿不到；
--   · 插件口径（weread_K4.koplugin/weread/lib/content.lua:1319/1465）：tar 取自
--     **目录记录的 chapter.tar**，web 接口只是回退，且回退请求带 Referer=reader_url。
-- 故障面全在纯函数与可注入的缝上，主机侧可完整钉住。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL download_assets_test: " .. msg)
        fails = fails + 1
    end
end

local DIR = "/tmp/wr_assets_test_" .. tostring(os.time())
os.execute("rm -rf '" .. DIR .. "'")
os.execute("mkdir -p '" .. DIR .. "'")

package.loaded.download = nil
local Download = require("download")
local Api = require("api")
local WeRead = require("protocol")

Download.ASSET_DIR = DIR .. "/imgcache"
Download.SPOOL = DIR .. "/books"

-- 绝不读真 auth.json：凭据入口一律桩掉（收尾还原，别污染同进程的其它 suite）。
local api_load_auth_saved = Api.load_auth
Api.load_auth = function() return { cookies = {} } end

local logs = {}
local Log = require("log")
local log_info_saved, log_error_saved = Log.info, Log.error
Log.info = function(m) logs[#logs + 1] = "I " .. tostring(m) end
Log.error = function(m) logs[#logs + 1] = "E " .. tostring(m) end

---------------------------------------------------------------- tar 构造工具

local function mk_header(name, size, typeflag, size_raw)
    local h = {}
    for i = 1, 512 do h[i] = "\0" end
    local function put(off, s)
        for i = 1, #s do h[off + i - 1] = s:sub(i, i) end
    end
    put(1, name or "")
    put(101, "0000644\0")
    put(109, "0000000\0")
    put(117, "0000000\0")
    put(125, size_raw or string.format("%011o", size or 0))
    put(137, "00000000000\0")
    put(149, "        ")                 -- chksum 占位（解析器不校验）
    put(157, typeflag or "0")
    put(258, "ustar")
    return table.concat(h)
end

local function mk_file(name, body, typeflag, size_raw)
    local pad = string.rep("\0", (512 - #body % 512) % 512)
    return mk_header(name, #body, typeflag, size_raw) .. body .. pad
end

local ZERO_BLOCK = string.rep("\0", 512)

---------------------------------------------------------------- wr.http_req 桩

local requests = {}
local tar_body, tar_status = nil, 200
local infos_body = nil
local img_body = nil

wr = {
    http_req = function(opts)
        requests[#requests + 1] = opts
        local u = tostring(opts.url)
        if u:find("chapterInfos", 1, true) then return infos_body, 200, {} end
        if u:find("res.weread", 1, true) then return img_body, 200, {} end
        return tar_body, tar_status, {}
    end,
}

local function reset()
    requests = {}
    logs = {}
    tar_body, tar_status = nil, 200
    infos_body = nil
    img_body = nil
end

local function count_of(pattern)
    local n = 0
    for _, r in ipairs(requests) do
        if tostring(r.url):find(pattern, 1, true) then n = n + 1 end
    end
    return n
end

local function dir_files(dir)
    local out = {}
    local p = io.popen("ls -1a '" .. dir .. "' 2>/dev/null")
    if p then
        for ln in p:lines() do
            if ln ~= "." and ln ~= ".." then out[#out + 1] = ln end
        end
        p:close()
    end
    return out
end

---------------------------------------------------------------- 1) tar 解析容错

-- 1a) 首个成员名字段为空（头以 NUL 开头）但**不是**全零块 → 不得当成归档结束。
--     旧实现 hdr:match("^%z+") 在这里 break，后面所有图片全丢（0 files 的一种成因）。
reset()
local body = mk_header("", 0, "0") .. mk_file("CB_101_cover.jpg", "JPGDATA") .. ZERO_BLOCK .. ZERO_BLOCK
local ents = Download._tar_entries(body)
check(#ents == 1, "空名头不得终止解析：应解出 1 个成员，实得 " .. #ents)
check(ents[1] and ents[1].name == "CB_101_cover.jpg",
    "应解出后续成员，实得 " .. tostring(ents[1] and ents[1].name))

-- 1b) size 字段不可解析（非八进制）→ 该项按 0 处理并继续，不得整个归档失败。
reset()
body = mk_header("weird.bin", 0, "0", "\1\2\3\4\5\6\7\8\9\10\11")
    .. mk_file("note.png", "PNGDATA") .. ZERO_BLOCK .. ZERO_BLOCK
ents = Download._tar_entries(body)
local got_png = false
for _, e in ipairs(ents) do if e.name == "note.png" and e.data == "PNGDATA" then got_png = true end end
check(got_png, "size 字段坏掉不得让整包失效：应仍解出 note.png，实得 " .. #ents .. " 项")

-- 1c) 目录项（typeflag '5'）与零长项不进结果（插件语义：只取常规文件且 size>0）。
reset()
body = mk_header("Images/", 0, "5") .. mk_file("Images/a.png", "A") .. ZERO_BLOCK .. ZERO_BLOCK
ents = Download._tar_entries(body)
check(#ents == 1 and ents[1].name == "Images/a.png",
    "目录项应被跳过，实得 " .. #ents .. " 项")

-- 1d) 两块全零仍然终止（回归护栏：别把正常结束条件改掉）。
reset()
body = mk_file("a.png", "A") .. ZERO_BLOCK .. ZERO_BLOCK .. mk_file("b.png", "B")
ents = Download._tar_entries(body)
check(#ents == 1 and ents[1].name == "a.png", "全零块应终止解析，实得 " .. #ents .. " 项")

---------------------------------------------------------------- 2) 资产落盘契约

-- 2a) 解出 0 个成员 ⇒ 不得写 .done（否则失败被幂等探针固化，永不重试）。
reset()
local dir = Download.asset_dir("9001", "u1")
tar_body = string.rep("\31\139", 400)          -- gzip 魔数开头：不是 tar
local ok_dir, aerr = Download.ensure_chapter_assets("9001", "u1", 1, "https://res.example/tar_1")
check(ok_dir == nil, "0 成员应返回 nil，实得 " .. tostring(ok_dir))
check(type(aerr) == "string" and aerr ~= "", "0 成员应给出原因，实得 " .. tostring(aerr))
local files = dir_files(dir)
local has_done = false
for _, f in ipairs(files) do if f == ".done" then has_done = true end end
check(not has_done, "解出 0 个成员时不得写 .done（目录内容: " .. table.concat(files, ",") .. "）")
local saw_magic = false
for _, l in ipairs(logs) do if l:find("1f8b", 1, true) or l:find("gzip", 1, true) then saw_magic = true end end
check(saw_magic, "0 成员应把载荷魔数写进日志便于定位，实得日志: " .. table.concat(logs, " | "))

-- 2b) 失败后再次调用应**重试**（不因 .done 短路）。
reset()
tar_body = mk_file("CB_9001_cover.jpg", "COVERBYTES") .. ZERO_BLOCK .. ZERO_BLOCK
ok_dir = Download.ensure_chapter_assets("9001", "u1", 1, "https://res.example/tar_1")
check(ok_dir == dir, "重试应成功并返回目录，实得 " .. tostring(ok_dir))
local f = io.open(dir .. "/cover.jpg", "rb")     -- CB_<bookId>_ 前缀应被剥掉
check(f ~= nil, "成员名 CB_<bookId>_ 前缀应剥掉后落盘 cover.jpg")
if f then check(f:read("*a") == "COVERBYTES", "落盘内容应与 tar 成员一致") f:close() end

-- 2c) .done 存在 ⇒ 幂等短路，一个请求都不发。
reset()
ok_dir = Download.ensure_chapter_assets("9001", "u1", 1, "https://res.example/tar_1")
check(ok_dir == dir, ".done 存在应直接返回目录")
check(#requests == 0, ".done 存在时不得发任何请求，实发 " .. #requests)

-- 2e) 化石目录（.done 在、图 0 张）⇒ 必须重试。真机上 CB_ 书 6 个章目录就是这个形态。
reset()
local fossil = Download.asset_dir("9009", "uf")
os.execute("mkdir -p '" .. fossil .. "'")
local fd = io.open(fossil .. "/.done", "w")
if fd then fd:write("1") fd:close() end
check(not Download._assets_complete(fossil), "只有 .done 没有图的目录不应判为完备")
tar_body = mk_file("CB_9009_pic.png", "P") .. ZERO_BLOCK .. ZERO_BLOCK
local ok_f = Download.ensure_chapter_assets("9009", "uf", 1, "https://res.example/tar_9009")
check(ok_f == fossil, "化石目录应被重新抓取，实得 " .. tostring(ok_f))
check(#requests == 1, "化石目录应发一次请求，实发 " .. #requests)
check(Download._assets_complete(fossil), "补齐后应判为完备")

-- 2d) bookId 本身是 CB_ 开头（非数字，公众号/自定义书）时，成员前缀是
--     CB_CB_<id>_name —— 只按 ^CB_%d+_ 通配剥会漏，图落在长文件名下而正文按裸名找。
reset()
local dir_cb = Download.asset_dir("CB_2H6Test", "uc1")
tar_body = mk_file("CB_CB_2H6Test_pic.png", "PICBYTES") .. ZERO_BLOCK .. ZERO_BLOCK
local ok_cb = Download.ensure_chapter_assets("CB_2H6Test", "uc1", 1, "https://res.example/t_cb")
check(ok_cb == dir_cb, "CB_ 型 bookId 也应成功解包，实得 " .. tostring(ok_cb))
local f2 = io.open(dir_cb .. "/pic.png", "rb")
check(f2 ~= nil, "CB_<bookId>_ 前缀应按实际 bookId 精确剥掉（落 pic.png），目录: "
    .. table.concat(dir_files(dir_cb), ","))
if f2 then f2:close() end

---------------------------------------------------------------- 3) tar URL 来源口径

-- 3a) 调用方给了 tar（gateway 目录里的 chapter.tar）⇒ 不得再去问 web chapterInfos。
reset()
tar_body = mk_file("CB_9002_a.png", "A") .. ZERO_BLOCK .. ZERO_BLOCK
Download.ensure_chapter_assets("9002", "u9", 3, "https://res.example/tar_CB_9002_3")
check(count_of("chapterInfos") == 0,
    "有 gateway tar 时不应打 web chapterInfos（该接口已被服务端拒 -2012），实打 "
        .. count_of("chapterInfos") .. " 次")
check(count_of("tar_CB_9002_3") == 1, "应直接用调用方给的 tar URL")

-- 3b) 没给 tar ⇒ 回退 web chapterInfos，且 Referer 必须是本书 reader_url（插件口径）。
reset()
infos_body = '{"data":[{"bookId":"9003","updated":[{"chapterIdx":7,"tar":"https://res.example/t7"}]}]}'
tar_body = mk_file("CB_9003_b.png", "B") .. ZERO_BLOCK .. ZERO_BLOCK
Download.ensure_chapter_assets("9003", "u3", 7)
check(count_of("chapterInfos") == 1, "无 gateway tar 时应回退 web 接口一次，实打 "
    .. count_of("chapterInfos"))
local referer
for _, r in ipairs(requests) do
    if tostring(r.url):find("chapterInfos", 1, true) then referer = r.headers and r.headers["Referer"] end
end
check(referer == WeRead.reader_url("9003"),
    "web 回退的 Referer 应为 reader_url（裸站首页 Referer 是 -2012 的怀疑面），实得 " .. tostring(referer))

-- 3c) web 接口返回 errCode ⇒ 应把失败说出来，而不是静默当成「这本书没有 tar」。
reset()
infos_body = '{"errCode":-2012,"errMsg":"refused"}'
local d2, e2 = Download.ensure_chapter_assets("9004", "u4", 1)
check(d2 == nil and type(e2) == "string", "errCode 应转成可见原因，实得 " .. tostring(d2) .. "/" .. tostring(e2))
check(e2 and (e2:find("2012", 1, true) or e2:find("chapterInfos", 1, true)),
    "原因里应带上服务端错误码，实得 " .. tostring(e2))

---------------------------------------------------------------- 4) 路径注入护栏

-- book_id / chapter_uid 来自服务端与书架响应，会拼进 os.execute 的单引号里。
local ad = Download.asset_dir("a'b", "u'id")
check(not ad:find("'", 1, true), "asset_dir 不得保留单引号（os.execute 拼接面），实得 " .. tostring(ad))
check(not ad:find("..", 1, true), "asset_dir 不得保留 .. 路径穿越，实得 " .. tostring(ad))
check(Download._path_safe("..") == "_" and Download._path_safe(".") == "_",
    "纯 . / .. 分量应整体替换，实得 " .. tostring(Download._path_safe("..")))

---------------------------------------------------------------- 5) 已 spool 章的图片回填

-- 「新下载的书没图片」的第二 half：早于图片功能落盘的章，重下时被 is_spooled 跳过、
-- 打开时被 ensure_chapter 的缓存早退跳过 ⇒ 没有任何路径能补图。
local BOOK = "9005"
local CHS = {
    { chapterIdx = 1, chapterUid = "v1", title = "第一章", wordCount = 10, tar = "https://res.example/t_9005_1" },
    { chapterIdx = 2, chapterUid = "v2", title = "第二章", wordCount = 10 },
}
Download.save_manifest(BOOK, "回填测试书", CHS)
Download.save_chapter(BOOK, 1, "第一章", "正文\1IMG:cover.jpg\1 更多正文")
Download.save_chapter(BOOK, 2, "第二章", "纯文本无图")

-- 5a) ensure_chapter 命中 spool 缓存时，仍应为带图标记的章补资产。
reset()
tar_body = mk_file("CB_9005_cover.jpg", "C1") .. ZERO_BLOCK .. ZERO_BLOCK
local text = Download.ensure_chapter(BOOK, CHS, 1)
check(type(text) == "string" and text:find("IMG:", 1, true) ~= nil, "应原样返回 spool 正文")
check(count_of("t_9005_1") == 1, "命中缓存也应回填图片资产（用目录里的 tar），实发 "
    .. count_of("t_9005_1"))

-- 5b) 无图标记的章不得白跑网络。
reset()
tar_body = mk_file("CB_9005_x.png", "X") .. ZERO_BLOCK .. ZERO_BLOCK
Download.ensure_chapter(BOOK, CHS, 2)
check(#requests == 0, "无 IMG 标记的章不应发起资产请求，实发 " .. #requests)

-- 5c) 全本下载遇到已 spool 的章，也要回填缺失的资产（重下=修图，不只是跳过）。
reset()
os.execute("rm -rf '" .. Download.asset_dir(BOOK, "v1") .. "'")
tar_body = mk_file("CB_9005_cover.jpg", "C1") .. ZERO_BLOCK .. ZERO_BLOCK
Download.fetch_catalog = function() return CHS end
local _, _, stats = Download.book(BOOK, 10, 1)
check(type(stats) == "table" and stats.ok == 2, "两章都应算成功，实得 " .. tostring(stats and stats.ok))
check(count_of("t_9005_1") == 1, "全本下载应为已 spool 的带图章回填资产，实发 "
    .. count_of("t_9005_1"))

---------------------------------------------------------------- 6) 离线（已下载）路径的图片可达性

-- 「已下载」屏打开章节走的是 list_downloaded_chapters → Reader.open；资产目录以
-- chapterUid 为键，列表丢了 uid 就等于离线路径永远找不到图。
reset()
local list = Download.list_downloaded_chapters(BOOK)
check(#list == 2, "应列出两章，实得 " .. #list)
check(list[1].chapterUid == "v1",
    "应带出 manifest 里的 chapterUid，实得 " .. tostring(list[1].chapterUid))
check(Download.asset_dir(BOOK, list[1].chapterUid) == Download.asset_dir(BOOK, "v1"),
    "由列表构造的资产目录应与写入时一致")
local offline = dir_files(Download.asset_dir(BOOK, "v1"))
local has_img = false
for _, f in ipairs(offline) do if f == "cover.jpg" then has_img = true end end
check(has_img, "离线资产目录里应有回填的 cover.jpg，实得: " .. table.concat(offline, ","))

---------------------------------------------------------------- 7) 无 tar 的书：正文 xhtml 绝对 URL 通道

-- 真机实证：CB_2H6B… 书 72 章 gateway 全无 tar、web chapterInfos 又被拒（-2012），
-- 但 xhtml 的 <img src> 是 https://res.weread.qq.com/wrepub/CB_<book>_img03.jpg。
-- 7a) 宿主白名单（安全边界：被投毒的书源不得把设备变成任意地址抓取器）
check(Download.trusted_image_url("https://res.weread.qq.com/wrepub/a.jpg") ~= nil,
    "weread 子域应放行")
check(Download.trusted_image_url("https://mmbiz.qpic.cn/x.png") ~= nil, "qpic 应放行")
check(Download.trusted_image_url("https://evil.example.com/weread.qq.com/a.jpg") == nil,
    "白名单必须按 host 段判定：路径里出现白名单域名不得放行")
check(Download.trusted_image_url("//res.weread.qq.com/a.jpg") == "https://res.weread.qq.com/a.jpg",
    "协议相对 URL 应补 https")

-- 7b) 键必须与 html_text 的标记同源（src 的 basename、去 query），否则 reader 找不到文件
local urls = Download.image_urls_from_raw(
    '<p>x</p><img src="https://res.weread.qq.com/wrepub/CB_9007_img03.jpg" data-w="1069px"/>'
        .. '<img src="https://res.weread.qq.com/a/b.png?tp=1"/>'
        .. '<img src="https://evil.example/x.jpg"/>')
check(urls["CB_9007_img03.jpg"] ~= nil, "应按标记名建键")
check(urls["b.png"] ~= nil, "带 query 的 src 应去 query 后建键")
check(urls["x.jpg"] == nil, "非白名单宿主的图不得进表")

-- 7c) 端到端：无 tar 时按 URL 落盘，文件名 = 标记名（reader 才能直接命中）
reset()
local BOOK7 = "9007"
Download.save_raw(BOOK7, "w1", '<img src="https://res.weread.qq.com/wrepub/CB_9007_img03.jpg"/>')
img_body = "IMGBYTES"
local d7, e7 = Download.ensure_chapter_images(BOOK7, "w1")
check(d7 == Download.asset_dir(BOOK7, "w1"),
    "应返回目录，实得 " .. tostring(d7) .. " / " .. tostring(e7))
local f7 = io.open(d7 .. "/CB_9007_img03.jpg", "rb")
check(f7 ~= nil, "落盘文件名应与标记名一致（目录: " .. table.concat(dir_files(d7), ",") .. "）")
if f7 then check(f7:read("*a") == "IMGBYTES", "内容应为响应体") f7:close() end
check(Download._assets_complete(d7), "取到图后应判为完备")

-- 7d) 幂等：已落盘的图不重取
reset()
img_body = "IMGBYTES"
Download.ensure_chapter_images(BOOK7, "w1")
check(#requests == 0, "已落盘的图不应重取，实发 " .. #requests)

---------------------------------------------------------------- 收尾

-- 同一进程里跑多套：模块级桩必须还原，否则污染后面的 suite。
Log.info = log_info_saved
Log.error = log_error_saved
Api.load_auth = api_load_auth_saved
os.execute("rm -rf '" .. DIR .. "'")
package.loaded.download = nil          -- 让后续 suite 拿到干净的 download（ASSET_DIR/SPOOL 不复用）
_G.wr = nil
print("download_assets done: " .. (fails == 0 and "ALL PASS" or ("FAILS=" .. fails)))
return fails
