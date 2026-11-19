-- 参照实现差分测试：本仓 position_of 必须与插件 position_mapper 的换算逐点一致。
--
-- 为什么单独一套：report_position_test.lua 的期望值是我手算的——手算能保证「符合我对公式的理解」，
-- 保证不了「符合参照实现」。本仓与插件写的是同一个服务端字段，而真机标定已证明服务端原样存 pr、
-- 不从 co 反推（report_calib.lua），所以两边一旦漂移，用户在插件与本客户端之间切换时位置会被写偏。
-- 期望值来自 `lua5.1` 直接调用插件的 local_to_remote()，见 position_golden_vectors.lua 头注释。
--
-- 三类行，判据不同，别混：
--   1 agree        —— 参照实现算得出，本仓必须给出一模一样的 chapter_offset / percent。
--   2 plugin_refused —— 参照实现对 words<=0 的章直接报错；本仓**刻意继续上报**（前言/空白章不该
--      把整本书锁死不更新）。这里钉两件：偏移必须是 0（words=0 ⇒ 该章内不可能推进），
--      以及同一章各页的 percent 必须相同（位置由前序章字数决定，与翻到第几页无关）。
--   3 gated        —— 参照实现算得出但本仓必须**拒答**：平均每章字数低于 MIN_AVG_WORDS
--      （真书架上 8/151 本就是这个形态：整本 wordCount=1~4 的占位目录）。
--      这类行仍带着参照实现的数字，是为了留下「我们当时**没有**把哪个错误位置发出去」的证据。
local Report = require("report")
local Golden = require("position_golden_vectors")

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL position_golden: " .. msg)
        fails = fails + 1
    end
end

local function words_of(ch)
    return math.max(0, math.floor(tonumber(ch and ch.wordCount) or 0))
end

local counts = { agree = 0, plugin_refused = 0, gated = 0 }
local stable_pct = {}

for _, v in ipairs(Golden.vectors) do
    local cat = Golden.catalogs[v.cat]
    local chapters = cat.chapters
    local total = 0
    for _, ch in ipairs(chapters) do total = total + words_of(ch) end
    local p, err = Report.position_of(chapters, v.idx, v.page, v.tp)

    if v.plugin_refused then
        counts.plugin_refused = counts.plugin_refused + 1
        check(p ~= nil, string.format(
            "%s idx=%d page=%d/%d 参照实现报错不等于本仓该拒答（本仓应继续），实得 err=%s",
            cat.name, v.idx, v.page, v.tp, tostring(err)))
        check(p and p.chapter_offset == 0, string.format(
            "%s idx=%d page=%d/%d 该章 wordCount=0 → 章内偏移必须恒为 0，实得 %s",
            cat.name, v.idx, v.page, v.tp, tostring(p and p.chapter_offset)))
        -- 同一章跨页 percent 不变
        local key = v.cat .. ":" .. v.idx
        if p then
            if stable_pct[key] == nil then
                stable_pct[key] = p.percent
            else
                check(p.percent == stable_pct[key], string.format(
                    "%s idx=%d page=%d/%d percent 随翻页漂移了（%s -> %s）：words=0 的章位置只由前序章字数决定",
                    cat.name, v.idx, v.page, v.tp,
                    tostring(stable_pct[key]), tostring(p.percent)))
            end
        end
    elseif total / #chapters < Report.MIN_AVG_WORDS then
        counts.gated = counts.gated + 1
        check(p == nil and err == "catalog_words_unusable", string.format(
            "%s idx=%d page=%d/%d 占位字数目录必须拒答（参照实现会给 off=%s pct=%s，正是不能发出去的数）",
            cat.name, v.idx, v.page, v.tp, tostring(v.off), tostring(v.pct)))
    else
        counts.agree = counts.agree + 1
        check(p ~= nil, string.format("%s idx=%d page=%d/%d 不该拒答，err=%s",
            cat.name, v.idx, v.page, v.tp, tostring(err)))
        check(p and p.chapter_offset == v.off, string.format(
            "%s idx=%d page=%d/%d 章内偏移应为 %d（参照实现），实得 %s",
            cat.name, v.idx, v.page, v.tp, v.off, tostring(p and p.chapter_offset)))
        check(p and p.percent == v.pct, string.format(
            "%s idx=%d page=%d/%d percent 应为 %d（参照实现），实得 %s",
            cat.name, v.idx, v.page, v.tp, v.pct, tostring(p and p.percent)))
    end
end

check(counts.agree >= 300, "agree 采样太少，差分没覆盖到（" .. counts.agree .. "）")
check(counts.plugin_refused == 34, "plugin_refused 行数与生成物不符（" .. counts.plugin_refused .. "）")
check(counts.gated >= 30, "gated 采样太少，拒发线没被这套数据打中（" .. counts.gated .. "）")

print(string.format("position_golden: agree=%d plugin_refused=%d gated=%d (vs %s)",
    counts.agree, counts.plugin_refused, counts.gated,
    "weread_K4.koplugin position_mapper.local_to_remote"))

return fails
