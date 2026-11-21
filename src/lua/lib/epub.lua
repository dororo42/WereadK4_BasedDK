-- epub.lua — 整本 epub 导出（用户口径「实施」：平台不发 epub 文件，本地组装）。
--
-- 组装口径与插件 write_epub 同款（真机实证过的合规结构，检验基准：
-- koreader/weread/cache/3300151063/空山 full.epub 62 entries 全项通过）：
--   mimetype（首条，application/epub+zip，store 不压缩=epub 规范要求）
--   META-INF/container.xml → OEBPS/content.opf（manifest+spine+metadata）
--   OEBPS/text/chapter-NNN.xhtml（解码后原始 xhtml；txt 书/老缓存包 <p> 降级）
--   OEBPS/images/*（imgcache 资产按引用收集）
--   OEBPS/nav.xhtml + OEBPS/toc.ncx（EPUB3+2 双目录）+ OEBPS/style.css
-- zip 由 wr.zip_write（C store 型写入器）落盘到 export/（USB 可见）。

local Download = require("download")
local Log = require("log")

local Epub = {}

Epub.EXPORT_DIR = "/mnt/us/weread/export"

Epub.CSS = [[body { margin: 1em; line-height: 1.5; }
h1 { font-size: 1.4em; margin: 0.6em 0; }
h2 { font-size: 1.25em; margin: 0.6em 0; }
p { text-indent: 2em; margin: 0.4em 0; }
img { max-width: 100%; }]]

Epub.CONTAINER = [[<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>]]

-- XML 转义（文本/属性共用）
function Epub.escape(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    return s
end

-- 纯文本 → 最小合法 xhtml（txt 书/缺 xhtml 的老缓存降级用）
function Epub.text_to_xhtml(text, title)
    local esc = Epub.escape(tostring(text or ""))
    local paras = ""
    if esc ~= "" then
        paras = "<p>" .. esc:gsub("\n+", "</p><p>") .. "</p>"
    end
    return [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>]] .. Epub.escape(title or "") ..
[[</title></head><body>]] .. paras .. [[</body></html>]]
end

-- 收集 xhtml 里的图片引用名（去重，保序）
function Epub.collect_images(xhtml)
    local seen, out = {}, {}
    for src in tostring(xhtml or ""):gmatch('<img[^>]-src%s*=%s*"([^"]+)"') do
        local name = src:match("([^/]+)%??[^/]*$") or ""
        if name ~= "" and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    return out
end

-- content.opf（EPUB3.0：metadata/manifest/spine）
function Epub.build_opf(book_id, title, author, chapters, image_names)
    local manifest, spine = {}, {}
    for i, _ in ipairs(chapters) do
        manifest[#manifest + 1] = string.format(
            '<item id="c%d" href="text/chapter-%03d.xhtml" media-type="application/xhtml+xml"/>', i, i)
        spine[#spine + 1] = string.format('<itemref idref="c%d"/>', i)
    end
    for i, name in ipairs(image_names) do
        local ext = (name:match("%.([%w]+)$") or "png"):lower()
        local mime = ext == "jpg" and "image/jpeg" or ext == "gif" and "image/gif"
            or ext == "png" and "image/png" or "image/png"
        manifest[#manifest + 1] = string.format(
            '<item id="img%d" href="images/%s" media-type="%s"/>',
            i, Epub.escape(name), mime)
    end
    return [[<?xml version="1.0" encoding="utf-8"?>
<package version="3.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:weread:]] .. Epub.escape(book_id) .. [[</dc:identifier>
    <dc:title>]] .. Epub.escape(title) .. [[</dc:title>
    <dc:creator>]] .. Epub.escape(author or "") .. [[</dc:creator>
    <dc:language>zh</dc:language>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="css" href="style.css" media-type="text/css"/>
    ]] .. table.concat(manifest, "\n    ") .. [[
  </manifest>
  <spine toc="ncx">
    ]] .. table.concat(spine, "\n    ") .. [[
  </spine>
</package>]]
end

-- nav.xhtml（EPUB3 目录）
function Epub.build_nav(title, chapters)
    local lis = {}
    for i, ch in ipairs(chapters) do
        lis[#lis + 1] = string.format(
            '    <li><a href="text/chapter-%03d.xhtml">%s</a></li>', i, Epub.escape(ch.title or ""))
    end
    return [[<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>]] ..
Epub.escape(title) .. [[</title></head><body><nav epub:type="toc" id="toc"><h1>]] ..
Epub.escape(title) .. [[</h1><ol>
]] .. table.concat(lis, "\n") .. "\n</ol></nav></body></html>"
end

-- toc.ncx（EPUB2 兼容目录）
function Epub.build_ncx(book_id, title, chapters)
    local points = {}
    for i, ch in ipairs(chapters) do
        points[#points + 1] = string.format(
            [[  <navPoint id="np%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="text/chapter-%03d.xhtml"/></navPoint>]],
            i, i, Epub.escape(ch.title or ""), i)
    end
    return [[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:weread:]] .. Epub.escape(book_id) .. [["/></head>
  <docTitle><text>]] .. Epub.escape(title) .. [[</text></docTitle>
  <navMap>
]] .. table.concat(points, "\n") .. "\n  </navMap>\n</ncx>"
end

-- 文件名净化（设备/USB 两侧安全）
local function filename_safe(s)
    s = tostring(s or ""):gsub('[\\/:*?"<>|%z%c]', "_")
    return #s > 0 and s or "book"
end

-- 导出整本。chapters = manifest 章表（chapterIdx/chapterUid/title）；
-- on_progress(done, total, title) 返回 false → 取消。
-- 返回 path | nil, err
function Epub.export(book_id, chapters, title, author, on_progress)
    if type(chapters) ~= "table" or #chapters == 0 then
        return nil, "no chapters"
    end
    -- 1) 章节内容 + 图片引用收集
    local entries = {
        mimetype = "application/epub+zip",
        ["META-INF/container.xml"] = Epub.CONTAINER,
    }
    local chapter_xhtmls, image_names, seen_img = {}, {}, {}
    for i, ch in ipairs(chapters) do
        local raw = Download.read_raw(book_id, ch.chapterUid)
        if not raw then
            -- 老缓存降级：纯文本包 <p>（图丢失，内容可读）
            raw = Epub.text_to_xhtml(Download.read_chapter(book_id, ch.chapterIdx), ch.title)
        end
        -- xhtml 里的相对 src（../Images/x.png）不改写：浏览器口径下相对路径
        -- 指向包内不存在文件会丢图——这里直接重写为 images/<name>
        raw = raw:gsub('(<img[^>]-src%s*=%s*")([^"]+)(")',
            function(pre, src, post)
                local name = src:match("([^/]+)%??[^/]*$") or src
                return pre .. "images/" .. name .. post
            end)
        chapter_xhtmls[i] = raw
        for _, name in ipairs(Epub.collect_images(raw)) do
            if not seen_img[name] then
                seen_img[name] = true
                image_names[#image_names + 1] = name
            end
        end
    end
    for i, ch in ipairs(chapters) do
        entries[string.format("OEBPS/text/chapter-%03d.xhtml", i)] = chapter_xhtmls[i]
    end
    for _, name in ipairs(image_names) do
        -- 资产在 imgcache 任一章目录下：按名扫该书全部章目录
        local data
        for _, ch in ipairs(chapters) do
            local f = io.open(Download.asset_dir(book_id, ch.chapterUid) .. "/" .. name, "rb")
            if f then
                data = f:read("*a")
                f:close()
                break
            end
        end
        if data then
            entries["OEBPS/images/" .. name] = data
        else
            Log.info("epub export: missing asset " .. name)
        end
    end
    entries["OEBPS/content.opf"] = Epub.build_opf(book_id, title, author, chapters, image_names)
    entries["OEBPS/nav.xhtml"] = Epub.build_nav(title, chapters)
    entries["OEBPS/toc.ncx"] = Epub.build_ncx(book_id, title, chapters)
    entries["OEBPS/style.css"] = Epub.CSS

    -- 2) 进度回报 + 取消（图片/章多时给 UI 机会）
    if on_progress then
        for i, ch in ipairs(chapters) do
            if on_progress(i, #chapters, ch.title) == false then
                return nil, "cancelled"
            end
        end
    end

    -- 3) zip 落盘（原子：先 tmp 再改名）
    os.execute("mkdir -p '" .. Epub.EXPORT_DIR .. "'")
    local path = Epub.EXPORT_DIR .. "/" .. filename_safe(title) .. "-" .. tostring(book_id) .. ".epub"
    local tmp = path .. ".tmp"
    local ok, err = wr.zip_write(tmp, entries)
    if not ok then
        return nil, "zip: " .. tostring(err)
    end
    -- 最小完整性自检：mimetype 必须在 zip 首条（epub 规范）
    local zf = io.open(tmp, "rb")
    local head = zf and zf:read(38) or ""
    if zf then zf:close() end
    if head:sub(1, 4) ~= "PK\x03\x04" or not head:find("mimetype", 31, true) then
        os.remove(tmp)
        return nil, "zip self-check failed"
    end
    os.remove(path)
    if not os.rename(tmp, path) then
        os.remove(tmp)
        return nil, "rename failed"
    end
    Log.info(string.format("epub export: %s (%d chapters, %d images) -> %s",
        book_id, #chapters, #image_names, path))
    return path
end

return Epub
