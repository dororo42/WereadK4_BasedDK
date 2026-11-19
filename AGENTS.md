# WereadK4_BasedDK

微信读书 K4 原生客户端（路线 E：多看架构模式自研）。详见 README.md 与 ~/reports/ 技术方案。

## 规则

- ub-mode：Make it Work → Right → Practice。TDD、可验证单元切分、LOG.md 动作日志。
- orbital_handoff：`handoffs/` 本地 only，每批次 CREATE 并更新下方指针。
- 设备：K4 = root@<K4_HOST>:2222（K5 离线）。交叉工具链 ~/x-tools/arm-kindle5-linux-gnueabi。

## Current Handoff

- Latest: `handoffs/2026-11-19-085900-dk2-download-reader-code-ready/HANDOFF.md`
- Branch: main（交接快照记为 09a3a57，实际 HEAD 已推进，以 `git log` 为准）
- Status: 离线代码审查修复完成并提交（信号安全应急恢复 / header 截断 / auth 原子写 / shard 奇数守卫 / PRNG 播种，共 5 处），已过 luac + 交叉编译 + host 行为测试；设备仍离线，download_smoke 真机验证与 DK-3 待 K4 恢复上线。

任何 agent 开始工作前，先读上面的 HANDOFF.md。这份指针由 orbital_handoff 维护，手工交接时请同步更新。
