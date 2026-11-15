# LOG — 动作日志（ub-mode）

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
