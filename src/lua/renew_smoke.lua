-- renew_smoke.lua — 免扫码续期的真机验收（DK-3 会话持久化批次的收口项）。
--
-- 验的是四件事，全部围绕一条硬约束：**绝不因为测试而把登录态弄丢**（丢了只能重扫二维码，
-- 有风控风险）。所以本脚本一次扫码都不发，且在任何分支下都必须保持可用会话。
--   1) Auth.renew 的分类结论正确（replaced/stale 为成功；network/no-refresh/cooling 不得改盘）
--   2) 失败分支一个字节都不写（用 Cookie 头的逐串比较，不外印任何值）
--   3) wr_rt 仍在（丢了它 = 本批修复回归）
--   4) 续期之后会话真能取到正文（走 t_0 分片 + Shard.decode，绕开 spool 缓存）
--
-- 只打印长度/布尔/计数，凭据值一律不外印。
-- 用法：ssh -p "$K4_PORT" "$K4_HOST" 'cd /mnt/us/weread && ./weread-dyn lua/renew_smoke.lua'
--       （必须真机跑：依赖 wr.http_req 与 /mnt/us/weread/data 下的真实登录态）

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path
local Api = require("api")
local Auth = require("auth")
local Cookie = require("cookie")
local Download = require("download")

local fails = 0
local function step(ok, name, detail)
    print(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name,
        detail and ("  -- " .. tostring(detail)) or ""))
    if not ok then fails = fails + 1 end
    return ok
end

-- 会话形态指纹：长度 + 逐串签名。签名只用于「有没有变」的比较，绝不打印。
local function fingerprint(auth)
    local jar = Cookie.sanitize(auth.cookies or {})
    return {
        skey = type(jar.wr_skey) == "string" and #jar.wr_skey or 0,
        rt = type(jar.wr_rt) == "string" and #jar.wr_rt or 0,
        names = (function()
            local n = 0
            for _ in pairs(jar) do n = n + 1 end
            return n
        end)(),
        header = Cookie.to_header(jar),
        login = Cookie.has_login_cookie(jar),
    }
end

if not wr.http_req then
    print("需要动态变体 weread-dyn（静态变体没有 wr.http_req）")
    os.exit(1)
end
assert(Api.has_login(), "需要登录态（本脚本不扫码：登录态没了就停下来交给人工）")

local before_auth = Api.load_auth()
local before = fingerprint(before_auth)
print(string.format("before: wr_skey=%d wr_rt=%d jar_items=%d has_login=%s",
    before.skey, before.rt, before.names, tostring(before.login)))
step(before.rt > 0, "wr_rt 已落盘（免扫码续期的唯一凭据）", "len=" .. before.rt)
step(before.skey >= Auth.RENEW_MIN_SKEY_LEN,
     "wr_skey 长度过门槛", before.skey .. "/" .. Auth.RENEW_MIN_SKEY_LEN)

------------------------------------------------------------------ 1. 分类结论

local status, err = Auth.renew(true)      -- force：绕开 600s 冷却，否则第二次只会回 cooling
print(string.format("renew(force) -> %s  (%s)", tostring(status), tostring(err)))
local ok_class = (status == "replaced" or status == "stale"
    or status == "network" or status == "expired")
step(ok_class, "renew 返回四态之一", status)
step(status ~= "no-refresh", "未回退成 no-refresh（wr_rt 缺失即本批修复回归）", status)
step(status ~= "cooling", "force 绕开冷却生效", status)

------------------------------------------------------------------ 2. 落盘纪律

local after = fingerprint(Api.load_auth())
print(string.format("after:  wr_skey=%d wr_rt=%d jar_items=%d has_login=%s",
    after.skey, after.rt, after.names, tostring(after.login)))

-- 核心不变量：无论续期结论如何，测试结束后会话必须还活着（否则就要重扫 = 事故）。
step(after.login, "续期后会话仍可用（绝不把登录态弄丢）", "has_login=" .. tostring(after.login))
step(after.rt > 0, "续期后 wr_rt 仍在", "len=" .. after.rt)

-- 失败/未知分支必须逐字节不动盘（插件语义：network/stale 不许清凭据）。
if status == "network" or status == "no-refresh" or status == "cooling" then
    step(after.header == before.header,
        tostring(status) .. " 分支未改写凭据",
        "header changed=" .. tostring(after.header ~= before.header))
elseif status == "expired" then
    -- expired 按设计只是「判定需要重扫」，同样不许它自己删凭据。
    step(after.header == before.header, "expired 分支也未删凭据（重扫交给人工决定）")
    print("  注意：classify_renewal 判 expired —— 不要自动扫码，报告用户由其决定。")
else
    -- 成功分支只断言「轮换后仍是可用会话」。**不断言值必须变化**：真机实测
    -- /web/login/renewal 常常把同一个 wr_skey 原样发回来（2026-11-19 探测：
    -- succ=1 且 wr_skey unchanged=true），拿「有没有变」当判据会造假 FAIL。
    step(after.skey >= Auth.RENEW_MIN_SKEY_LEN,
        tostring(status) .. " 分支：轮换后 wr_skey 仍可用", "len=" .. after.skey)
    print("  header changed=" .. tostring(after.header ~= before.header)
        .. "（false 不代表续期失败，服务端可原样发回同一 key）")
end

------------------------------------------------------------------ 3. 冷却真的生效

local second = Auth.renew()              -- 不带 force：紧接着的第二次必须被冷却挡住
step(second == "cooling", "不带 force 的第二次续期被冷却挡住（不打成心跳）",
     tostring(second))

------------------------------------------------------------------ 4. 续期后会话真能用（绕开缓存）

local shelf = Api.get_shelf()
local book = shelf and shelf.books and shelf.books[1]
if step(type(book) == "table", "书架可取（正文验证需要一本书）", book and book.title) then
    local chapters = Download.fetch_catalog(book.bookId)
    if step(type(chapters) == "table" and #chapters > 0, "目录可取", "#" .. tostring(#chapters)) then
        local sess = Download.new_session()
        local psvts, perr = Download.fetch_psvts(book.bookId)
        sess.tried, sess.psvts, sess.perr = true, psvts, perr
        if step(psvts ~= nil, "psvts 可取（正文签名参数）", perr) then
            local idx = math.min(3, #chapters)          -- 第 1 章常是短引子，取第 3 章更有代表性
            local ch = chapters[idx]
            local text, terr = Download.fetch_chapter_text(book.bookId, ch.chapterUid, psvts)
            local title_len = #(tostring(ch.title))
            print(string.format("  ch[%s] %s body_bytes=%s",
                tostring(ch.chapterIdx), tostring(ch.title),
                tostring(text and #text or 0)))
            step(text ~= nil and #text > title_len + 8,
                 "续期后取到真实正文（非标题级空分片）",
                 text and ("bytes=" .. #text .. " > title+8=" .. (title_len + 8))
                      or tostring(terr))
        end
    end
end

print(string.format("renew smoke: %d failure(s)", fails))
os.exit(fails == 0 and 0 or 1)
