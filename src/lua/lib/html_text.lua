-- html_text.lua — epub xhtml → 纯文本（简版剥离器）。
--
-- DK-2 简版口径：剥标签保留文本；块级标签转换行；img → [图片] 占位（图片渲染
-- 属 DK-3 图片路径）；实体解码（命名常见集 + 数字/十六进制 → UTF-8）。
-- 输出空白规整：行 trim、连续空行折叠为 1。

local HtmlText = {}

local ENT = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
    nbsp = " ", hellip = "…", mdash = "—", ndash = "–",
    ldquo = "“", rdquo = "”", lsquo = "‘", rsquo = "’",
    middot = "·", bull = "•", copy = "©", reg = "®", trade = "™",
}

-- codepoint → UTF-8 字节（与 json.lua 解码端同构）
local function utf8_enc(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096),
            0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144),
        0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

function HtmlText.to_text(xhtml)
    local s = tostring(xhtml or "")
    s = s:gsub("^\xEF\xBB\xBF", "")               -- UTF-8 BOM（freetype 渲染为怪字形）
    -- 图片 → 行内标记 \1IMG:<basename>\1（块级，前后断行）。
    -- src 常为 epub 包内相对路径（../Images/note.png）——只留 basename，
    -- 由 reader 用章资产目录（chapter.tar 解包）解析；解析不到降级 [图片]。
    -- [&amp; 实体此时还没解码，不影响 basename 取尾段]
    s = s:gsub('<%s*img[^>]-src%s*=%s*"([^"]+)"[^>]*>', function(src)
        -- 标记名 = src 最后一段且**去 query**：落盘文件名由 Download.image_urls_from_raw
        -- 用同一套推导（还要过 path_safe，'?' 会变成 '_'）。两侧不一致就等于图永远找不到。
        local base = tostring(src):match("([^/]+)$")
        local name = base and base:match("^[^?]+")
        if not name or name == "" then return "\n[图片]\n" end
        return "\n\1IMG:" .. name .. "\1\n"
    end)
    s = s:gsub("<%s*img[^>]*>", "\n[图片]\n")   -- 无 src 的 img 兜底占位
    -- 块级闭合标签 → 换行（在剥其余标签之前）。
    -- 注意：Lua 模式没有 | 交替——必须逐标签多趟（曾写成 (p|div|…) 逐字面匹配全不命中）。
    for _, tag in ipairs({ "p", "div", "h1", "h2", "h3", "h4", "h5", "h6",
                           "li", "tr", "blockquote", "section" }) do
        s = s:gsub("<%s*/%s*" .. tag .. "%s*>", "\n")
    end
    s = s:gsub("<%s*br[^>]*>", "\n")
    -- 剥其余标签（含样式/脚本整段）
    s = s:gsub("<%s*style[^>]*>.-</%s*style%s*>", "")
    s = s:gsub("<%s*script[^>]*>.-</%s*script%s*>", "")
    s = s:gsub("<[^>]+>", "")
    -- 实体
    s = s:gsub("&#[xX](%x+);", function(h) return utf8_enc(tonumber(h, 16) or 0) end)
    s = s:gsub("&#(%d+);", function(d) return utf8_enc(tonumber(d) or 0) end)
    s = s:gsub("&(%a+);", function(n) return ENT[n] or ("&" .. n .. ";") end)
    -- 空白规整：行 trim + 连续空行折叠为 1
    local out, prev_blank = {}, true
    for line in (s .. "\n"):gmatch("(.-)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line == "" then
            if not prev_blank then
                out[#out + 1] = ""
                prev_blank = true
            end
        else
            out[#out + 1] = line
            prev_blank = false
        end
    end
    -- 尾部 trim：块级闭合产生的末尾换行不进输出
    return (table.concat(out, "\n"):gsub("%s+$", ""))
end

return HtmlText
