-- tests/report_retry_test.lua — 上报被服务端判为会话过期时的行为（DK-3.5 真机踩到）。
--
-- 起因：真机 read_report_smoke 第一次跑回 `errCode=-2012 status=200`——GET 全部正常、
-- 只有 /web/book/read 被拒。插件的判据（weread/lib/read_report.lua:173-180）：服务端
-- 会话没了就用 -2012/-2013 回答（HTTP 仍 200），对策是「续期 + 重试一次」（同文件:118）。
-- 本仓阅读侧刻意不做 30s 心跳，所以一章读完再上报时 wr_skey 很可能已经过龄——
-- 这条重试不是可选项，是无心跳设计的必要补偿。
--
-- 只测行为：喂给它什么响应，看它发几次请求、续期几次、最后回什么。
package.path = "src/lua/lib/?.lua;src/lua/?.lua;" .. package.path

local Api = require("api")
local Auth = require("auth")
local Report = require("report")

local fails = 0
local function check(cond, name, detail)
    if not cond then
        fails = fails + 1
        print("  FAIL report_retry: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end

local api_orig, renew_orig = Api.request, Auth.renew
local function restore()
    Api.request, Auth.renew = api_orig, renew_orig
end

-- 编排一次场景：responses 为依次返回的 {data, status}；renew_verdict 为续期返回值。
-- 返回 send 的结果与计数。
local function scenario(responses, renew_verdict)
    local posts, renews = 0, 0
    Api.request = function(opts)
        if opts.method ~= "POST" or opts.url ~= Report.URL then
            error("上报只该打 POST " .. Report.URL .. "，实得 "
                .. tostring(opts.method) .. " " .. tostring(opts.url))
        end
        posts = posts + 1
        local r = responses[posts] or responses[#responses]
        return r[1], r[2]
    end
    Auth.renew = function(force)
        renews = renews + 1
        check(force == nil or force == false, "续期不得用 force（冷却就是重试上限）")
        return renew_verdict or "cooling"
    end
    local ok, res, err = pcall(Report.send, {
        book_id = "3300235630", psvts = "psvts-value",
        elapsed_seconds = 12,
        position = { chapter_uid = "15", chapter_idx = 15, chapter_offset = 900, percent = 96 },
    })
    if not ok then restore(); error(res) end
    return { res = res, err = err, posts = posts, renews = renews }
end

-- 1) 首次就被收下：不多发一个请求，也不多续一次
local s = scenario({ { { succ = true }, 200 } })
check(s.res and s.res.accepted == true, "accepted 透传服务端成功", s.err)
check(s.posts == 1 and s.renews == 0, "成功路径必须零额外请求/零续期",
    string.format("posts=%d renews=%d", s.posts, s.renews))

-- 2) -2012（登录超时）→ 续期一次；续上了就重试，重试被收下
s = scenario({ { { errCode = -2012 }, 200 }, { { succ = true }, 200 } }, "replaced")
check(s.res and s.res.accepted == true, "-2012 续期后重试成功应判 accepted", s.err)
check(s.posts == 2, "续期后必须重试一次", "posts=" .. s.posts)
check(s.renews == 1, "只续一次，不许连环续期", "renews=" .. s.renews)

-- 3) -2013 同属会话类
s = scenario({ { { errCode = -2013 }, 200 }, { { synckey = "k" }, 200 } }, "replaced")
check(s.res and s.res.accepted == true, "-2013 也走同一条自愈路", s.err)
check(s.posts == 2, "-2013 必须重试一次", "posts=" .. s.posts)

-- 4) 冷却中（renew 回 cooling）→ 绝不重试：弱网下失败的上报不该翻倍打服务端
s = scenario({ { { errCode = -2012 }, 200 } }, "cooling")
check(s.res == nil and s.posts == 1 and s.renews == 1,
    "续期被冷却挡住时必须就此收手，不多发一次",
    string.format("posts=%d renews=%d res=%s", s.posts, s.renews, tostring(s.res)))
check(s.err and s.err:find("2012", 1, true) ~= nil, "错误里要留得住 -2012 这个线索", s.err)

-- 5) 重试仍被拒 → 只重试一次就收手，并把 errCode 报出来
s = scenario({ { { errCode = -2012 }, 200 }, { { errCode = -2012 }, 200 } }, "replaced")
check(s.res == nil and s.posts == 2 and s.renews == 1,
    "重试上限一次，失败不得无限自愈",
    string.format("posts=%d renews=%d", s.posts, s.renews))

-- 6) 非会话类错误（服务端明确拒绝参数）→ 不动凭据、不续期
s = scenario({ { { errCode = -2022 }, 200 } }, "replaced")
check(s.res == nil and s.posts == 1 and s.renews == 0,
    "只有会话类 errCode 才允许触发续期",
    string.format("posts=%d renews=%d", s.posts, s.renews))

-- 7) 传输层失败（连不上）→ 判不出 errCode，绝不据此续期（凭据未知，见续期纪律）
s = scenario({ { nil, "timeout" } }, "replaced")
check(s.res == nil and s.posts == 1 and s.renews == 0,
    "网络失败不得被当成会话过期",
    string.format("posts=%d renews=%d", s.posts, s.renews))

-- 8) 没有 psvts 时依旧一票否决（派生写要参数齐全，续期逻辑不得绕过它）
do
    local posts = 0
    Api.request = function() posts = posts + 1 return { succ = true }, 200 end
    local res, err = Report.send({ book_id = "1", psvts = "",
        position = { chapter_uid = "1", chapter_idx = 1, chapter_offset = 0, percent = 0 } })
    check(res == nil and err == "NO-PSVTS" and posts == 0,
        "NO-PSVTS 必须在任何请求之前拦住", string.format("res=%s posts=%d", tostring(res), posts))
end

restore()
return fails
