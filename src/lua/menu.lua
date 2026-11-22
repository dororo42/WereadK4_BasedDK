-- menu.lua — DK-1 step2 中文菜单（freetype 主路径 + 8x16 点阵回退）。
--
-- 字体：统一走 lib/fonts.lua（唯一决策点，缺文件回退出厂默认 wqy）；本屏另有
-- 8x16 点阵路径兜底（fb_text），功能不劣化。
-- 交互：Up/Down 移动，中键(Press) 选择，Back/Menu/Home 退出。
-- 阅读态键位（翻页/换章/目录）见 docs/keymap-k4.md，声明在 reader.lua 的键位表里。
-- SMOKE=true 时只渲染一帧 + 像素自检（采样字形区最小灰度）即退出（自动化验收）。

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path

local Api = require("api")
local Auth = require("auth")
local Shelf = require("shelf")
local Download = require("download")
local Reader = require("reader")
local Config = require("config")
local Downloaded = require("downloaded")
local Log = require("log")
local Report = require("report")
local Sync = require("sync")
local Progress = require("progress")
local WeRead = require("protocol")
local Fonts = require("fonts")


-- 菜单项随登录态变化（shelf/阅读在登录后可用）
-- 主菜单收敛到五个入口（多看风的少而稳）：同步进度/检查连接/运行状态全部归入
-- 设置屏（分组见 settings_screen）。凭据失效(离线·登录失效)时追加扫码登录——
-- 只在用户显式选择时才出二维码（绝不自动扫码，风控约束）。
local function build_items()
    local status = Auth.status()
    if Api.has_login() then
        local auth = Api.load_auth()
        local name = tostring(auth.account.name or auth.account.user_vid or "已登录")
        local items = { "继续阅读", "书架", "已下载", "设置" }
        if status == "离线·登录失效" then
            items[#items + 1] = "扫码登录"
        end
        items[#items + 1] = "退出"
        return items, name, status
    end
    return { "扫码登录", "书架(需登录)", "已下载", "设置", "退出" }, nil, status
end

local items, account_name, account_status = build_items()

local sel = 1
local running = true
local last_check_ts = 0          -- 「检查连接」防抖（用户显式动作，60s 内直接回缓存结论）

assert(wr.fb_open(), "fb_open failed")
-- SMOKE 允许输入被占用（KOReader EVIOCGRAB 独占时仍可自动验收渲染）；
-- 交互模式必须拿到输入。
local ok_in = wr.input_open()
if not SMOKE then assert(ok_in, "input_open failed (KOReader 独占中?)") end

local W, H = wr.fb_w(), wr.fb_h()

-- 设计令牌（多看 600×800 观感：标题 26 / 列表 24 / 小字 16 / 行高 38）：
-- 与 shelf/downloaded/reader 页脚同一套尺寸，一处调整全线跟随。
local ft_main = Fonts.load(24)
local ft_small = ft_main and Fonts.load(16) or nil
local FT_MODE = (ft_main ~= nil)

local ITEM_H   = FT_MODE and 38 or (16 * 2)      -- 行高
local TITLE_H  = FT_MODE and 36 or (16 * 2)
local Y0       = 76

local function text(x, y, s, fg, font_id)
    if FT_MODE and font_id then
        local endx = wr.fb_text_ft(font_id, x, y, s, fg)
        if endx then return endx end
    end
    return wr.fb_text(x, y, s, 2, fg)   -- 点阵回退（scale=2）
end

local function draw()
    items, account_name, account_status = build_items()
    if sel > #items then sel = #items end
    wr.fb_fill(0, 0, W, H, 0x00)                            -- 白底
    local title = "微信读书 K4" .. (account_name and ("  " .. account_name) or "")
    text(16, 14, title, 0xFF, ft_main)                      -- 标题（含账号名）
    -- 右上角时钟（小字右对齐）：e-ink 常亮场景下比状态栏更省一次翻屏
    local clock = os.date("%m-%d %H:%M")
    local function small_w(s)
        return (FT_MODE and ft_small) and (wr.font_width(ft_small, s) or #s * 10) or #s * 10
    end
    if ft_small then
        wr.fb_text_ft(ft_small, W - 16 - small_w(clock), 22, clock, 0x60)
    else
        wr.fb_text(W - 16 - small_w(clock), 22, clock, 1, 0x60)
    end
    wr.fb_fill(16, 14 + TITLE_H, W - 32, 2, 0xFF)           -- 分隔线

    for i, name in ipairs(items) do
        local y = Y0 + (i - 1) * ITEM_H
        if i == sel then
            wr.fb_fill(12, y - 6, W - 24, ITEM_H - 6, 0xFF) -- 黑底高亮
            text(22, y, name, 0x00, ft_main)                -- 白字
        else
            text(22, y, name, 0xFF, ft_main)                -- 黑字
        end
    end

    if ft_small then
        wr.fb_text_ft(ft_small, 16, H - 40, "上下移动  中键选择  返回退出", 0x60)
        -- 页脚右侧账号状态（Auth.status 不触网；探测入口=「检查连接」）
        wr.fb_text_ft(ft_small, W - 16 - small_w(account_status), H - 40, account_status, 0x60)
    else
        wr.fb_text(16, H - 26, "Up/Down:move  Center:select  Back:exit", 1, 0x60)
        wr.fb_text(W - 16 - small_w(account_status), H - 26, account_status, 1, 0x60)
    end
    wr.fb_quant()      -- Duokan 16 级量化（幂等，绘制期统一收敛）
    wr.fb_refresh(0)   -- partial 不闪
end

-- 选中非 Exit 项：显示提示，等任意键回到菜单。
-- keep_screen=true 时不重绘主菜单（调用方随后自己 draw，省掉一次 eink 刷新）。
local function show(msg, keep_screen)
    wr.fb_fill(0, 0, W, H, 0x00)
    text(16, 14, "微信读书 K4", 0xFF, ft_main)
    wr.fb_fill(16, 14 + TITLE_H, W - 32, 2, 0xFF)
    text(22, Y0 + 20, msg, 0xFF, ft_main)
    if ft_small then
        wr.fb_text_ft(ft_small, 16, H - 40, "按任意键返回", 0x60)
    else
        wr.fb_text(16, H - 26, "press any key to go back", 1, 0x60)
    end
    wr.fb_quant()
    wr.fb_refresh(0)
    while wr.input_poll(-1, true) == nil do end
    if not keep_screen then draw() end
end

-- 列表标签截断（UTF-8 安全，用 protocol.utf8_substr）：章节标题可能长于一行
local function clip(s, n)
    s = tostring(s or "")
    if #s <= n then return s end
    local head = WeRead.utf8_substr(s, n)
    if #head < #s then head = head .. "…" end
    return head
end

-- 目录列表：Up/Down 移动，Left/Right 翻屏，Press 跳转，Back 取消（与 shelf 同款导航）。
-- 末项固定「退出阅读」——快捷菜单(Menu / ScreenKB+Down)与目录(ScreenKB+Up)共用这一屏，
-- 不再多造一层菜单。返回 chapterIdx | "exit" | nil(取消)
local function pick_chapter(chapters, cur_idx)
    local ROWS = math.max(1, math.floor((H - Y0 - 56) / ITEM_H))
    local n = #chapters + 1
    local pos = Download.chapter_pos(chapters, cur_idx) or 1
    local pg = math.floor((pos - 1) / ROWS)
    local pages = math.max(1, math.ceil(n / ROWS))

    local function draw_toc()
        wr.fb_fill(0, 0, W, H, 0x00)
        text(16, 14, "目录", 0xFF, ft_main)
        wr.fb_fill(16, 14 + TITLE_H, W - 32, 2, 0xFF)
        local first = pg * ROWS
        for i = 1, ROWS do
            local idx = first + i
            if idx > n then break end
            local y = Y0 + (i - 1) * ITEM_H
            local label
            if idx <= #chapters then
                local ch = chapters[idx]
                label = clip(string.format("%s%d. %s",
                    ch.chapterIdx == cur_idx and "> " or "", ch.chapterIdx, ch.title), 20)
            else
                label = "退出阅读"
            end
            if idx == pos then
                wr.fb_fill(12, y - 6, W - 24, ITEM_H - 6, 0xFF)
                text(22, y, label, 0x00, ft_main)
            else
                text(22, y, label, 0xFF, ft_main)
            end
        end
        if ft_small then
            wr.fb_text_ft(ft_small, 16, H - 40,
                string.format("%d/%d 屏 · %d 章 · 上下移动 左右翻屏 中键跳转 返回取消",
                    pg + 1, pages, #chapters), 0x60)
        end
        wr.fb_quant()
        wr.fb_refresh(0)
    end

    draw_toc()
    while true do
        local key = wr.input_poll(1000, true)
        if key == "Up" then
            pos = pos - 1; if pos < 1 then pos = n end
            pg = math.floor((pos - 1) / ROWS); draw_toc()
        elseif key == "Down" then
            pos = pos + 1; if pos > n then pos = 1 end
            pg = math.floor((pos - 1) / ROWS); draw_toc()
        elseif key == "Left" then
            pg = pg - 1; if pg < 0 then pg = pages - 1 end
            pos = pg * ROWS + 1; draw_toc()
        elseif key == "Right" then
            pg = pg + 1; if pg > pages - 1 then pg = 0 end
            pos = pg * ROWS + 1; draw_toc()
        elseif key == "Press" then
            if pos > #chapters then return "exit" end
            return chapters[pos].chapterIdx
        elseif key == "Back" or key == "Menu" or key == "Home" then
            return nil
        end
    end
end

-- 快捷菜单（Menu / ScreenKB+Down，docs/keymap-k4.md §二语义）：阅读态五选一
-- （继续阅读/章节目录/下载全本/下载后面5章/退出阅读）。返回所选项名字符串。
-- Back/Home = 继续阅读（取消）。items 可选覆盖（默认四项）。
local function quick_menu(ch_title, items)
    items = items or { "继续阅读", "章节目录", "下载全本", "下载后面 5 章", "退出阅读" }
    local sel = 1
    local function draw_qm()
        wr.fb_fill(0, 0, W, H, 0x00)
        text(16, 14, clip(ch_title, 18), 0xFF, ft_main)
        wr.fb_fill(16, 14 + TITLE_H, W - 32, 2, 0xFF)
        for i, name in ipairs(items) do
            local y = Y0 + (i - 1) * ITEM_H
            if i == sel then
                wr.fb_fill(12, y - 6, W - 24, ITEM_H - 6, 0xFF)
                text(22, y, name, 0x00, ft_main)
            else
                text(22, y, name, 0xFF, ft_main)
            end
        end
        if ft_small then
            wr.fb_text_ft(ft_small, 16, H - 40, "上下移动 中键选择 返回继续阅读", 0x60)
        end
        wr.fb_quant()
        wr.fb_refresh(0)
    end
    draw_qm()
    while true do
        local key = wr.input_poll(1000, true)
        if key == "Up" then
            sel = sel - 1; if sel < 1 then sel = #items end; draw_qm()
        elseif key == "Down" then
            sel = sel + 1; if sel > #items then sel = 1 end; draw_qm()
        elseif key == "Press" then
            return items[sel]
        elseif key == "Back" or key == "Home" then
            return "继续阅读"
        end
    end
end

-- 批量下载屏：全本与"后面 5 章"共用一套循环、取消、汇总（唯一差别是章数上限）。
-- count 传 math.huge 即全本；from_pos 是目录数组下标（不是服务端 chapterIdx）。
-- 已 spool 的章由 Download.book 跳过 → 中途取消后重跑就是续传（幂等）。
local function download_batch(book_id, count, from_pos)
    local last_shown = 0
    local dl, dlerr, stats = Download.book(book_id, count, from_pos,
        function(done, total, t)
            -- 取消：单进程无异步，网络往返之间是唯一的按键时机；input_poll(0) 不等待。
            local k = wr.input_poll(0, true)
            if k == "Back" or k == "Home" then return false end
            local now = wr.millis()
            -- e-ink 全刷限流（插件 download_dialog 同口径 3s）：151 章逐章闪屏既慢又糊，
            -- 计数每章都算，重绘只在首章、每 3 秒、末章时发。
            if last_shown == 0 or now - last_shown >= 3000 or done == total then
                last_shown = now
                Auth.clear_screen(string.format("下载 %d/%d: %s",
                    done, total, clip(tostring(t or ""), 18)))
            end
        end)
    local msg
    if not dl then
        msg = "下载失败: " .. clip(tostring(dlerr), 40)
    elseif dlerr == "cancelled" then
        -- Download.book 中断返回：chapters 正常、各章 _err=cancelled
        msg = "已取消（已完成部分保留）"
    else
        msg = string.format("%s: 成功 %d 失败 %d / 共 %d 章",
            stats.cancelled and "已取消" or "下载完成", stats.ok, stats.fail, stats.total)
    end
    Auth.clear_screen(msg)
    local t0 = wr.millis()
    while wr.millis() - t0 < 1500 do end
end

-- 打开书本时的云端对位（用户口径：与微信读书端保持一致）。
-- 设置「云端进度」=关 时整段跳过；force=true（菜单「同步进度」入口）忽略设置强制拉一次。
-- 返回新的 cur_idx 与 page（page 可能是 {fraction=}）；不动就把原值原样退回。
-- 判异与取舍在 sync.lua（纯函数），这里只做取数与跳转——两侧都不读屏。
local function cloud_position(book_id, chapters, cur_idx, page, force)
    if not force and Config.load().progress_sync == false then
        return cur_idx, page
    end
    local remote, rerr = Sync.remote(book_id)
    if not remote then
        -- 静默：自动路径上没网/接口改版不该拦住打开书；手动入口由调用方另屏提示
        if force then show("云端进度不可用: " .. clip(tostring(rerr), 30), true) end
        return cur_idx, page
    end
    local tgt, terr = Sync.target(remote, chapters)
    if not tgt then
        if force then show("云端位置对不上本书目录: " .. clip(tostring(terr), 24), true) end
        return cur_idx, page
    end
    -- 本地百分比要 total_pages 才算得出（老记录没有 → 退化成比章序）
    local rec = Progress.get(book_id)
    local local_pct, local_pos = nil, Download.chapter_pos(chapters, cur_idx)
    if not rec then
        local_pos = nil                      -- 本地从没记过：不是"两边不一致"，是第一次读
    elseif rec.total_pages then
        local lp = Report.position_of(chapters, rec.chapter_idx, rec.page, rec.total_pages)
        if lp then local_pct = lp.percent end
    end
    local side, why = Sync.choose(remote, tgt, local_pct, local_pos)
    if side ~= "remote" then
        if force then
            show(string.format("无需跳转：%s（云端 第%d章 / 本地 第%d章）",
                why, tgt.chapter_idx, cur_idx), true)
        end
        return cur_idx, page
    end
    Auth.clear_screen(string.format("已同步到云端位置: 第%d章 %s（%s）",
        tgt.chapter_idx, clip(tgt.title or "", 10), why))
    local t0 = wr.millis()
    while wr.millis() - t0 < 1500 do end
    return tgt.chapter_idx, { fraction = tgt.fraction }
end

-- 运行状态屏（用户口径：测试 log 反映实际加载占用与错误）。
-- 真机缺陷实证：app.log 行最长 114 字符，16px 字号 ≈1800px 远超 600px 屏宽——
-- 长行直接画出右边缘是「显示不正常」的根因。修复=所有行统一按字符数裁剪
-- （clip=utf8_substr，按最坏 CJK 全宽估），meminfo 不再抄原始行而是解析成一条。
local function status_screen(ft_main, ft_small)
    local W, H = wr.fb_w(), wr.fb_h()
    local mem_total, mem_free = nil, nil
    local f = io.open("/proc/meminfo", "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^(%w+):%s+(%d+)")
            if k == "MemTotal" then mem_total = math.floor(tonumber(v) / 1024) end
            if k == "MemFree" then mem_free = math.floor(tonumber(v) / 1024) end
            if mem_total and mem_free then break end
        end
        f:close()
    end
    local heap_kb = math.floor(collectgarbage("count"))
    local books = Download.list_books()
    local bytes, chs_down = 0, 0
    for _, b in ipairs(books) do
        bytes = bytes + (b.bytes or 0)
        chs_down = chs_down + (b.chapters_down or 0)
    end
    local errs_total = Log.error_count()

    wr.fb_fill(0, 0, W, H, 0x00)
    local y = 20
    local function row(s, small)
        s = clip(s, small and 32 or 22)          -- 32×16px=512px < 600-24×2 ✓
        if small and ft_small then
            wr.fb_text_ft(ft_small, 24, y, s, 0x40)
        elseif ft_main then
            wr.fb_text_ft(ft_main, 24, y, s, 0xFF)
        else
            wr.fb_text(24, y, s, 1, 0xFF)
        end
        y = y + (small and 26 or 38)
    end
    row("运行状态", false)
    row("账号: " .. tostring(Auth.status()), true)
    if mem_total then
        row(string.format("内存: 共 %d MB · 空闲 %d MB", mem_total, mem_free or 0), true)
    end
    row(string.format("Lua heap: %d KB", heap_kb), true)
    row(string.format("已下载: %d 本 / %d 章 / %s",
        #books, chs_down,
        bytes >= 1024 * 1024 and string.format("%.1fMB", bytes / 1048576)
            or string.format("%dKB", math.floor(bytes / 1024))), true)
    row(string.format("错误: 本次进程 %d / 累计 %d", Log.errors, errs_total), true)
    wr.fb_fill(16, y, W - 32, 1, 0x40)
    y = y + 12
    row("app.log 尾部:", true)
    for _, line in ipairs(Log.tail(8)) do
        row(line ~= "" and line or " ", true)
    end
    row("任意键返回", true)
    wr.fb_quant()
    wr.fb_refresh(0)
    while wr.input_poll(-1, true) == nil do end
end

-- 阅读主循环：全项目唯一的跨章决策点（reader 只报 action，不持有目录）。
-- 每次离开一章就 Progress.set 落盘 → Back/Home/断电都能续读；Progress 单一写者就在这里。
local function read_book(book_id, force_sync, title_hint)
    local chapters, cerr = Download.fetch_catalog(book_id)
    if not chapters or #chapters == 0 then
        show("目录加载失败: " .. tostring(cerr):sub(1, 40), true)
        return
    end

    local rec = Progress.get(book_id)
    Download.save_manifest(book_id,
        tostring(title_hint or (rec and rec.title) or book_id), chapters)
    Log.info(string.format("catalog %s: %d chapters", book_id, #chapters))
    local cur_idx = (rec and rec.chapter_idx) or chapters[1].chapterIdx
    if not Download.find_chapter(chapters, cur_idx) then
        cur_idx = chapters[1].chapterIdx   -- 进度指向的章已不在目录（下架/改版）→ 从头读
    end
    local page = (rec and rec.page) or 1
    cur_idx, page = cloud_position(book_id, chapters, cur_idx, page, force_sync)
    local sess = Download.new_session()    -- psvts 每本书只抽一次

    while true do
        local ch = Download.find_chapter(chapters, cur_idx)
        Auth.clear_screen("准备章节: " .. clip(ch.title, 16))
        -- body 不叫 text：外层 text() 是渲染helper，遮蔽它会让后续误用静默变成字符串拼接
        local body, terr = Download.ensure_chapter(book_id, chapters, cur_idx, sess)
        if not body then
            show("章节下载失败: " .. tostring(terr):sub(1, 40), true)
            return
        end

        -- page 要么是整数页码（1 起，负数=末页），要么是 {fraction=0..1}
        -- （云端跳转：页数只有 reader 自己算得出，调用方只能给比例）
        -- 时长 tick（isword 活动量口径）：翻页渲染后由 reader 排水调用，
        -- 每片 ≤30s（服务端对大 rt 静默丢弃），失败即弃——在线口径，无积压。
        local function on_tick(page, total_pages, seconds)
            local res, rerr = Report.send({
                book_id = book_id, chapters = chapters, chapter_idx = cur_idx,
                page = page, total_pages = total_pages,
                psvts = sess.psvts, pclts = sess.pclts, token = sess.token,
                elapsed_seconds = seconds,
            })
            if not res then
                Log.info("rt tick dropped: " .. tostring(rerr))
            end
        end
        local ret = Reader.open(body, ch.title, page, Download.asset_dir(book_id, ch.chapterUid),
            { on_tick = on_tick })
        if not ret then
            show("阅读器打开失败", true)
            return
        end
        Progress.set(book_id, cur_idx, ret.page, ch.title, ret.total_pages)
        -- 离章：位置随余量时长分片连发（≤30s×4，无定时器）。失败不打扰阅读——
        -- 本地进度已落盘，位置下次离开该章还会再报；在线口径时长即弃。
        Report.send_reading({
            book_id = book_id, chapters = chapters, chapter_idx = cur_idx,
            page = ret.page, total_pages = ret.total_pages,
            psvts = sess.psvts, pclts = sess.pclts, token = sess.token,
        }, ret.reading_seconds)

        local pos = Download.chapter_pos(chapters, cur_idx)
        if ret.action == "next_chapter" then
            if pos >= #chapters then
                show("已到最后一章", true)
                return
            end
            cur_idx = chapters[pos + 1].chapterIdx
            page = 1
        elseif ret.action == "prev_chapter" then
            if pos <= 1 then
                page = 1                 -- 已是第一章：停在首页，不退出阅读
            else
                cur_idx = chapters[pos - 1].chapterIdx
                page = -1                -- 负数 = 上一章末页（reader.lua 约定）
            end
        elseif ret.action == "quickmenu" then
            -- 进度已在上方统一落盘；此处只做分支
            local qm = quick_menu(ch.title)
            if qm == "退出阅读" then
                return
            elseif qm == "章节目录" then
                local pick = pick_chapter(chapters, cur_idx)
                if pick == "exit" then
                    return
                elseif pick then
                    cur_idx = pick
                    page = 1
                else
                    page = ret.page          -- 目录取消 → 回原页
                end
            elseif qm == "下载全本" or qm == "下载后面 5 章" then
                -- 全本 = 从第 1 章起全部（已 spool 的跳过）；后 5 章 = 当前章之后 5 章
                local count, from = 5, pos + 1
                if qm == "下载全本" then count, from = math.huge, 1 end
                if from > #chapters then
                    Auth.clear_screen(qm == "下载全本" and "本书没有可下载的章节"
                        or "已是最后一章，后面没有可下载的章节")
                    local t0 = wr.millis()
                    while wr.millis() - t0 < 1200 do end
                else
                    download_batch(book_id, count, from)
                end
                page = ret.page
            else
                page = ret.page              -- 继续阅读：回原页
            end
        elseif ret.action == "toc" then
            local pick = pick_chapter(chapters, cur_idx)
            if pick == "exit" then
                return
            elseif pick then
                cur_idx = pick
                page = 1
            else
                page = ret.page          -- Back 取消 → 回到原页
            end
        else                             -- "exit"：Back / Home
            return
        end
    end
end

-- 「检查连接」显式探测：force 绕过 600s 冷却是用户显式动作；60s 防抖防连点。
-- 只报结论不自动扫码——renew 失败 ≠ 该重扫（可能是无网/冷却）。
local function check_connection()
    local res, rerr
    if os.time() - last_check_ts < 60 then
        res = "debounced"
        show("刚检查过: " .. Auth.status(), true)
    else
        Auth.clear_screen("正在检测连接…")
        res, rerr = Auth.renew(true)
        last_check_ts = os.time()
        local msg = { replaced = "在线（会话已续期）", stale = "在线（凭据稍受限）",
            expired = "离线：登录已失效（设置内可扫码重新登录）",
            network = "离线：无网络连接", cooling = "状态未变（冷却中）",
            ["no-refresh"] = "登录态缺少 refreshToken，建议扫码登录" }
        show("检查连接: " .. (msg[res] or tostring(res)) ..
            (msg[res] == nil and (" " .. tostring(rerr)) or ""), true)
    end
    Log.info(string.format("conn check: %s", tostring(res)))
end

-- 「同步进度」手动入口：对最近一本书强制拉一次云端位置并接着读（忽略设置开关）。
local function sync_last_book()
    local last = Progress.get_last()
    if last then
        assert(wr.fb_open(), "fb_open failed")
        read_book(last, true, (Progress.get(last) or {}).title)
    else
        show("暂无阅读记录，无从同步")
    end
end

-- 设置屏（分组）：阅读 / 账号 / 系统 三组，组间分组线（不可选行，导航跳过）。
-- 主菜单的「同步进度/检查连接/运行状态」全部归入这里（多看风的少而稳）。
local function settings_screen()
    local SEP = { sep = true }
    local font_opts = {}
    for _, c in ipairs(Fonts.list()) do
        font_opts[#font_opts + 1] = { label = c.label, v = c.path }
    end
    local entries = {
        -- 阅读
        { name = "字号", key = "font_size",
          opts = { {label="16 pt",v=16},{label="18 pt",v=18},{label="20 pt",v=20},
                   {label="22 pt",v=22},{label="24 pt",v=24},{label="26 pt",v=26},
                   {label="28 pt",v=28},{label="30 pt",v=30} } },
        { name = "行距", key = "line_factor",
          opts = { {label="紧凑",v=1.3},{label="标准",v=1.54},{label="宽松",v=1.8} } },
        { name = "左右边距", key = "margin_x",
          opts = { {label="窄",v=20},{label="标准",v=30},{label="宽",v=40} } },
        { name = "上下边距", key = "margin_top",
          opts = { {label="紧",v=16},{label="标准",v=24},{label="松",v=32} } },
        { name = "字体", key = "font_path", cur = Fonts.path, opts = font_opts,
          apply = function(o)
              -- 先在设备上开一次这个 face：文件在但 freetype 打不开（损坏、
              -- 非字体、槽位耗尽）时必须拒绝，否则坏设置要到下次翻页才暴露。
              local ft = Fonts.open(o.v, 30)
              if not ft then
                  return "字体打不开，未改设置: " .. clip(o.label, 10)
              end
              wr.font_close(ft)
              Config.set("font_path", o.v)
              -- 菜单自身立即换面（这一屏就是最好的预览）；阅读页在下次
              -- Reader.open 时才取新句柄，所以正文要换章才见效。
              wr.font_close(ft_main)
              ft_main = Fonts.load(24)
              if ft_small then wr.font_close(ft_small) end
              ft_small = ft_main and Fonts.load(16) or nil
              return "已切换字体: " .. clip(o.label, 10)
          end },
        SEP,
        -- 账号
        { name = "云端进度", key = "progress_sync",
          opts = { {label="开",v=true},{label="关",v=false} } },
        { name = "检查连接", action = check_connection },
        { name = "同步进度", action = sync_last_book },
        SEP,
        -- 系统
        { name = "运行状态", action = status_screen },
    }

    local sel_e, running2 = 1, true
    local function current_of(e)
        return tostring(e.cur and e.cur() or Config.load()[e.key])
    end
    -- 选中下标只落在可选行上（sep 不可停）
    local function step_e(dir)
        repeat
            sel_e = sel_e + dir
            if sel_e < 1 then sel_e = #entries end
            if sel_e > #entries then sel_e = 1 end
        until not entries[sel_e].sep
    end

    local function draw_set()
        wr.fb_fill(0, 0, W, H, 0x00)
        text(16, 14, "设置", 0xFF, ft_main)
        wr.fb_fill(16, 14 + TITLE_H, W - 32, 1, 0x40)
        for i, e in ipairs(entries) do
            local y = Y0 + (i - 1) * ITEM_H
            if e.sep then
                wr.fb_fill(16, y + math.floor(ITEM_H / 2) - 1, W - 32, 1, 0x40)
            else
                local curv = current_of(e)
                local label = e.name
                for _, o in ipairs(e.opts or {}) do
                    if tostring(o.v) == curv then label = label .. "（当前: " .. o.label .. "）" end
                end
                if i == sel_e then
                    wr.fb_fill(12, y - 6, W - 24, ITEM_H - 6, 0xFF)
                    text(22, y, label, 0x00, ft_main)
                else
                    text(22, y, label, 0xFF, ft_main)
                end
            end
        end
        if ft_small then
            wr.fb_text_ft(ft_small, 16, H - 40, "上下移动 中键进入 返回", 0x60)
        end
        wr.fb_quant()
        wr.fb_refresh(0)
    end

    draw_set()
    while running2 do
        local k = wr.input_poll(1000, true)
        if k == "Up" then
            step_e(-1); draw_set()
        elseif k == "Down" then
            step_e(1); draw_set()
        elseif k == "Press" then
            local e = entries[sel_e]
            if e.action then
                e.action()
                draw_set()
            else
                -- 值选择屏（通用）
                local curv = current_of(e)
                local sel_v = 1
                for i, o in ipairs(e.opts) do if tostring(o.v) == curv then sel_v = i end end
                local function draw_vals()
                    wr.fb_fill(0, 0, W, H, 0x00)
                    text(16, 14, e.name, 0xFF, ft_main)
                    wr.fb_fill(16, 14 + TITLE_H, W - 32, 1, 0x40)
                    for i, o in ipairs(e.opts) do
                        local y = Y0 + (i - 1) * ITEM_H
                        if i == sel_v then
                            wr.fb_fill(12, y - 6, W - 24, ITEM_H - 6, 0xFF)
                            text(22, y, o.label, 0x00, ft_main)
                        else
                            text(22, y, o.label, 0xFF, ft_main)
                        end
                    end
                    wr.fb_quant()
                    wr.fb_refresh(0)
                end
                draw_vals()
                local picking = true
                while picking do
                    local k2 = wr.input_poll(1000, true)
                    if k2 == "Up" then
                        sel_v = sel_v - 1; if sel_v < 1 then sel_v = #e.opts end; draw_vals()
                    elseif k2 == "Down" then
                        sel_v = sel_v + 1; if sel_v > #e.opts then sel_v = 1 end; draw_vals()
                    elseif k2 == "Press" then
                        local o = e.opts[sel_v]
                        if e.apply then
                            show(e.apply(o), true)
                        else
                            Config.set(e.key, o.v)
                            show("已设置（下次阅读生效）", true)
                        end
                        picking = false
                    elseif k2 == "Back" or k2 == "Menu" or k2 == "Home" then
                        picking = false
                    end
                end
                draw_set()
            end
        elseif k == "Back" or k == "Menu" or k == "Home" then
            running2 = false
        end
    end
end

draw()

-- SMOKE 像素自检（墨量极性：0x00=白底 / 0xFF=黑字）：字形区应有亮像素（>200）
if SMOKE then
    local function region_max(x0, y0, x1, y1)
        local m = 0
        for yy = y0, y1 do
            for xx = x0, x1 do
                local v = wr.fb_get(xx, yy)
                if v > m then m = v end
            end
        end
        return m
    end
    local title_max = region_max(18, 16, 300, 14 + TITLE_H)
    local item1_max = region_max(22, Y0, 260, Y0 + ITEM_H - 10)
    local footer_max = region_max(16, H - 44, 400, H - 10)
    print(string.format("pixel-check title=%d item1=%d footer=%d", title_max, item1_max, footer_max))
    if title_max < 55 or item1_max < 55 then
        print("PIXEL-CHECK FAIL: glyph region empty")
    else
        print("PIXEL-CHECK PASS")
    end
end

if not SMOKE then
    while running do
        local key = wr.input_poll(1000, true)
        if key == "Up" then
            sel = sel - 1; if sel < 1 then sel = #items end; draw()
        elseif key == "Down" then
            sel = sel + 1; if sel > #items then sel = 1 end; draw()
        elseif key == "Press" then
            if items[sel] == "退出" then
                running = false
            elseif items[sel] == "扫码登录" then
                local account, lerr = Auth.login(
                    function(url) Auth.draw_login_screen(url, "微信扫码登录", "手机微信扫码 · Back 取消") end,
                    function(msg) Auth.clear_screen(msg) end)
                if account then
                    Auth.clear_screen("登录成功: " .. tostring(account.name or account.user_vid))
                    local t0 = wr.millis()
                    while wr.millis() - t0 < 1500 do end
                else
                    Auth.clear_screen("登录未完成: " .. tostring(lerr):sub(1, 50))
                    local t0 = wr.millis()
                    while wr.millis() - t0 < 2500 do end
                end
                sel = 1
                draw()
            elseif items[sel] == "已下载" then
                sel = 1
                Downloaded.browse()
                draw()
            elseif items[sel] == "书架" then
                sel = 1
                local book_id = Shelf.run()
                if book_id then
                    assert(wr.fb_open(), "fb_open failed")
                    read_book(book_id, nil, (Progress.get(book_id) or {}).title)
                end
                draw()
            elseif items[sel] == "继续阅读" then
                local last = Progress.get_last()
                if last then
                    assert(wr.fb_open(), "fb_open failed")
                    read_book(last, nil, (Progress.get(last) or {}).title)
                else
                    show("暂无阅读记录")
                end
                draw()
            elseif items[sel] == "设置" then
                sel = 1
                settings_screen()
                draw()
            else
                show("已选择: " .. items[sel])
            end
        elseif key == "Back" or key == "Menu" or key == "Home" then
            running = false
        end
    end
end

if ft_main then wr.font_close(ft_main) end
if ft_small then wr.font_close(ft_small) end
wr.input_close()
wr.fb_close()
print("menu done, sel=" .. sel .. (SMOKE and " (smoke)" or "") .. (FT_MODE and " ft=on" or " ft=off"))
