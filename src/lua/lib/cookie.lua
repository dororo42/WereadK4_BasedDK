-- cookie.lua — 移植自 weread_K4.koplugin weread/lib/cookie.lua（cookie 合并/持久化语义）
local Cookie = {}

-- 会话 jar 只承认这两类名字：wr_* 与显式白名单。插件 credential_store
-- 的加载期复校同款纪律——解析噪声/第三方 cookie 一律进不了 jar。
Cookie.ALLOWED_NAMES = { ptcz = true, RK = true, pgv_pvid = true }

function Cookie.is_session_name(name)
    if type(name) ~= "string" then
        return false
    end
    if name:match("^wr_[%w_]+$") then
        return true
    end
    return Cookie.ALLOWED_NAMES[name] == true
end

-- 丢弃非法条目。幂等：合法 jar 过一遍逐字节不变。
function Cookie.sanitize(cookies)
    local clean = {}
    for name, value in pairs(cookies or {}) do
        if Cookie.is_session_name(name)
           and type(value) == "string" and #value > 0 and #value <= 4096
           and not value:find(";") and not value:find("[%c]") then
            clean[name] = value
        end
    end
    return clean
end

function Cookie.to_header(cookies)
    local parts = {}
    for key, value in pairs(cookies or {}) do
        -- Strip control characters from both key and value to prevent CRLF
        -- header injection (L-1 fix; S-08: the key was previously trusted).
        local safe_key = tostring(key or ""):gsub("[%c]", "")
        local safe_value = tostring(value or ""):gsub("[%c]", "")
        table.insert(parts, safe_key .. "=" .. safe_value)
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

function Cookie.merge(cookies, updates)
    local merged = {}
    for key, value in pairs(cookies or {}) do
        merged[key] = value
    end
    for key, value in pairs(updates or {}) do
        merged[key] = value
    end
    return merged
end

function Cookie.merge_set_cookie(cookies, set_cookie)
    if not set_cookie or set_cookie == "" then
        return cookies
    end
    cookies = cookies or {}
    if type(set_cookie) == "table" then
        for _, value in pairs(set_cookie) do
            Cookie.merge_set_cookie(cookies, value)
        end
        return cookies
    end
    for name, value in set_cookie:gmatch("([%w_]+)=([^;,\r\n]*)") do
        if Cookie.is_session_name(name) then
            if value == "" then
                cookies[name] = nil
            else
                -- Enforce cookie count and value size limits (L-6 fix)
                local count = 0
                for _ in pairs(cookies) do count = count + 1 end
                if count < 32 and #value <= 4096 then
                    cookies[name] = value
                end
            end
        end
    end
    return cookies
end

-- jar 是否等价（条目名 + 值逐项相同）。用途：Api.request 只在会话**真的变了**时才写盘——
-- 每个 2xx 响应都重写 auth.json 既磨闪存，又让「谁在什么时候改了凭据」无从回答。
function Cookie.equal(a, b)
    local left, right = a or {}, b or {}
    for name, value in pairs(left) do
        if right[name] ~= value then return false end
    end
    for name, value in pairs(right) do
        if left[name] ~= value then return false end
    end
    return true
end

function Cookie.has_login_cookie(cookies)
    -- Modern WeRead uses wr_gid instead of wr_skey; fall back to wr_gid as the login credential.
    if cookies and type(cookies.wr_skey) == "string" and #cookies.wr_skey >= 8 then
        return true
    end
    return cookies and type(cookies.wr_gid) == "string" and #cookies.wr_gid >= 5
end

return Cookie
