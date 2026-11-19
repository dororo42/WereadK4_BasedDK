# kual/ — KUAL 集成（DK-4）

KUAL 菜单（设备 `/mnt/us/extensions/weread/`，isword 0.3.9 遗留定义）三项：
启动微信读书 / 生成兼容报告 / 恢复启动状态。**menu.json 未改动**（铁律：不替换
isword 安装；三项 action 指向的脚本此前全部缺失=启动无反应的根因），本目录补齐
三个脚本，部署到 `/mnt/us/weread/`（menu.json 的绝对路径处）。

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
