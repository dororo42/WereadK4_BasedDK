-- net_smoke.lua — DK-2 TLS 冒烟：https GET 两个端点，验证 libcurl 复用链路。
-- 端点1：https://www.baidu.com（TLS 通用性基线）
-- 端点2：https://weread.qq.com/（业务目标域）
-- 无屏幕交互（纯网络+控制台），不依赖输入独占。

local targets = {
    "https://www.baidu.com/",
    "https://weread.qq.com/",
}

if not wr.http_get then
    print("net: http_get 未注册（静态变体? 需要 weread-dyn）")
    os.exit(1)
end

for _, url in ipairs(targets) do
    local body, status = wr.http_get(url)
    if body then
        print(string.format("OK  %s -> status=%d bytes=%d", url, status, #body))
    else
        print(string.format("FAIL %s -> %s", url, tostring(status)))
    end
end
print("net smoke done")
