-- report_calib.lua — 上报位置换算的标定（只读：一次都不写服务端）。
--
-- 为什么要跑它：report.position_of 产出两个位置字段，而它们的单位是我从插件
-- position_mapper.lua:186-209 推来的假设——co=章内字数、pr=(前序章字数+本章偏移)/全书字数。
-- 零位移验收只是把服务端自己的值原样回写，证明的是「签名面被收下」，
-- **没有**证明这套换算能解释服务端的真实数据。接线一旦跑起来换算就会写进
-- 用户手机端的进度，那是可感知的损害，所以先量一遍。
--
-- 两个问题分开问，因为可判定性完全不同：
--   Q1 co 的上界：服务端的 co 会不会超过本章 wordCount？超过 → 服务端不校验 co，
--      它只是「按同套约定互认的客户端之间的提示」。
--   Q2 pr 是不是由 co 推出来的：把 pr 按字数模型反解回章内偏移，落在不在 co 上？
--      只有 pr 是「书内未完成」的中间值、且 pr 的分辨率够细（1 个百分点 <= 本章字数）时
--      才可判；pr=0 / pr=100 的行不含信息（反解出的是负偏移或整章），一律记 NA 而不是 OK。
--      多数行不自洽 = 服务端各存各的（pr 不是 co 的函数）→ 后果：我方算的 pr 会被原样记住，
--      所以换算不可信时必须拒发，而不是「发出去再看」。
--
-- 用法：. tools/k4-env.local.sh && ssh -p "$K4_PORT" "$K4_HOST"
--       'cd /mnt/us/weread && ./weread-dyn lua/report_calib.lua'
-- 弱网下一本书两次请求（getprogress + 目录），书架上百本，所以有 DEADLINE_S 硬预算：
-- 到点就停并说明「本次只采到这些」，绝不把样本当全量。

package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path

local Api = require("api")
local Download = require("download")

local DEADLINE_S = 150          -- 网络预算；超出就停止采样（结论标注样本量）
local Q2_SLACK = 2              -- 目录 wordCount 与真实正文字数的系统性误差（字数/字元、排版）

assert(Api.has_login(), "需要登录态（本脚本不扫码）")

local shelf = Api.get_shelf()
local books = shelf and shelf.books
if type(books) ~= "table" then
    print("shelf failed")
    os.exit(1)
end

local t0 = os.time()
local sampled, skipped = 0, 0
local co_over, co_within = 0, 0            -- Q1
local q2_in, q2_out, q2_na = 0, 0, 0       -- Q2

print("id ci co words total pr band(co per pr) q2")
for _, b in ipairs(books) do
    if os.time() - t0 >= DEADLINE_S then
        print(string.format("-- deadline %ds reached, sampling stopped", DEADLINE_S))
        break
    end
    local id = b.bookId
    if id and tostring(id):sub(1, 7) ~= "MP_WXS_" then
        local data = Api.get_progress(id)
        local rec = type(data) == "table"
            and (type(data.book) == "table" and data.book or data) or nil
        local co = rec and tonumber(rec.chapterOffset)
        local pr = rec and tonumber(rec.progress)
        local idx = rec and tonumber(rec.chapterIdx or rec.chapterIndex)
        if co and pr and idx then
            local chapters = Download.fetch_catalog(id)
            local pos = chapters and #chapters > 0
                and Download.chapter_pos(chapters, idx) or nil
            if pos then
                local total, before = 0, 0
                for i, ch in ipairs(chapters) do
                    local w = math.floor(tonumber(ch.wordCount) or 0)
                    total = total + w
                    if i < pos then before = before + w end
                end
                local words = math.floor(tonumber(chapters[pos].wordCount) or 0)
                sampled = sampled + 1

                -- Q1
                if words > 0 and co > words then
                    co_over = co_over + 1
                else
                    co_within = co_within + 1
                end

                -- Q2：pr 反解出的章内偏移区间（pr 只到整数个百分点 → 半个点为界）
                local band_lo = math.max(0, (pr - 0.5) / 100 * total - before) - Q2_SLACK
                local band_hi = (pr + 0.5) / 100 * total - before + Q2_SLACK
                local resolvable = words > 0 and total > 0 and pr > 0 and pr < 100
                    and total / 100 <= words
                local verdict = "NA"
                if resolvable then
                    if co >= band_lo and co <= band_hi then
                        q2_in = q2_in + 1
                        verdict = "IN"
                    else
                        q2_out = q2_out + 1
                        verdict = "OUT"
                    end
                else
                    q2_na = q2_na + 1
                end
                print(string.format("%s ci=%d co=%d words=%d total=%d pr=%d [%.0f,%.0f] %s",
                    tostring(id), idx, co, words, total, pr, band_lo, band_hi, verdict))
            else
                skipped = skipped + 1
            end
        end
    end
end

print(string.format(
    "calib: sampled=%d skipped=%d  Q1 co>wordCount=%d co<=words=%d  Q2 IN=%d OUT=%d NA=%d",
    sampled, skipped, co_over, co_within, q2_in, q2_out, q2_na))
if sampled == 0 then
    print("calib: 无可采样书籍（书架无服务端进度或目录失败）")
    os.exit(1)
end
if co_over > 0 then
    print(string.format(
        "calib: 服务端 co 有 %d/%d 本超过本章 wordCount → 服务端存的 co 不是「章内字数」，"
        .. "且服务端对 co 不校验、原样存。含义：co 只能当作「我方发出的字数提示」，"
        .. "跨客户端唯一可信的位置字段是 progress；本仓任何读路径都不得反解 co。",
        co_over, sampled))
end
local decidable = q2_in + q2_out
if decidable == 0 then
    print("calib: Q2 无可判定行（没有 0<pr<100 且分辨率足够的小书）"
        .. " → 「服务端是否由 co 推导 pr」未测出结论")
elseif q2_out > q2_in then
    print(string.format(
        "calib: 仅 %d/%d 个可判定点的 pr 能由 co 按字数推出 → 服务端不由 co 反推 pr，"
        .. "co 与 pr 各存各的。后果：我方算出的 pr 会被原样记住，换算不可信时必须拒发"
        .. "（report.MIN_AVG_WORDS），而不是发出去再看。", q2_in, decidable))
else
    print(string.format(
        "calib: %d/%d 个可判定点自洽 → 服务端可能在由 co 推导 pr，"
        .. "此时 co 的单位是硬约束，position_of 必须与之一致", q2_in, decidable))
end
os.exit(0)
