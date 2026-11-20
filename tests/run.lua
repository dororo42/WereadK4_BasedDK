-- 主机侧 Lua 单测 runner（lua5.1）：make host-lua-test，须在仓库根目录执行。
-- 只收无设备依赖的纯逻辑模块：主机上不存在 wr.* C 绑定，模块「加载期」不调用
-- wr 才可以进来（函数体内调用无妨，单测不走那些路径）。
package.path = "src/lua/lib/?.lua;src/lua/?.lua;tests/?.lua;" .. package.path

math.randomseed(os.time())

local suites = {
    "progress_test",
    "download_pure_test",
    "reader_keys_test",
    "cookie_test",
    "renew_test",
    "report_position_test",
    "report_retry_test",
    "position_golden_test",
    "api_jar_test",
    "crypto_test",
    "wrap_test",
    "html_text_test",
    "config_test",
    "shelf_recent_test",
    "fonts_test",
    "download_batch_test",
    "sync_test",
    "shelf_ui_test",
    "reader_layout_test",
    "menu_ui_test",
}

local total = 0
for _, name in ipairs(suites) do
    local path = "tests/" .. name .. ".lua"
    local chunk, lerr = loadfile(path)
    if not chunk then
        print("LOAD-FAIL " .. path .. ": " .. tostring(lerr))
        total = total + 1
    else
        local ok, res = pcall(chunk)
        if not ok then
            print("RUN-FAIL " .. name .. ": " .. tostring(res))
            total = total + 1
        elseif type(res) ~= "number" then
            print("BAD-RETURN " .. name .. ": 单测须返回失败计数(number)")
            total = total + 1
        else
            total = total + res
        end
    end
end

if total == 0 then
    print("LUA-TESTS-OK (" .. #suites .. " suite(s))")
else
    print("LUA-TESTS-FAIL: " .. total .. " failure(s)")
end
os.exit(total == 0 and 0 or 1)
