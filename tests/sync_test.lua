-- sync.lua 的纯逻辑单测：云端进度取数、云端→本地映射、两侧取舍。
--
-- 为什么值得写：这条链的输入是服务端 JSON（形态有两种：{book={…}} 与裸记录，
-- 真机取证见 report_calib.lua），输出是"跳到哪一章的哪一页"。映射算错的后果不是
-- 崩溃而是**把用户读过的地方当成没读**，静默且不可逆（下一次上报会把它写回服务端）。
-- 所以三种判异口径（percent 可比 / 章序兜底 / 本地无记录）都必须钉住。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

package.path = "src/lua/lib/?.lua;src/lua/?.lua;" .. package.path

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL sync: " .. msg)
        fails = fails + 1
    end
end

local saved = {
    sync = package.loaded.sync, api = package.loaded.api, download = package.loaded.download,
}
package.loaded.sync, package.loaded.api = nil, nil

local progress = nil
package.loaded.api = {
    get_progress = function() return progress end,
}
local Sync = require("sync")
local Download = require("download")

local CAT = {}
for i = 1, 6 do
    CAT[i] = { chapterUid = "u" .. i, chapterIdx = 9 + i, title = "第" .. i .. "章", wordCount = 200 }
end

------------------------------------------------------------------ remote() 取数与归一
-- 1) 嵌套形态 {book={…}}
progress = { book = { chapterUid = "u4", chapterIdx = 13, chapterOffset = 50,
                      progress = 42.5, updateTime = 1700000000, summary = "第四章" } }
local r, e = Sync.remote("b1")
check(r ~= nil, "嵌套形态应解析成功，实得 err=" .. tostring(e))
check(r and r.chapter_uid == "u4" and r.chapter_idx == 13 and r.offset == 50
      and r.percent == 42.5 and r.updated == 1700000000 and r.title == "第四章",
    "字段应逐项归一，实得 " .. string.format("%s/%s/%s/%s",
        tostring(r and r.chapter_uid), tostring(r and r.offset),
        tostring(r and r.percent), tostring(r and r.title)))

-- 2) 裸记录形态 + chapterIndex 别名 + readingProgress 别名
progress = { chapterUid = 7, chapterIndex = "15", chapterOffset = "30",
             readingProgress = "60" }
r = Sync.remote("b1")
check(r and r.chapter_uid == "7" and r.chapter_idx == 15 and r.offset == 30 and r.percent == 60,
    "数字字符串必须归一成数字、uid 归一成字符串（服务端两型混发），实得 " ..
    string.format("%s/%s/%s/%s", tostring(r and r.chapter_uid), tostring(r and r.chapter_idx),
        tostring(r and r.offset), tostring(r and r.percent)))

-- 3) errCode 非零 = 通道失败，不能当成"云端没进度"
progress = { errCode = -2012 }
r, e = Sync.remote("b1")
check(r == nil and e and e:find("-2012", 1, true) ~= nil,
    "errCode 应原样回传（会话失效由调用方的续期逻辑判），实得 " .. tostring(e))

-- 4) 传输失败 / 无位置字段：两种失败必须可区分
progress = nil
r, e = Sync.remote("b1")
check(r == nil and e and e:find("request failed", 1, true) ~= nil,
    "nil 响应应报传输失败，实得 " .. tostring(e))
progress = { errCode = 0, summary = "只有标题" }
r, e = Sync.remote("b1")
check(r == nil and e ~= nil, "既无 uid 又无 idx 应判无位置字段，实得 " .. tostring(e))
progress = { errCode = "0" }
r = Sync.remote("b1")
check(r == nil, "errCode 字符串 \"0\" 也算无位置字段而非通道失败")

------------------------------------------------------------------ target() 云端 → 本地
-- 5) uid 命中优先，idx 只兜底
local remote = { chapter_uid = "u3", chapter_idx = 99, offset = 100, percent = 30 }
local t, terr = Sync.target(remote, CAT)
check(t ~= nil, "uid 命中应映射成功，实得 err=" .. tostring(terr))
check(t and t.pos == 3 and t.chapter_idx == 12 and t.chapter_uid == "u3" and t.title == "第3章",
    "目标章应取目录里的那条（idx 与 uid 冲突时信 uid），实得 " ..
    string.format("%s/%s", tostring(t and t.pos), tostring(t and t.chapter_idx)))
remote = { chapter_uid = "u404", chapter_idx = 11, offset = 0 }
t = Sync.target(remote, CAT)
check(t and t.pos == 2, "uid 对不上时应用 chapterIdx 兜底，实得 " .. tostring(t and t.pos))
remote = { chapter_uid = "u404", chapter_idx = 77, offset = 0 }
t, terr = Sync.target(remote, CAT)
check(t == nil and terr == "chapter_not_in_catalog",
    "两把钥匙都对不上必须拒绝，实得 " .. tostring(terr))

-- 6) 章内比例：offset/wordCount，越界夹到 1，字数不可用退到章首
remote = { chapter_uid = "u2", offset = 100, percent = 10 }
t = Sync.target(remote, CAT)
check(t and math.abs(t.fraction - 0.5) < 1e-9, "200 字读到 100 → 0.5，实得 " .. tostring(t and t.fraction))
remote = { chapter_uid = "u2", offset = 99999 }
t = Sync.target(remote, CAT)
check(t and t.fraction == 1, "offset 超字数必须夹到 1（服务端 co 可大于 wordCount，真机 97/171 本如此）")
CAT[2].wordCount = 0
t = Sync.target({ chapter_uid = "u2", offset = 500 }, CAT)
check(t and t.fraction == 0, "字数目录不可用应退到章首而不是猜页码，实得 " .. tostring(t and t.fraction))
CAT[2].wordCount = 200
t = Sync.target({ chapter_uid = "u2" }, CAT)
check(t and t.fraction == 0, "无 offset 视为章首")

-- 7) 入参防御：空目录 / nil
check(Sync.target(remote, {}) == nil, "空目录应拒绝")
check(Sync.target(nil, CAT) == nil, "nil remote 应拒绝")

------------------------------------------------------------------ choose() 取舍
-- 8) 本地没记录 → 用云端（第一次在这台设备上读）
local side, why = Sync.choose({ percent = 10 }, { pos = 2, chapter_idx = 11 }, nil, nil)
check(side == "remote" and why == "no_local_record",
    "本地无记录应用云端，实得 " .. side .. "/" .. tostring(why))

-- 9) percent 可比：领先>2 用云端，落后>2 留本地，差 2 以内留本地
check(Sync.choose({ percent = 50 }, { pos = 3 }, 40, 3) == "remote", "云端领先 10 点应用云端")
side, why = Sync.choose({ percent = 50 }, { pos = 3 }, 49, 3)
check(side == "local" and why == "same", "差 1 点属噪声，不该打扰用户，实得 " .. tostring(why))
side, why = Sync.choose({ percent = 50 }, { pos = 3 }, 80, 3)
check(side == "local" and why == "local_ahead", "本地更靠前必须留本地，实得 " .. tostring(why))
check(Sync.choose({ percent = 50 }, nil, 10, 2) == "local", "映射失败时不该跳转")

-- 10) percent 算不出（老记录无 total_pages）→ 章序兜底
side, why = Sync.choose({ percent = nil }, { pos = 4 }, nil, 2)
check(side == "remote" and why == "remote_ahead_chapter",
    "无 percent 时章序更靠后即可用云端，实得 " .. side .. "/" .. tostring(why))
side, why = Sync.choose({ percent = nil }, { pos = 2 }, nil, 4)
check(side == "local", "章序落后不该跳，实得 " .. tostring(why))

------------------------------------------------------------------ 还原
package.loaded.sync, package.loaded.api, package.loaded.download =
    saved.sync, saved.api, saved.download

print("sync done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails)
    .. " (fails=" .. fails .. ")")
return fails
