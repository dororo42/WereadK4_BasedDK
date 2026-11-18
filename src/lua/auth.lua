-- auth.lua — 微信读书扫码登录（K4 屏上显示二维码）。
--
-- 流程移植自 weread_K4.koplugin weread/lib/qr_login.lua（v9.x gateway 模式）：
--   getLoginUid → 本地 QR（/web/confirm?uid=…）→ 0.5s 轮询 getLoginInfo
--   → succeed: webLoginVid/accessToken → userInfo → apikeyGet(3 重试) → 存 auth.json
-- QR 矩阵渲染：speedata/luaqrcode（vendored lib/qrencode.lua）+ fb 块绘制。
-- 前置条件（与插件一致）：账号需开通"微信读书 Skill"，否则 apikeyGet 返回空。
-- 取消：轮询间隙按 Back/Menu/Home 退出。

local WeRead = require("protocol")
local Cookie = require("cookie")
local Api = require("api")

local Auth = {}

local function shallow_copy(t)
    local r = {}
    for k, v in pairs(t or {}) do r[k] = v end
    return r
end

Auth.POLL_INTERVAL_MS = 500
Auth.POLL_TIMEOUT = 3          -- 单次 getLoginInfo 总超时（插件 2/3s 口径）
Auth.LOGIN_URL = Api.BASE_URL .. "/web/confirm?uid="

------------------------------------------------------------------ QR 渲染

-- 矩阵 ±1/±2 → 黑/白块，居中 + 标题 + 提示
local function draw_qr(matrix, title, hint)
    local W, H = wr.fb_w(), wr.fb_h()
    local n = #matrix
    local quiet = 2                              -- 二维码四周静区（模块数）
    local total = n + quiet * 2
    local block = math.floor(math.min(W, H) * 0.55 / total)
    local size = total * block
    local x0 = math.floor((W - size) / 2)
    local y0 = math.floor((H - size) / 2) + 20

    wr.fb_fill(0, 0, W, H, 0xFF)
    if title and wr.fb_w and pcall(function()
        local ft = wr.font_load("/mnt/us/weread/fonts/wqy-microhei.ttc", 30)
        if ft then
            local w = wr.font_width(ft, title)
            wr.fb_text_ft(ft, math.floor((W - w) / 2), 30, title, 0x00)
            wr.font_close(ft)
        end
    end) then
        -- freetype 标题成功
    else
        wr.fb_text(16, 30, "WeRead Login", 2, 0x00)
    end
    for i = 1, n do
        for j = 1, n do
            if matrix[i][j] > 0 then
                wr.fb_fill(x0 + (j - 1 + quiet) * block, y0 + (i - 1 + quiet) * block,
                           block, block, 0x00)
            end
        end
    end
    if hint and wr.fb_text_ft then
        local ft = wr.font_load("/mnt/us/weread/fonts/wqy-microhei.ttc", 20)
        if ft then
            local w = wr.font_width(ft, hint)
            wr.fb_text_ft(ft, math.floor((W - w) / 2), y0 + size + 16, hint, 0x40)
            wr.font_close(ft)
        end
    end
    wr.fb_quant()
    wr.fb_refresh(1)                             -- full：QR 变化大，闪一次干净
    return x0, y0, size
end

local function clear_screen(msg)
    local W, H = wr.fb_w(), wr.fb_h()
    wr.fb_fill(0, 0, W, H, 0xFF)
    pcall(function()
        local ft = wr.font_load("/mnt/us/weread/fonts/wqy-microhei.ttc", 30)
        if ft then wr.fb_text_ft(ft, 40, 200, msg, 0x00); wr.font_close(ft) end
    end)
    wr.fb_quant()
    wr.fb_refresh(1)
end

------------------------------------------------------------------ poll

-- 返回: "done" | "timeout" | "cancelled" | "error:<msg>"
function Auth.poll_once(uid)
    local url = Api.BASE_URL .. "/api/auth/getLoginInfo?uid="
        .. WeRead.urlencode(uid) .. "&otp="
    local data, err = Api.request({
        url = url,
        headers = { ["Referer"] = Api.SKILLS_PAGE_URL },
        timeout = Auth.POLL_TIMEOUT,
    })
    if not data then
        -- 网络抖动按 pending 处理，继续轮询（插件 U17-1 同款）
        return "timeout:" .. tostring(err)
    end
    if data.succeed == true then
        return "done:" .. tostring(data.webLoginVid or "") .. ":" .. tostring(data.accessToken or "")
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
    local auth = Api.load_auth()

    progress_cb = progress_cb or function() end

    -- 1) 取 uid
    local data, err = Api.request({
        url = Api.BASE_URL .. "/api/auth/getLoginUid",
        headers = { ["Referer"] = Api.SKILLS_PAGE_URL },
        timeout = 20,
    })
    if not data or type(data.uid) ~= "string" or data.uid == "" then
        return nil, "getLoginUid 失败: " .. tostring(err or (data and data.errCode))
    end
    local uid = data.uid

    -- 2) 显示 QR（调用方负责屏；无 fb 时 display_cb=nil 跳过绘制）
    local login_url = Auth.LOGIN_URL .. WeRead.urlencode(uid)
    if display_cb then display_cb(login_url, uid) end

    -- 3) 轮询（Back 取消；过期自动重取 uid 重画）
    local deadline = os.time() + 300            -- 5 分钟登录会话
    while os.time() < deadline do
        local r = Auth.poll_once(uid)
        if wr.input_open then
            local key = wr.input_poll(0, true)  -- 非阻塞查取消键
            if key == "Back" or key == "Menu" or key == "Home" then
                return nil, "cancelled"
            end
        end
        if r == "expired" then
            data = Api.request({
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
        elseif type(r) == "string" and r:sub(1, 5) == "done:" then
            local vid = r:match("^done:([^:]+):")
            local token = r:match("^done:[^:]+:(.+)$")
            if not vid or vid == "" or not token or token == "" then
                return nil, "登录响应缺少凭据"
            end
            progress_cb("扫码成功，获取账号信息…")
            local account, cerr = Auth._complete(vid, token, auth)
            if account then return account end
            if cerr == "no_apikey" then
                return nil, "未获取到 API Key：该账号未开通微信读书 Skill" ..
                    "（App → 我 → 设置 → 微信读书 Skill → 获取 API Key 后重扫）"
            end
            return nil, "登录完成但取账号信息失败"
        elseif type(r) == "string" and r:sub(1, 4) == "otp:" then
            return nil, "该账号需要短信验证码（K4 暂不支持输入）。" ..
                "请先在微信读书网页版登录一次本设备后再试，或联系项目侧开放该能力。"
        elseif type(r) == "string" and r:sub(1, 6) == "error:" then
            return nil, r:sub(7)
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

-- 登录完成：userInfo → apikeyGet → 存盘（插件 _complete_protocol 同款语义）
function Auth._complete(vid, token, auth)
    local cookies = shallow_copy(auth.cookies)

    local user_data = Api.authenticated_get(
        Api.BASE_URL .. "/api/userInfo?userVid=" .. WeRead.urlencode(vid),
        vid, token, "userInfo")
    if not user_data then return nil end

    local api_key = ""
    for attempt = 1, 3 do
        local api_data = Api.authenticated_get(
            Api.BASE_URL .. "/api/skills/apikeyGet?only_show=1",
            vid, token, "apikeyGet")
        if api_data and type(api_data.apikey) == "string" and api_data.apikey ~= "" then
            api_key = api_data.apikey
            break
        end
        local t0 = os.time()
        while os.time() - t0 < 1 do end         -- 0.5~1s 重试间隔
    end
    if api_key == "" then return nil, "no_apikey" end

    auth.cookies = cookies
    auth.cookies.wr_vid = vid
    auth.cookies.wr_skey = token
    auth.cookies.wr_ql = "0"
    auth.cookies.wr_ticket = nil
    auth.cookies.wr_wrpa = nil
    auth.api_key = api_key
    auth.account = {
        name = type(user_data.name) == "string" and user_data.name or "",
        user_vid = vid,
        login_method = "qr",
        login_time = os.time(),
    }
    Api.save_auth(auth)
    return auth.account
end

return Auth
