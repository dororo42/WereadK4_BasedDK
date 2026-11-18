# LOG — 动作日志（ub-mode）

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
