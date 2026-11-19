# LOG — 动作日志（ub-mode）

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
   级联，147c543），download_smoke 待设备恢复；上份交接三项全部给出结局；设备离线 blocker 记录。

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
