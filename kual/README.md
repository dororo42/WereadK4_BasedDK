# kual/ — KUAL 集成（DK-4）

KUAL 主菜单显示**单个「微信读书」按钮，点击直接启动**（menu.json 单条 depth-1
action 项=KUAL 主菜单按钮，无子菜单；exitmenu:true=点击后 KUAL 自杀退出再跑脚本）。
2026-11-21 按用户口径改造（原 isword 0.3.9 三项子菜单已去除，原文件备份为
设备 menu.json.v2-backup）。

诊断/恢复两个脚本仍在 `/mnt/us/weread/`（ssh 调用；不再占用 KUAL 菜单位）。
另：fpcheck 的「Write fingerprint report」已并入 KUAL 内置【Kual】菜单（2026-11-21 用户口径；fpcheck 根项命名 "KUAL" 子菜单→KUAL collate 同名合并机制，根按钮显示 "KUAL+" 为上游合并标记）。未动。

## KUAL 执行机制（k4weread.sh 取证）

菜单点击 → KUAL 自杀退出（onStop）→ 脚本后台执行（stderr→/var/tmp/KUAL.log），
cwd=扩展目录。所以脚本直接前台跑应用，无"卡菜单"问题；应用 stderr 进
`/mnt/us/weread/data/start.log`。

## framework 处理（koreader.sh K4 默认路径同款，可逆）

framework 服务保留；cvm SIGSTOP 防盖屏；应用退出（或 TERM）→ SIGCONT +
appmgrd 回主屏。不 stop framework、不碰 rc5。异常兜底 = recover.sh。

## 部署

`tools/deploy-kual.sh`（见 tools/）：scp 三件到 /mnt/us/weread/ + chmod。
menu.json 若被改过可对照备份 /mnt/us/extensions/weread/menu.json.orig。
