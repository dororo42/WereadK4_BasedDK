-- tests/cookie_test.lua — 会话 jar 的写入门禁（纯逻辑，主机可跑）。
-- 动机：真机上服务端一次匿名响应下发的空值把 wr_vid/wr_skey 清掉，导致必须重扫
-- 二维码。jar 只能被「登录 / 续期」这两条已校验路径改动，且条目名必须合法。
local Cookie = require("cookie")

local fails = 0
local function check(cond, name, detail)
    if not cond then
        fails = fails + 1
        print("  FAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end

-- 1) 名字门禁
check(Cookie.is_session_name("wr_skey"), "wr_skey is a session name")
check(Cookie.is_session_name("wr_rt"), "wr_rt is a session name")
check(Cookie.is_session_name("ptcz"), "ptcz whitelisted")
check(Cookie.is_session_name("RK"), "RK whitelisted")
check(Cookie.is_session_name("pgv_pvid"), "pgv_pvid whitelisted")
check(not Cookie.is_session_name("cookies"), "bare 'cookies' rejected")
check(not Cookie.is_session_name("PHPSESSID"), "third-party name rejected")
check(not Cookie.is_session_name("wr"), "bare 'wr' rejected")
check(not Cookie.is_session_name("wr_"), "empty suffix rejected")
check(not Cookie.is_session_name("wr_s-key"), "hyphenated name rejected")
check(not Cookie.is_session_name(nil), "nil rejected")
check(not Cookie.is_session_name(7), "number rejected")

-- 2) 非法条目清不掉合法条目；幂等
local jar = { wr_vid = "12345678", wr_skey = "abcdefgh", wr_rt = "rt-value",
              cookies = "noise", [""] = "empty-name" }
local clean = Cookie.sanitize(jar)
check(clean.wr_vid == "12345678", "sanitize keeps wr_vid")
check(clean.wr_skey == "abcdefgh", "sanitize keeps wr_skey")
check(clean.wr_rt == "rt-value", "sanitize keeps wr_rt")
check(clean.cookies == nil, "sanitize drops bogus 'cookies' entry")
check(Cookie.sanitize(clean).wr_skey == "abcdefgh", "sanitize stays valid on second pass")
local n1 = 0; for _ in pairs(clean) do n1 = n1 + 1 end
local n2 = 0; for _ in pairs(Cookie.sanitize(clean)) do n2 = n2 + 1 end
check(n1 == n2, "sanitize is idempotent", n1 .. " vs " .. n2)

-- 3) 值门禁：空值 / 含分号 / 控制字符都不进 jar
local function only(value)
    return Cookie.sanitize({ wr_skey = value }).wr_skey
end
check(only("ok-value") == "ok-value", "plain value kept")
check(only("") == nil, "empty value dropped")
check(only("a;b") == nil, "value with ';' dropped (would break Cookie header)")
check(only("a\nb") == nil, "value with newline dropped (CRLF injection surface)")
check(only(string.rep("x", 5000)) == nil, "oversized value dropped")

-- 4) merge_set_cookie 只写合法会话名，且保持「空值=删除」契约
local merged = Cookie.merge_set_cookie({}, "wr_skey=newkey12; Path=/; Domain=.weread.qq.com")
check(merged.wr_skey == "newkey12", "merge stores wr_skey")
check(merged.Path == nil, "merge ignores Path attribute")
check(merged.Domain == nil, "merge ignores Domain attribute")

local polluted = Cookie.merge_set_cookie({ wr_vid = "11112222" }, "cookies=junk; wr_skey=abcdef01")
check(polluted.cookies == nil, "merge refuses bogus 'cookies' name")
check(polluted.wr_skey == "abcdef01", "merge still takes valid cookie from same line")
check(polluted.wr_vid == "11112222", "merge preserves untouched session cookie")

local expired = Cookie.merge_set_cookie({ wr_skey = "abcdef01", wr_vid = "11112222" }, "wr_skey=; Max-Age=0")
check(expired.wr_skey == nil, "merge deletes on empty value (contract)")
check(expired.wr_vid == "11112222", "deletion is per-name, not jar-wide")

-- 5) 登录判定：8 字符门槛（短 skey = 死会话假阳性）
check(Cookie.has_login_cookie({ wr_skey = "abcdefgh" }), "8-char skey counts as logged in")
check(not Cookie.has_login_cookie({ wr_skey = "short" }), "sub-8-char skey is not a session")
check(not Cookie.has_login_cookie({}), "empty jar is not a session")
check(Cookie.has_login_cookie({ wr_gid = "12345" }), "wr_gid fallback works")

print("cookie_test: " .. fails .. " failure(s)")
return fails
