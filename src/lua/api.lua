-- api.lua — 微信读书 API 请求层。
--
-- 语义移植自 weread_K4.koplugin weread/lib/client.lua（2026-11 现行 gateway 模式）：
--  · 登录链路 = cookie 模式（/api/auth/*、/api/userInfo、/api/skills/apikeyGet）
--  · 数据链路 = gateway：POST i.weread.qq.com/api/agent/gateway，Bearer api_key
-- 底层 transport 换成本仓 net.c 的 wr.http_req（libcurl 复用多看 TLS 栈）。
-- cookie 持久化：/mnt/us/weread/data/auth.json。

local Cookie = require("cookie")
local WeRead = require("protocol")
local Json = require("json")

local Api = {}

Api.BASE_URL = "https://weread.qq.com"
Api.GATEWAY_URL = "https://i.weread.qq.com/api/agent/gateway"
Api.SKILLS_PAGE_URL = Api.BASE_URL .. "/r/weread-skills"
Api.AUTH_PATH = "/mnt/us/weread/data/auth.json"

------------------------------------------------------------------ auth store

function Api.load_auth()
    local f = io.open(Api.AUTH_PATH, "r")
    if not f then return { cookies = {}, api_key = "", account = {} } end
    local text = f:read("*a")
    f:close()
    local auth = Json.decode(text)
    if type(auth) ~= "table" then
        return { cookies = {}, api_key = "", account = {} }
    end
    auth.cookies = auth.cookies or {}
    auth.account = auth.account or {}
    return auth
end

function Api.save_auth(auth)
    -- 原子写（tmp + rename）统一由 Json.write_atomic 负责——避免掉电/kill 打断
    -- 致 auth.json 截断损坏 → 下次 Json.decode 失败 → load_auth 返回空 →
    -- 用户被登出需重扫（ub-mode：崩溃中途应结束于同一状态）。
    return Json.write_atomic(Api.AUTH_PATH, auth)
end

function Api.has_login(auth)
    auth = auth or Api.load_auth()
    return Cookie.has_login_cookie(auth.cookies) and (auth.api_key or "") ~= ""
end

------------------------------------------------------------------ headers

local function base_headers(extra)
    local h = {
        ["User-Agent"] = WeRead.USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*",
    }
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

-- resp_headers["set-cookie"] 可能是多行拼接（"\n" 分隔）→ 拆开逐条合并
local function merge_cookies(cookies, resp_headers)
    local sc = resp_headers and resp_headers["set-cookie"]
    if not sc or sc == "" then return cookies end
    for line in sc:gmatch("[^\n]+") do
        cookies = Cookie.merge_set_cookie(cookies, line)
    end
    return cookies
end

------------------------------------------------------------------ requests

-- Api.request{ url=, method=, headers=, body=, skip_cookie=, timeout= }
--   -> data(json), status, resp_headers | nil, err, status
function Api.request(opts)
    opts = opts or {}
    local auth = opts.auth or Api.load_auth()
    local headers = base_headers(opts.headers)
    local method = opts.method or (opts.body and "POST") or "GET"

    if not opts.skip_cookie then
        local ch = Cookie.to_header(auth.cookies)
        if ch ~= "" then headers["Cookie"] = ch end
    end

    local body, status, resp_headers = wr.http_req({
        url = opts.url,
        method = method,
        headers = headers,
        body = opts.body,
        timeout = opts.timeout or 30,
    })
    if not body then
        return nil, status, nil          -- status 位置承载错误串
    end

    auth.cookies = merge_cookies(auth.cookies, resp_headers)
    if not opts.no_save then
        Api.save_auth(auth)
    end

    if opts.raw then
        return body, status, resp_headers
    end
    local data, jerr = Json.decode(body)
    if data == nil and body ~= "" then
        return nil, "bad json: " .. tostring(jerr), status
    end
    return data, status, resp_headers
end

-- 登录完成后的认证 GET（X-Vid/X-Skey + cookie），401 重试 3 次（插件同款）
function Api.authenticated_get(url, vid, token, stage)
    local auth = Api.load_auth()
    local last_err, last_status
    for attempt = 1, 3 do
        local data, status, resp_headers = Api.request({
            url = url,
            headers = {
                ["Referer"] = Api.SKILLS_PAGE_URL,
                ["X-Vid"] = vid,
                ["X-Skey"] = token,
            },
            auth = auth,
            timeout = 20,
        })
        if data then
            auth.cookies = merge_cookies(auth.cookies, resp_headers)
            Api.save_auth(auth)
            return data, status
        end
        last_err, last_status = status, status
        if tostring(last_status):find("401", 1, true) == nil then
            break                        -- 仅 401 重试（插件语义）
        end
    end
    return nil, last_err or ("authenticated_get failed: " .. tostring(stage))
end

-- 数据 API 网关：POST gateway，Bearer api_key（skip_cookie，插件同款）
function Api.gateway(api_name, params, auth)
    auth = auth or Api.load_auth()
    if (auth.api_key or "") == "" then
        return nil, "api key 未配置（需先登录并开通微信读书 Skill）"
    end
    local payload = {
        api_name = api_name,
        skill_version = WeRead.SKILL_VERSION,
    }
    for k, v in pairs(params or {}) do payload[k] = v end
    local data, status = Api.request({
        url = Api.GATEWAY_URL,
        method = "POST",
        body = Json.encode(payload),
        skip_cookie = true,
        headers = {
            ["Authorization"] = "Bearer " .. auth.api_key,
        },
        auth = auth,
    })
    return data, status
end

-- 便捷封装（数据链路）
function Api.get_shelf()
    return Api.gateway("/shelf/sync", {})
end

function Api.get_book_info(book_id)
    return Api.gateway("/book/info", { bookId = book_id })
end

function Api.get_progress(book_id)
    return Api.gateway("/book/getprogress", { bookId = book_id })
end

return Api
