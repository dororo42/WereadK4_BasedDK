# WereadK4_BasedDK

微信读书 K4 原生客户端（路线 E：多看架构模式自研）。详见 README.md；技术方案/逆向报告是本机 only 材料（`~/reports/`、`/data/webdav/`），未随仓库发布，其结论已落进 `docs/`。

## 规则

- ub-mode：Make it Work → Right → Practice。TDD、可验证单元切分、LOG.md 动作日志。
- orbital_handoff：`handoffs/` 本地 only，每批次 CREATE 并更新下方指针。
- 设备：K4 走 usbnet SSH（`root@$K4_HOST:$K4_PORT`）；真值在本机 `tools/k4-env.local.sh`（gitignore，**勿提交**），模板 `tools/k4-env.example.sh`。K5 离线。交叉工具链 ~/x-tools/arm-kindle5-linux-gnueabi。

## Current Handoff

- Latest: `handoffs/2026-11-19-111648-dk3-reading-keys-resume/HANDOFF.md`
- Branch: main @ 07a7561（DK-3 阅读侧 6 个提交 af3c702→a5e6b61 已落地；指针快照可能滞后，以 git log 为准）
- Remote: `origin` = https://github.com/dororo42/WereadK4_BasedDK （**public**，35 commits 已推送）
- Status: 代码就绪且已公开推送；仅剩设备阻塞——真机验收（dk3_smoke + 键位手感）待 K4 上线

任何 agent 开始工作前，先读上面的 HANDOFF.md。这份指针由 orbital_handoff 维护，手工交接时请同步更新。
