-- html_text_test.lua — epub 剥离器回归：标签剥离/实体/图片占位/块级换行。
package.path = "src/lua/lib/?.lua;src/lua/?.lua;tests/?.lua;" .. package.path
local HtmlText = require("html_text")

local fails = 0
local function check(name, ok, detail)
    print((ok and "PASS " or "FAIL ") .. name .. (detail and ("  " .. detail) or ""))
    if not ok then fails = fails + 1 end
end

-- 1) 段落 → 换行，标签全剥
check("p.strip", HtmlText.to_text("<p>第一段</p><p>第二段</p>") == "第一段\n第二段")

-- 2) 图片占位（封面/插图）
check("img.marker", HtmlText.to_text('<p><img src="../Images/a.jpg"/></p>') == "\1IMG:a.jpg\1")
check("img.nosrc", HtmlText.to_text('<p><img/></p>') == "[图片]")

-- 3) 常见实体
check("entity.named", HtmlText.to_text("A&amp;B&quot;C&quot;") == 'A&B"C"')
check("entity.dec", HtmlText.to_text("&#28176;&#28176;") == "渐渐")
check("entity.hex", HtmlText.to_text("&#x4E2D;&#x6587;") == "中文")

-- 4) 样式/脚本整段移除
check("style.dropped", HtmlText.to_text("<style>p{margin:0}</style><p>正文</p>") == "正文")

-- 5) 空白规整：连续空行折叠
check("blank.collapse", HtmlText.to_text("<p>A</p><p></p><p></p><p>B</p>") == "A\n\nB")

-- 6) 真实结构样例（epub 章节）
local sample = [[<?xml version="1.0"?><html><head><style>.t{font-size:1em}</style></head>
<body><h2>第二章</h2><p>他开始写作&#x3002;</p>
<div class="block"><img src="cover.jpg"/></div>
<p>结尾&amp;完</p></body></html>]]
check("real.sample", HtmlText.to_text(sample) == "第二章\n他开始写作。\n\n\1IMG:cover.jpg\1\n\n结尾&完")

print(string.format("html_text_test done: %s (fails=%d)",
      fails == 0 and "ALL PASS" or "HAS FAILURES", fails))
return fails
