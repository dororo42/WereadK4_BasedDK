# WereadK4_BasedDK

微信读书 K4 原生客户端（路线 E：多看 Duokan 架构模式自研，非 KOReader 插件）。

## 目标

在 Kindle 4 上运行独立微信读书客户端：菜单式+快捷键交互（非触摸），功能对齐 weread_K4 插件，技术方案详见 `~/reports/WereadK4_BasedDK-技术方案与实施计划-2026-11-15.md`。

## 纪律

- ub-mode（Make it Work → Right → Practice）：每阶段可独立验证后才进下一阶段。
- orbital_handoff：`handoffs/` 本地 only，每批次结束 CREATE。
- 技术方案：`~/reports/WereadK4_BasedDK-技术方案与实施计划-2026-11-15.md`。

## 铁律

- 全自研代码，无 isword/多看二进制复用（仅借鉴架构模式与 API 知识）。
- K4 设备操作先备份；不替换 KOReader/weread_K4 安装。
- weread_K4 插件与本项目并行不互斥。

## Current Handoff

- (尚无——DK-0 完成后 CREATE 首份)
