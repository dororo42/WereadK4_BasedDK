-- report.lua 位置换算主机单测：把「本地页码」映射成服务端进度语义
-- （chapter_offset 按**章内字数**发、percent 是**按累计字数的全书百分比**）。
-- 约定出处：weread_K4.koplugin/weread/lib/position_mapper.lua:186-209。注意这是客户端
-- 之间的约定：真机标定（lua/report_calib.lua）证明服务端对 co/pr 各自原样存、不从 co
-- 反推 pr，所以换算错了会被直接记住——第 9~11 组钉的就是「不可信时拒答」这条底线。
-- 页码约定：page 是「当前看到的页」，所以偏移 = (page-1)/total_pages * wordCount。
local Report = require("report")

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL report_position: " .. msg)
        fails = fails + 1
    end
end

local function catalog(...)
    local t = { ... }
    for i, ch in ipairs(t) do
        ch.chapterUid = ch.chapterUid or tostring(100 + i)
    end
    return t
end

-- 1) 单章：首页 = 偏移 0（还没读完任何一页）
local one = catalog({ chapterIdx = 1, wordCount = 1000 })
local p = Report.position_of(one, 1, 1, 10)
check(p and p.chapter_offset == 0, "第 1 页偏移应为 0，实得 " .. tostring(p and p.chapter_offset))
check(p and p.percent == 0, "单章首页 percent 应为 0")

-- 2) 单章中段：第 6/10 页 = 前 5 页读完 = 500 字 = 50%
p = Report.position_of(one, 1, 6, 10)
check(p and p.chapter_offset == 500, "6/10 页偏移应为 500，实得 " .. tostring(p and p.chapter_offset))
check(p and p.percent == 50, "6/10 页 percent 应为 50，实得 " .. tostring(p and p.percent))

-- 3) 多章：偏移只算当前章内，percent 必须把前面章的字数累加进去
local two = catalog(
    { chapterIdx = 1, wordCount = 1000 },
    { chapterIdx = 2, wordCount = 1000 })
p = Report.position_of(two, 2, 3, 10)
check(p and p.chapter_offset == 200, "第二章 3/10 页章内偏移应为 200（不含前章）")
check(p and p.percent == 60, "前章 1000 + 本章 200 = 60%，实得 " .. tostring(p and p.percent))
check(p and p.chapter_idx == 2 and p.chapter_uid == "102",
      "chapter_idx / chapter_uid 必须取自目录记录（服务端认 chapterUid，不认数组下标）")

-- 4) chapterIdx 不连续：服务端值不能当数组下标用（已知坑），这里是 7/8 号章
local gap = catalog(
    { chapterIdx = 7, wordCount = 1000 },
    { chapterIdx = 8, wordCount = 3000 })
p = Report.position_of(gap, 8, 5, 10)
check(p and p.chapter_offset == 1200,
      "章号不连续时仍按目录顺序累加，实得 " .. tostring(p and p.chapter_offset))
check(p and p.percent == 55, "(1000+1200)/4000 = 55%，实得 " .. tostring(p and p.percent))

-- 5) 全书字数为 0（目录没有可用字数）：必须拒答，不许报 percent=0
--    服务端把 pr 原样存（见 report_calib.lua 的标定），报 0 等于把用户进度清零。
local zero = catalog({ chapterIdx = 1, wordCount = 0 })
local err
p, err = Report.position_of(zero, 1, 5, 10)
check(p == nil and err ~= nil, "全书字数为 0 时必须拒答，实得 "
    .. (p and ("percent=" .. tostring(p.percent)) or "nil"))
check(err == "catalog_words_unusable", "拒答原因应为 catalog_words_unusable，实得 " .. tostring(err))

-- 6) 越界输入被夹紧：page 超界 / 负数 / total_pages=0 都不得产出越界偏移或非法 percent
p = Report.position_of(one, 1, 999, 10)
check(p and p.chapter_offset <= 1000 and p.percent <= 100 and p.percent >= 0,
      "page 越界必须夹进合法区间，实得 offset=" .. tostring(p and p.chapter_offset)
          .. " percent=" .. tostring(p and p.percent))
p = Report.position_of(one, 1, -3, 0)
check(p and p.chapter_offset == 0,
      "total_pages=0 / page 负数 → 偏移 0，实得 " .. tostring(p and p.chapter_offset))

-- 7) 章不在目录里 → 明确失败，不许悄悄按第 1 章上报（那会把服务端位置拽回开头）
p, err = Report.position_of(two, 99, 1, 10)
check(p == nil and err ~= nil, "章不在目录时必须回 nil + 原因")

-- 8) 纯函数纪律：同输入两次结果逐字段相同，且不改动传进来的目录、不返回共享表
local before = two[1].wordCount
local a = Report.position_of(two, 2, 4, 12)
local b = Report.position_of(two, 2, 4, 12)
check(a.chapter_offset == b.chapter_offset and a.percent == b.percent, "position_of 必须是纯函数")
check(two[1].wordCount == before and a ~= b, "不得就地修改目录，也不得返回同一张可被改写的表")

-- 9) 假字数目录（真机标定采到的形态：一整本书每章 wordCount=1~4，total 只有 138）
--    这种目录算出的 percent 会把「97%」的书报成个位数——拒答比报错强。
local junk = {}
for i = 1, 40 do junk[i] = { chapterIdx = i, wordCount = 3 } end
p, err = Report.position_of(junk, 4, 5, 10)
check(p == nil and err == "catalog_words_unusable",
      "每章平均字数低到不可能是真字数时必须拒答，实得 "
        .. (p and ("percent=" .. tostring(p.percent)) or tostring(err)))

-- 10) 但拒答线不能过宽：短篇/薄目录（每章几十~几百字）仍要能上报
local thin = catalog(
    { chapterIdx = 1, wordCount = 60 },
    { chapterIdx = 2, wordCount = 80 })
p = Report.position_of(thin, 2, 3, 10)
check(p and p.chapter_offset == 16 and p.percent == 54,
      "薄目录（每章 60~80 字）仍应换算：(60+16)/140=54%，实得 "
        .. (p and string.format("offset=%s percent=%s",
            tostring(p.chapter_offset), tostring(p.percent)) or "nil"))

-- 11) 前言/空白章混在正常目录里（个别 wordCount=0）不应触发拒答：全书平均仍可用
local mixed = catalog(
    { chapterIdx = 1, wordCount = 0 },
    { chapterIdx = 2, wordCount = 2000 },
    { chapterIdx = 3, wordCount = 2000 })
p = Report.position_of(mixed, 3, 6, 10)
check(p and p.chapter_offset == 1000 and p.percent == 75,
      "单章 wordCount=0 只影响该章偏移，不该让整本拒答，实得 "
        .. (p and string.format("offset=%s percent=%s",
            tostring(p.chapter_offset), tostring(p.percent)) or "nil"))

return fails
