# LOG — 动作日志（ub-mode）

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
