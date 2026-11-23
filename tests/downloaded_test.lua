-- downloaded.lua 纯函数层的主机测（_chapter_entries / _backfill，UI 循环不入测）。
--
-- 为什么值得写：层2解包 bug（把 {label, chapter} 包装表直接当章数据用，nil text
-- 传进 Reader.open 崩掉整个应用——真机 reader.lua:105 实证）就是"标签与数据的
-- 包装"没有测试钉住导致的。回填逻辑则钉住筛选/查名/降级三件事。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

local fails = 0

-- 桩隔离：run.lua 单进程顺序跑全部套件。下载/阅读等模块必须在 require
-- downloaded 之前替换（downloaded.lua 在加载期捕获模块引用）；api 是原地改写，
-- 要按函数粒度还原。套件中途出错也必须还原（pcall 兜底），否则污染后续套件。
local saved_api_funcs = {}
local saved_loaded = {}
local function install_stubs()
    for _, name in ipairs({ "auth", "log", "download", "progress", "reader", "fonts", "downloaded" }) do
        saved_loaded[name] = package.loaded[name]
    end
    package.loaded.auth = { clear_screen = function() end }
    package.loaded.log = {
        info = function() end, error = function() end, debug = function() end,
        tail = function() return {} end, error_count = function() return 0 end, errors = 0,
    }
    package.loaded.progress = { stubs = true }
    package.loaded.reader = { stubs = true }
    package.loaded.fonts = { stubs = true }
    local Api = package.loaded.api or require("api")
    saved_api_funcs.get_shelf = Api.get_shelf
    saved_api_funcs.has_login = Api.has_login
end
local function restore_stubs()
    for name, v in pairs(saved_loaded) do
        if v == nil then package.loaded[name] = nil else package.loaded[name] = v end
    end
    local Api = package.loaded.api
    for k, v in pairs(saved_api_funcs) do
        if v == nil then Api[k] = nil else Api[k] = v end
    end
end

local DL
local function run()
    install_stubs()
    package.loaded.download = { fetch_catalog = function() return nil, "stub" end,
        save_manifest = function() return true end }
    package.loaded.downloaded = nil
    DL = require("downloaded")

    local function check(cond, msg)
        if not cond then
            print("FAIL downloaded_test: " .. msg)
            fails = fails + 1
        end
    end

    ---------------------------------------------------------------- _chapter_entries

    local chs = {
        { chapterIdx = 2, chapterUid = "u2", title = "第二章", text = "正文二" },
        { chapterIdx = 1, chapterUid = "u1", title = "第一章", text = "正文一" },
    }
    local entries = DL._chapter_entries(chs)
    check(#entries == 2, "应生成两条包装表，实得 " .. #entries)
    check(entries[1].label == "2. 第二章", "label 用于列表显示")
    check(entries[1].chapter == chs[1], "chapter 必须指向原章数据（解包 bug 回归钉）")
    check(entries[1].chapter.text == "正文二", "取章正文必须走 .chapter.text")

    ---------------------------------------------------------------- _backfill

    local calls = {}
    package.loaded.download.fetch_catalog = function(id)
        calls[#calls + 1] = { f = "catalog", id = id }
        return { { chapterIdx = 1, chapterUid = "u1", title = "一", wordCount = 1 } }
    end
    package.loaded.download.save_manifest = function(id, title, chs2)
        calls[#calls + 1] = { f = "save", id = id, title = title, n = #chs2 }
        return true
    end
    local Api = require("api")

    -- 1) 全部有 manifest（chapters_total>0）→ 不回填
    Api.has_login = function() return true end
    Api.get_shelf = function() error("不该触发 shelf") end
    local n = DL._backfill({ { bookId = "101", title = "书A", chapters_total = 5 } }, nil)
    check(n == 0, "无缺 manifest 的书不应触发回填，实得 " .. n)

    -- 2) 有缺 → shelf 查名 + catalog 拉目录 + save_manifest
    calls = {}
    Api.get_shelf = function()
        calls[#calls + 1] = { f = "shelf" }
        return { books = {
            { bookId = "202", title = "盲视" },
            { bookId = "303", title = "游隼" },
        } }
    end
    n = DL._backfill({
        { bookId = "202", title = "202", chapters_total = 0, chapters_down = 3 },
        { bookId = "303", title = "303", chapters_total = 0, chapters_down = 1 },
    }, nil)
    check(n == 2, "两本书都应回填成功，实得 " .. n)
    local saved = {}
    for _, c in ipairs(calls) do
        if c.f == "save" then saved[c.id] = c end
    end
    check(saved["202"] and saved["202"].title == "盲视" and saved["202"].n == 1,
        "书名应来自 shelf 且 manifest 含目录")
    check(saved["303"] and saved["303"].title == "游隼", "第二本也应回填")

    -- 2b) 章数齐全但标题就是 bookId（真机 CB_ 书的形态）→ 也要回填
    calls = {}
    Api.get_shelf = function()
        return { books = { { bookId = "CB_2H6Btest", title = "图片书" } } }
    end
    n = DL._backfill({ { bookId = "CB_2H6Btest", title = "CB_2H6Btest",
                         chapters_total = 72, chapters_down = 72 } }, nil)
    check(n == 1, "标题缺失（=bookId）即使章数齐全也应回填，实得 " .. n)
    local saved_cb
    for _, c in ipairs(calls) do if c.f == "save" then saved_cb = c end end
    check(saved_cb and saved_cb.title == "图片书", "应写入 shelf 里的真书名")

    -- 3) shelf 查不到的书 → 跳过（保留 id 显示，不写坏 manifest）
    calls = {}
    Api.get_shelf = function() return { books = {} } end
    n = DL._backfill({ { bookId = "404", title = "404", chapters_total = 0 } }, nil)
    check(n == 0, "shelf 查不到名应跳过，实得 " .. n)
    local touched = false
    for _, c in ipairs(calls) do if c.f == "save" then touched = true end end
    check(not touched, "查不到名不得写 manifest")

    -- 4) 未登录 → 直接跳过（离线浏览不因回填不可用）
    Api.has_login = function() return false end
    Api.get_shelf = function() error("未登录不该触网") end
    n = DL._backfill({ { bookId = "505", title = "505", chapters_total = 0 } }, nil)
    check(n == 0, "未登录应跳过回填，实得 " .. n)
end

local ok, err = pcall(run)
restore_stubs()
if not ok then
    print("RUN-FAIL downloaded_test: " .. tostring(err))
    fails = fails + 1
end

print("downloaded_test done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails) .. " (fails=" .. fails .. ")")
return fails
