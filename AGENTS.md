# WereadK4_BasedDK

微信读书 K4 原生客户端（路线 E：多看架构模式自研）。详见 README.md；技术方案/逆向报告是本机 only 材料（`~/reports/`、`/data/webdav/`），未随仓库发布，其结论已落进 `docs/`。

## 规则

- ub-mode：Make it Work → Right → Practice。TDD、可验证单元切分、LOG.md 动作日志。
- orbital_handoff：`handoffs/` 本地 only，每批次 CREATE 并更新下方指针。
- 设备：K4 走 usbnet SSH（`root@$K4_HOST:$K4_PORT`）；真值在本机 `tools/k4-env.local.sh`（gitignore，**勿提交**），模板 `tools/k4-env.example.sh`。K5 离线。交叉工具链 ~/x-tools/arm-kindle5-linux-gnueabi。

## Current Handoff

- Latest: `handoffs/2026-11-20-211540-shelf-pagination-fonts-sync/HANDOFF.md`
- Branch: main @ 353c56e
- Status: 等待决策（真机按键复验 + 是否 push）；主机 19 套单测与 13 条变异已全绿

任何 agent 开始工作前，先读上面的 HANDOFF.md。这份指针由 orbital_handoff 维护，手工交接时请同步更新。
