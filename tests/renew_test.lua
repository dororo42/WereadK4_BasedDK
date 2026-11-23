-- tests/renew_test.lua — 续期四态分类器（纯逻辑，主机可跑）。
-- 要害：只有真 expired 才可能要求重扫二维码；network/stale 必须保住现有凭据。
package.path = "src/lua/?.lua;" .. package.path

-- auth.lua 顶层 require 这些模块；主机上没有 wr.* C 绑定，但分类器不碰 wr，
-- 只要加载期不触发即可。protocol/api 在加载期只定义函数与播种 random。
local Auth = require("auth")

local fails = 0
local function check(cond, name, detail)
    if not cond then
        fails = fails + 1
        print("  FAIL " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end

local MIN = Auth.RENEW_MIN_SKEY_LEN
local long_key = string.rep("k", MIN)
local short_key = string.rep("k", MIN - 1)

-- 1) 传输层失败 → network（凭据未知，不许动）
check(Auth.classify_renewal({ reached = false }) == "network", "transport failure is network")
check(Auth.classify_renewal({ reached = false, http_status = 500 }) == "network",
    "transport failure outranks any status")

-- 2) 401/403 → expired（服务端直接拒绝凭据，唯一合理的重扫场景）
check(Auth.classify_renewal({ reached = true, http_status = 401 }) == "expired", "401 is expired")
check(Auth.classify_renewal({ reached = true, http_status = 403,
    new_skey = long_key }) == "expired", "403 is expired even with a key")

-- 3) succ=1 + 可用 skey → replaced
check(Auth.classify_renewal({ reached = true, http_status = 200, succ = true,
    new_skey = long_key }) == "replaced", "succ + usable key is replaced")

-- 4) succ=1 + 短/缺 skey → expired（插件在 K5 真机踩到的假阳性：UI 报已续期而会话已死）
check(Auth.classify_renewal({ reached = true, http_status = 200, succ = true,
    new_skey = short_key }) == "expired", "succ + stub skey must NOT report replaced")
check(Auth.classify_renewal({ reached = true, http_status = 200, succ = true }) == "expired",
    "succ + no skey must NOT report replaced")

-- 5) 非成功但有可用替换 key → stale（收下、退避、不重扫）
check(Auth.classify_renewal({ reached = true, http_status = 200, succ = false,
    new_skey = long_key }) == "stale", "usable replacement key is stale")

-- 6) 非成功且无 key → expired
check(Auth.classify_renewal({ reached = true, http_status = 200, succ = false }) == "expired",
    "rejection without key is expired")
check(Auth.classify_renewal({ reached = true, http_status = 500, succ = false,
    new_skey = short_key }) == "expired", "server error without key is expired")

-- 7) 边界：恰好 MIN 长度算可用（差一字节就把好会话判死会白白烧掉一次扫码）
check(#long_key == MIN, "fixture is exactly MIN long")
check(Auth.classify_renewal({ reached = true, http_status = 200, succ = true,
    new_skey = long_key }) == "replaced", "MIN-length key accepted")
check(#short_key == MIN - 1, "short fixture is MIN-1")

-- 7b) 门槛同源性：续期可用判定与 has_login_cookie 必须同一把尺子。
-- 真机 wr_skey 是 8 字符；若这里比 has_login_cookie 严，健康的续期会被判 expired，
-- 白烧掉一次成功续期（插件用 16，本机实测会全线误报）。
local Cookie = require("cookie")
check(Cookie.has_login_cookie({ wr_skey = long_key }),
    "RENEW_MIN_SKEY_LEN key also satisfies has_login_cookie")
check(Cookie.has_login_cookie({ wr_skey = short_key }) == false
      or Auth.classify_renewal({ reached = true, http_status = 200, succ = true,
                                 new_skey = short_key }) ~= "replaced",
    "the two thresholds never disagree in the direction that discards a live session")

-- 8) 幂等：同一响应重复分类结果一致（调用方会重试，分类器不能有记忆）
local r = { reached = true, http_status = 200, succ = true, new_skey = long_key }
check(Auth.classify_renewal(r) == Auth.classify_renewal(r), "classifier is pure")

-- 9) 冷却常量存在且合理（扫码有风控风险，续期不能打成心跳）
check(type(Auth.RENEW_COOLDOWN_S) == "number" and Auth.RENEW_COOLDOWN_S >= 300,
    "renewal cooldown is at least 5 minutes")

-- 10) Auth.status 语义（主菜单状态行数据源，不触网）
package.loaded.api = package.loaded.api or require("api")
local Api = require("api")
local saved_has_login = Api.has_login
Auth.last_renew_result = nil
Api.has_login = function() return false end
check(Auth.status() == "未登录", "无登录态必须显示未登录，实得 " .. Auth.status())
Api.has_login = function() return true end
check(Auth.status() == "已登录", "登录但未检测显示已登录，实得 " .. Auth.status())
Auth.last_renew_result = "replaced"
check(Auth.status() == "在线", "replaced 应显示在线，实得 " .. Auth.status())
Auth.last_renew_result = "stale"
check(Auth.status() == "在线", "stale 也算在线（凭据稍受限）")
Auth.last_renew_result = "expired"
check(Auth.status() == "离线·登录失效", "expired 显示离线·登录失效")
Auth.last_renew_result = "network"
check(Auth.status() == "离线·无网络", "network 显示离线·无网络")
Api.has_login = saved_has_login
Auth.last_renew_result = nil

-- 11) Auth.logout：auth.json 改名保留（.bak-logout-<ts>，误退可恢复），退出后必须
--     判为未登录（成功判据是事后状态，不是 os.execute 返回值——5.1/LuaJIT 口径不一）。
local saved_auth_path = Api.AUTH_PATH
local TDIR = "/tmp/wr_renew_logout_test_" .. tostring(os.time())
os.execute("mkdir -p '" .. TDIR .. "'")
local f = io.open(TDIR .. "/auth.json", "w")
f:write('{"cookies":{"wr_skey":"kkkkkkkk"},"api_key":"testkey","account":{"name":"t"}}')
f:close()
Api.AUTH_PATH = TDIR .. "/auth.json"
check(Api.has_login(), "fixture 必须先判为已登录（否则 logout 测的是空文件）")
local ok1 = Auth.logout()
check(ok1 == true, "退出应返回 true")
check(not Api.has_login(), "退出后必须判为未登录")
local p = io.popen("ls '" .. TDIR .. "'")
local listing = p and p:read("*a") or ""
if p then p:close() end
check(listing:find("auth%.json%.bak%-logout%-%d+", 1, false) ~= nil,
    "原凭据必须改名保留为 .bak-logout-<ts>，实得 " .. listing:gsub("\n", " "))
local ok2 = Auth.logout()
check(ok2 == true, "重复退出应幂等返回 true（文件已不在=已是未登录）")
check(not Api.has_login(), "重复退出后仍是未登录")
Api.AUTH_PATH = saved_auth_path
os.execute("rm -rf '" .. TDIR .. "'")

print("renew_test: " .. fails .. " failure(s)")
return fails
