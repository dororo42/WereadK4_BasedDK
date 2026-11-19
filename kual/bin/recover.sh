#!/bin/sh
# recover.sh — 恢复启动状态（KUAL 菜单"恢复启动状态"）：
# 结束应用 + 确保 framework 起来 + 回主屏。start.sh 异常后的人工兜底。
killall weread-dyn 2>/dev/null
if ! pidof cvm >/dev/null 2>&1; then
    /etc/init.d/framework start 2>/dev/null
    sleep 2
fi
lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
exit 0
