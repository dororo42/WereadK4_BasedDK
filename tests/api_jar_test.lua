-- api.lua「响应绝不弄丢登录态」这条规则的行为测试（主机，无设备）。
--
-- 规则本体在 Api.request 里：已有会话的机器上，只接受「合并后仍是可用会话」的 2xx 响应。
-- 起因是真机实测——服务端一次匿名/超时响应会下发 `wr_skey=`（空值 = 按标准语义删除），
-- 无条件合并把登录态清光，只剩重扫码；而扫码有风控风险，用户明令禁止。
-- 此前这条规则只活在注释里，加上 Makefile 的写入口计数（3 处，全部门禁后置）。
-- 本套把它钉成断言：既钉「不落盘」，也钉「调用方传进来的那份 jar 不被就地改坏」——
-- 后者才是同一次运行里翻页/续读继续可用的前提，落盘保住了但内存里没了 skey 一样要重扫。
local Api = require("api")
local Cookie = require("cookie")

local fails = 0
local function check(cond, msg)
    if not cond then
        print("FAIL api_jar: " .. msg)
        fails = fails + 1
    end
end

------------------------------------------------------------------ 环境桩
local saved_wr = rawget(_G, "wr")
local saved_save = Api.save_auth
local saved_load_auth = Api.load_auth

local req_log, save_log = {}, {}
Api.save_auth = function(auth)
    table.insert(save_log, {
        skey = auth.cookies and auth.cookies.wr_skey,
        rt = auth.cookies and auth.cookies.wr_rt,
        login = Cookie.has_login_cookie(auth.cookies),
    })
    return 1
end
-- 任何一次 request 都不许走磁盘（真机上那文件有登录态，主机上没有）
Api.load_auth = function()
    check(false, "测试路径不该读磁盘 auth.json")
    return { cookies = {}, api_key = "", account = {} }
end

local resp = nil   -- 由每个场景设定：{ body=, status=, headers= }
local function set_resp(body, status, set_cookie)
    resp = { body = body, status = status, headers = set_cookie and { ["set-cookie"] = set_cookie } or {} }
end

wr = {
    http_req = function(t)
        table.insert(req_log, t)
        if resp.body == nil then return nil, "transport: connection reset" end
        return resp.body, resp.status, resp.headers
    end,
}

local function reset()
    req_log, save_log = {}, {}
end

local LOGIN_JAR = function()
    return { wr_skey = "abcdefghij", wr_rt = "rt_token_value", wr_vid = "1234567890" }
end

------------------------------------------------------------------ 场景
-- 1) 200 但下发 `wr_skey=`（删除）→ 既不落盘，也不能把调用方的 jar 就地掏空
reset()
local jar1 = LOGIN_JAR()
set_resp('{"succ":1}', 200, "wr_skey=; Path=/; Domain=.qq.com")
Api.request({ url = "https://weread.qq.com/web/book/any", auth = { cookies = jar1, api_key = "k" } })
check(#save_log == 0, "1) 会清会话的 200 竟然落盘了（save " .. #save_log .. " 次）")
check(Cookie.has_login_cookie(jar1),
    "1) 拒了落盘却把内存 jar 掏空了：wr_skey=" .. tostring(jar1.wr_skey)
        .. "（同一次运行里后续请求会一起没登录态，最后还是只剩扫码）")

-- 2) 合法轮换（新 skey，仍是可用会话）→ 必须落盘，否则轮换白做、下次又 -2012
reset()
local jar2 = LOGIN_JAR()
set_resp('{"succ":1}', 200, "wr_skey=NEWNEWNEW9; wr_rt=rt_rotated_value")
Api.request({ url = "https://weread.qq.com/web/book/any", auth = { cookies = jar2, api_key = "k" } })
check(#save_log == 1, "2) 合法轮换未落盘（save " .. #save_log .. " 次）")
check(save_log[1] and save_log[1].skey == "NEWNEWNEW9", "2) 落盘的不是新 skey")
check(save_log[1] and save_log[1].rt == "rt_rotated_value", "2) 轮换把 wr_rt 弄丢了")

-- 3) 非 2xx 带删除 cookie → 不落盘、内存 jar 完好
reset()
local jar3 = LOGIN_JAR()
set_resp("", 401, "wr_skey=; wr_vid=")
local d3, s3 = Api.request({ url = "https://weread.qq.com/web/book/any", auth = { cookies = jar3, api_key = "k" } })
check(#save_log == 0, "3) 401 也改了凭据盘（save " .. #save_log .. " 次）")
check(Cookie.has_login_cookie(jar3), "3) 401 把内存 jar 掏空了")
check(s3 == 401, "3) 状态码没透传（" .. tostring(s3) .. "）")

-- 4) 登录中途（本来就没会话）→ 不受此限，部分 cookie 也要存，否则登录永远走不完
reset()
local jar4 = { wr_vid = "1234567890" }
set_resp('{"succ":1}', 200, "wr_skey=FIRSTFIRST1")
Api.request({ url = "https://weread.qq.com/cgi-bin/any", auth = { cookies = jar4, api_key = "" } })
check(#save_log == 1, "4) 登录中途的第一份 skey 被门禁挡住了（save " .. #save_log .. " 次）")
check(save_log[1] and save_log[1].login == true, "4) 存下去的那份不是可用会话")

-- 5) no_save（登录流程中途显式不落盘）→ 零次写盘
reset()
local jar5 = LOGIN_JAR()
set_resp('{"succ":1}', 200, "wr_skey=ANOTHERANOT")
Api.request({ url = "https://weread.qq.com/web/book/any", auth = { cookies = jar5, api_key = "k" }, no_save = true })
check(#save_log == 0, "5) no_save 没被尊重（save " .. #save_log .. " 次）")

-- 6) 传输层失败 → 一次都不写，错误串照原样从第二个返回值出来
reset()
local jar6 = LOGIN_JAR()
set_resp(nil, nil, nil)
local d6, e6 = Api.request({ url = "https://weread.qq.com/web/book/any", auth = { cookies = jar6, api_key = "k" } })
check(d6 == nil, "6) 传输失败不该有数据")
check(tostring(e6):find("connection reset") ~= nil, "6) 错误串没透传：" .. tostring(e6))
check(#save_log == 0, "6) 传输失败还写了盘")
check(Cookie.has_login_cookie(jar6), "6) 传输失败弄坏了内存 jar")

-- 7) 200 + 坏 JSON，但会话轮换合法 → 仍要落盘（凭据面与解析面各自独立；
--    否则 -2012 之后拿到一个解析失败的响应就把新 skey 丢了，重试永远学不会）
reset()
local jar7 = LOGIN_JAR()
set_resp("<html>not json</html>", 200, "wr_skey=ROTATEDROT7")
local d7 = Api.request({ url = "https://weread.qq.com/web/book/any", auth = { cookies = jar7, api_key = "k" } })
check(d7 == nil, "7) 坏 JSON 该返回 nil")
check(#save_log == 1, "7) 合法轮换因为解析失败没落盘（save " .. #save_log .. " 次）")

-- 8) 出站 Cookie 头确实带着这份会话（门禁不改变请求侧行为）
reset()
local jar8 = LOGIN_JAR()
set_resp('{"succ":1}', 200, nil)
Api.request({ url = "https://weread.qq.com/web/book/any", auth = { cookies = jar8, api_key = "k" } })
local sent = req_log[1] and req_log[1].headers and req_log[1].headers["Cookie"] or ""
check(sent:find("wr_skey=abcdefghij") ~= nil, "8) 出站 Cookie 头没带登录 cookie")
check(#save_log == 0, "8) 没有任何 set-cookie 也写了盘")

wr = saved_wr
Api.save_auth = saved_save
Api.load_auth = saved_load_auth

print("api_jar: 8 场景（拒写会话破坏者 / 合法轮换必须落盘 / 登录中途不受限 / 传输与解析面独立）")
return fails
