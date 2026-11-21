-- epub.lua 纯函数层的主机测（opf/nav/ncx/escape/text_to_xhtml/collect_images）。
--
-- 为什么值得写：epub 合规结构（mimetype 首条/opf 元素计数/双目录）是导出产物的
-- 验收口径——生成器一处拼错整本废；这些是纯字符串函数，主机可钉死。
-- zip 组装在 C（设备端到端验），不在此测。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL epub_test: " .. msg)
        fails = fails + 1
    end
end

-- 桩隔离（run.lua 单进程顺序跑）：替换先于 require + 结束必还原
local saved_loaded = {}
for _, name in ipairs({ "download", "log", "epub" }) do
    saved_loaded[name] = package.loaded[name]
end
local function restore_loaded()
    for name, v in pairs(saved_loaded) do
        if v == nil then package.loaded[name] = nil else package.loaded[name] = v end
    end
end
package.loaded.download = {
    read_raw = function() return nil end,
    read_chapter = function() return "正文" end,
    asset_dir = function(_, _) return "/tmp/nothing" end,
}
package.loaded.log = {
    info = function() end, error = function() end, debug = function() end,
    tail = function() return {} end, error_count = function() return 0 end, errors = 0,
}
package.loaded.epub = nil
local Epub = require("epub")

-- 1) escape：五个实体 + 属性安全
check(Epub.escape('a&b<c>d"e') == "a&amp;b&lt;c&gt;d&quot;e",
    "escape 应处理 & < > \"，实得 " .. Epub.escape('a&b<c>d"e'))

-- 2) text_to_xhtml：合法最小 xhtml（XML 声明 + 命名空间 + 段落）
local x = Epub.text_to_xhtml("第一段\n\n第二段", "书名")
check(x:find('<?xml version="1.0" encoding="utf-8"?>', 1, true) ~= nil, "应有 XML 声明")
check(x:find('xmlns="http://www.w3.org/1999/xhtml"', 1, true) ~= nil, "应有 xhtml 命名空间")
check(x:find("<p>第一段</p><p>第二段</p>", 1, true) ~= nil, "换行应切段")

-- 3) collect_images：去重保序 + 相对路径 basename
local imgs = Epub.collect_images('<img src="../Images/note.png"/><img src="a.jpg"/><img src="../Images/note.png"/>')
check(#imgs == 2 and imgs[1] == "note.png" and imgs[2] == "a.jpg",
    "应去重取 basename，实得 " .. table.concat(imgs, ","))

-- 4) build_opf：manifest 计数 + spine 计数 + metadata 齐全
local chs = {
    { chapterIdx = 1, chapterUid = 11, title = "第一章" },
    { chapterIdx = 2, chapterUid = 12, title = "第二章" },
}
local opf = Epub.build_opf("3300057890", "游隼", "贝克", chs, { "note.png", "a.jpg" })
local function count(s, pat)
    local n = 0
    for _ in s:gmatch(pat) do n = n + 1 end
    return n
end
check(count(opf, '<item id="c%d"') == 2, "manifest 应有 2 章")
check(count(opf, '<item id="img%d"') == 2, "manifest 应有 2 图")
check(count(opf, "<itemref") == 2, "spine 应有 2 引用")
check(opf:find('urn:weread:3300057890', 1, true) ~= nil, "dc:identifier 应含书号")
check(opf:find("<dc:title>游隼</dc:title>") ~= nil, "dc:title 应转义后写入")
check(opf:find('properties="nav"') ~= nil, "nav 应声明 properties（EPUB3）")
check(opf:find('href="images/note.png"', 1, true) ~= nil, "图片 href 应进 manifest")
check(opf:find('image/png') ~= nil and opf:find('image/jpeg') ~= nil, "图片 MIME 应按扩展名")

-- 5) nav/ncx：双目录 + 章链接对齐
local nav = Epub.build_nav("游隼", chs)
check(nav:find('epub:type="toc"') ~= nil, "nav 应有 epub:type")
check(nav:find('text/chapter-001.xhtml', 1, true) ~= nil
    and nav:find('text/chapter-002.xhtml', 1, true) ~= nil, "nav 章链接应对齐")
local ncx = Epub.build_ncx("3300057890", "游隼", chs)
check(ncx:find('dtb:uid" content="urn:weread:3300057890"') ~= nil, "ncx uid 应一致")
check(count(ncx, "<navPoint ") == 2, "ncx 应有 2 个 navPoint")
check(ncx:find("第一章") ~= nil and ncx:find("第二章") ~= nil, "ncx 章标题应转义后原样可读")

-- 6) 章标题转义进 nav/ncx（恶意/特殊字符不破结构）
local chs2 = { { chapterIdx = 1, chapterUid = 1, title = 'a&b<c>' } }
local nav2 = Epub.build_nav("t", chs2)
check(nav2:find("a&amp;b&lt;c&gt;", 1, true) ~= nil, "标题 & <> 应转义")
check(nav2:find("<a href=", 1, true) ~= nil, "结构不应被特殊字符破坏")

restore_loaded()

print("epub_test done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails) .. " (fails=" .. fails .. ")")
return fails
