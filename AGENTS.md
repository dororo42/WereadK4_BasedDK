# WereadK4_BasedDK

微信读书 K4 原生客户端（路线 E：多看架构模式自研）。详见 README.md 与 ~/reports/ 技术方案。

## 规则

- ub-mode：Make it Work → Right → Practice。TDD、可验证单元切分、LOG.md 动作日志。
- orbital_handoff：`handoffs/` 本地 only，每批次 CREATE 并更新下方指针。
- 设备：K4 = root@<K4_HOST>:2222（K5 离线）。交叉工具链 ~/x-tools/arm-kindle5-linux-gnueabi。

## Current Handoff

- Latest: `handoffs/2026-11-15-204026-dk0-fbtest-offline/HANDOFF.md`
- Branch: main @ 73d99c0
- Status: DK-0 离线批次完成，等待 K4 上线真机验收

任何 agent 开始工作前，先读上面的 HANDOFF.md。这份指针由 orbital_handoff 维护，手工交接时请同步更新。
