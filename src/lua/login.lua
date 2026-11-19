-- login.lua — 登录正式入口：屏上 QR + 轮询 + 成功验证。
-- 用法: weread-dyn lua/login.lua
-- 成功后立即拉书架验证登录态，结果写控制台（后台运行时看 data/login.log）。

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path

local Api = require("api")
local Auth = require("auth")

if Api.has_login() then
    local auth = Api.load_auth()
    print("already logged in: " .. tostring(auth.account.name or auth.account.user_vid))
    print("如需换号：删除 /mnt/us/weread/data/auth.json 后重跑")
    os.exit(0)
end

assert(wr.fb_open(), "fb_open failed")
assert(wr.input_open(), "input_open failed")   -- 轮询期间 Back 取消

local account, err = Auth.login(
    function(url)                              -- display_cb：画 QR
        local ok = Auth.draw_login_screen(url, "微信扫码登录", "手机微信扫码 · Back 取消")
        if not ok then print("qr draw failed") end
    end,
    function(msg)                              -- progress_cb
        Auth.clear_screen(msg)
    end
)

if account then
    Auth.clear_screen("登录成功: " .. tostring(account.name or account.user_vid))
    -- 登录态验证：拉书架
    local shelf, serr = Api.get_shelf()
    do
        local t0 = wr.millis()
        while wr.millis() - t0 < 1500 do end
    end
    if shelf and type(shelf.books) == "table" then
        Auth.clear_screen(string.format("书架验证 OK: %d 本书", #shelf.books))
        print("shelf verify OK: " .. #shelf.books .. " books")
    else
        print("shelf verify FAILED: " .. tostring(serr or "empty"))
        Auth.clear_screen("登录 OK，书架拉取待查（看 log）")
    end
    local t0 = wr.millis()
    while wr.millis() - t0 < 2500 do end
else
    print("login failed: " .. tostring(err))
    if wr.fb_w() > 0 then Auth.clear_screen("登录未完成: " .. tostring(err):sub(1, 60)) end
end

wr.input_close()
wr.fb_close()
print("login done")
