# WereadK4_BasedDK

微信读书 K4 原生客户端（路线 E：多看 Duokan 架构模式自研，非 KOReader 插件）。

## 目标

在 Kindle 4 上运行独立微信读书客户端：菜单式+快捷键交互（非触摸），功能对齐 weread_K4 插件，技术方案详见 `~/reports/WereadK4_BasedDK-技术方案与实施计划-2026-11-15.md`。

## 纪律

- ub-mode（Make it Work → Right → Practice）：每阶段可独立验证后才进下一阶段。
- orbital_handoff：`handoffs/` 本地 only，每批次结束 CREATE。
- 技术方案：`~/reports/WereadK4_BasedDK-技术方案与实施计划-2026-11-15.md`。
- 底层驱动与资产依据：`docs/duokan-k4-driver-architecture.md` + `docs/duokan-firmware-inventory.md`。

## 铁律（2026-11-16 用户修订）

- **允许复用多看固件资产**（.so/字体/脚本/算法知识），但**必须标注来源与版本**（`vendor/duokan/README.md` + 安装包 NOTICE + docs 出处引用）；核心业务代码自研。
- **先把项目做起来**（复用优先），后续再逐步优化（可替换为上游源码自编译）。
- K4 设备操作先备份；不替换 KOReader/weread_K4 安装。
- weread_K4 插件与本项目并行不互斥。
- 本系统经 KUAL 启动，与原生系统（及多看，若安装）并存，不碰 rc5。

## Current Handoff

- Latest: `handoffs/2026-11-15-204026-dk0-fbtest-offline/HANDOFF.md`
