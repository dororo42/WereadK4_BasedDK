#!/bin/sh
# recover.sh — 恢复启动状态（KUAL 菜单"恢复启动状态"）：
# 结束应用 + 恢复 cvm + 回主屏。用于 start.sh 异常后的人工兜底。
killall weread-dyn 2>/dev/null
killall -CONT cvm 2>/dev/null
lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
exit 0
