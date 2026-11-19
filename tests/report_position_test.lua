-- report.lua 位置换算主机单测：把「本地页码」映射成服务端进度语义
-- （chapterOffset 是**章内字数偏移**、progress 是**按累计字数的全书百分比**）。
-- 判据出处：weread_K4.koplugin/weread/lib/position_mapper.lua:186-209（offset 以
-- wordCount 为界、percent 四舍五入到整数点）。这层错了服务端会记住错的阅读位置，
-- 所以先离线钉住，再谈上报。
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

-- 5) wordCount 缺失/为 0（前言、封面章）：不得除零，偏移恒 0
local zero = catalog({ chapterIdx = 1, wordCount = 0 })
p = Report.position_of(zero, 1, 5, 10)
check(p and p.chapter_offset == 0, "wordCount 为 0 时偏移必须 0")
check(p and p.percent == 0, "全书字数为 0 时 percent 应为 0（不得 nan/inf）")

-- 6) 越界输入被夹紧：page 超界 / 负数 / total_pages=0 都不得产出越界偏移或非法 percent
p = Report.position_of(one, 1, 999, 10)
check(p and p.chapter_offset <= 1000 and p.percent <= 100 and p.percent >= 0,
      "page 越界必须夹进合法区间，实得 offset=" .. tostring(p and p.chapter_offset)
          .. " percent=" .. tostring(p and p.percent))
p = Report.position_of(one, 1, -3, 0)
check(p and p.chapter_offset == 0,
      "total_pages=0 / page 负数 → 偏移 0，实得 " .. tostring(p and p.chapter_offset))

-- 7) 章不在目录里 → 明确失败，不许悄悄按第 1 章上报（那会把服务端位置拽回开头）
local err
p, err = Report.position_of(two, 99, 1, 10)
check(p == nil and err ~= nil, "章不在目录时必须回 nil + 原因")

-- 8) 纯函数纪律：同输入两次结果逐字段相同，且不改动传进来的目录、不返回共享表
local before = two[1].wordCount
local a = Report.position_of(two, 2, 4, 12)
local b = Report.position_of(two, 2, 4, 12)
check(a.chapter_offset == b.chapter_offset and a.percent == b.percent, "position_of 必须是纯函数")
check(two[1].wordCount == before and a ~= b, "不得就地修改目录，也不得返回同一张可被改写的表")

return fails
