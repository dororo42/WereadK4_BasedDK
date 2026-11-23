-- auth.lua — 微信读书扫码登录（K4 屏上显示二维码）。
--
-- 流程移植自 weread_K4.koplugin weread/lib/qr_login.lua（v9.x gateway 模式）：
--   预热 skills 页(wr_fp 设备身份) → getLoginUid → 本地 QR（/web/confirm?uid=…）
--   → 0.5s 轮询 getLoginInfo → succeed: userInfo → apikeyGet(3 重试) → 存 auth.json
-- 登录全程使用独立 cookie jar（wr_fp + 各步 Set-Cookie 合并），成功后才落盘
-- （与插件 login_cookies 语义一致；B5：wr_fp 隔离设备会话，避免互踢 -2012 类）。
-- QR 矩阵渲染：speedata/luaqrcode（vendored lib/qrencode.lua）+ fb 块绘制。
-- 前置条件（与插件一致）：账号需开通"微信读书 Skill"，否则 apikeyGet 返回 401/空。
-- 取消：轮询间隙按 Back/Menu/Home 退出。

local WeRead = require("protocol")
local Cookie = require("cookie")
local Json = require("json")
local Api = require("api")
local Fonts = require("fonts")

local Auth = {}

Auth.POLL_INTERVAL_MS = 500
Auth.POLL_TIMEOUT = 3
Auth.LOGIN_URL = Api.BASE_URL .. "/web/confirm?uid="
Auth.FP_PATH = "/mnt/us/weread/data/device_fp"

------------------------------------------------------------------ QR 渲染（暴露给 login.lua / menu.lua 复用）

-- URL → QR 矩阵。返回 ok, matrix | nil, err
function Auth.encode_qr(url)
    local q = dofile("/mnt/us/weread/lua/lib/qrencode.lua")
    local ok, matrix = q.qrcode(url)
    if not ok then return nil, tostring(matrix) end
    return matrix
end

-- 登录屏：白底 + freetype 标题 + 居中 QR + 提示行。需 fb 已开。
function Auth.draw_login_screen(url, title, hint)
    local matrix, err = Auth.encode_qr(url)
    if not matrix then return nil, err end
    local W, H = wr.fb_w(), wr.fb_h()
    local n = #matrix
    local quiet = 2
    local total = n + quiet * 2
    local block = math.floor(math.min(W, H) * 0.55 / total)
    local size = total * block
    local x0 = math.floor((W - size) / 2)
    local y0 = math.floor((H - size) / 2) + 20

    wr.fb_fill(0, 0, W, H, 0x00)
    if title and wr.font_load then
        pcall(function()
            local ft = Fonts.load(24)
            if ft then
                local w = wr.font_width(ft, title)
                wr.fb_text_ft(ft, math.floor((W - w) / 2), 30, title, 0xFF)
                wr.font_close(ft)
            end
        end)
    end
    for i = 1, n do
        for j = 1, n do
            if matrix[i][j] > 0 then
                wr.fb_fill(x0 + (j - 1 + quiet) * block, y0 + (i - 1 + quiet) * block,
                           block, block, 0x00)
            end
        end
    end
    if hint and wr.font_load then
        pcall(function()
            local ft = Fonts.load(16)
            if ft then
                local w = wr.font_width(ft, hint)
                wr.fb_text_ft(ft, math.floor((W - w) / 2), y0 + size + 16, hint, 0x40)
                wr.font_close(ft)
            end
        end)
    end
    wr.fb_quant()
    wr.fb_refresh(1)
    return x0, y0, size
end

-- 消息屏（成功/失败/提示）
function Auth.clear_screen(msg)
    local W, H = wr.fb_w(), wr.fb_h()
    wr.fb_fill(0, 0, W, H, 0x00)
    if wr.font_load then
        pcall(function()
            local ft = Fonts.load(30)
            if ft then
                local w = wr.font_width(ft, msg)
                wr.fb_text_ft(ft, math.floor((W - w) / 2), math.floor(H / 2) - 20, msg, 0xFF)
                wr.font_close(ft)
            end
        end)
    end
    wr.fb_quant()
    wr.fb_refresh(1)
end

------------------------------------------------------------------ 设备指纹（wr_fp，插件 B5 同款：urandom 4 字节 → 数字串，持久化）

function Auth.device_fingerprint()
    local f = io.open(Auth.FP_PATH, "r")
    if f then
        local v = f:read("*l")
        f:close()
        if v and v ~= "" then return v end
    end
    local fp = tostring(os.time()) .. tostring(math.random(1000, 9999))
    local fh = io.open("/dev/urandom", "rb")
    if fh then
        local data = fh:read(4)
        fh:close()
        if data and #data == 4 then
            local b1, b2, b3, b4 = data:byte(1, 4)
            fp = string.format("%.0f", b1 * 16777216 + b2 * 65536 + b3 * 256 + b4)
        end
    end
    local f2 = io.open(Auth.FP_PATH, "w")
    if f2 then f2:write(fp); f2:close() end
    return fp
end

------------------------------------------------------------------ 登录流程

local function new_jar()
    local jar = {}
    jar.wr_fp = Auth.device_fingerprint()
    return jar
end

-- 预热：GET skills 页（text/html），jar 收集 Set-Cookie（插件 B5）
local function preheat(jar)
    local body, status, resp_headers = wr.http_req({
        url = Api.SKILLS_PAGE_URL,
        headers = {
            ["User-Agent"] = WeRead.USER_AGENT,
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Referer"] = Api.BASE_URL .. "/",
            ["Cookie"] = Cookie.to_header(jar),
        },
        timeout = 20,
    })
    if resp_headers then
        local sc = resp_headers["set-cookie"]
        if sc then
            for line in sc:gmatch("[^\n]+") do
                jar = Cookie.merge_set_cookie(jar, line)
            end
        end
    end
    return jar, status
end

local function jar_request(jar, opts)
    opts = opts or {}
    -- Api.request 约定 auth 是 {cookies=…, api_key=…, account=…}；这里曾直接把
    -- 扁平 jar 当 auth 传入，于是 Api.request 的 `auth.cookies = merged` 在 jar
    -- 里写出了一个名为 "cookies" 的伪 cookie，并跟着 Cookie 头出站。
    opts.auth = { cookies = jar }
    opts.no_save = true                     -- 登录中途不落盘
    local data, status, resp_headers = Api.request(opts)
    if resp_headers and resp_headers["set-cookie"] then
        for line in resp_headers["set-cookie"]:gmatch("[^\n]+") do
            jar = Cookie.merge_set_cookie(jar, line)
        end
    end
    return data, status
end

-- 轮询一次。返回 "done" + 凭据表 | "expired" | "otp:<code>" | "waiting" | "timeout:<err>"
-- 凭据表带 refresh：它是唯一能免扫码续期的东西，丢了就得重扫二维码。
function Auth.poll_once(uid, jar)
    local url = Api.BASE_URL .. "/api/auth/getLoginInfo?uid="
        .. WeRead.urlencode(uid) .. "&otp="
    local data, err = jar_request(jar, {
        url = url,
        headers = { ["Referer"] = Api.SKILLS_PAGE_URL },
        timeout = Auth.POLL_TIMEOUT,
    })
    if not data then
        return "timeout:" .. tostring(err)   -- 网络抖动按 pending 处理（插件 U17-1）
    end
    if data.succeed == true or tonumber(data.succeed) == 1 then
        return "done", {
            vid = tostring(data.webLoginVid or ""),
            token = tostring(data.accessToken or ""),
            refresh = type(data.refreshToken) == "string" and data.refreshToken or "",
        }
    end
    local logic = tostring(data.logicCode or "")
    if logic == "LOGIN_TIMEOUT" then
        return "expired"
    elseif logic == "NEED_OTP" or logic == "OTP_NOT_MATCH" or logic == "OTP_EXPIRED" then
        return "otp:" .. logic
    end
    return "waiting"
end

-- 完整登录。返回 account 表 | nil, err
function Auth.login(display_cb, progress_cb)
    progress_cb = progress_cb or function() end

    -- 1) 预热 + 取 uid（独立 jar 全程携带）
    local jar = new_jar()
    jar = preheat(jar)

    local data, err = jar_request(jar, {
        url = Api.BASE_URL .. "/api/auth/getLoginUid",
        headers = { ["Referer"] = Api.SKILLS_PAGE_URL },
        timeout = 20,
    })
    if not data or type(data.uid) ~= "string" or data.uid == "" then
        return nil, "getLoginUid 失败: " .. tostring(err or (data and data.errCode))
    end
    local uid = data.uid

    -- 2) 显示 QR
    local login_url = Auth.LOGIN_URL .. WeRead.urlencode(uid)
    if display_cb then display_cb(login_url, uid) end

    -- 3) 轮询（Back 取消；过期自动重取 uid 重画）
    local deadline = os.time() + 300
    while os.time() < deadline do
        local r, cred = Auth.poll_once(uid, jar)
        if wr.input_open then
            local key = wr.input_poll(0, true)
            if key == "Back" or key == "Menu" or key == "Home" then
                return nil, "cancelled"
            end
        end
        if r == "expired" then
            data = jar_request(jar, {
                url = Api.BASE_URL .. "/api/auth/getLoginUid",
                headers = { ["Referer"] = Api.SKILLS_PAGE_URL },
                timeout = 20,
            })
            if data and type(data.uid) == "string" and data.uid ~= "" then
                uid = data.uid
                login_url = Auth.LOGIN_URL .. WeRead.urlencode(uid)
                if display_cb then display_cb(login_url, uid) end
                progress_cb("二维码已刷新")
            else
                return nil, "刷新二维码失败"
            end
        elseif r == "done" then
            local vid = cred and cred.vid or ""
            local token = cred and cred.token or ""
            if vid == "" or token == "" then
                return nil, "登录响应缺少凭据"
            end
            progress_cb("扫码成功，获取账号信息…")
            local account, cerr = Auth._complete(vid, token, jar, cred.refresh)
            if account then return account end
            if cerr == "no_apikey" then
                return nil, "未获取到 API Key：该账号未开通微信读书 Skill" ..
                    "（App → 我 → 设置 → 微信读书 Skill → 获取 API Key 后重扫）"
            end
            return nil, "登录完成但取账号信息失败"
        elseif type(r) == "string" and r:sub(1, 4) == "otp:" then
            return nil, "该账号需要短信验证码（K4 暂不支持输入）。" ..
                "请先在微信读书网页版登录一次本设备后再试。"
        end
        -- waiting / timeout → 继续轮
        local t0 = wr.millis()
        while wr.millis() - t0 < Auth.POLL_INTERVAL_MS do
            local k = wr.input_poll and wr.input_poll(50, true)
            if k == "Back" or k == "Menu" or k == "Home" then
                return nil, "cancelled"
            end
        end
    end
    return nil, "登录会话超时（5 分钟）"
end

-- 登录完成：userInfo → apikeyGet（全 jar + X-Vid/X-Skey）→ 落盘（插件 _complete_protocol 语义）
function Auth._complete(vid, token, jar, refresh_token)
    local auth_headers = {
        ["Referer"] = Api.SKILLS_PAGE_URL,
        ["X-Vid"] = vid,
        ["X-Skey"] = token,
    }

    local user_data = jar_request(jar, {
        url = Api.BASE_URL .. "/api/userInfo?userVid=" .. WeRead.urlencode(vid),
        headers = auth_headers,
        timeout = 20,
    })
    if not user_data then return nil end

    local api_key = ""
    for attempt = 1, 3 do
        local api_data = jar_request(jar, {
            url = Api.BASE_URL .. "/api/skills/apikeyGet?only_show=1",
            headers = auth_headers,
            timeout = 20,
        })
        if api_data and type(api_data.apikey) == "string" and api_data.apikey ~= "" then
            api_key = api_data.apikey
            break
        end
        local t0 = os.time()
        while os.time() - t0 < 1 do end
    end
    if api_key == "" then return nil, "no_apikey" end

    -- jar + 凭据落盘（新 jar 起底，防旧账号泄漏——插件同款）
    local store = Api.load_auth()
    store.cookies = Cookie.sanitize(jar)
    store.cookies.wr_vid = vid
    store.cookies.wr_skey = token
    store.cookies.wr_ql = "0"
    store.cookies.wr_ticket = nil
    store.cookies.wr_wrpa = nil
    -- refreshToken → wr_rt：/web/login/renewal 靠它换回 wr_skey。
    -- 此前这里把它丢了 → web 会话一过期就只能重扫二维码（风控风险）。
    if type(refresh_token) == "string" and refresh_token ~= "" then
        store.cookies.wr_rt = WeRead.urlencode(refresh_token)
    end
    store.api_key = api_key
    store.account = {
        name = type(user_data.name) == "string" and user_data.name or "",
        user_vid = vid,
        login_method = "qr",
        login_time = os.time(),
    }
    Api.save_auth(store)
    return store.account
end

------------------------------------------------------------------ 会话续期（免扫码）

Auth.RENEW_COOLDOWN_S = 600       -- 插件同款冷却：被动续期，不打成心跳
-- 可用 skey 的门槛必须与 Cookie.has_login_cookie 一致，否则健康的续期会被判死。
-- 插件用 16，但真机实测（2026-11-19 K4）登录态与 /web/login/renewal 轮换回来的
-- wr_skey 都是 8 字符——照搬 16 会让每次成功续期都误报 expired。
Auth.RENEW_MIN_SKEY_LEN = 8

-- 纯分类器：把一次 renewal 响应折成四态，任何「删凭据」的决定都不在这里发生。
-- 插件 client.lua:692-710 的语义：只有真 expired 才允许要求重扫，network/stale
-- 必须原样保留当前凭据。
function Auth.classify_renewal(r)
    if not r.reached then
        return "network"                       -- 超时/DNS/reset：凭据状态未知
    end
    local skey = r.new_skey
    local skey_usable = type(skey) == "string" and #skey >= Auth.RENEW_MIN_SKEY_LEN
    if r.http_status and (r.http_status == 401 or r.http_status == 403) then
        return "expired"                       -- 服务端直接拒绝凭据
    end
    if r.succ then
        -- succ=1 但没拿到可用 skey：这是"续期成功"的假象，会话其实已经死了。
        return skey_usable and "replaced" or "expired"
    end
    if skey_usable then
        return "stale"                         -- 有可用替换 key：收下，退避，别重扫
    end
    return "expired"
end

local last_renew_attempt = 0

-- 最近一次续期/探测结论（状态栏数据源；进程内缓存，真实网络操作发生时自动更新）。
-- "replaced"/"stale"=在线 "expired"=登录失效 "network"=无网络 nil=未检测。
Auth.last_renew_result = nil

-- 主菜单状态行（不触网）：登录态 + 最近续期结论 → 展示标签。
function Auth.status()
    if not Api.has_login() then return "未登录" end
    if Auth.last_renew_result == "replaced" or Auth.last_renew_result == "stale" then
        return "在线"
    elseif Auth.last_renew_result == "expired" then
        return "离线·登录失效"
    elseif Auth.last_renew_result == "network" then
        return "离线·无网络"
    end
    return "已登录"
end

-- 退出账号：auth.json 改名保留（.bak-logout-<ts>，误退可恢复）。设备指纹、阅读
-- 进度、已下载内容都不动——退出只清登录态。成功判据是「退出后判为未登录」：
-- os.execute 的返回值口径在 Lua 5.1/LuaJIT 间不一致，不作依据。
function Auth.logout()
    os.execute("mv '" .. Api.AUTH_PATH .. "' '" .. Api.AUTH_PATH
        .. ".bak-logout-" .. tostring(os.time()) .. "' 2>/dev/null")
    Auth.last_renew_result = nil
    return not Api.has_login(), Api.AUTH_PATH
end

-- 用 wr_rt 换新的 wr_skey。返回 status（见 classify_renewal）+ 错误串。
-- 落盘纪律：先判成功，再改副本，最后原子替换——失败响应一律不触盘。
function Auth.renew(force)
    local now = os.time()
    if not force and now - last_renew_attempt < Auth.RENEW_COOLDOWN_S then
        return "cooling"
    end
    Auth.last_renew_result = nil        -- 发起真探测：清掉旧结论，失败路径不再残留"在线"
    last_renew_attempt = now

    local auth = Api.load_auth()
    local jar = Cookie.sanitize(auth.cookies)
    if type(jar.wr_rt) ~= "string" or jar.wr_rt == "" then
        return "no-refresh"                    -- 老 auth.json 没存 refreshToken
    end

    local body, status, resp_headers = wr.http_req({
        url = "https://weread.qq.com/web/login/renewal",
        method = "POST",
        headers = {
            ["User-Agent"] = WeRead.USER_AGENT,
            ["Accept"] = "application/json, text/plain, */*",
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
            ["Referer"] = "https://weread.qq.com/",
            ["Cookie"] = Cookie.to_header(jar),
        },
        body = Json.encode({ rq = "%2Fweb%2Fbook%2Fread", ql = false }),
        timeout = 20,
    })

    local reached = body ~= nil
    local data = nil
    if reached and body ~= "" then
        data = Json.decode(body)
    end
    local sc = resp_headers and resp_headers["set-cookie"]
    local fresh = {}
    if sc and sc ~= "" then
        for line in sc:gmatch("[^\n]+") do
            fresh = Cookie.merge_set_cookie(fresh, line)
        end
    end

    local result = Auth.classify_renewal({
        reached = reached,
        http_status = status,
        succ = data ~= nil and WeRead.is_success_response(data) or false,
        new_skey = fresh.wr_skey,
    })
    if result ~= "cooling" then Auth.last_renew_result = result end

    if result == "replaced" or result == "stale" then
        -- 只增量收紧：新 key 覆盖同名项，其余保留；sanitize 兜住条目名。
        for name, value in pairs(fresh) do
            if Cookie.is_session_name(name) then
                jar[name] = value
            end
        end
        auth.cookies = Cookie.sanitize(jar)
        Api.save_auth(auth)
    end
    -- network / expired：什么都没改，磁盘上的凭据原样保留。
    return result, reached and (data and tostring(data.errCode or data.errMsg) or "no-json")
        or tostring(status)
end

return Auth
