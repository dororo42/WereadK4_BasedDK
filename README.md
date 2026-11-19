# WereadK4_BasedDK

微信读书 K4 原生客户端（路线 E：多看 Duokan 架构模式自研，非 KOReader 插件）。

## 目标

在 Kindle 4 上运行独立微信读书客户端：菜单式+快捷键交互（非触摸），功能对齐 weread_K4 插件。

技术方案与实施计划（`~/reports/WereadK4_BasedDK-技术方案与实施计划-2026-11-15.md`）是多看逆向阶段的
本机研究文档，**未随仓库发布**；已发布的依据与结论见 `docs/`。

## 纪律

- ub-mode（Make it Work → Right → Practice）：每阶段可独立验证后才进下一阶段。
- orbital_handoff：`handoffs/` 本地 only，每批次结束 CREATE。
- 技术方案：本机 only（`~/reports/`，未随仓库发布）；仓库内依据见下一条 `docs/`。
- 底层驱动与资产依据：`docs/duokan-k4-driver-architecture.md` + `docs/duokan-firmware-inventory.md`。

## 铁律（2026-11-16 用户修订）

- **允许复用多看固件资产**（.so/字体/脚本/算法知识），但**必须标注来源与版本**（`vendor/duokan/README.md` + 安装包 NOTICE + docs 出处引用）；核心业务代码自研。
- **先把项目做起来**（复用优先），后续再逐步优化（可替换为上游源码自编译）。
- K4 设备操作先备份；不替换 KOReader/weread_K4 安装。
- weread_K4 插件与本项目并行不互斥。
- 本系统经 KUAL 启动，与原生系统（及多看，若安装）并存，不碰 rc5。

## Current Handoff

`handoffs/` 是 orbital_handoff 的本机交接通道，**不入库**（见 `.gitignore`），公开仓库里点不到。
仓库内的指针是 `AGENTS.md` 的 `## Current Handoff` 段（同样按本机状态维护，快照可能滞后 `git log`）。

## 构建与部署

公开仓库只含源码与文档；构建还依赖两类**不入库**的本机资产：

- 交叉工具链 `~/x-tools/arm-kindle5-linux-gnueabi`（可用 `make CROSS=<前缀>` 覆盖）。
- `vendor/`：LuaJIT 2.1（armel 静态，`-DLUAJIT_DISABLE_JIT`）、FreeType 2.13.2 自编静态库、
  多看固件的 `libcurl.so.4.3.0` 与 `wqy-microhei.ttc`（来源与版本标注见 `docs/duokan-firmware-inventory.md`）。
- 动态变体 `weread-dyn` 另需 `~/k4-sysroot`（设备 glibc 2.12.1 基线）。

不需要设备的门禁：`make host-selftest`（C 层量化/输入自测）、`make host-lua-test`（Lua 单测）。
交叉编译：`make weread`（静态）/ `make weread-dyn`（动态，体积更小）。

部署前先提供设备地址（本机 only，不入库）：

```bash
cp tools/k4-env.example.sh tools/k4-env.local.sh   # 填 K4_HOST=root@<设备地址>
tools/deploy-weread.sh                             # 全量部署 + SMOKE 像素自检
tools/deploy-weread.sh --interactive               # 五向键交互验收
```

设备侧数据面验收脚本（无 UI，退出码非 0 即失败）：`lua/download_smoke.lua`、`lua/dk3_smoke.lua`。
键位约定见 `docs/keymap-k4.md`。
