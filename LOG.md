# LOG — 动作日志（ub-mode）

## 2026-11-19 · DK-3.5 阅读上报落地：签名面真机被收下，位置逐字节落盘（零位移验收）

**目标**：设备在线而键位验收需要人，就趁这个窗口把 DK-3 之后唯一不需要人按键的项做完——
`read_report`（原语 `make_read_payload` 自 DK-2 起就是零调用方）。

### 动作

1. **先取证语义**（不猜协议）：插件 `weread/lib/position_mapper.lua:186-209` 定下两条换算——
   `chapterOffset` 是**章内字数偏移**（以目录 `wordCount` 为上界，不是字节数），
   `progress` 是 `(前序章字数 + 本章偏移) / 全书字数` 四舍五入到整数点；
   `weread/lib/reader_state.lua:29-31` 证明 psvts/pclts/token 三件本应从同一张 reader 页一起抽。
   端点只有 `POST /web/book/read`——没有独立的 setprogress，位置随时报一起落。
2. **架构取舍：不做心跳**。插件是 30s 心跳 + 调度器 + 积压补报；本客户端单进程无异步，
   心跳会把网络请求打进翻页关键路径（K4 弱网一次往返数秒，手感直接变卡），且规律定时流量
   在服务端是风控面（与「UA 必须同源」同一个道理）。改成**离开一章时发一次**，
   `rt` 取该段墙上时间并夹到 30s（服务端只吃小步 rt，大值被静默丢弃）。
3. TDD：`tests/report_position_test.lua` 先跑红（`module 'report' not found`）再实现
   `src/lua/report.lua`。8 组断言里三条是「必须失败」的：章不在目录时不得悄悄按第 1 章上报
   （那会把服务端位置拽回开头）、`wordCount=0` 不得除零、越界页码必须夹进合法区间。
4. **减法优先**：不新增凭据写入口——上报走已受门禁的 `Api.request`，`CRED-WRITERS-OK (3)` 未放宽；
   不动 `reader.lua`（`sm` 摘要留空，代价只是服务端「最近阅读」少一句片段，不值得为它加一条页首行回传）。
   `download.fetch_psvts` 只加**第三个返回值**（整份 reader state），老调用点与
   `dk3_smoke` 的按名计数都不受影响。
5. **动网络前先备份**：`auth.json` → `auth.json.bak-report`（设备 data 下第 4 份备份）。
6. **验收件刻意做成零位移**（`src/lua/read_report_smoke.lua`）：上报用的是**服务端当前的位置**
   而不是本地进度，所以不挪用户的阅读位置；报完回读 `/book/getprogress` 对账，因为只断言
   `accepted` 会被「回 succ 但不写」糊过去（net.c 那次假绿的教训）；选书只挑「服务端已有位置」的第一本，
   找不到就退出而不是造假数据。
7. 真机结果（首跑 `read_report smoke: 0 failure(s)`，8 项全 PASS）：`sg`/`s` 签名面被收下
   （token 从 reader 页实抽，29 字符）；`ci=15 co=1908 pr=96` 回读**逐字节相同**；
   `pclts` 该书页面上没有 → 沿用插件的 `e(now)` 兜底，不算失败；
   本地字数换算与服务端 percent 相差 3 个点（99 vs 96，页码取整方向所致），在容忍内
   ——**此句已被下一条推翻**：那条比对用的基准（服务端 co 是字数）本身不成立，见
   「2026-11-19 · 标定推翻「在容忍内」」。
   如实记一条：这次验收带了 `rt=30`，服务端该书的阅读时长统计多了 30 秒（位置未动）。

## 2026-11-19 · 标定推翻「在容忍内」：co 不是服务端语义；-2012 是无心跳设计的常态

**目标**：上一条里我用「相差 3 个点，在容忍内」结案了一个**没验过的假设**——上报位置的单位。
接线一跑就会写进用户手机端的进度，假设错了是可感知的损害，所以这一轮只做一件事：把它量出来。

### 动作

1. **写标定件 `src/lua/report_calib.lua`（纯只读，一次都不写服务端）**：对书架每本带服务端
   进度的书取 `(ci, co, pr)` + 目录字数，看本仓换算能不能解释服务端的真实数据。
2. **第一版设计是错的，先拆自己**：首跑 171 本被我本机 `timeout 240` 掐死在书架中途；
   更要紧的是我把 co 与「由 pr 反解的偏移」直接比差——`pr` 服务端只到整数个百分点，
   1 个点对应 `total/100` 字，对十万字的书容差天然巨大，**这项检查对大多数书根本不可能失败**。
   重做成两个可判定性不同的问题：Q1「co 会不会超过本章 wordCount」（与 pr 无关，硬证据）、
   Q2「pr 能否由 co 推出」（只在 `0<pr<100` 且 `total/100 <= 本章字数` 时可判，其余记 NA 而不是 OK），
   加 150s 网络硬预算并打印样本量。
3. **标定结论（两次独立采样：171 本 / 160 本）**：
   * `co > wordCount` 的书 **97/171 与 91/160**——服务端存的 co 不是「章内字数」，且不校验、原样存；
   * Q2 可判定点 **43 个里 2 个、40 个里 2 个**自洽 → **服务端不由 co 反推 pr**，co 与 pr 各存各的。
   * 于是「字数偏移」是**客户端之间的约定**（本仓与插件互认，与手机端靠 pr 互认），不是服务端算法；
     推论有两条：① 任何读路径不得反解服务端 co（`grep chapterOffset` 复核：生产路径确实只写不读）；
     ② pr 算错会被**直接记住**，所以换算不可信时必须拒发而不是发出去再看。
4. **标定顺带抓到会真伤用户的形态**：不少书的目录 `wordCount` 是占位值（整本每章 1~4 字，
   `total` 只有 138）。拿这种目录换算，主机实测把一本服务端 `pr=97` 的书算成 **`percent=8`**。
   TDD 先红（3 条失败，其中一条直接打印出那个 8）再实现：`Report.MIN_AVG_WORDS = 20`，
   平均每章不足 20 字即 `nil, "catalog_words_unusable"`——本地进度照旧，只是不发这一枪。
   另两组（每章 60~80 字的薄目录仍要能报、个别 `wordCount=0` 的前言章不得拖整本拒答）钉住这条线不画宽。
5. **真机 `-2012` 取证 + 修根因**：本轮首跑 `read_report_smoke` 回 `errCode=-2012 status=200`，
   而几十秒前 GET 全通（calib 读了 160 本）。插件判据：`read_report.lua:173-180`——
   会话没了就用 -2012/-2013 回答（HTTP 仍 200），`:118` 的对策是「续期 + 重试一次」。
   跑 `renew_smoke`（`wr_skey` 轮换）后同一条上报立刻被收下。**根因在本仓自己的设计**：
   刻意不做心跳 → 一章读完再报时 skey 常常已过龄，所以 -2012 是常态路径而非异常。
   实现照插件：`Report.send` 遇 -2012/-2013 → `Auth.renew()`（**非 force**，它自带的 600s 冷却
   就是重试上限）→ `replaced` 才重试，且只重试一次。传输层失败不续期（凭据未知，不许猜会话已死），
   其它 errCode 不续期（参数被拒续期也没用）。
6. `tests/report_retry_test.lua`（8 场景，先红 7 条再绿）把这些行为钉成断言：恰好一次续期一次重试、
   冷却中绝不重试、重试上限一次、-2022 与网络失败零续期、`NO-PSVTS` 仍在任何请求之前拦住、
   续期绝不带 force。
7. **删掉自己写的假绿**：`read_report_smoke` 原第 3 组拿**服务端的 co** 折成页码再比 percent，
   而 `co/words=1.87` 被 `math.min(10, …)` 夹成末页——那条 PASS 恰恰是反例被吞掉的结果。
   换成夹不出一致的判据：真机目录上 page 1..10 逐页可算、随翻页单调不减、始终落在 0..100
   （设备实测 `92% -> 99%`，服务端 96 落在其中）。
8. 纪律与坑：动网络路径前 `auth.json` → `auth.json.bak-calib`；`${PIPESTATUS[0]}` 是 bashism，
   设备走 `sh -c` → 语法错误让一次 calib 白跑，管道尾巴改在本机做。

### 验证

- 主机：`make host-lua-test` → **7 套全绿** + `CRED-WRITERS-OK (3)`（自愈复用 `Auth.renew`，
  没有新增凭据写入口）；`luac -p` 全过；红→绿可复现（位置门 3 红、重试 7 红）。
- 设备：`PIXEL-CHECK PASS`；`read_report_smoke` **11 项全 PASS**（零位移，offset/percent 回读对账）；
  `dk3_smoke` 0 failure；`renew_smoke` 0 failure；`report_calib` 两次采样 exit 0，结论一致。
- 全程未扫码；`wr_rt` 28 字符全程未丢。

### 状态

DK-3.5 的发送面现在对两类真实故障免疫：目录字数不可信（拒发）、skey 过龄（续一次重试一次）。
`chapterOffset` 的语义按证据降级为「同约定客户端之间的提示」，`progress` 是唯一跨客户端位置字段。
仍待办：键位手感验收需要人人在设备边按键（`tools/deploy-weread.sh --interactive`）。

### 排查记录：`cmp` 把我误导成「凭据被删」，真判据在 Lua 层

1. 我写「`auth.json` 与备份逐字节相同 ⇒ 会话没被动过」，实测 `cmp -s` 全部 **DIFF**，
   第一反应是 `Set-Cookie: wr_rt=`（空值删除）把 refreshToken 吃掉了——那等于只剩重扫码。
2. 逐条查下来两个结论都与猜测相反：
   * 备份之间本来就该不同（`bak-recheck`→`bak-report` 之间跑过一次 `renew(force)`，
     轮换 `wr_skey` 并补发 `wr_pf`，5 项 → 6 项）；
   * **`Json.encode` 的键序随 `pairs` 抖动**，同一份会话也能比出 DIFF。
     `cmp` 只能证「字节序列不同」，永远不能证「凭据增减」——这条判据从一开始就是错的。
3. 权威读数用 Lua 层：`Cookie.sanitize` 后取**条目名 + 值长度 + has_login_cookie**，
   当前盘面 `n=6 [wr_fp=10 wr_pf=9 wr_ql=1 wr_rt=28 wr_skey=8 wr_vid=8] login=true`，
   与 `bak-report` 完全一致 → 上报路径（含其响应）没有改动 jar 内容。
   我那条 BusyBox grep 之所以显示 5 项，是因为 `tr ',' '\n'` 把含逗号的 cookie 值切断了；
   **BusyBox 文本切分不是会话读数**，别再用它判 cookie 数量。
4. 把结论做成机器断言：`read_report_smoke.lua` 增第 4 组——跑完一遍必须
   `has_login==true` 且 `wr_rt >= 8`（丢了就只剩重扫码），并把 `header_unchanged`
   作为信息打印（合法轮换会改它，所以不断言相等，只断言会话仍可用）。
5. **一条纪律违例，如实记录**：我为查值长度写的 `awk -F\"` 字段序号写错，把若干条 cookie
   的**真值打印到了本机终端**。值只出现在本机这次会话输出里，未进任何文件、提交、交接文档；
   正确写法就是上面第 3 条（名字 + 长度 + 布尔）。以后探测凭据盘面一律走 Lua 层指纹，
   不在 shell 里切 JSON。

### 验证

- 主机：`make host-lua-test` → 6 套全绿 + `CRED-WRITERS-OK (3)`；`luac -p` 全过；先红后绿可复现。
- 设备：`tools/deploy-weread.sh` → `PIXEL-CHECK PASS`；`read_report_smoke.lua` 加上会话不变量组后
  复跑 **10 项全 PASS**，其中 offset/percent 两条是**回读对账**而非请求返回码，
  `header_unchanged=true` 证明上报路径没动 jar。
- 会话不变量：`Api.has_login()` 与 `Cookie.has_login_cookie` 全程 true，`wr_rt` 28 字符未丢。
- 全程未扫码。

### 状态

DK-3.5 的服务端写入面已打通并证明落盘。两处待办：① `menu.read_book` 里的接线只做了静态核对
（`Report.send` 入参形状与 `sess.psvts/pclts/token` 来源），它要随键位手感验收在同一次真实阅读里
跑到——那需要人按键；② 本批与之前各批的提交仍未 push，等用户点头。

## 2026-11-19 · 真机验收跑绿：续期=replaced、正文可用；并更正「设备离线」是我的探测写错

**目标**：用户指出「真机一直在线」，把持久化批次唯一未取证的一项（免扫码续期真机复测）跑完，
顺手清掉本会话遗留在设备上的探测脚本。

### 动作

1. **前提更正（这是本批最重要的发现）**：`tools/k4-env.local.sh` 里 `K4_HOST` 的值已含
   `root@` 前缀，所以我用来判「在线/掉线」的 `bash -c 'exec 3<>/dev/tcp/$K4_HOST/$K4_PORT'`
   打的是 `/dev/tcp/root@192.168.2.151/2222` —— 无效目标，稳定报 `No route to host`，
   被我当成设备离线，还挂了个 10 分钟的轮询监视器去「等它上线」。改用 `ssh -o ConnectTimeout`
   一试就到了认证阶段，设备一直在线。
   另一面也要分清：本批更早的 `ssh` 确实真失败过，设备 dmesg 里
   `Battery: Resume - TimeSuspended(secs)=2435` 印证它真睡了约 40 分钟。**两种「连不上」原因不同，
   判据只能是 ssh 本身走到哪一步**（路由不通 / 认证失败 / 通了）。
2. 先按纪律备份：`auth.json` → `auth.json.bak-recheck`（数据目录现共 3 份备份，都在设备上）。
3. `tools/deploy-weread.sh` → `PIXEL-CHECK PASS`、`EXIT=0`（Lua 层不内嵌在二进制里，
   deploy 的 scp glob 就是分发路径，所以新增脚本无需重编）。
4. `dk3_smoke.lua` → `0 failure(s)`：5/5 章有真实正文（bytes 17/293/3096/2946/2691，longest=3096），
   缓存重跑 0 次网络调用。
5. 新增并跑通正式验收件 `src/lua/renew_smoke.lua` → `0 failure(s)`：
   `renew(force)` 回 **replaced**；`jar_items` 5→6（服务端补发 `wr_pf`）、`wr_skey` 仍 8 字符、
   `wr_rt` 28 字符、**前后 `has_login` 都 true**；不带 force 的第二次 = `cooling`；
   续期后走 t_0 取到 3030 字节正文。**门槛 16→8 的校准由真机确认，不再只是探测推断。**
6. 清场（先验无凭据值再删）：9 个 `probe_*.lua`、`evsniff`、`data/poll_raw.json`、
   `data/login_run.log`（`grep -ci token` = 0，只含已被消费掉的二维码 uid）。
7. 提交 37f8cb9（renew_smoke + 真机证据写进 commit body）。

### 验证

- 设备侧三条命令全绿：`dk3 smoke: 0 failure(s)` / `renew smoke: 0 failure(s)` EXIT=0 / `PIXEL-CHECK PASS`。
- 主机侧未回归：`make host-lua-test` → 5 套 + `CRED-WRITERS-OK (3)`；`make host-selftest` 绿。
- 全程**未触发扫码**，登录态未被破坏（这正是本批要证明的不变量）。

### 状态

DK-3 只剩一项：键位手感交互验收（`tools/deploy-weread.sh --interactive`，需要人在设备边按键；
重点验 ScreenKB 组合键与 code 29 是否报 release）。本批 + 上批的提交仍未 push，等用户点头。
下一批的可达性判据请直接用 ssh，别再拿 `/dev/tcp/$K4_HOST` 当探针。


## 2026-11-19 · 免扫码续期 + 会话持久化（照 weread_K4 插件补齐登录生命周期）

**目标**：用户指示「不要扫码，可能触发风控，需要参考原 weread_K4 插件，做好登录的持久化」。
上一批修完 `net.c` 丢响应头之后，`set-cookie` 首次真正进入 Lua——于是「任何响应都合并落盘」的老
设计开始反复吃掉登录态。这一批解决的是会话生命周期，不只是补一个 renew。

### 动作

1. **唯一一次扫码**（按用户要求，之后不再）：`Auth.login` 走通，落盘后立刻检查 refreshToken 是否留存。
2. **写盘路径审计**：全仓只有三处会写 `auth.json` —— `Api.request`（当时是无条件合并+落盘）、
   `Auth._complete`、新增的 `Auth.renew`。第一处就是「重登一次又被探测脚本清空」的机制，也是风控面上
   最危险的一处：一次匿名响应即可作废整个 jar。
3. **cookie 条目门禁**（`src/lua/lib/cookie.lua` 新增 `is_session_name` + `sanitize`）：名称只允许
   `wr_*` 加 ptcz/RK/pgv_pvid，值不得含 `;`/控制字符、上限 4096 字节；幂等（合法 jar 过一遍不变）。
   删除语义（`name=` 空值）保持标准行为——安全性挪到调用层，而不是改契约。
4. **根因**：`auth.lua` 的 `jar_request` 把扁平 jar 当 `auth` 传给 `Api.request`，而后者约定
   `auth = {cookies=…}`，于是 `auth.cookies = merged` 在 jar 里写出一个名为 `cookies` 的伪 cookie 并
   跟着 Cookie 头出站。源头改 `opts.auth = { cookies = jar }`，另在 `Api.load_auth` 边界一次性
   sanitize 作纵深防御（插件 credential_store 加载期复校同款）。真机已验证该伪条目消失。
5. **单一写入口**（`src/lua/api.lua`）：只有「2xx 且合并后仍是可用会话」才写盘——判据用
   `Cookie.has_login_cookie` 对新旧 jar 各算一次，因此登录中途（还没有会话）不受限制、合法轮换照常
   生效，而降级/匿名响应不再触盘。
6. **只读派生请求**（`src/lua/download.lua fetch_psvts`）：reader 页不再合并响应 cookie、不再落盘；
   同时补上 UA——此前不带 UA 落到 `net.c` 默认 `WereadK4/0.1`，与正文 POST 的 Edge UA 在同一会话里
   呈现两种客户端身份，插件 `migrations.lua:11` 明确把这列为风控触发面。
7. **`wr_rt` 留存**：`poll_once` 从拼接串改为返回凭据表（带 refresh），`_complete` 把 `refreshToken`
   urlencode 后存进 `cookies.wr_rt`。此前直接丢弃 → web 域一过期只能重扫（正是用户要避免的事）。
   真机 `wr_rt` 28 字符已在盘。
8. **免扫码续期**（`src/lua/auth.lua` 新增纯函数 `classify_renewal` + `renew`）：四态
   `network / expired / replaced / stale`。只有 `replaced|stale` 增量收紧落盘（过 `is_session_name`），
   失败分支什么都不改——插件 `client.lua:692-710` 纪律：network/stale 绝不清凭据，只有真 expired
   才允许要求重扫。冷却 600s，被动续期不打成心跳。
9. **空分片自愈**（`src/lua/download.lua`）：`EMPTY-SHARD` 由「静默返回空」改为硬失败 → 触发一次
   `Auth.renew()` → 重试。会话过期的表现从「整本书只剩标题」变成「续期一次后拿到正文」。
10. **断言硬化**（`src/lua/dk3_smoke.lua`）：批 3→5，`spool has content` 换成
    `spool has real chapter body`（正文须明显长于标题）。缺的正是这条断言，才让上一轮 8/8 假绿。
11. **门槛校准**：插件的 16 字符门槛在本机全线误报。裸探测（`/tmp/probe_renew.lua`，一次性脚本）显示
    `status=200 body={"succ":1}` 且轮换回来的 `wr_skey` 只有 **8** 字符——续期其实成功，是被照搬过来的
    阈值判死。改 `Auth.RENEW_MIN_SKEY_LEN = 8` 与 `has_login_cookie` 同源，并加测试禁止两者在
    「会丢活会话」的方向上不一致。
12. **不变量复查抓出残留写入口**：按「谁写 auth.json」逐行 grep，发现 `Api.authenticated_get` 在
    `Api.request`（已受门禁）之后又自己 `merge_cookies` + `save_auth` 一次——一次带空值 Set-Cookie 的
    响应照样能绕过门禁清空会话；而它全仓零调用方（登录走 jar_request，书架走 Api.gateway）。整段删除，
    凭据写入口收敛为三处且全部经过判定：`Api.request` 门禁分支、`Auth._complete`、`Auth.renew`。
13. **把不变量做成机器门槛**（`Makefile` host-lua-test）：`Api.save_auth` 调用点数必须恰好等于 3，否则整条
    Lua 门禁红牌并打印「合法写入口是哪三处 + 为什么」。**双向验证过**：现状 3 处绿；临时插入第 4 处未受判定
    的写盘点后立即失败（`CRED-WRITER-GUARD: Api.save_auth 调用点 4 处，应为 3`），复原后回绿。
    理由：这条纪律靠 grep 记忆不可靠，下一批 agent（或我）新增落盘点时不会先想起它。

### 验证

- 主机 5 套全绿：新增 `tests/cookie_test.lua`（名/值门禁、幂等、Path/Domain 忽略、按名删除、门槛）与
  `tests/renew_test.lua`（9 组四态 + 冷却下限 + 门槛同源）。
- 真机（改阈值前）：jar 名 `wr_fp wr_ql wr_rt wr_skey wr_vid`；伪 `cookies` 条目消失；`has_login` true；
  取章 2814 字节 HAS-BODY；`renew()` 之后 `has_login` 仍 true（凭据没被吃掉——这条是本批的核心不变量）。
- **未竟**：阈值修正后的真机 `renew()` 复测（期望 `replaced` 且 `wr_skey` 轮换落盘）——设备已掉线
  （`no route to host`），主机侧已复核但真机结论留待下一批。

### 状态

代码 + 测试就绪（本批 5 个提交 a59da13→115dc3e），未 push。待办：① 设备上线复测 `renew()` = `replaced`；② 键位手感验收
（`tools/deploy-weread.sh --interactive`）仍未做；③ 探测脚本仍留在设备 `/mnt/us/weread/lua/`，
`auth.json.prelogin-1910` / `bak-1926` / `pre-renew-test` 备份待用户决定去留。


## 2026-11-19 · 真机验收发现正文为空 → 修掉 net.c 两个响应头 bug（会话cookie从不刷新）

**目标**：用户告知 K4 上线，要求「进行必要的测试」，把 DK-3 积压的真机数据面验收跑完。

### 动作

1. **离线门槛复绿**后部署：`make host-selftest`（量化 + input 组合键）、`make host-lua-test`（3 套）、
   `tools/deploy-weread.sh`（`PIXEL-CHECK PASS`），再跑 `dk3_smoke.lua` → 末行 `0 failure(s)`。
2. **没有采信这个绿**：spool 下来的 3 章只有 8/14/66 字节——全是标题。扩面到 8 本书取第 5 章，
   `fetch_chapter_text` 一律返回 **0 字节正文**，确认是会话级而非单书级问题。
   → `dk3_smoke.lua:79` 的 `spooled > 0` 只验证「文件存在」，标题级缓存即可满足 → **验收假绿**。
3. **排除法定位**：`make_content_params` 与参考插件逐字节相同（diff 只有 require 路径与 randomseed）→
   不是参数/签名；对照端点经同一路径返回 2.7KB 404 页面 → 不是 body 捕获；
   `t_0` 的 `status=200 bodylen=0` 是服务端真的给了空分片。
4. **根因一**（`src/device/net.c:55`）：`on_header` 早退条件 `total > 6`——本意是给
   `memcmp(line,"HTTP/",6)` 限长防越界，实际把**每一条真实响应头**全部丢弃，`set-cookie` 到不了 Lua。
   改为 `(total >= 6 && memcmp(...) == 0)`：既保住短行，也不越界读状态行前缀。
5. **根因二**（`src/device/net.c:268`）：响应头入表时 `lua_gettable` 已弹走 key，收尾又把 key 压在
   value 之上，而 `lua_settable` 要求栈序 `[..., tbl, key, value]` → 实际写成 `tbl[值] = 名`
   （现象：`nginx/1.16.1: server`）。改为 `pushkey; pushvalue(key); gettable(-3)`，两个分支统一收尾
   `settable(-3)`。`hdrs["set-cookie"]` 此前恒为 nil。
6. **代价与教训**：`set-cookie` 合并首次真正生效后，服务端下发 `wr_vid=`/`wr_skey=`（空值），
   `lib/cookie.lua:46` 按标准语义正确地删除了它们 → 设备上登录态失效（无备份，已无法回滚）。
   会话早已名存实亡（这正是 bug 的表现），但**把过期落盘的直接触发者是我反复跑的探测脚本**：
   动网络路径前应先备份 `data/auth.json`。本轮起固化为习惯，已在重登前补 `auth.json.prelogin-1910`。
7. 旧 spool 整体挪至 `/mnt/us/weread/books.stale-1843`（未删）；`evsniff` 交叉编译推上设备，
   确认三个输入节点均未被 grab（event0 tequila-keypad / event1 fiveway / event2 volume）。

### 验证

- 修复后 `probe_pairs.lua`：`KEY=[server] VAL=[nginx/1.16.1]`、`content-type`→`text/html; charset=utf-8`，
  同名头追加语义正常（`vary` = 两行 `Accept-Encoding`）——键值不再颠倒。
- 修复后 8 本书第 5 章正文：**531 / 2069 / 14333 / 9262 / 4213 / 1123 / 2284 / 15795 字节，全部 HAS-BODY**。
  正文链路自 DK-2 起首次真正打通（此前阅读器渲染的一直是空数据）。
- `make weread-dyn` 重建零警告；`make host-selftest` / `host-lua-test` 仍全绿。

### 状态

已修已提交（net.c 两处）。待办：`wr_rt` 缺失（`auth.lua:186` 丢弃 `refreshToken`，web 域轮换 skey 后
无法续期）→ 本轮重登后验证；`dk3_smoke` 断言需改为要求正文长度、`fetch_chapter_text` 需对空分片报错，
否则这类故障继续静默通过；键位手感验收因 60s 采集窗口内无人按键仍未完成。


## 2026-11-19 · git 历史改写：从全部提交中清除内网设备地址（force push 已获授权）

**目标**：用户指示「用 git filter-repo 清除历史里的旧 IP 并 force push」。上一批只清了 HEAD，
已公开的历史提交里设备地址真值仍在（199 处命中）。

### 动作

1. **范围审计**：`git grep` 全历史扫 RFC1918 模式 → 只有一个内网地址、199 处、跨 38 个提交；
   没有第二个内网 IP。
2. **先备份**：`git bundle create /home/doro/backups/WereadK4_BasedDK-pre-filter-20261119.bundle --all`
   + `git bundle verify`（"records a complete history"，170K）。改写不可逆，回退全靠它。
3. **不在工作仓里跑 filter-repo**：`vendor/`（61M 多看资产）、`build/`（16M）、`handoffs/`（196K）、
   `tools/k4-env.local.sh` 都是 gitignore 的不可再生本机资产，而 filter-repo 收尾会 reset/gc——风险不值得。
   改在 `git clone --no-local` 出的临时仓里跑（第一次漏了 `--no-local`，被 filter-repo 拒：本地 clone 不算 fresh clone）。
4. **替换规则**：`--replace-text`，单行「真值`==><K4_HOST>`」（filter-repo 默认按字面匹配，无需 `literal:` 前缀）；
   占位符与 HEAD 现行写法一致，历史条目读起来仍通顺。真值本身只存在于本机 `tools/k4-env.local.sh`，不写进本文件。
5. **改写后逐项验证**（见「验证」），确认无误才动工作仓。
6. **工作仓换头**：`git fetch <临时仓> refs/heads/main` + `git checkout -B main FETCH_HEAD`
   —— tracked 内容零变化（HEAD tree hash 不变），ignored 资产完好（vendor/build/handoffs 尺寸复核一致）。
7. **推送**：`git push --force-with-lease=refs/heads/main:<改写前 SHA>`——lease 钉住审计过的远端状态，
   远端若被别人动过就拒绝，比裸 `--force` 安全。第 1 次尝试即成功（代理这轮没抽风）。
8. **本地清尾**：`git reflog expire --expire=now --all && git gc --prune=now` → 旧对象（含真值）从本机仓库消失
   （`git cat-file -t <旧SHA>` 报 not found）；临时 clone 与替换表文件删除。
9. **修复被改写打断的 SHA 引用**：历史改写让所有 SHA 变号，`AGENTS.md`/`LOG.md` 里 17 处引用会指向不存在的提交。
   从备份 bundle 取旧历史，按 subject 逐条对齐（38↔38，`diff` 全等）建映射，精确替换 12 个被引用的 SHA；
   `docs/` 里那个 7 位十六进制的固件 SHA-256 前缀（`07a2238…`）不在映射表内，未被误伤。
   `AGENTS.md` 的指针行顺手去掉钉死的 SHA（每提交都过时，这次改写正好证明它脆弱）。

### 旧→新 SHA 映射（引用旧号的笔记/交接按此换算）

| 旧 | 新 | 提交 |
|---|---|---|
| af3c702 | 247d897 | DK-3 输入层: ScreenKB 修饰键 latch |
| 216a6d8 | 2e7054e | DK-3 进度存储: progress.lua + Json.write_atomic |
| 0df7c75 | ab517c6 | DK-3 下载侧: 按需补章 + 批量预取 |
| d88bdbf | b3e28a2 | DK-3 阅读器: 键位对齐 + 跨章 action 信号 |
| a42d1cf | 2ad8908 | DK-3 菜单: read_book 循环 + 目录 + 续读 |
| fa69a41 | da53ffc | DK-3 验收: dk3_smoke.lua |
| a5e6b61 | 76c85c3 | DK-3 文档: keymap-k4.md + LOG |
| 07a7561 | a630b2f | AGENTS.md: handoff 指针 → dk3 kit |
| f5bc76f | ec914a2 | AGENTS.md: 状态更新（远端已建） |
| 9672af5 | 3101774 | 公开仓库卫生整改 |
| 9a8b1e9 | d7cbf42 | LOG: 公开发布批次 |
| 147c543 | cc213b1 | DK-2 后半: download/reader/menu 级联 |

### 验证

- 改写仓：全历史 `git grep` 内网网段零命中；**HEAD tree hash 与改写前逐字节相同**（`8e1d6b3c…`）→ 发布内容未被动；
  38 提交、subject 列表、author/date 列表与原历史 `diff` 全等；138 个 blob 落上 `<K4_HOST>` 占位符。
- 远端：`git ls-remote origin` = `d7cbf42` = 本地 HEAD；`gh api commits?per_page=100` = 38；
  `forks=0 / watchers=0`（无派生仓残留旧历史）。
- 引用修复后：12 个旧 SHA 全仓 `git grep` 零命中；12 个新 SHA 逐个 `git log -1 --format=%s` 与预期主题一致。
- 回归：`make host-selftest`（HOST-OK + INPUT-OK）、`make host-lua-test`（3 套件 0 failure）。

### 状态 / 残留

- **GitHub 侧仍可按旧 SHA 直取**：`gh api repos/.../commits/<旧SHA>` 仍返回 200——force push 只改分支可达性，
  悬空对象要等 GitHub 自己的 GC。要立刻彻底清除需联系 GitHub Support，或删仓重建
  （本仓 forks=0、watchers=0、无 issue/PR，删重建代价很低）。
- 备份 bundle 在 `/home/doro/backups/`（含改写前完整历史与设备地址真值）——**本机 only，勿上传**。
- 设备仍离线，DK-3 真机验收继续阻塞。

## 2026-11-19 · 公开发布 + 公开仓库卫生整改（设备仍离线）

**目标**：用户两条指示——①「本机已有 GH 授权，直接推送为项目，公开」；②「执行 1 和 2」
（= 我报告的三点公开可见项里的前两点：内网设备地址、指向本机 `~/reports/` 的死引用；第三点 LICENSE 留给用户决定）。

### 动作

1. **发布前审计**（推送会把 35 个提交全部公开，先审后推）：tracked 文件清单逐个过（50 个，全是源码/文档/测试/工具）；
   枚举历史上曾 add 过的所有路径——无 `auth.json`、无 `vendor/`、无 `handoffs/`、无二进制；
   全历史密钥正则扫描（`wr_skey=`/`wr_vid=`/`api_key=`/PRIVATE KEY/`ghp_`/`ssh-rsa`/`password=`）零命中；
   `WeRead.DEFAULT_READER_TOKEN`（`src/lua/lib/protocol.lua:18`）与公开上游插件
   `weread.koplugin/weread/lib/protocol.lua:7` 逐字节相同 → 是上游硬编码值，不是用户凭据。
2. **建仓并推送**：`gh repo create WereadK4_BasedDK --public --source=. --remote=origin --push`。
   仓库建成但 push 失败——本机 gost 代理（127.0.0.1:10800）对 `github.com:443` 不稳：
   HTTP CONNECT 返回 503（约 15s 后）或 TLS 中途被断（`GnuTLS recv error (-110)`），
   socks5h 也只偶发成功，直连超时；而 `api.github.com` 稳定 200（所以 `gh` 能用）。
   连续 ~20 次失败后**重试即通**——不改配置，只循环重试（写法已记进 handoff 的 Blocker 段）。
3. **指针状态更新**（ec914a2）：`AGENTS.md` 原文「git push（仓库无 remote）双阻塞」在公开后成了假信息，
   补 Remote 行并把 Status 改为「仅剩设备阻塞」。
4. **设备地址移出仓库**（3101774）：`deploy-k4.sh` / `deploy-weread.sh` 改为
   「环境变量 > `tools/k4-env.local.sh` > 报错退出」，删掉硬编码默认值；新增 `tools/k4-env.example.sh`
   （只有变量名与占位符）；`tools/k4-env.local.sh` 进 `.gitignore`；
   `AGENTS.md`/`LOG.md`/`dk3_smoke.lua` 里的字面 IP 换成 `$K4_HOST` / `<K4_HOST>`。
5. **本机文档引用标注 local-only**（3101774）：README 增「构建与部署」段（明说不入库的构建依赖：
   `~/x-tools` 交叉工具链、`vendor/`、`~/k4-sysroot`，以及设备地址配置步骤）；
   `Current Handoff` 段改为说明 `handoffs/` 本地 only；`docs/duokan-k4-driver-architecture.md`
   证据源表下加注（表内路径均为本机材料，结论已抄进文档，读者不需要原文件）。
6. **未做**：git 历史重写。IP 与旧引用仍存在于**已公开的历史提交**里，从 HEAD 清掉不等于从历史清掉；
   清历史要 `filter-repo` + force push（或删仓重建），属不可逆操作 → 交用户决定。

### 验证

- 审计：`git ls-tree -r --name-only origin/main` 敏感路径扫描（handoff/auth.json/vendor/*.so/*.zip/*.pem/.env）零命中。
- 整改：`git grep` 内网网段正则（`192.168.` 段全模式）全仓零命中；`git check-ignore -v tools/k4-env.local.sh` 命中 `.gitignore:12`；
  `bash -n` 两脚本通过；**用 stub ssh/scp 跑三种配置情形**——本机文件被 source、`K4_HOST`/`K4_PORT` 环境变量覆盖生效、
  两者皆无时报出带指引的错误（测行为不测实现）；`luac -p dk3_smoke.lua` 通过。
- 回归：`make host-selftest`（HOST-OK + input combo selftest OK）、`make host-lua-test`（3 套件 0 failure）全绿。
- 远端：`git rev-parse HEAD` == `origin/main`；仓库 public。

### 状态

- 2 个提交（ec914a2、3101774）+ 本条 LOG。仓库 https://github.com/dororo42/WereadK4_BasedDK 已公开。
- 设备仍离线（`.151` ARP FAILED、ping 不通；未做全网段端口扫描——被安全策略拦下，也不该扫）。
  → `dk3_smoke.lua` 真机验收与键位手感验收**继续阻塞**，仍是 DK-3 唯一未了结项。

## 2026-11-19 · DK-3 阅读侧：键位对齐 KOReader 习惯 + 批量下载 + 断点续读（设备仍离线）

**目标**：用户两条要求——① 继续 DK-3（阅读侧优先、章末自动续读）；② 参考 weread_K4 插件快捷键，
保留该使用习惯。

### 动作

1. **键位习惯溯源**：插件的键位不是它自定的，而是 KOReader 在 K4 上的默认——插件只劫持四处
   （`ScreenKB+Down`/`Home`/`Menu`/`Back`，`reader_navigation.lua:18-161`）。权威表在插件
   `README.md:70-88`：`Left/Right`=换章、`LPgFwd/RPgFwd`=下一页、`LPgBack/RPgBack`=上一页、
   `Press`=底部菜单、`Menu`=顶部菜单、`Back`=关闭、`Home`=书架、`ScreenKB+Up`=目录。
   我们 DK-2 的 reader 把 `Right/Down/Press` 当翻页、四个 bezel 翻页键一个没绑——直接冲突。
2. **C 层修饰键 latch**（247d897）：`wr_input_poll` 原本丢弃 release，Lua 侧看不到修饰键抬起。
   latch 放 C（键位语义本来就在 `input.c` 决策，不下沉 Lua 造成分裂），产出 KOReader 同款
   `ScreenKBPlus<Key>`；latch 挂 `struct wr_input`（跨设备：code 29 在 event0，D-pad 在 event1），
   且排在通用 release 过滤之前（否则抬起被丢 → 修饰键粘住）。主机自测 `WR_INPUT_TEST_MAIN`。
3. **进度存储**（2e7054e）：`lib/progress.lua`（原子写、损坏降级为空、book_id 一律 tostring 作键）；
   顺手把 `api.lua:save_auth` 里手写的 tmp+rename 抽成 `Json.write_atomic` 共用（消除重复）。
4. **下载侧**（ab517c6）：`is_spooled`（空文件不算缓存）/`chapter_pos`+`find_chapter`
   （服务端 chapterIdx 不连续，与数组下标不能混用）/`new_session`+`ensure_chapter`
   （psvts 每书抽一次、懒取；命中缓存零网络请求）。**不做批量预取**：单进程无异步，
   预取只是把同样的等待提前到开书时（拖慢首页），改为章切换时按需下载 + 「准备章节」屏。
5. **阅读器**（b3e28a2）：键位表导出为 `Reader.KEY_*` 模块字段（改键位不动控制流，且可主机单测钉住）；
   跨章动作以 `action` 信号交回调用方；`start_page` 负数 = 从末页开始（回退上一章用）。
6. **菜单**（2ad8908）：`read_book` = 全项目唯一跨章决策点（目录→进度起点→按需取章→渲染→
   每次离章即 `Progress.set`→按 action 分派）；`pick_chapter` 目录列表（末项「退出阅读」，
   快捷菜单与目录共用一屏）；「继续阅读」接 `Progress.get_last()`。
7. **验收**（da53ffc）：`dk3_smoke.lua` 用 `count_calls()` 包装 `fetch_psvts`/`fetch_chapter_text`
   计数，直接断言「重跑 0 次网络请求」，不用计时阈值猜测。
8. **文档**：`docs/keymap-k4.md`（对齐表 + 两处刻意偏离 + 组合键实现 + 未接绑定的组合键清单）。

### 验证

- 离线全绿：`make host-selftest`（quant HOST-OK + input combo selftest OK）、
  `make host-lua-test`（progress / download_pure / reader_keys 三套 0 failure）、
  `luac -p` 全量、`make weread` + `make weread-dyn` 交叉编译零新警告。
- 真机待跑（设备离线）：`dk3_smoke.lua` + `--interactive` 键位手感验收。
  **唯一离线不可验的假设**：真机 evdev 上 code 29 的 press/release 是否成对出现
  （若只报 press，修饰键会粘住 → 需在 C 层加超时自动释放）。

### 状态

- 6 个提交（247d897 → da53ffc）。推送仍阻塞：仓库无 remote，需用户给远端地址。
- 两处刻意偏离（`Up/Down` 降级为翻页、`Press` 保留翻页）均一行可翻转，
  `tests/reader_keys_test.lua` 会强制同步断言——真机手感不对时改这两处即可。

## 2026-11-19 · 离线代码审查修复批次（ub-mode + code-review）

**目标**：全量审查 C 设备/桥接层（~1626 行）+ Lua 协议/加密/业务层（~3507 行），修复其中可离线完成的缺陷。无 🔴 阻断级；核心协议/加密层质量高（已由可工作的登录+书架链路实证）。

### 动作（分级审查 → 修复 5 处）

1. 🟡 **信号安全**（wrmain.c / wrbridge.c / wrbridge.h）：原 `on_signal` 调 `wr_cleanup → wr_ft_done → FT_Done → free()`，`free` 非 async-signal-safe；Ctrl+C 打断 malloc 会死锁/坏堆且屏幕不恢复。新增 `wr_emergency_restore()`（仅 memcpy/ioctl/fsync/close 级恢复），信号路径改调它，正常退出仍用完整 `wr_cleanup`。逐一核实 `wr_input_close`(ioctl+close)/`wr_fb_restore`(memcpy)/`wr_fb_refresh_full`(ioctl)/`wr_fb_wait`(fsync) 均无 malloc/free。
2. 🟡 **header 截断**（net.c）：HTTP 头定长 `char item[1024]`+`snprintf` → 长 Cookie/Authorization 静默截断致鉴权失败且无线索。改按 `klen+vlen+3` 堆分配手工拼接，`curl_slist_append`（内部拷贝）后立即 `free`。
3. 🟡 **auth 原子写**（api.lua）：`save_auth` 就地覆写 auth.json，掉电/kill 中断 → 截断 → `Json.decode` 失败 → 用户被登出。改「先编码 → 写 .tmp → 同分区 rename」，写/rename 失败即 `os.remove(tmp)`；并删除无效 no-op `os.rename(path,path)`（注释名不副实，既不建目录也不校验）。
4. 🟡 **shard 奇数守卫**（shard.lua）：`reverse_swaps` 步长 -2 成对消费 positions，奇数个 → i=1 时 `positions[0]=nil` 算术崩溃。入口加 `#positions%2~=0 → error`（fail-fast；`Shard.decode` 已被 download.lua pcall，异常转干净解码失败）。奇偶性证明：`swap_positions` 恒返回偶数（成对插入 + 第二插入守卫在循环条件成立时必然成立）→ 守卫为纯防御、对真实解码路径零回归。
5. 💡 **PRNG 播种**（protocol.lua）：全树无 `math.randomseed` → nonce（r / rn / ts）跨运行恒定、可预测。比对参考插件（/home/doro/weread_K4.koplugin）确认其 `main.lua:28 init()` 调 `math.randomseed(os.time())`，本仓端口 protocol.lua 时遗漏该播种。改在 protocol.lua 加载时播种一次（require 缓存保证仅执行一次；「生成 nonce 的模块自带播种」，不依赖宿主入口）。

### 验证（设备离线，本地静态 + 行为测试）

- `luac -p`：api / shard / protocol 全通过。
- 交叉编译 `-Wall -Wextra -fsyntax-only`（wrmain / wrbridge / net）零警告；`make weread` + `weread-dyn` 全量链接成功（7MB 静态 / 3MB 动态 ARM EABI5，唯一告警是 LuaJIT lj_clib.o 既有的 static-dlopen 提示，与本次无关）；`make host-selftest` HOST-OK。
- **api.lua 行为测试**（加载真实模块，host lua5.1 + bit）：往返保存/读取（含 UTF-8 账号名）+ 覆盖写 + 无残留 `.tmp` = T_API_OK。
- **protocol.lua 行为测试**：两进程相隔 >1s（不同 os.time 种子）→ nonce `r` 不同（111556 vs 15389929），且 `make_content_params` 输出结构（b/c/ct/ps/r/s）不变 = 播种生效且无回归。

### 状态 / 未做（需真机，或判定为过度工程）

- 设备仍离线（No route to host）。以上均可离线验证；`download_smoke` 真机验证待 K4 恢复上线。
- **延后**：💡 menu.lua stringly-typed 分派（按中文标签字面量比较）、🟢 忙等自旋（auth/login/shelf/menu 多处 `while millis()-t0<N do end`）—— 二者均改设备侧 UI/输入行为，离线无法证伪，且现有代码已在真机跑通（登录+书架），遵循「不重构无法验证的工作代码」，待设备恢复再做。
- **跳过**：🟢 render.c 负 pitch / pixel_mode 防御 —— `FT_LOAD_RENDER` 恒返回正 pitch + GRAY，加校验违反「不为不可能场景加防御代码」；🟢 auth.lua `dofile`→`require`（qrencode 绝对路径更健壮且为冷路径）；🟢 json.lua null 语义（当前业务未触及，改动有回归风险）。

## 2026-11-19 · 复用 vs 自编译评估 + handoff 固化（设备仍离线）

**目标**：用户决策问题（复用多看 vs 重新编译，哪个更贴合/收益更高）+ 当前状态 handoff。

### 动作

1. **评估落地** `docs/tech-decision-reuse-vs-recompile.md`：结论=现状双变体混合已是收益最优
   （渲染/UI 自编译 + 网络层复用 libcurl），复用是过渡态（TLS 老化/CVE/绑定 glibc 2.12.1），
   自编译不省 TLS 大坑；网络层失效预案 runbook 化（weread TLS 握手失败=唯一触发信号）。
   多看自有组件（KindleApp/dkkernel）判死维持——复用甜点区=OSS 成品运行库+字体数据。
2. **handoff** `dk2-download-reader-code-ready`（READY）：DK-2 后半代码完成（download/reader/menu
   级联，cc213b1），download_smoke 待设备恢复；上份交接三项全部给出结局；设备离线 blocker 记录。

### 状态

- 设备仍离线（No route to host）。设备上线后首跑 download_smoke（见 handoff 下一步 1）。
- 本批次无代码变更（纯文档/交接）。

## 2026-11-19 · DK-2 后半：download.lua + reader.lua 完成（真机 smoke 待设备恢复）

**目标**：DK-2 余项——章节下载 + 阅读器 + 菜单级联全实现。

### 动作

1. **插件 content.lua 管线还原**：目录=gateway /book/chapterinfo（Bearer）；正文=GET reader 页抽 psvts（正则兜底）→ make_content_params（protocol 已有：b/c=WeRead.e 加密+s 签名）→ POST /web/book/chapter/t_0(+t_1) → **shard 解码链**（32 字符 MD5 前缀校验 + 字节二进制→4 进制换位表 reverse_swaps + URL-safe base64）→ 纯文本。e_*/tar（epub/图片）简版不含。
2. **lib/shard.lua 移植**（纯 Lua 分支，去 FFI——静态 exe 无动态符号）。
3. **download.lua**：catalog（normalize 三形态展开）/fetch_psvts（cookie 带 jar）/fetch_chapter_text（t_0+可选 t_1，JSON 错误体识别）/spool（books/<id>/<idx>.txt，BusyBox mkdir）。
4. **reader.lua**：freetype 26px 排版——UTF-8 二分折行（protocol.utf8_substr + font_width 贪心）、段落空行布局、五向翻页（Right/Down/Press 前翻，Left/Up 后翻，Back 退）、页脚进度；fb/input 生命周期归调用方（menu 级联共享）。
5. **menu.lua 级联**：书架选书 → clear_screen"下载章节中" → Download.book(首章) → Reader.open → 回菜单。
6. **download_smoke.lua**：全自动验证（书架第一本 → 目录 → 2 章下载 → spool 预览）。
7. 笔误修复：download.lua Json 未定义引用、`not type(x)=="table"` 逻辑反。

### 状态

- 全部 luac 语法通过。**真机 download_smoke 未跑**：scp 阶段设备掉线（No route to host，
  疑似休眠断 WiFi/被拿走），重试 4 次×15s 未恢复。设备上线后：
  `tools/deploy-weread.sh` 然后 `ssh … ./weread-dyn lua/download_smoke.lua`。

### 风险点（smoke 首跑重点看）

- psvts 正则抽取（__INITIAL_STATE__ 大 JSON 的正则兜底路径是否命中）
- t_0 shard MD5 校验（协议参数/时间戳偏差会在这里暴露）
- 未购书 errCode（shelf.books[1] 可能是不可读条目——脚本只报错不选书，交互模式用户选书更可控）

## 2026-11-19 · DK-2 登录+书架全链路打通（真实账号登录成功，书架 10181 本）

**目标**：登录正式入口 + 菜单级联 + 书架视图；用户实际扫码打通登录态。

### 动作

1. **login.lua 正式入口**（QR→扫码→成功屏+书架验证）、**shelf.lua 书架列表**（gateway /shelf/sync → 中文列表 + 分页 + 五向键导航，SMOKE 像素自检）、**menu.lua 级联**（登录/书架项接线，标题显示账号名）。
2. **json.lua 数字解析 bug 修复**（扫码登录凭据丢失根因）：`string.find` 无捕获组时 Lua 5.1 只返回两值，`local _,e,num = find(...)` 的 num 恒 nil → 所有 JSON 数字值静默丢失（webLoginVid 数字型凭据消失）。修复=模式加捕获组；api_smoke 补数字回归用例。
3. **手机端"扫码失败"根因修复**：缺 **wr_fp 设备身份 cookie**。auth.lua 重写为插件 login_cookies 语义：独立 cookie jar（wr_fp=urandom 4 字节持久化 + skills 页预热 + 各步 Set-Cookie 合并），成功才落盘；api.lua 加 no_save 开关支持登录中途不写盘。
4. **排除项**： salvage 第 2 轮会话（手工 auth.json + vid/skey）→ userInfo 层活但 apikeyGet 401（缺完整 jar）→ 证实必须走完整预热流程。
5. 部署脚本升级为全量 lua 推送。

### 真机验证（PASS）

- **扫码登录成功**（账号 32819470）：手机端确认成功 → LOGIN_SUCCESS → userInfo → apikeyGet → auth.json 落盘
- **gateway /shelf/sync：10181 books**（登录态验证达标）
- 书架列表屏 SMOKE：`shelf pixel-check header=0`（真实数据渲染）
- 调试过程证据链：poll_raw.json 落盘定位字段缺失 → DBG print 定位 json 数字 bug → 本地单测修复后一次通过

### 遗留与下一步

- 用户交互验收：`tools/deploy-weread.sh --interactive`（菜单五向键 + 书架翻页选择；Back 返回）
- download.lua 章节下载 + reader.lua 阅读器（DK-2 后半，方案 §五）
- 10181 books 含公众号/出版物等混合条目，shelf 视图分类过滤待做（对照插件 shelf 结构 books/archive/albums/mp）
- NEED_OTP 短信验证码输入（K4 无键盘 UI，暂不支持，提示先网页版登录）

## 2026-11-19 · DK-2 业务层基础设施：API/登录 11 项真机验证全 PASS

**目标**：DK-2 业务层第一波——网络扩展 + 协议层移植 + 登录流程 + 自动验证。

### 动作

1. **插件源研究**（/home/doro/weread_K4.koplugin/weread/lib/）：发现 v9.x 已迁 **gateway 模式**——登录后 apikeyGet 拿 key，数据 API 走 POST i.weread.qq.com/api/agent/gateway + Bearer（方案 §4.3 旧 Cookie 直连表过时）；protocol.lua 纯 Lua 可原样移植（sign/e/web_app_id）；QR 非图片而是本地编码器（qrmessage），登录 URL=/web/confirm?uid=；NEED_OTP=新设备短信验证码状态。
2. **net.c 扩展** `http_req(opts)`：method/headers/body/响应头收集（同名头 \n 拼接，Set-Cookie 多值语义）；坑：LuaJIT pushfstring 不保证 %.*s，改纯栈 concat。
3. **纯 Lua 四件移植**（铁律标注来源）：crypto.lua（MD5/SHA256）/protocol.lua（改 require 路径）/cookie.lua/qrencode.lua（speedata/luaqrcode MIT，本地验证 29×29 矩阵）。
4. **自研 json.lua**：decode/encode，\u 代理对→UTF-8，主机 roundtrip 测试过。
5. **api.lua**：auth store（/mnt/us/weread/data/auth.json）/cookie 注入/Set-Cookie 合并/gateway Bearer/401×3 重试（插件同款）。
6. **auth.lua**：QR 登录全流程——getLoginUid→QR 屏（fb 块渲染+量化）→0.5s 轮询（Back 取消/过期自动重取 uid 重画）→userInfo→apikeyGet→存盘；NEED_OTP 给出明确指引（K4 暂不支持验证码输入）。
7. **wrmain** 加全局 arg 表（标准 Lua 语义）；deploy 脚本全量 lua 推送、BIN 默认 weread-dyn。

### 真机验证（PASS 11/11）

- MD5 已知向量 abc/空串、sign/e 格式、cookie 合并、json 往返
- **getLoginUid 返回真实 uid**（登录链路无凭据可调，TLS+JSON+头全通）
- gateway 无 key 本地守卫、userInfo 未登录 401 结构化
- **QR 屏渲染 finder 像素自检 PASS**（黑块确凿，屏显 5s）
- api_smoke 首败两例：arg[1] 是脚本路径（标准 arg 语义）→ 遍历判断；QR 采样点忘加 quiet 偏移 → 修

### 下一步

用户实际扫码登录（屏上 QR + 手机微信）→ 登录态拉书架（gateway /shelf/sync）→ shelf.lua/download.lua/reader.lua（方案 §五 DK-2 余项）。扫码前需确认账号已开通微信读书 Skill。

## 2026-11-19 · DK-1 完成确认 + DK-2 网络层打通（动态变体 + 复用多看 libcurl TLS PASS）

**用户确认**：DK-1 交互之前已验证——DK-1 全部完成。
**DK-2 拍板执行**：首选路线（复用多看 libcurl 动态变体）一次打通。

### 动作

1. **最小动态链接实验**：experiments/dyn/dyn_hello.c 用 TC(gcc14) 编码 + `-L~/k4-sysroot/lib` 链接设备 glibc 2.12.1；产物 interpreter=/lib/ld-linux.so.3，最高符号版本 GLIBC_2.4；设备实跑 EXIT=0——动态变体技术前提全验证。
2. **复用资产抽取**：多看 libcurl.so.4.3.0（curl 7.29.0 + OpenSSL 1.0.1e 内嵌，1.9MB）→ vendor/duokan/lib/（NOTICE 已标注，部署名 libcurl.so.4）；curl 7.29.0 头文件从 GitHub tag 取（curl.se 归档 URL 已失效）。
3. **手工 curlbuild.h（armel）**：SIZEOF_LONG=4 / curl_off_t=long long(64bit)，**必须含 dist 尾部的两个 typedef**（curl_socklen_t/curl_off_t）——漏了会报 curl_off_t undeclared（首败根因）。
4. **网络层三件**：`src/device/net.c`（curl_easy 最小面：http_get，VERIFYPEER 开/FOLLOWLOCATION/TIMEOUT 30/NOSIGNAL，body 动态缓冲）、`net_stub.c`（静态构建 no-op，桥接口不变）、wrbridge.c 的 wr_register 追加 wr_net_register 调用（静态/动态两态无差别）。
5. **Makefile weread-dyn 目标**：动态链接（无 -static），`-L~/k4-sysroot/lib`（libc 基线 2.12.1）+ `-l:libcurl.so.4.3.0` 精确名 + rpath `$ORIGIN/lib`。产物 3MB，NEEDED libcurl.so.4/librt/libdl/libgcc_s/libc，最高 GLIBC_2.7。
6. **链接坑两个**：① gcc 注入 `--sysroot`，**相对路径 -L 会被前缀到 sysroot 下**（首败）→ 全部绝对路径；② `-lcurl` 搜索名在 sysroot 语义下解析失败 → `-l:精确文件名`（ld 记 SONAME libcurl.so.4，运行期 rpath 命中）。
7. **部署脚本升级** `tools/deploy-weread.sh`：新增 weread-dyn/lib/net_smoke 部署 + `--net-smoke` 模式（一键部署+TLS 验证）。

### 真机 TLS 冒烟（PASS）

- `https://weread.qq.com/` → **status=200, 773KB**（VERIFYPEER 开启，设备 ca-bundle.pem 验签通过，复用 OpenSSL 1.0.1e）
- `https://www.baidu.com/` → curl rc=60（2015 时代 bundle 缺新根）——仅影响通用冲浪，业务域无关；**保持证书验证开启，勿关闭**。
- deploy-weread.sh --net-smoke 全链路复现 PASS（EXIT=0）。

### 下一步

DK-2 业务层（方案 §五）：auth.lua 扫码登录 / api.lua 签名移植（weread_K4 插件源 /home/doro/weread_K4.koplugin/）/ shelf / download / reader / sync。网络层基座（http_get）已就绪。

## 2026-11-18 · DK-1 step2 真机验收通过（freetype 中文渲染）

**目标**：DK-1 step2——freetype 接入，菜单升级中文。路线拍板：**上游 freetype 2.13.2 静态自编**
（复用多看 libfreetype 的动态变体归 DK-2 与 libcurl 一起做——届时反正要做 /lib sysroot；
静态自编在设备在线窗口外也零依赖，FreeType License=BSD 类可静态链接，NOTICE 标注）。

### 动作

1. **freetype 2.13.2 交叉静态编译**：`--host=arm-kindle5-linux-gnueabi --disable-shared --enable-static --without-{zlib,bzip2,png,harfbuzz,brotli}`（最小核心，TTF/TTC 渲染够用；ftgzip 自带内部 inflate 不需外部 -lz）。产出 4.5MB `libfreetype.a`（vendor/freetype，gitignored）。
2. **渲染层** `src/device/render.c/h`：FT_Init/FT_New_Face(face 0)/FT_Set_Pixel_Sizes（px 6~96 钳制）；UTF-8 手写解码器（1-4 字节，非法字节跳过）；字形混合 `dst=(dst*(255-cov)+fg*cov+127)/255` 背景透明；基线=y+ascender/64；行 stride=line_length、越界裁剪。最多 4 个并发字体句柄。
3. **桥扩展** `wrbridge.c`：`font_load(path[,px=28])` / `font_close(id)` / `fb_text_ft(id,x,y,utf8[,fg])` / `font_width(id,utf8)` / `fb_get(x,y)`（像素自检用）。wr_cleanup 统一 wr_ft_done。
4. **menu.lua 中文升级**：主字号 30 + 小字号 20；中文菜单项（继续阅读/书架/搜索/同步进度/设置/退出）+ 中文页脚；**点阵字体按次回退**（fb_text_ft 失败落 fb_text，缺字体文件整体回退 step1 英文模式）；draw() 加 fb_quant()（Duokan 量化收敛后再刷新）。SMOKE 增加**像素自检**（采样标题/首项/页脚区最小灰度，>200=字形区全白=失败）——无眼睛也可自动验收。
5. **SMOKE 容错**：input_open 失败不再 assert（KOReader EVIOCGRAB 独占时仍可自动验收渲染）；交互模式保持必须拿到输入。
6. **部署脚本** `tools/deploy-weread.sh`：weread+lua+字体（首次 5.2MB）三件部署，默认 SMOKE，`--interactive` 进交互。布局 `/mnt/us/weread/{weread,lua,fonts}`。
7. **DK-2 铺路（趁设备在线）**：设备 `/lib` 关键库归档 `~/k4-sysroot/lib/`——**实测设备 glibc=2.12.1**（2011-09-23），DK-2 动态变体的链接基线（TC 自带 glibc 更新，不可直接动态链接）。

### 真机验收（PASS）

- SMOKE：`ft=on`、pixel-check title=0 item1=0 footer=102（字形笔画确凿）、EXIT=0、dmesg 净、渲染后恢复原屏。
- 中文渲染全管线：UTF-8→freetype→8bpp 混合→Duokan 量化→0x46dd partial 刷新。
- 交互链路不变（step1 已验证五向导航）；KOReader 当前未运行，设备处于可交互状态。
- 构建产物 7MB 静态 exe（LuaJIT+freetype 内嵌），零代码警告（dlopen 链接注记为 LuaJIT 静态库既有无害产物）。

### 下一步

DK-1 收尾交互复验（用户侧：`tools/deploy-weread.sh --interactive`，五向键导航中文菜单）后即完成 DK-1，
进 DK-2 网络层：首选复用多看 libcurl+OpenSSL 动态变体（~/k4-sysroot 基线 glibc 2.12.1），
备选 OpenSSL 3.x 静态自编。

## 2026-11-18 · DK-1 step1 真机验收通过（LuaJIT VM + 输入独占 + 五向键菜单）

**目标**：DK-1 分阶段第一步——LuaJIT 2.1 armel 静态 VM + Lua C API 桥 + 内置点阵字体 + evdev 输入 + 五向键菜单，K4 真机可交互（freetype 中文渲染留 step2）。

### 动作

1. **LuaJIT 交叉编译**（最大风险项，已攻克）：vendor/luajit 2.1.1788856981，`HOST_CC="gcc -m32"`（buildvm 指针尺寸须匹配 32 位 ARM target，为此 apt 装 gcc-multilib/libc6-dev-i386）+ `LUAJIT_DISABLE_JIT`（K4/K5 JIT-on 定性崩）+ `BUILDMODE=static`。产出 `libluajit.a`（377KB），真机冒烟 LuaJIT 可跑（27KB 基线）。qemu binfmt 跑 buildvm 方案失败（老工具链 buildvm 在 qemu-arm 下 segfault），-m32 是正解。
2. **桥选型：Lua C API 而非 FFI**——静态可执行文件无动态符号表，`ffi.C.<sym>` 走 dlsym 解析不到；C API（lua_pushcfunction）静态/动态皆可。`src/bridge/wrbridge.c` 导出 `wr` 全局表：fb_open/close/w/h/refresh/fill/quant/text、input_open/close/poll、millis。
3. **设备层**：`src/device/input.c/h`（evdev event0=tequila-keypad/event1=fiveway，手工镜像 16B input_event 避 glibc time_t 歧义，键码取自 KOReader event_map_kindle4.lua）；`src/device/font8x16.h`（从 Uni2-VGA16.psf.gz 抽 95 个 ASCII 字形，PSF1 ASCII 直接索引 index==codepoint）；`src/host/wrmain.c`（LuaJIT VM 宿主，SIGINT/TERM 信号安全 cleanup）。
4. **menu.lua**：五向键 ASCII 菜单（Up/Down 移动、中键选中、Back/Menu/Home 退出），SMOKE 模式只渲染一帧即退（自动化验收）。Makefile 加 luajit/weread 目标，链接补 `-lrt`（老 glibc 的 clock_gettime 在 librt）。
5. **SMOKE 真机 PASS**：`weread menu.lua --smoke` → EXIT=0，渲染+恢复原屏，dmesg 无 segfault。整条管线（fb 备份→VM 启动→点阵字渲染→刷新→恢复）真机跑通。

### 关键发现 1：输入设备被 KOReader EVIOCGRAB 独占（架构级）

- 交互测试初次失败：按键无反应。写 `tools/evsniff.c` 诊断（用 EVIOCGRAB 抢占测试：抢到=无人独占，EBUSY=已被独占）。
- 确证：KOReader 运行时 `event0/event1` 均 `[GRABBED-by-other]`——KOReader 用 EVIOCGRAB 独占按键+五向键（屏蔽原生系统）。**即使 SIGSTOP 冻结 KOReader，grab 锁仍由其打开的 fd 持有**，其他读者收不到任何事件。`event2(volume)` free。
- **修复（生产必需）**：`wr_input_open` 对每个设备 EVIOCGRAB 独占、`wr_input_close` 释放。前台全屏应用必须独占输入，否则原生 cvm/KOReader 会同时读键并重绘盖屏（正是菜单被盖的同款机制）。实测：KOReader 退出后设备全 free，我方菜单启动即抢到（evsniff 反向确认 event0/1 = GRABBED-by-other=我们的菜单），退出后释放回 free（good citizenship，不锁死设备）。
- 原生框架 cvm **不**独占抓取——所以 KOReader 退出后我方 grab 能成功并排除原生。测试需先让 KOReader 释放（用户手动退出，进度自动保存）。

### 关键发现 2：show() 消息闪现（auto-repeat）

- 现象：中键选中后「press any key」消息一闪即回菜单。根因：按住中键时内核持续发 auto-repeat（value=2），show() 单次 `input_poll(-1)` 被同一按键的 repeat 立即满足。
- **修复**：`wr_input_poll` 加 `ignore_repeat` 参（跳过 value==2 只认首次按下 value==1）；Lua 侧 `input_poll(t, true)`。menu.lua show() 改为 `while wr.input_poll(-1, true) == nil do end`（循环等真实新按键），主循环也 ignore_repeat（离散按键、防长按重复触发 show/退出）。

### 验证

- 本地：`make host-selftest` HOST-OK；`make weread`/`make fbtest` 重建 exit=0 零警告（仅 dlopen-in-static 无害警告）。
- 真机：用户确认「正常响应」——高亮移动/中键选中/消息稳定不闪/退出正常；`menu done, sel=6` 干净退出；退出后 evsniff 确认 event0/1 回 `[free]`（grab 已释放）；dmesg 无 segfault。DK-1 step1 交互链全通验收闭环。

### 附带：GitHub/CI 可行性问答（用户提问）

结论=不划算且「公开」有风险：①交叉编译痛点已本地攻克，CI 无增量；②CI 够不到局域网 K4，真机在环验收（deploy/dmesg/目视）替代不了；③公开仓暴露多看固件逆向文档 + 微信读书非官方私有 API 客户端，法律/ToS 敏感。建议维持本地编译；若要可复现性走私有仓 + 自托管 runner，不公开。（未执行任何推送/建仓，等用户明确点头。）

### 下一步

DK-1 step2：freetype 中文渲染路线拍板（复用多看 libfreetype.so.6.5.0 动态变体 vs 上游静态自编）→ fb_draw_text 升级中文。其后 DK-2 网络层（首选复用多看 libcurl+OpenSSL 动态变体）。

## 2026-11-18 · DK-0 真机验收通过（K4 上线批次）

**目标**：解除 K4 离线阻塞，完成 DK-0 真机验收；顺带排查 SSH 认证与内存占用。

### 动作

1. 设备连通性排查：<K4_HOST> 不回 ICMP（ping 100% 丢包）但 ARP REACHABLE——WiFi 唤醒慢，SSH 需长 ConnectTimeout（30s 才握手成功；2s/10s 超时都是假阴性）。deploy 脚本未设 ConnectTimeout 时依赖 OpenSSH 默认超时，可用。
2. **SSH 认证修复**：设备 2222 = KOReader **魔改版 dropbear**（plugins/SSH.koplugin/main.lua:15-17），authorized_keys 从相对路径 `settings/SSH/authorized_keys` 读取（即 `/mnt/us/koreader/settings/SSH/authorized_keys`），非标准 `/tmp/root/.ssh/`。本机公钥装入该路径后免密登录生效；清理了误写入的 /tmp/root/.ssh（tmpfs，本就重启即消）。备份里发现旧 workbuddy 密钥（历史项目），未动。
3. **DK-0 真机验收 PASS**：`tools/deploy-k4.sh 5` → 量化自测 PASS；fb 实测 `600x800@8bpp line_length=600 smem_len=966656` 与方案 §4.1 假设一致；图案绘制+恢复刷新成功，EXIT=0；dmesg 无 segfault/fb 报错。屏幕视觉图案用户已目视确认，DK-0 验收完全闭环。
4. **内存占用分析**（KOReader 在场）：MemTotal 256MB / MemFree 13.9MB（假象），Buffers 33.6 + Cached 48.5 = 82MB 可回收，实际可用 ~96MB；AnonPages 108MB 中 cvm（Java 框架）58.1MB + reader.lua（KOReader）51.5MB 占 ~90%；无 swap，/mnt/us 是 vfat+FUSE 不便建 swapfile。结论：DK-0/1 内存充裕无需调优；开发期可选 `echo 3 > /proc/sys/vm/drop_caches`（零风险）或 `/etc/init.d/framework stop`（-58MB，可逆，本客户端走 raw fb ioctl 不依赖框架）；不建议上 swap。
5. Committed_AS 912MB / CommitLimit 128MB 说明：overcommit_memory=0 启发式模式不看 CommitLimit，912MB 是承诺预留量（Java arena/LuaJIT 地址空间）非实际占用，对几十 MB 级的本项目无影响。
6. HANDOFF 打钩：立即下一步第 1 条 → done；K4 离线 blocker → 解除。

### 下一步

DK-1：LuaJIT 2.1 armel 静态交叉编译（-joff）+ wrbridge.c FFI + menu.lua 按键菜单。

## 2026-11-16 · 铁律修订：多看资产复用解禁（标注制度）

**用户拍板**：多看系统刷机后与原系统并存；本系统走 KUAL 启动（并存不碰 rc5）；
**允许复用多看代码/资产，必须标注来源与版本；先把项目做起来，后续再优化。**

### 动作

1. README 铁律改写（复用+标注+先跑起来；KUAL 并存条目新增）。
2. 固件盘点 §四 资产判定翻转：固件 .so 从"不复用"改为"**可复用（标注）**"，落地形态记录两选：
   - 动态主进程变体 = **复刻多看自己的配方**（一手实证：KindleApp NEEDED 从原生系统取 libc/libm/libpthread/libgcc_s/libstdc++，从自带 lib/ 取其余 13 个；rundk.sh:386 `LD_LIBRARY_PATH=.:$SYS_LITE_PATH/lib/:../lib/` + FONTCONFIG_PATH）；前提=链接期用设备真实 /lib 作 sysroot（glibc 符号版本对齐，K4 在线后 pull 一条命令）。
   - 备选=上游源码静态自编（无 glibc 风险）。
   - 不可行形态明示：静态主进程 + dlopen 固件 .so（双 libc 堆/errno 分裂）。
3. TLS 结论简化（inventory §五 + 主抽取文档 §2.4）：**DK-2 首选复用多看 libcurl+OpenSSL（零编译）**，需动态变体；静态 OpenSSL 自编降为备选。DK-2 开工按设备在线状态拍板。
4. DK-1 保持：freetype 上游静态自编（设备离线约束下最快，避免动态变体的 glibc 对齐依赖）+ vendor 字体（授权字体现在可选配，随 NOTICE 标注）。
5. vendor/duokan/README 升级为复用制度文档：统一 NOTICE 声明模板（固件来源+版本+zip 哈希）+ 预留 lib/ 节。

### 影响面

- DK-1/DK-2 依赖表更新（主抽取文档 §五）；字体源、TLS 路线均已定版或留拍板点。
- "判死项"中 weread_ui patch/双缓冲等与复用解禁无关（那是"patch 闭源大件执行体"，非"复用其运行库"），维持判死。

## 2026-11-16 · 多看固件包原件盘点（用户澄清：原始文档=固件包本身）

**目标**：以固件原件（非评估报告）为一手来源，取证 K4 可用的底层资产。

### 动作

1. 校验 `/data/webdav/K4(xKindle_2015-05-15.36515.rtm).zip` SHA-256 与逆向报告一致；解包 1255 节点到 `/home/doro/duokan-fw-extract/`（仓库外工作区）。
2. **KindleApp 固件一手复核**（交叉 objdump，不经过报告转述）：设备路径 `/dev/fb0` + `/dev/input/event0/1/2`（strings）；fb 模块 0x494000–0x494d40 十处 ioctl；字面量池逐码计数 0x46db×1 / 0x46dd×1 / 0x4602×2 / 0x46f0 / 0x46f1 / 0x46e9 / 0x46ed，未用项 0x46e4/0x46ef/0x46e1/0x46f5 全 0——**逆向报告 §3 ioctl 清单经原件复验成立**。0x4600 计数为 0 的解释：ARM 立即数可编码（0x46 rot8），走 mov 不进池。
3. 运行时盘点：libfreetype.so.6.5.0（EABI4，NEEDED libz+libc）、libcurl.so.4.3.0（**curl 7.29.0 + OpenSSL 1.0.1e 内嵌**，解释包内无 libssl）、libdkkernel 10.9MB 等 13 库；字体 18 个（sysfonts 5 + userfonts 13）；rundk.sh GBK 转码实录启动链（S95framework 降级 + duokantag + LIPC）。
4. **资产判定**：固件 .so 不 dlopen（①铁律 ②EABI4 依赖宿主 libc + 静态 glibc 宿主 dlopen 坑 → 正确路径=上游源码静态编译）；**字体=数据资产可用**——开源可再分发子集（wqy-microhei.ttc GPLv2+FE、DejaVuSans.ttf）抽到 `vendor/duokan/fonts/`（vendor/ 已 gitignore），授权字体（方正/华文/微软系）留解包区本机用。
5. 产出 `docs/duokan-firmware-inventory.md`（一手盘点）+ 更新 `docs/duokan-k4-driver-architecture.md`（DK-1 字体源定版 + TLS 先例佐证改写：多看 OpenSSL 1.0.1e 2015 服役 = armel 生产先例，1.1.1 为保守降级档）。

### 注意

- 字面量池 grep 格式坑：NiLuJe binutils `objdump -s` 每字 8 hex 字符无空格（`db460000`），带空格 pattern 全零是假阴性。
- /tmp/ka_text.hex（19MB 中间物，临时）。

## 2026-11-16 · 多看逆向资产抽取（docs/）

**目标**：定位本机多看逆向原始文档，抽取 K4 实际可靠的底层驱动事实与可用架构，固化进项目。

### 动作

1. 定位证据源：多看逆向主报告（`~/reports/Duokan-xKindle-K4固件逆向与借鉴优化报告-2026-11-07.md`，REA/Ghidra 全量反汇编）+ 固件原件（`/data/webdav/K4(xKindle_2015-05-15.36515.rtm).zip`，SHA-256 可复核）+ isword 输入层/硬件门取证（`/home/doro/isword_k4/docs/phase3-input-layer.md`）+ K4Refresh 双机 A/B 报告与 ABI 代码。
2. 抽取并固化 → `docs/duokan-k4-driver-architecture.md`：
   - 底层驱动事实库（fb/eink ioctl 全量清单、fb 布局、量化恒等式、input evdev 三设备+uinput、工具链、LIPC 电源），逐条标注验证等级 L1双机/L2单机/L3反汇编/L4待验证；
   - 可用架构 7 条模式（单进程 fb 持有者、mmap 直绘+显式刷新、区域 partial 策略、排版分层、LIPC 门面、用户区部署、幂等量化）；
   - 判死项 5 条（weread_ui patch/双缓冲/现代 strace/内核波形/fast 档）；
   - DK-0~4 阶段对照表。
3. 发现并记录编号勘误：isword 文档的旋转 ioctl `0x4630` 与多看反汇编字面量池 `0x46f0/0x46f1` 不符，以反汇编为准（本项目不使用旋转，仅防误引）。
4. **补记网络栈风险**：自研进程内静态 OpenSSL3+curl 在 2.6.31/armv7 无真机先例（方案 §八未列）——DK-2 第一件事先做静态编译+K4 冒烟；备选 OpenSSL 1.1.1 或 K4Refresh musl 静态配方。

## 2026-11-15 · DK-0 二轮代码复核（离线）

**目标**：用户要求核实 bug 与回滚安全性。全量复核 fb.h/fb.c/main.c/Makefile/deploy-k4.sh。

### 复核结论

- 核对无误：update_area_t 24 字节 ABI（对齐 K4Refresh 真机验证版）；var/fix 手工镜像缓冲（284/304B）大于 2.6.31 内核 struct（内核只写自己的 sizeof）；量化 8 组向量逐位一致；fill_rect 边界钳制；量化只动可见区不碰驱动私有区。
- 发现并修复 3 项 + 1 项 errno：
  1. 🟠 失败路径/Ctrl+C 不恢复原屏 → main.c 重构：统一 `restore_screen()` + `goto out`，SIGINT/TERM 置位标志 + 分片 nanosleep 睡眠，任何退出路径先恢复再退出（中断退出码 130）。
  2. 🟠 恢复刷新返回值被忽略（失败仍打 fbtest OK）→ restore_screen 返回 rc 并检查。
  3. 🟡 deploy-k4.sh 的 DELAY 未校验直接拼远程命令 → 数字守卫（已用注入串实测拦截）。
  4. 🟢 bpp≠8 返回 -EBADF → -EINVAL。
  5. 顺手修：刷新失败与中断同时发生时 130 吞掉真实失败码 → 真实失败码优先。

### 验证

- `make host-selftest` PASS；`make fbtest` 零警告；qemu 冒烟 PASS（自测过/ENOENT 路径正确）。
- deploy 脚本 `bash -n` + 注入串守卫实测 PASS。

### 设备层回滚安全性（复核后结论）

正常路径 备份→画图→刷新→停留→恢复→刷新；失败/中断路径统一恢复。唯一残留情形：恢复刷新本身失败时面板停在图案，但 fb 内存已恢复，任意后续系统刷新（回 KOReader 按键等）即重绘原内容，无持久化残留。

## 2026-11-15 · DK-0 离线批次

**目标**：DK-0 工具链 + fb/eink 最小验证（技术方案 §五）。设备离线，本批次完成全部离线工作。

### 动作

1. 确认工具链 `~/x-tools/arm-kindle5-linux-gnueabi`（gcc 14.4.0）可用。
2. 参考 K4Refresh `src/eink.rs`（K4/K5 双机验证 ABI）+ `src/quant.rs`（Duokan nibble 量化）+ `src/fx.rs`（fx 档位语义），编写：
   - `src/device/fb.h/fb.c`：fb open/mmap + 0x4600/0x4602 信息 + 0x46db/0x46dd 刷新三件套 + fxquant + fill_rect + backup/restore + 量化自测。
   - `src/device/main.c`：DK-0 fbtest 入口（DK-1 起由 LuaJIT 主进程替换）。
   - `Makefile`：`make fbtest`（交叉静态）/ `make host-selftest`（主机量化自测）。
   - `tools/deploy-k4.sh`：部署 + 真机验证脚本。
3. 验证（离线可做的全部）：
   - `make host-selftest`：量化 8 组向量 + 幂等性 PASS。
   - `make fbtest`：产出 `build/fbtest` = ELF32 ARM EABI5 静态，GNU/Linux 2.6.31（与 K4 内核一致），-Wall -Wextra 无警告。
   - qemu-arm 冒烟：量化自测 PASS，fb open 路径正确返回 ENOENT（主机无 /dev/fb0），无非法指令。

### 阻塞

- **K4 真机验证 blocked**：<K4_HOST> ping 不通（ssh 2222 超时），设备当前离线。
  待设备上线后执行 `tools/deploy-k4.sh 5`，观察屏幕出现 白底+边框+16级渐变条+中央黑块，
  退出码 0，dmesg 无 segfault → DK-0 验收完成。

### 下一步

1. 设备上线 → `tools/deploy-k4.sh 5` → 完成 DK-0 验收。
2. DK-1：LuaJIT 2.1 交叉编译（-joff）+ wrbridge.c FFI 导出 + menu.lua 按键菜单。
