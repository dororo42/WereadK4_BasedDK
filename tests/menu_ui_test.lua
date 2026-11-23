-- menu.lua 的主机回环测：设置屏、快捷菜单下载分支、打开书本时的云端对位。
--
-- 为什么值得写：menu.lua 是无模块脚本，所有新逻辑都长在按键循环里，而设备 SMOKE
-- 只渲染一帧、**不进循环**——上一批三个真机缺陷（快捷菜单死键、下载汇总失真、
-- 书架 PAGE 未定义）全在这个盲区里。本套件把 wr.* 换成 mock、把外部模块换成桩，
-- 于是整个脚本能跑起来；_G 装 __index 拦截，"改名后遗留全局"当场报错。
--
-- 分工：Download.book 的取消/汇总语义在 download_batch_test.lua，percent 取舍在
-- sync_test.lua，fraction→页码在 reader_layout_test.lua。这里只钉 menu 自己的事：
-- 它拿哪条参数调谁、屏上出现哪句话、设置有没有落到 config.json。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

package.path = "src/lua/lib/?.lua;src/lua/?.lua;" .. package.path

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL menu_ui: " .. msg)
        fails = fails + 1
    end
end

------------------------------------------------------------------ 共享状态（必须先声明：
-- 下面的 mock/桩闭包引用它们，声明在后会变成全局引用，严格 _G 会当场拦下）
local queue = {}                  -- 阻塞按键脚本（队列空 → "Back"，循环必然收敛）
local poll0_key, poll0_used       -- input_poll(0) 专用通道：非阻塞轮询
local frames, cur_frame
local clock_ms = 5000
local calls = {}                  -- 各桩被怎么调的流水账
local font_fail = {}              -- path → true 表示 freetype 打不开
local dl_result                   -- 下一批 Download.book 的返回值覆盖 {chapters, err, stats}
local reader_ret                  -- 下一次 Reader.open 的返回值覆盖
local sync_remote_ret, sync_remote_err
local sync_target_ret, sync_target_err
local sync_side, sync_why
local last_book_id, last_rec

local function keys_of(t)
    local n = {}
    for k in pairs(t) do n[#n + 1] = tostring(k) end
    table.sort(n)
    return table.concat(n, ", ")
end
-- 严格桩：读到桩里没有的名字就报错，而不是静默 nil。静默 nil 会把"桩没跟 menu.lua
-- 同步"伪装成"菜单坏了"——缺字段在真机是死键，改名在真机是崩溃，两种真缺陷都会漏。
local function strict(t, what)
    return setmetatable(t, {
        __index = function(_, k)
            error(what .. " 桩里没有 ." .. tostring(k) .. "（可用: " .. keys_of(t) .. "）", 0)
        end,
    })
end

------------------------------------------------------------------ wr mock
wr = strict({
    fb_open = function() return true end,
    fb_close = function() end,
    fb_w = function() return 600 end,
    fb_h = function() return 800 end,
    fb_fill = function() end,
    fb_text = function(_x, _y, s) cur_frame[#cur_frame + 1] = tostring(s) end,
    fb_text_ft = function(_ft, _x, _y, s) cur_frame[#cur_frame + 1] = tostring(s) end,
    fb_get = function() return 255 end,
    fb_quant = function() frames[#frames + 1] = cur_frame; cur_frame = {} end,
    fb_refresh = function() end,
    font_load = function(path, px)
        calls[#calls + 1] = { f = "font_load", path = path, px = px }
        if font_fail[path] then return nil end
        return 1
    end,
    font_close = function() end,
    font_width = function(_, s) return #tostring(s) * 12 end,
    input_open = function() return true end,
    input_close = function() end,
    input_poll = function(timeout)
        if timeout == 0 then
            poll0_used = true
            return poll0_key
        end
        return table.remove(queue, 1) or "Back"
    end,
    -- 每次 +1ms：忙等（1500ms 提示停留）花 1500 次迭代收敛，测试里既不死锁也不改变
    -- 任何 3 秒量级的判断（下载限流步长是 1000ms，+1 是噪声级）。
    millis = function() clock_ms = clock_ms + 1; return clock_ms end,
    http_req = function() return nil, "not-in-test" end,
}, "wr")

local function capture()
    frames[#frames + 1] = cur_frame
    cur_frame = {}
end
local function all_text()
    local t = {}
    for _, f in ipairs(frames) do t[#t + 1] = table.concat(f, "|") end
    return table.concat(t, "||")
end
-- 最后一帧（状态翻转后的重绘主菜单）：缺席断言只能看它——all_text 会连开机时的
-- 旧帧一起算进去，登录态翻转前画过的名字永远在。
local function last_frame_text()
    return table.concat(frames[#frames] or {}, "|")
end
local function keys_of(t)
    local n = {}
    for k in pairs(t) do n[#n + 1] = tostring(k) end
    table.sort(n)
    return table.concat(n, ", ")
end
-- 严格桩：读到桩里没有的名字就报错，而不是静默 nil。静默 nil 会把"桩没跟 menu.lua
-- 同步"伪装成"菜单坏了"——缺字段在真机是死键，改名在真机是崩溃，两种真缺陷都会漏。
local function strict(t, what)
    return setmetatable(t, {
        __index = function(_, k)
            error(what .. " 桩里没有 ." .. tostring(k) .. "（可用: " .. keys_of(t) .. "）", 0)
        end,
    })
end

local function keys(...)
    queue = { ... }
end
local function call_of(name)
    for i = #calls, 1, -1 do
        if calls[i].f == name then return calls[i] end
    end
    return nil
end
local function count_of(name)
    local n = 0
    for _, c in ipairs(calls) do if c.f == name then n = n + 1 end end
    return n
end
-- 某次写盘之后发生了哪些 font_load（"设置立即生效"唯一的可观测量）
local function loads_after_write(key)
    local seen, n, sizes = false, 0, {}
    for _, c in ipairs(calls) do
        if c.f == "config_set" and c.key == key then
            seen = true
        elseif seen and c.f == "font_load" then
            n = n + 1
            sizes[#sizes + 1] = tostring(c.px)
        end
    end
    return n, table.concat(sizes, ",")
end
local function frames_matching(pattern)
    local n = 0
    for _, f in ipairs(frames) do
        for _, s in ipairs(f) do
            if s:find(pattern) then n = n + 1 end
        end
    end
    return n
end

------------------------------------------------------------------ 模块桩
local CFG = "/tmp/wr_menu_test_config.json"
local saved_loaded = {}
local function stub(name, tbl)
    saved_loaded[name] = package.loaded[name]
    package.loaded[name] = strict(tbl, name)
end

local CAT = {}
for i = 1, 8 do
    CAT[i] = { chapterUid = "u" .. i, chapterIdx = 9 + i, title = "第" .. i .. "章", wordCount = 200 }
end

os.remove(CFG)
local Config = require("config")
Config.PATH = CFG
local config_set_saved = Config.set
Config.set = function(key, v)                      -- 记录写盘时刻：字体换面必须发生在它之后
    calls[#calls + 1] = { f = "config_set", key = key }
    return config_set_saved(key, v)
end
frames, cur_frame = {}, {}
-- fonts 用真模块（这正是"只留一处字体决策"要验的东西），但取一份干净实例再改 probe：
-- 直接改共享表会把假 probe 漏给后面的测试。
package.loaded.fonts = nil
local Fonts = require("fonts")
Fonts.probe = function() return false end       -- 主机没有设备字体：清单只剩默认项
local DEFAULT_FONT = Fonts.DEFAULT

local api_logged_in = true          -- 必须先于引用它的桩声明（否则闭包捕获全局 nil）
stub("api", {
    has_login = function() return api_logged_in end,
    load_auth = function() return { account = { name = "测试号" }, cookies = {} } end,
    BASE_URL = "https://weread.qq.com",
    get_shelf = function() return { books = {} } end,
})
local auth_status_ret = "已登录"
local auth_login_ret, auth_logout_ret
stub("auth", {
    status = function() return auth_status_ret end,
    clear_screen = function(m)
        cur_frame[#cur_frame + 1] = "CLR:" .. tostring(m)
        capture()
    end,
    renew = function() return "cooling" end,
    draw_login_screen = function()
        calls[#calls + 1] = { f = "draw_login_screen" }
    end,
    login = function(draw_cb)
        calls[#calls + 1] = { f = "auth_login" }
        local r = auth_login_ret
        auth_login_ret = nil
        if r then
            api_logged_in = true               -- 登录成功 → 登录态翻转（设置项同位换标签）
            -- 真实现里出码回调由 Auth.login 在拿到 URL 时调；桩必须同样调它，
            -- 否则「屏上出码」永远测不到。
            if draw_cb then draw_cb("https://weread.qq.com/qr-in-test") end
            return r
        end
        return nil, "not-in-test"
    end,
    logout = function()
        calls[#calls + 1] = { f = "auth_logout" }
        local r = auth_logout_ret
        auth_logout_ret = nil
        if r ~= nil then return r end
        api_logged_in = false                  -- 退出成功 → 登录态翻转
        return true
    end,
})
stub("shelf", { run = function() calls[#calls + 1] = { f = "shelf" }; return "B77" end })
stub("downloaded", { browse = function() calls[#calls + 1] = { f = "dl_browse" } end })
stub("log", {
    errors = 0,
    info = function() end,
    error = function() end,
    debug = function() end,
    tail = function() return {} end,
    error_count = function() return 0 end,
})
stub("progress", {
    get_last = function() return last_book_id end,
    get = function() return last_rec end,
    set = function(_b, idx, page, _title, total_pages)
        calls[#calls + 1] = { f = "progress_set", idx = idx, page = page, total = total_pages }
        return true
    end,
})
stub("report", {
    send_reading = function(_o, secs) return math.ceil((secs or 0) / 30) end,
    send = function(o)
        calls[#calls + 1] = { f = "report_send", idx = o.chapter_idx, page = o.page }
        return { accepted = true, percent = 63 }
    end,
    -- 桩只回一个"看得懂"的百分比；断言打在 menu 传进来的参数上（不在此复制公式）。
    position_of = function(_chs, idx, page, total)
        calls[#calls + 1] = { f = "position_of", idx = idx, page = page, total = total }
        local pct = (page and total) and math.floor((page - 1) / total * 100 + 0.5) or nil
        return pct and { percent = pct } or nil, "no_position"
    end,
})
stub("download", {
    fetch_catalog = function(b)
        calls[#calls + 1] = { f = "fetch_catalog", book = b }
        return CAT
    end,
    find_chapter = function(chs, idx)
        for _, c in ipairs(chs) do if c.chapterIdx == idx then return c end end
    end,
    chapter_pos = function(chs, idx)
        for i, c in ipairs(chs) do if c.chapterIdx == idx then return i end end
    end,
    ensure_chapter = function() return "正文正文正文" end,
    new_session = function() return { psvts = "ps", pclts = "pc", token = "tk" } end,
    is_spooled = function() return false end,
    save_manifest = function(_b, _title, _chs) end,
    list_books = function() return {} end,
    asset_dir = function(_b, _uid) return "/tmp/stub_assets" end,
    book = function(_b, count, from, cb)
        calls[#calls + 1] = { f = "dl_book", count = count, from = from }
        if dl_result then
            local r = dl_result
            dl_result = nil
            return r[1], r[2], r[3]
        end
        local stats = { total = 3, done = 0, ok = 0, fail = 0, cancelled = false }
        for i = 1, 3 do
            stats.done, stats.ok = i, i
            if cb(i, 3, "第" .. i .. "章") == false then
                stats.cancelled = true
                break
            end
            clock_ms = clock_ms + 1000          -- 每章之间过 1 秒：喂给 menu 的 3s 限流
        end
        return CAT, nil, stats
    end,
})
stub("sync", {
    SAME_THRESHOLD_PERCENT = 2,
    remote = function(b)
        calls[#calls + 1] = { f = "sync_remote", book = b }
        return sync_remote_ret, sync_remote_err
    end,
    target = function()
        calls[#calls + 1] = { f = "sync_target" }
        return sync_target_ret, sync_target_err
    end,
    choose = function(_r, _t, local_pct, local_pos)
        calls[#calls + 1] = { f = "sync_choose", local_pct = local_pct, local_pos = local_pos }
        return sync_side, sync_why
    end,
})
stub("reader", {
    open = function(_body, title, start)
        calls[#calls + 1] = { f = "reader_open", start = start, title = title }
        local r = reader_ret
        reader_ret = nil
        return r or { page = 2, total_pages = 9, action = "exit" }
    end,
})

------------------------------------------------------------------ 严格全局
setmetatable(_G, {
    __index = function(_, k)
        error("undefined global read: " .. tostring(k), 0)
    end,
})

------------------------------------------------------------------ 跑菜单
local function run_menu()
    frames, cur_frame = {}, {}
    clock_ms = 5000
    poll0_used = false            -- poll0_key 由各用例在 reset_state 之后设置，别在这里清
    SMOKE = false
    local ok, err = pcall(loadfile("src/lua/menu.lua"))
    return ok, err
end

-- 复位每个用例的桩状态
local function reset_state()
    calls = {}
    sync_remote_ret, sync_remote_err = nil, "request failed: not-in-test"
    sync_target_ret, sync_target_err = nil, nil
    sync_side, sync_why = "local", "same"
    reader_ret, dl_result = nil, nil
    poll0_key = nil
    auth_status_ret = "已登录"
    api_logged_in = true
    auth_login_ret, auth_logout_ret = nil, nil
    last_book_id, last_rec = nil, nil
end
local function reading_state()
    last_book_id = "B77"
    last_rec = { chapter_idx = 10, page = 3, total_pages = 9 }
end

------------------------------------------------------------------ 用例
-- 1) 主菜单五项齐全（含曾被做成死项的「同步进度」）+ 账号名
reset_state()
keys("Back")
local ok, err = run_menu()
check(ok, "主菜单应跑通，实得 " .. tostring(err))
local txt = all_text()
for _, name in ipairs({ "继续阅读", "书架", "已下载", "设置", "退出" }) do
    check(txt:find(name, 1, true) ~= nil, "首屏应列出「" .. name .. "」，实得 " .. txt:sub(1, 120))
end
check(txt:find("测试号", 1, true) ~= nil, "首屏应显示账号名")
check(txt:find("已登录", 1, true) ~= nil, "页脚应显示账号状态（Auth.status）")
check(txt:match("%d%d%-%d%d %d%d:%d%d") ~= nil, "标题行右侧应有 MM-DD HH:MM 时钟")

-- 1a2) 登录失效态：菜单追加「扫码登录」（只在用户显式选择时才出码）
reset_state()
auth_status_ret = "离线·登录失效"
keys("Back")
ok, err = run_menu()
check(ok, "离线失效态应跑通，实得 " .. tostring(err))
txt = all_text()
check(txt:find("扫码登录", 1, true) ~= nil, "登录失效时必须提供扫码登录入口")
check(txt:find("离线·登录失效", 1, true) ~= nil, "页脚应如实显示离线·登录失效")
check(txt:find("已登录", 1, true) == nil, "失效态不得再显示「已登录」")

-- 1b) 检查连接入口：调 Auth.renew(true) 并如实回报结论
reset_state()
keys("Down", "Down", "Down", "Press",          -- 主菜单 → 设置
     "Down", "Down", "Down", "Down", "Down", "Down", "Down", "Press")  -- 检查连接（可选项第 8 = Down×7）
ok, err = run_menu()
check(ok, "检查连接应跑通，实得 " .. tostring(err))
check(all_text():find("正在检测连接", 1, true) ~= nil, "检测中应有过程提示")
check(all_text():find("检查连接: 状态未变（冷却中）", 1, true) ~= nil,
    "renew 结论应如实回报，实得 " .. all_text():sub(1, 200))

-- 2) 设置 → 字体：face 打不开时不得写配置（坏路径会让下次翻页无声降级）
reset_state()
keys("Down", "Down", "Down", "Press",         -- 主菜单 → 设置（第 4 项）
     "Down", "Down", "Down", "Down", "Press", -- 设置 → 字体（第 5 项）
     "Press")                                -- 值选择 → 唯一候选
font_fail[DEFAULT_FONT] = true
ok, err = run_menu()
font_fail[DEFAULT_FONT] = nil
check(ok, "字体设置路径应跑通，实得 " .. tostring(err))
check(all_text():find("字体打不开", 1, true) ~= nil,
    "打不开必须说清，实得 " .. all_text():sub(1, 200))
check(Config.load().font_path == nil, "打不开时不该把坏路径写进 config.json")
check(call_of("font_load") ~= nil, "选择时必须先在设备上开一次 face 验证")

-- 3) 设置 → 字体：能打开则落盘，且菜单自身立即换面（这一屏就是预览）
reset_state()
keys("Down", "Down", "Down", "Press", "Down", "Down", "Down", "Down", "Press", "Press")
ok, err = run_menu()
check(ok, "字体切换应跑通，实得 " .. tostring(err))
check(Config.load().font_path == DEFAULT_FONT,
    "打开成功必须落盘，实得 " .. tostring(Config.load().font_path))
check(all_text():find("已切换字体", 1, true) ~= nil, "切换成功要有回执")
local loads = count_of("font_load")
check(loads >= 5,
    "启动 2 面 + 验证 1 次 + 换面后主/小字重开 2 次 = 至少 5 次 font_load（菜单立即生效），实得 " .. loads)
local after, sizes = loads_after_write("font_path")
check(after >= 2 and sizes:find("24", 1, true) and sizes:find("16", 1, true),
    "写盘后必须重开主字(24)与小字(16)，否则这一屏不换面=死键，实得 " .. after .. " 次 [" .. sizes .. "]")

-- 4) 设置 → 云端进度=关：阅读时一个云端请求都不发（说不同步就别联网）
reset_state()
reading_state()
keys("Down", "Down", "Down", "Press",         -- 设置（第 4 项）
     "Down", "Down", "Down", "Down", "Down", "Press", -- 云端进度（第 7 项）→ 值选择
     "Down", "Press",                        -- 关
     "Back", "Back",                          -- 提示屏 + 退出设置
     "Press")                                 -- 继续阅读（第 1 项）
ok, err = run_menu()
check(ok, "关闭云端进度应跑通，实得 " .. tostring(err))
check(Config.load().progress_sync == false, "设置项必须存布尔 false，实得 "
    .. tostring(Config.load().progress_sync))
check(count_of("sync_remote") == 0,
    "云端进度=关 时不该调 Sync.remote，实得 " .. count_of("sync_remote") .. " 次")
check(count_of("reader_open") >= 1, "仍应正常进入阅读（同步只是附加步）")

-- 5) 继续阅读（同步开）：拉到云端位置 → Reader.open 收到 {fraction=}
Config.set("progress_sync", true)
reset_state()
reading_state()
sync_remote_ret = { chapter_uid = "u3", percent = 80 }
sync_target_ret = { chapter_idx = 12, pos = 3, fraction = 0.4, title = "第3章" }
sync_side, sync_why = "remote", "remote_ahead"
keys("Press")
ok, err = run_menu()
check(ok, "云端对位路径应跑通，实得 " .. tostring(err))
check(count_of("sync_remote") == 1, "打开书时应拉一次云端进度")
local po = call_of("position_of")
check(po and po.idx == 10 and po.page == 3 and po.total == 9,
    "本地百分比必须由记录的 chapter/page/total_pages 换算，实得 "
    .. string.format("%s/%s/%s", tostring(po and po.idx), tostring(po and po.page),
        tostring(po and po.total)))
check(call_of("sync_choose").local_pct == 22,
    "换算结果应交给判异（(3-1)/9≈22%），实得 " .. tostring(call_of("sync_choose").local_pct))
local ro = call_of("reader_open")
check(ro and type(ro.start) == "table" and ro.start.fraction == 0.4,
    "采用云端位置时起始位必须是 {fraction=0.4}，实得 "
    .. (ro and type(ro.start) or "nil"))
check(all_text():find("已同步到云端位置", 1, true) ~= nil,
    "跳转要有回执（静默跳页会让用户以为书坏了）")
local ps = call_of("progress_set")
check(ps and ps.total == 9, "本地进度必须带上 total_pages（下次判异的分母），实得 "
    .. tostring(ps and ps.total))

-- 6) 云端落后本地：留在本地页码，不许谎称已同步
Config.set("progress_sync", true)
reset_state()
reading_state()
sync_remote_ret = { chapter_uid = "u1", percent = 5 }
sync_target_ret = { chapter_idx = 10, pos = 1, fraction = 0.1, title = "第1章" }
sync_side, sync_why = "local", "local_ahead"
keys("Press")
ok, err = run_menu()
check(ok, "本地更靠前应跑通，实得 " .. tostring(err))
local ro2 = call_of("reader_open")
check(ro2 and ro2.start == 3,
    "不采用云端时必须用本地页码，实得 " .. tostring(ro2 and ro2.start))
check(all_text():find("已同步到云端位置", 1, true) == nil, "没跳转就不许说跳了")

-- 7) 「同步进度」入口 = 无视设置、强制拉一次并回报结果
Config.set("progress_sync", false)
reset_state()
reading_state()
sync_remote_ret = { chapter_uid = "u1", percent = 5 }
sync_target_ret = { chapter_idx = 10, pos = 1, fraction = 0.1, title = "第1章" }
sync_side, sync_why = "local", "same"
keys("Down", "Down", "Down", "Press",       -- 主菜单 → 设置（第 4 项）
     "Down", "Down", "Down", "Down", "Down", "Down", "Down", "Down", "Press",  -- 同步进度（可选项第 9 = Down×8）
     "Back")                                 -- 返回设置 → 主菜单 Back 退出
ok, err = run_menu()
check(ok, "同步进度入口应跑通，实得 " .. tostring(err))
check(count_of("sync_remote") == 1,
    "手动入口应无视设置拉一次，实得 " .. count_of("sync_remote") .. " 次")
txt = all_text()
check(txt:find("已选择") == nil, "同步进度不得退化成「已选择」打印")
check(txt:find("same") ~= nil, "手动同步必须回报判异结果，实得 " .. txt:sub(1, 200))
Config.set("progress_sync", true)

-- 7b) 「已下载」入口：中键进 Downloaded.browse（离线浏览，不触网）
reset_state()
keys("Down", "Down", "Press")               -- 第 3 项 → 已下载
ok, err = run_menu()
check(ok, "已下载入口应跑通，实得 " .. tostring(err))
check(count_of("dl_browse") == 1, "中键已下载必须进 Downloaded.browse")

-- 7c) 「运行状态」入口：状态屏（内存/堆/spool 占用/错误计数/app.log 尾部）
reset_state()
keys("Down", "Down", "Down", "Press",         -- 主菜单 → 设置
     "Down", "Down", "Down", "Down", "Down", "Down", "Down", "Down", "Down", "Press", -- 运行状态（可选项第 10 = Down×9）
     "Back", "Back")                            -- 状态屏任意键 → 设置返回 → 主菜单 Back 退出
ok, err = run_menu()
check(ok, "运行状态屏应跑通，实得 " .. tostring(err))
txt = all_text()
check(txt:find("运行状态", 1, true) ~= nil, "状态屏标题必须出现，实得 " .. txt:sub(1, 200))
check(txt:find("已下载: 0 本 / 0 章", 1, true) ~= nil, "spool 占用必须来自 Download.list_books")
check(txt:find("错误: 本次进程 0 / 累计 0", 1, true) ~= nil, "错误计数必须出现（Log.errors/累计）")
check(txt:find("app.log 尾部", 1, true) ~= nil, "log 尾部段落必须出现")

-- 8) 快捷菜单 → 下载全本：math.huge + 从第 1 章起；进度屏 3 秒限流；汇总来自 stats
reset_state()
reading_state()
reader_ret = { page = 3, total_pages = 9, action = "quickmenu" }
keys("Press", "Down", "Down", "Press")      -- 继续阅读 → 快捷菜单第 3 项
ok, err = run_menu()
check(ok, "下载全本应跑通，实得 " .. tostring(err))
local dl = call_of("dl_book")
check(dl and dl.count == math.huge and dl.from == 1,
    "全本 = 不设上限、从第 1 章起，实得 count=" .. tostring(dl and dl.count)
    .. " from=" .. tostring(dl and dl.from))
check(poll0_used, "取消必须用非阻塞轮询（阻塞轮询会把下载屏冻住）")
check(frames_matching("下载 %d/3") == 2,
    "3 章各隔 1 秒：全刷应只在首章与末章发生（2 次），实得 " .. frames_matching("下载 %d/3"))
check(all_text():find("成功 3 失败 0 / 共 3 章", 1, true) ~= nil,
    "汇总必须由 stats 出，实得 " .. (all_text():match("下载%a+: [^|]*") or "-"))

-- 9) 下载中按 Back：stats.cancelled → 文案必须说「已取消」，不得谎报完成
reset_state()
reading_state()
reader_ret = { page = 3, total_pages = 9, action = "quickmenu" }
poll0_key = "Back"
keys("Press", "Down", "Down", "Press")
ok, err = run_menu()
check(ok, "取消下载应跑通，实得 " .. tostring(err))
check(all_text():find("已取消", 1, true) ~= nil,
    "取消要如实回报，实得 " .. (all_text():match("已取消[^|]*") or "-"))

-- 10) 下载后面 5 章：起点是当前章之后一项
reset_state()
reading_state()
reader_ret = { page = 3, total_pages = 9, action = "quickmenu" }
keys("Press", "Down", "Down", "Down", "Press")   -- 快捷菜单第 4 项
ok, err = run_menu()
check(ok, "下载后 5 章应跑通，实得 " .. tostring(err))
dl = call_of("dl_book")
check(dl and dl.count == 5 and dl.from == 2,
    "后 5 章应从当前章（目录第 1 项）之后起，实得 count=" .. tostring(dl and dl.count)
    .. " from=" .. tostring(dl and dl.from))

-- 11) 已在最后一章：不许发起空下载，并说明原因
reset_state()
last_book_id = "B77"
last_rec = { chapter_idx = CAT[8].chapterIdx, page = 3, total_pages = 9 }
reader_ret = { page = 3, total_pages = 9, action = "quickmenu" }
keys("Press", "Down", "Down", "Down", "Press")
ok, err = run_menu()
check(ok, "末章下载分支应跑通，实得 " .. tostring(err))
check(count_of("dl_book") == 0,
    "末章时不该发起下载，实得发了 " .. count_of("dl_book") .. " 次")
check(all_text():find("已是最后一章", 1, true) ~= nil, "末章必须说明为什么没下")

-- 12) 下载目录失败：给原因，而不是"成功 0 失败 0"
reset_state()
reading_state()
reader_ret = { page = 3, total_pages = 9, action = "quickmenu" }
dl_result = { nil, "catalog failed: http 500", nil }
keys("Press", "Down", "Down", "Press")
ok, err = run_menu()
check(ok, "下载失败分支应跑通，实得 " .. tostring(err))
txt = all_text()
check(txt:find("下载失败", 1, true) ~= nil and txt:find("500", 1, true) ~= nil,
    "失败要带服务端原因，实得 " .. (txt:match("下载失败[^|]*") or "-"))
check(txt:find("成功 0 失败 0", 1, true) == nil, "失败时不许打印零计数")

-- 13) 设置 → 账号项（已登录态）=「退出账号」：确认后 Auth.logout，退出立即全屏生效
reset_state()
keys("Down", "Down", "Down", "Press",              -- 主菜单 → 设置
     "Down", "Down", "Down", "Down", "Down", "Down", "Press",   -- 账号项（可选项第 7 = Down×6）
     "Press")                                       -- 确认屏中键
ok, err = run_menu()
check(ok, "退出账号应跑通，实得 " .. tostring(err))
check(call_of("auth_logout") ~= nil, "确认后必须调 Auth.logout，实得 "
    .. tostring(count_of("auth_logout")))
txt = all_text()
check(txt:find("退出账号", 1, true) ~= nil, "已登录时同一位置必须显示「退出账号」")
check(txt:find("退出后需要重新扫码登录", 1, true) ~= nil, "退出是破坏性操作，必须先确认")
check(txt:find("已退出账号", 1, true) ~= nil, "退出要有回执，实得 " .. txt:sub(-200))
local post = last_frame_text()
check(post:find("测试号", 1, true) == nil, "退出后主菜单不得再显示账号名，末帧 "
    .. post:sub(1, 120))
check(post:find("扫码登录", 1, true) ~= nil, "退出后主菜单必须提供扫码登录入口")

-- 14) 设置 → 账号项（未登录态）=「扫码重新登录」：显式发起出码，成功后同一位置
--     翻转为「退出账号」（两者同位不同态）
reset_state()
api_logged_in = false
auth_login_ret = { name = "新号" }
keys("Down", "Down", "Down", "Press",
     "Down", "Down", "Down", "Down", "Down", "Down", "Press",
     "Back")                                        -- 登录回执后退出设置 → 主菜单 Back 收敛
ok, err = run_menu()
check(ok, "扫码重新登录应跑通，实得 " .. tostring(err))
check(call_of("auth_login") ~= nil, "未登录时账号项必须发起扫码登录")
check(call_of("draw_login_screen") ~= nil, "扫码登录必须屏上出码")
txt = all_text()
check(txt:find("扫码重新登录", 1, true) ~= nil, "未登录时同一位置必须显示「扫码重新登录」")
check(txt:find("登录成功: 新号", 1, true) ~= nil, "登录成功要有回执，实得 " .. txt:sub(-200))
check(txt:find("退出账号", 1, true) ~= nil, "登录成功后同一位置应翻转为「退出账号」")
check(txt:find("测试号", 1, true) ~= nil, "登录后主菜单应显示新账号名")

------------------------------------------------------------------ 还原
setmetatable(_G, nil)
for n, v in pairs(saved_loaded) do package.loaded[n] = v end
Config.PATH = "/mnt/us/weread/data/config.json"
package.loaded.fonts = nil          -- 丢弃被改过 probe 的实例；下份测试 require 到原件
os.remove(CFG)
_G.wr = nil
_G.SMOKE = nil

print("menu_ui done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails)
    .. " (fails=" .. fails .. ")")
return fails
