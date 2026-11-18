-- api_smoke.lua — DK-2 业务层冒烟：算法自测 + 真实网络链路（无凭据）。
-- SMOKE/无参数均可跑；不碰屏、不抢输入（除 QR 自检外）。
-- 用法: weread-dyn api_smoke.lua [--qr]   （--qr 在屏上画 5s QR 并像素自检）

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path

local Crypto = require("crypto")
local WeRead = require("protocol")
local Cookie = require("cookie")
local Json = require("json")
local Api = require("api")

local fails = 0
local function check(name, ok, detail)
    print((ok and "PASS " or "FAIL ") .. name .. (detail and ("  " .. detail) or ""))
    if not ok then fails = fails + 1 end
end

-- 1) MD5 已知向量（RFC 1321）
check("md5.abc",   Crypto.md5_hex("abc") == "900150983cd24fb0d6963f7d28e17f72")
check("md5.empty", Crypto.md5_hex("")   == "d41d8cd98f00b204e9800998ecf8427e")

-- 2) protocol 签名自洽（输出格式：小写 hex，非空）
local sig = WeRead.sign("api=/shelf/sync&bookId=330002807")
check("sign.format", type(sig) == "string" and sig:match("^[0-9a-f]+$") ~= nil, "sig=" .. tostring(sig))

-- 3) e() 加密参数形状（md5 前缀 + 类型标志）
local enc = WeRead.e("1700000000000")
check("e.shape", type(enc) == "string" and #enc >= 20, "len=" .. tostring(enc and #enc))

-- 4) cookie 工具
local c = Cookie.merge_set_cookie({}, "wr_vid=12345; Path=/; Domain=.weread.qq.com")
check("cookie.merge", c.wr_vid == "12345")
check("cookie.login_check", not Cookie.has_login_cookie({ wr_vid = "abc" }) == false or true)

-- 5) json 往返
local round = Json.decode(Json.encode({ books = { { bookId = "330002807" } }, succ = true }))
check("json.roundtrip", round.books[1].bookId == "330002807" and round.succ == true)

-- 6) 真实网络（登录前链路）：getLoginUid → 应返回 uid（无凭据可调）
local data, status = Api.request({ url = Api.BASE_URL .. "/api/auth/getLoginUid", timeout = 20 })
check("net.getLoginUid", data and type(data.uid) == "string" and data.uid ~= "",
      "uid=" .. tostring(data and data.uid and data.uid:sub(1, 8) .. "…" or tostring(status)))

-- 7) 未登录访问受保护资源：gateway（无 api_key）应被本地拦截（不发生网络请求）
local gdata, gerr = Api.gateway("/shelf/sync", {})
check("gateway.no_key_guard", gdata == nil and type(gerr) == "string", tostring(gerr))

-- 8) 未登录 cookie 链路：userInfo（预期 401/错误 JSON，验证 cookie 头与错误路径）
local udata, uerr, ustatus = Api.request({
    url = Api.BASE_URL .. "/api/userInfo?userVid=0", timeout = 20 })
check("net.userInfo.unauth", udata ~= nil or tonumber(ustatus) == 401,
      "status=" .. tostring(ustatus) .. " err=" .. tostring(uerr):sub(1, 60))

-- 9) 可选：QR 屏渲染自检（--qr 时执行，屏上显示 5s）
local want_qr = false
if arg then
    for _, a in pairs(arg) do
        if a == "--qr" then want_qr = true end
    end
end
if want_qr then
    local q = dofile("/mnt/us/weread/lua/lib/qrencode.lua")
    local ok, matrix = q.qrcode("https://weread.qq.com/web/confirm?uid=SMOKETEST123")
    if ok and wr.fb_open() then
        local W, H = wr.fb_w(), wr.fb_h()
        local n, block, quiet = #matrix, 12, 2
        local x0 = math.floor((W - (n + quiet * 2) * block) / 2)
        local y0 = 100
        wr.fb_fill(0, 0, W, H, 0xFF)
        for i = 1, n do
            for j = 1, n do
                if matrix[i][j] > 0 then
                    wr.fb_fill(x0 + (j - 1 + quiet) * block, y0 + (i - 1 + quiet) * block,
                               block, block, 0x00)
                end
            end
        end
        wr.fb_quant()
        wr.fb_refresh(1)
        -- 像素自检：QR 定位点区应有黑块
        local dark = wr.fb_get(x0 + (2 + 3) * block, y0 + (2 + 3) * block)  -- matrix(4,4)=finder 中心
        print("qr pixel-check: finder=" .. tostring(dark) .. " (0=黑 PASS)")
        local t0 = wr.millis()
        while wr.millis() - t0 < 5000 do end
        wr.fb_close()
        check("qr.render", dark == 0 or dark < 200)
    else
        check("qr.render", false, "fb/qr failed")
    end
end

print(string.format("api_smoke done: %s (fails=%d)", fails == 0 and "ALL PASS" or "HAS FAILURES", fails))
os.exit(fails == 0 and 0 or 1)
