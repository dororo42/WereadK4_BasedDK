# WereadK4_BasedDK

微信读书 K4 原生客户端（路线 E：多看架构模式自研）。详见 README.md；技术方案/逆向报告是本机 only 材料（`~/reports/`、`/data/webdav/`），未随仓库发布，其结论已落进 `docs/`。

## 规则

- ub-mode：Make it Work → Right → Practice。TDD、可验证单元切分、LOG.md 动作日志。
- orbital_handoff：`handoffs/` 本地 only，每批次 CREATE 并更新下方指针。
- 设备：K4 走 usbnet SSH（`root@$K4_HOST:$K4_PORT`）；真值在本机 `tools/k4-env.local.sh`（gitignore，**勿提交**），模板 `tools/k4-env.example.sh`。K5 离线。交叉工具链 ~/x-tools/arm-kindle5-linux-gnueabi。

## Current Handoff

- Latest: `handoffs/2026-11-19-150713-dk3-device-acceptance-pending/HANDOFF.md`（本地 only，不入库）
- Branch: main（2026-11-19 做过一次历史改写，改写前的所有 SHA 已失效；映射表见 `LOG.md`，一律以 `git log` 为准）
- Remote: `origin` = https://github.com/dororo42/WereadK4_BasedDK （**public**：任何提交立刻公开，`git add` 前先 `git status` 复核）
- Status: 正文链路已打通 —— 真机暴露 `dk3_smoke` 假绿，根因是 net.c 丢响应头（05bd524 修），
  书架 8/8 本书已 spool 出真实正文；剩两项真机验收：键位手感（`--interactive`）与免扫码续期实测

任何 agent 开始工作前，先读上面的 HANDOFF.md。这份指针由 orbital_handoff 维护，手工交接时请同步更新。
