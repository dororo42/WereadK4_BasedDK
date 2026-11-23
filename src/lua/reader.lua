-- reader.lua — 简版阅读器：freetype 排版 + KOReader 习惯键位 + 进度显示。
--
-- DK-2 简版口径（方案 §八）：纯文本段落渲染（spool txt），无图片/样式；
-- 排版引擎（crengine 级）后续独立迭代。UTF-8 安全折行用 protocol.utf8_substr。
--
-- 键位对齐 KOReader + weread_K4 插件在 K4 上的习惯（出处与两处偏离见 docs/keymap-k4.md）：
--   LPgFwd / RPgFwd / Down / Press = 下一页（末页再往前 → 下一章，自动续读）
--   LPgBack / RPgBack / Up         = 上一页（首页再往后 → 上一章）
--   Right = 下一章，Left = 上一章
--   Menu / ScreenKB+Down = 快捷菜单，ScreenKB+Up = 目录（三者都交调用方处理）
--   Back / Home = 退出（进度由调用方保存）
-- 组合键名 "ScreenKBPlusX" 由 C 输入层 latch 产出（src/device/input.c）。
--
-- 本模块只管「单章渲染 + 翻页」，不持有目录：跨章动作以 action 信号交回调用方
-- （menu.read_book 是唯一的跨章决策点）。
-- 返回 { page=, total_pages=, action= }，action ∈ next_chapter|prev_chapter|toc|exit。

local WeRead = require("protocol")
local Log = require("log")
local Config = require("config")
local Fonts = require("fonts")

local Reader = {}

Reader.FONT_MIN, Reader.FONT_MAX = 16, 40       -- 字号钳制边界（设置 UI 与钳制共用）

local function font_size()
    local fs = tonumber(Config.load().font_size) or 22
    if fs < Reader.FONT_MIN then fs = Reader.FONT_MIN end
    if fs > Reader.FONT_MAX then fs = Reader.FONT_MAX end
    return fs
end

-- 行高 = 字号 × 行距系数（设置"行距"档位：紧凑 1.3 / 标准 1.54 / 宽松 1.8）
local function line_h(fs)
    local factor = tonumber(Config.load().line_factor) or 1.54
    return math.floor(fs * factor + 0.5)
end
-- 边距（设置屏「左右边距/上下边距」，config.json 的 margin_x/margin_top）。
-- 底边距固定 44：那是页脚区，正文底边距随页脚高度。
local function margin_x()
    local v = tonumber(Config.load().margin_x)
    if not v or v < 12 or v > 80 then return 30 end
    return v
end
local function margin_top()
    local v = tonumber(Config.load().margin_top)
    if not v or v < 8 or v > 60 then return 24 end
    return v
end
local MARGIN_BOTTOM = 44          -- 页脚区（16px 点阵页脚，正文区比旧 56 多 12px/屏）

-- 键位表：一处声明，dispatch 只做查表（改键位不动控制流）。
-- 导出为模块字段，使键位本身可在主机侧被单测钉住（tests/reader_keys_test.lua）——
-- 键位是用户肌肉记忆的直接对象，值得一个不依赖设备的回归护栏。
Reader.KEY_NEXT_PAGE = { LPgFwd = true, RPgFwd = true, Down = true, Press = true }
Reader.KEY_PREV_PAGE = { LPgBack = true, RPgBack = true, Up = true }
Reader.KEY_NEXT_CH   = { Right = true }
Reader.KEY_PREV_CH   = { Left = true }
-- docs/keymap-k4.md §二：Menu / ScreenKB+Down = 快捷菜单；ScreenKB+Up = 目录。
-- 三键曾经全绑 toc（真机 bug：快捷菜单键打开的都是目录）→ 拆成两组。
Reader.KEY_QUICKMENU = { Menu = true, ScreenKBPlusDown = true }
Reader.KEY_TOC       = { ScreenKBPlusUp = true }
Reader.KEY_EXIT      = { Back = true, Home = true }

-- UTF-8 按字符切分（宽松版：非法序列按 1 字节吞掉，保证永远前进不丢字节）。
-- 宽度首字节判长与 protocol.utf8_substr 同源。
local function utf8_chars(line)
    local chars = {}
    local i, n = 1, #line
    while i <= n do
        local b = line:byte(i)
        local w = 1
        if b >= 0xF0 then w = 4
        elseif b >= 0xE0 then w = 3
        elseif b >= 0xC2 and b <= 0xDF then w = 2
        end
        chars[#chars + 1] = line:sub(i, i + w - 1)
        i = i + w
    end
    return chars
end

-- UTF-8 安全折行：字符域贪心（measure 依赖注入，主机侧可测）。
-- 历史 bug（code review 🔴）：旧版 pos 按字节推进、fit 按字符计数，中文行超宽时
-- 切进多字节字符中间——ASCII 恰好字节=字符而漏过测试。本版在字符数组上工作，
-- 单字符超宽也强制收进一行（不死循环、不丢字）。
-- measure(candidate_string) 返回像素宽度；设备路径传 wr.font_width 绑定。
function Reader.wrap_line(measure, maxw, line)
    local rows = {}
    local chars = utf8_chars(line)
    local i = 1
    while i <= #chars do
        local j = i
        local last_fit = i
        while j <= #chars do
            local cand = table.concat(chars, "", i, j)
            local w = measure(cand)
            if w and w <= maxw then
                last_fit = j
                j = j + 1
            else
                break
            end
        end
        rows[#rows + 1] = table.concat(chars, "", i, last_fit)
        i = last_fit + 1
    end
    return rows
end

-- 阅读时长钟（isword weread_ui "dwell limit" 语义的纯函数实现，主机可测）：
-- 秒数只在「活动窗口」内累计——两次交互间隔 ≤ DWELL_LIMIT_S 才计（翻页/按键
-- = 活动），静默超限的间隙不计。这正是"在线阅读多少报多少"：开着不翻页
-- 不计时，不靠墙钟不靠定时器。毫秒入口由调用方喂（设备 wr.millis/主机测试桩）。
Reader.DWELL_LIMIT_S = 90
function Reader.new_clock()
    return { acc_ms = 0, last = nil }
end
-- 每次交互（任意键）调用：窗口按 min(dt, dwell 上限) 计入
function Reader.clock_activity(clk, now_ms)
    if clk.last == nil then clk.last = now_ms; return end
    local dt = now_ms - clk.last
    clk.last = now_ms
    if dt > 0 then
        clk.acc_ms = clk.acc_ms + math.min(dt, Reader.DWELL_LIMIT_S * 1000)
    end
end
-- 翻页后取走满 30s 的整块（服务端对 >30s 的 rt 静默丢弃——插件/真机判据）。
-- 单次最多排空 3 块（90s）：翻页间隙慢于 30s 时的积压，在渲染完的页面上
-- 消化（不挡当页显示，只延后下一次按键的响应）。
function Reader.clock_take(clk, now_ms)
    if clk.last ~= nil then
        local dt = now_ms - clk.last
        clk.last = now_ms
        if dt > 0 then
            clk.acc_ms = clk.acc_ms + math.min(dt, Reader.DWELL_LIMIT_S * 1000)
        end
    end
    local full = math.floor(clk.acc_ms / 30000)
    local n = math.min(full, 3)
    if n > 0 then clk.acc_ms = clk.acc_ms - n * 30000 end
    return n * 30
end
-- 离章余量（< 翻页间隔+dwell；由调用方分片连发）
function Reader.clock_remainder_s(clk)
    return math.floor(clk.acc_ms / 1000)
end

-- 章节 → 屏幕行数组（段落间空行；assets_dir 非空时解析 IMG 标记为图片块）。
-- 行元素 = 字符串 | 图片块表 { img_w, img_h, img_gray, slot, total, top_pad }：
-- 图片块占 total 个行槽（含顶部对齐余量），分页切片天然把整块切进同一页——
-- layout 阶段块超页宽时用空行垫到页边界（原子性，图片不跨页）。
function Reader.layout(ft, maxw, text, assets_dir, lh)
    local rows = {}
    for line in (text:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"):gmatch("(.-)\n") do
        line = line:match("^(.-)%s*$") or ""
        local img_name = line:match("^\1IMG:(.+)\1$")
        if img_name then
            local blk = assets_dir and Reader.load_image_block(assets_dir, img_name, maxw, lh) or nil
            if blk then
                -- 原子分页：块总高（行槽）装不进当前页余量 → 垫空行到下一页边界
                local k = blk.total
                local row_in_page = #rows % math.max(1, Reader._rows_per_page or 1)
                local left = math.max(1, Reader._rows_per_page or 1) - row_in_page
                if k <= left then
                    blk.top_pad = 0
                else
                    blk.top_pad = left % math.max(1, Reader._rows_per_page or 1)
                    for _ = 1, blk.top_pad do rows[#rows + 1] = "" end
                end
                for s = 1, k do
                    rows[#rows + 1] = { img_w = blk.w, img_h = blk.h, img_gray = blk.gray, slot = s }
                end
            else
                rows[#rows + 1] = "[图片]"
                rows[#rows + 1] = ""
            end
        elseif line == "" then
            rows[#rows + 1] = ""
        else
            for _, r in ipairs(Reader.wrap_line(function(s)
                    return wr.font_width(ft, s)
                end, maxw, line)) do
                rows[#rows + 1] = r
            end
        end
    end
    return rows
end

-- 加载并缩放一张图（会话内解码缓存）。返回 { w, h, gray, total } | nil。
-- 缩放：等比装进 maxw × 页高 的框（宽适配后高仍超出页高的图，按高反推宽——
-- 超页高的块永远装不进原子分页，跨页绘制必然裁切并压过页脚，真机实证）。
Reader._img_cache = {}
Reader._rows_per_page = nil
function Reader.load_image_block(assets_dir, name, maxw, lh)
    local nm = tostring(name)
    local key = assets_dir .. "/" .. nm     -- 缓存键固定用标记名：解析到哪都只算一次
    local cached = Reader._img_cache[key]
    if cached ~= nil then return cached or nil end
    local path = key
    local f = io.open(path, "rb")
    if not f then
        -- 标记名 = src 的 basename，常带 CB_<bookId>_ 前缀（真机实证
        -- CB_3300057890_device_phone_frontcover.jpg），而落盘文件可能被剥过前缀
        -- → 两个方向都要试，否则就是"图在盘上却渲染不出"。
        local stripped = nm:match("^CB_[^_]+_(.+)$")
        if stripped then
            local alt = assets_dir .. "/" .. stripped
            local af = io.open(alt, "rb")
            if af then f, path = af, alt end
        end
    end
    if not f then
        -- 目录扫描兜底：文件名比标记长（仍带前缀）也能对上
        local pp = io.popen("ls -1 '" .. assets_dir .. "' 2>/dev/null")
        if pp then
            local esc = nm:gsub("([%.%[%]%%])", "%%%1")
            for fn in pp:lines() do
                if fn == nm or fn:match("[_/]" .. esc .. "$") then
                    path = assets_dir .. "/" .. fn
                    f = io.open(path, "rb")
                    break
                end
            end
            pp:close()
        end
    end
    if not f then Reader._img_cache[key] = false return nil end
    local data = f:read("*a")
    f:close()
    local gray, w, h = wr.image_decode(data)   -- C 绑定返回序：gray, w, h
    if not gray or not w or w <= 0 or h <= 0 then Reader._img_cache[key] = false return nil end
    -- 等比缩放到 maxw 内（最近邻点采样，C 层做——Lua 拼 60 万 string.char 参数会爆栈）
    local dw = math.min(maxw, w)
    local dh = math.max(1, math.floor(h * (dw / w) + 0.5))
    -- 高也要进页：钳到 (rows_per_page-1) 行，保证 total = ceil(dh/lh)+1 ≤ rows_per_page，
    -- 原子块才恒能整页放下。rpp≤1 的退化场景没有可用页框，不钳。
    local lh_eff = lh or 34
    local max_h = (Reader._rows_per_page and Reader._rows_per_page > 1)
        and (Reader._rows_per_page - 1) * lh_eff or nil
    if max_h and dh > max_h then
        dh = max_h
        dw = math.max(1, math.floor(w * dh / h + 0.5))   -- 等比反推，宽必然 ≤ maxw
    end
    gray = wr.image_scale(gray, w, h, dw, dh)
    if not gray then Reader._img_cache[key] = false return nil end
    local blk = { w = dw, h = dh, gray = gray, total = 0 }
    blk.total = math.ceil(blk.h / (lh or 34)) + 1
    Reader._img_cache[key] = blk
    return blk
end

-- start_page: 起始页（1 起）；传负数表示「从末页开始」——上一章回退时用；
-- 传 { fraction = 0..1 } 表示按比例定位——云端进度跳转时用（总页数只有本模块
-- 排版后才算得出，调用方给不了页码，只给得了比例；两解都传时以 fraction 为准）。
function Reader.open(chapter_text, chapter_title, start_page, assets_dir, opts)
    opts = opts or {}
    assert(wr.fb_open(), "fb_open failed")
    assert(wr.input_open(), "input_open failed")
    local fs = font_size()
    local lh = line_h(fs)
    local ft = Fonts.load(fs)
    if not ft then
        wr.fb_close()
        return nil, "font load failed"
    end

    local W, H = wr.fb_w(), wr.fb_h()
    local maxw = W - margin_x() * 2
    local rows_per_page = math.floor((H - margin_top() - MARGIN_BOTTOM) / lh)
    Reader._rows_per_page = rows_per_page
    Reader._img_cache = {}
    local rows = Reader.layout(ft, maxw, chapter_text, assets_dir, lh)
    local total_pages = math.max(1, math.ceil(#rows / rows_per_page))
    local page
    if type(start_page) == "table" then
        local f = math.min(math.max(tonumber(start_page.fraction) or 0, 0), 1)
        page = math.min(math.floor(f * total_pages) + 1, total_pages)
    else
        page = tonumber(start_page) or 1
        if page < 1 then page = total_pages end
        page = math.min(page, total_pages)
    end

    local function draw()
        wr.fb_fill(0, 0, W, H, 0x00)
        local first = (page - 1) * rows_per_page
        local y = margin_top()
        for i = first + 1, math.min(first + rows_per_page, #rows) do
            local row = rows[i]
            if type(row) == "table" then
                -- 图片块：slot 1 绘制一次（垫行是独立 "" 行，块行 slot 从 1 起），其余槽只推进 y
                if row.slot == 1 then
                    local ix = math.floor((W - row.img_w) / 2)
                    wr.fb_image(ix, y, row.img_w, row.img_h, row.img_gray)
                end
            elseif row ~= "" then
                wr.fb_text_ft(ft, margin_x(), y, row, 0xFF)
            end
            y = y + lh
        end
        -- 页脚：标题 + 进度（16px 点阵定宽灰字居中：不占 freetype 槽位、不随正文字号）
        local footer = string.format("%s  %d/%d", chapter_title or "", page, total_pages)
        wr.fb_text(math.floor((W - #footer * 8) / 2), H - MARGIN_BOTTOM + 14, footer, 1, 0x60)
        wr.fb_quant()
        wr.fb_refresh(0)
    end

    -- 时长排水：翻页渲染完成（页面已可见）后发已满 30s 的整块；失败即弃
    -- （在线口径，无离线积压），不挡当页显示。
    local clk = Reader.new_clock()
    Reader.clock_activity(clk, wr.millis())
    local function drain(page)
        local chunk = Reader.clock_take(clk, wr.millis())
        if chunk >= 30 and opts.on_tick then
            local okt, terr = pcall(opts.on_tick, page, total_pages, chunk)
            if not okt then Log.info("rt tick error: " .. tostring(terr)) end
        end
    end

    draw()
    local action
    while true do
        local key = wr.input_poll(1000, true)
        if key then Reader.clock_activity(clk, wr.millis()) end
        -- 未绑定的键（含 ScreenKB 自身、其它组合键）静默忽略；nil = 超时
        if key and Reader.KEY_NEXT_PAGE[key] then
            if page < total_pages then
                page = page + 1
                draw()
                drain(page)
            else
                action = "next_chapter"   -- 章末再往前翻 → 自动续读
                break
            end
        elseif key and Reader.KEY_PREV_PAGE[key] then
            if page > 1 then
                page = page - 1
                draw()
                drain(page)
            else
                action = "prev_chapter"   -- 首页再往后翻 → 回上一章（调用方决定停在末页）
                break
            end
        elseif key and Reader.KEY_NEXT_CH[key] then
            action = "next_chapter"
            break
        elseif key and Reader.KEY_PREV_CH[key] then
            action = "prev_chapter"
            break
        elseif key and Reader.KEY_QUICKMENU[key] then
            action = "quickmenu"
            break
        elseif key and Reader.KEY_TOC[key] then
            action = "toc"
            break
        elseif key and Reader.KEY_EXIT[key] then
            action = "exit"
            break
        end
    end

    -- 离章余量（<90s 活动窗口 + <30s 排水残量；menu 分片连发）
    local reading_seconds = Reader.clock_remainder_s(clk)
    wr.font_close(ft)
    -- fb/input 不在此关闭：menu 级联共享（调用方管理生命周期）
    return { page = page, total_pages = total_pages, action = action,
        reading_seconds = reading_seconds }
end

return Reader
