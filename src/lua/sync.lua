-- sync.lua — 云端阅读进度 ↔ 本地章节/页位的换算层（「与微信读书端保持一致」的执行者）。
--
-- 分工：本模块只做数据（拉、归一化、映射、判异），不碰屏幕也不提问。提问与跳转
-- 在 menu.read_book——UI 决策只应有一个地方（原先「同步进度」菜单项是死的：
-- 列表里有它，分支里没有，按下去只打印一行"已选择"）。
--
-- 上报方向不在这里：Report.send 已实现（每离开一章随阅读时长一起发 /web/book/read，
-- 服务端没有独立的 setprogress 接口）。两个方向合起来才是"保持一致"。

local Api = require("api")
local Download = require("download")

local Sync = {}

-- 差距小于此值不值得打扰用户（插件 progress_sync.SAME_THRESHOLD_PERCENT 同值）
Sync.SAME_THRESHOLD_PERCENT = 2

-- 拉取并归一化。字段口径来自真机取证（report_calib.lua）：响应可能是 {book={…}}
-- 也可能是裸记录；progress 是 0~100 百分比；chapterOffset 是**章内字数偏移**
-- （客户端之间的约定，服务端原样存、不解释）；chapterUid 才是服务端主键，
-- chapterIdx 可能因目录改版而错位，所以只在 uid 对不上时兜底。
function Sync.remote(book_id)
    local data, status = Api.get_progress(book_id)
    if type(data) ~= "table" then
        return nil, "request failed: " .. tostring(status)
    end
    local code = data.errCode or data.errcode
    if code ~= nil and tostring(code) ~= "0" then
        return nil, "errCode=" .. tostring(code)
    end
    local rec = type(data.book) == "table" and data.book or data
    local out = {
        chapter_uid = rec.chapterUid ~= nil and tostring(rec.chapterUid) or nil,
        chapter_idx = tonumber(rec.chapterIdx or rec.chapterIndex),
        offset = tonumber(rec.chapterOffset),
        percent = tonumber(rec.progress or rec.readingProgress or rec.bookProgress),
        updated = tonumber(rec.updateTime),
        title = rec.summary ~= nil and tostring(rec.summary) or nil,
    }
    if not out.chapter_uid and not out.chapter_idx then
        return nil, "云端没有位置字段（没读过，或接口改版）"
    end
    return out
end

-- 云端位置 → 本地可跳转目标（纯函数，主机单测直接打它）。
-- 返回 { chapter_idx, chapter_uid, title, fraction, percent, pos } | nil, reason。
-- 章内位置只有 offset/wordCount 这一条路；字数目录不可用时退到章首（fraction 0）——
-- 章首仍比整本书从头读准，而"猜一个页码"会把错的进度当成用户的读数写回去。
function Sync.target(remote, chapters)
    if type(remote) ~= "table" or type(chapters) ~= "table" or #chapters == 0 then
        return nil, "input_missing"
    end
    local pos
    if remote.chapter_uid then
        for i, ch in ipairs(chapters) do
            if tostring(ch.chapterUid) == remote.chapter_uid then
                pos = i
                break
            end
        end
    end
    if not pos and remote.chapter_idx then
        pos = Download.chapter_pos(chapters, remote.chapter_idx)
    end
    if not pos then return nil, "chapter_not_in_catalog" end

    local ch = chapters[pos]
    local words = math.floor(tonumber(ch.wordCount) or 0)
    local fraction = 0
    if words > 0 and remote.offset and remote.offset > 0 then
        fraction = math.min(remote.offset, words) / words
    end
    return {
        chapter_idx = ch.chapterIdx,
        chapter_uid = ch.chapterUid,
        title = ch.title,
        pos = pos,
        fraction = fraction,
        percent = remote.percent,
    }
end

-- 该用哪一侧，返回 "remote"|"local", 原因。策略口径：
-- 云端领先（或本地从没记过）就用云端——这正是"与微信读书端保持一致"；云端落后或
-- 差距在阈值内就保留本地，本地位置随后由 Report.send 推上去，两个方向都在收敛，
-- 不需要弹窗让用户做选择题（五向键上每一次提问都是成本）。
-- 可比时按 percent（跨端一致的真口径）；percent 算不出（缺 total_pages 或字数目录
-- 被拒发线挡住）时退到章序比较——两者回答的是同一个问题：谁读得更靠后。
function Sync.choose(remote, target, local_percent, local_pos)
    if not target then return "local", "no_remote_target" end
    local rp = remote and tonumber(remote.percent)
    if rp ~= nil and local_percent ~= nil then
        local gap = rp - local_percent
        if gap > Sync.SAME_THRESHOLD_PERCENT then return "remote", "remote_ahead" end
        if gap < -Sync.SAME_THRESHOLD_PERCENT then return "local", "local_ahead" end
        return "local", "same"
    end
    if local_pos == nil then return "remote", "no_local_record" end
    if target.pos > local_pos then return "remote", "remote_ahead_chapter" end
    return "local", "same_or_local_ahead_chapter"
end

return Sync
