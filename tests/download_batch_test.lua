-- Download.book 的批量契约：汇总、跳过、取消、回调异常隔离。
--
-- 为什么值得写：菜单的「下载全本/后面 5 章」把结果文案全押在这三个数上，而上一版
-- 是调用方自己回数——回数的那份目录和写 _err 的那份不是同一张表，汇总永远是
-- "成功 0 失败 0"（真机用户可见的错）。取消是新加的：151 章的全本下载没有退出
-- 通道就等于没有该功能。
--
-- 网络与磁盘全部截在 Download 自己的可替换字段上（模块表即接缝），
-- 断言的是调用次数与 stats，不是内部实现。
--
-- 契约：suite 返回失败计数（勿 os.exit）。

package.path = "src/lua/lib/?.lua;src/lua/?.lua;" .. package.path

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL dl_batch: " .. msg)
        fails = fails + 1
    end
end

local saved = { download = package.loaded.download, api = package.loaded.api }
package.loaded.download, package.loaded.api = nil, nil

local Download = require("download")
local saved_field = {}
for _, k in ipairs({ "fetch_catalog", "is_spooled", "ensure_chapter", "save_chapter" }) do
    saved_field[k] = Download[k]
end

local CAT = {}
for i = 1, 5 do
    CAT[i] = { chapterUid = "u" .. i, chapterIdx = 10 + i, title = "第" .. i .. "章", wordCount = 100 }
end

local fetched, spooled, fail_at
local function reset()
    fetched = {}
    spooled = {}
    fail_at = nil
    Download.fetch_catalog = function() return CAT end
    Download.is_spooled = function(_b, idx) return spooled[idx] == true end
    Download.ensure_chapter = function(_b, _chs, idx)
        fetched[#fetched + 1] = idx
        if fail_at == idx then return nil, "boom-" .. idx end
        return "正文-" .. idx
    end
end
reset()

------------------------------------------------------------------ 用例
-- 1) 正常跑完：stats 三项与实取次数一致
local chs, err, st = Download.book("b1", 5, 1, nil)
check(chs ~= nil and err == nil, "成功路径应返回目录")
check(st and st.total == 5 and st.done == 5 and st.ok == 5 and st.fail == 0
      and st.cancelled == false,
    "5/5/0/未取消，实得 " .. string.format("%s/%s/%s/%s",
        tostring(st and st.done), tostring(st and st.ok),
        tostring(st and st.fail), tostring(st and st.cancelled)))
check(#fetched == 5, "5 章都应取正文，实得 " .. #fetched)

-- 2) 单章失败不中断，且计入 fail（后续章节可能正常）
reset()
fail_at = CAT[3].chapterIdx
_, _, st = Download.book("b1", 5, 1, nil)
check(st.ok == 4 and st.fail == 1 and st.done == 5,
    string.format("中间一章失败应为 ok4/fail1/done5，实得 %d/%d/%d",
        st.ok, st.fail, st.done))
check(CAT[3]._err ~= nil and CAT[5]._err == nil,
    "_err 应写在失败那章（供 reader 缺章提示）")

-- 3) 回调返回 false = 取消：立即停手，不再多发一次网络请求
reset()
local seen = 0
_, _, st = Download.book("b1", 5, 1, function(done, total, title)
    seen = done
    if done == 2 then return false end
end)
check(st.cancelled == true, "取消必须标记在 stats 上（菜单文案靠它区分完成/已取消）")
check(st.done == 2 and st.ok == 2 and seen == 2,
    "取消应停在第 2 章，实得 done=" .. st.done .. " 回调末值=" .. seen)
check(#fetched == 2,
    "取消后不得再取后面的章（K4 上多一章就是多一次风控暴露），实得取了 " .. #fetched .. " 次")

-- 4) 回调抛错不毁掉整批（pcall 隔离），也不把章判成失败
reset()
_, _, st = Download.book("b1", 5, 1, function() error("ui boom") end)
check(st.done == 5 and st.fail == 0 and st.cancelled == false,
    "回调报错时整批仍应跑完且不误判失败，实得 " ..
    string.format("%d/%d/%s", st.done, st.fail, tostring(st.cancelled)))

-- 5) 命中缓存的章不触网、算成功（幂等 = 续传）
reset()
spooled[CAT[1].chapterIdx] = true
spooled[CAT[2].chapterIdx] = true
_, _, st = Download.book("b1", 5, 1, nil)
check(#fetched == 3, "已 spool 的 2 章不该再取，实得取了 " .. #fetched .. " 次")
check(st.ok == 5 and st.fail == 0 and st.done == 5,
    "缓存章也计入成功（用户口径：全本 5/5）")

-- 6) 全本口径：max_chapters = math.huge → total 收敛到目录长度
reset()
_, _, st = Download.book("b1", math.huge, 1, nil)
check(st.total == 5 and st.done == 5,
    "math.huge 应等于「到最后一章」，实得 total=" .. tostring(st.total))
-- 起始位置越界必须夹回末章，而不是算出负的 total
reset()
_, _, st = Download.book("b1", 3, 99, nil)
check(st.total == 1 and st.done == 1,
    "start_pos 越界应夹到末章（total=1），实得 " .. tostring(st.total))
reset()
_, _, st = Download.book("b1", 2, 4, nil)
check(st.total == 2 and st.done == 2, "末章前 2 章，实得 " .. tostring(st.total))

-- 7) 目录取不到时仍是 nil, err（菜单「下载失败」分支的前提）
reset()
Download.fetch_catalog = function() return nil, "http 500" end
local c7, e7, s7 = Download.book("b1", 5, 1, nil)
check(c7 == nil and type(e7) == "string" and e7:find("500", 1, true) ~= nil,
    "目录失败应返回 nil + 原因，实得 " .. tostring(e7))
check(s7 == nil, "目录失败不该有 stats")

------------------------------------------------------------------ 还原
for k, v in pairs(saved_field) do Download[k] = v end
package.loaded.download, package.loaded.api = saved.download, saved.api

print("dl_batch done: " .. (fails == 0 and "ALL PASS" or "FAILS=" .. fails)
    .. " (fails=" .. fails .. ")")
return fails
