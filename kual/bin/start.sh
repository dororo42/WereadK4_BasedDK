#!/bin/sh
# start.sh — WereadK4_BasedDK 的 KUAL 启动器。
#
# KUAL 执行机制（k4weread.sh 取证）：菜单点击后 KUAL 自杀退出，本脚本经
# MKK su 在后台执行，stderr 追加到 /var/tmp/KUAL.log，cwd=扩展目录。
#
# framework 处理（koreader.sh --framework_stop 模式同款）：
#   **framework 整体 stop/start**。此前用 cvm SIGSTOP——用户真机实证：阅读数分钟
#   退出后 framework 弹"发生错误"并重启 framework 栈（cvm 半停态崩溃面被证伪，
#   2026-11-20）。framework stop 后无 cvm/无盖屏/无 watcher 弹窗面；代价是退出
#   回主屏多几秒（framework 完整重建）。不碰 rc5（README 铁律）。
#
# 应用：weread-dyn（动态变体，带网络）+ menu.lua 主菜单。
# 信号链：killall TERM → 进程内 on_signal → wr_cleanup（恢复原屏/释放输入）。

APP=/mnt/us/weread/weread-dyn
SCRIPT=/mnt/us/weread/lua/menu.lua
LOGDIR=/mnt/us/weread/data
LOG="$LOGDIR/start.log"

mkdir -p "$LOGDIR"

{
    echo "=== weread start $(date) ==="

    # 防重复：结束旧实例（TERM → 进程内清理：恢复原屏/释放 EVIOCGRAB）
    killall weread-dyn 2>/dev/null && sleep 1

    # framework 整体停（cvm/framework 随之退出；KUAL 已自杀，无残留 UI）
    if [ -e /etc/init.d/framework ]; then
        trap "" TERM                       # framework stop 会向会话发 TERM（koreader.sh 同款防杀）
        /etc/init.d/framework stop
        trap - TERM
        sleep 1                            # 等待拆解完成（koreader.sh 用 1.25s）
        FRAMEWORK_STOPPED=1
        echo "framework stopped"
    fi

    "$APP" "$SCRIPT" >> "$LOG" 2>&1
    rc=$?
    echo "app exit rc=$rc"

    if [ "$FRAMEWORK_STOPPED" = "1" ]; then
        /etc/init.d/framework start
        echo "framework started"
        sleep 2                            # 等主屏重绘完成再切 home
    fi

    # 回主屏
    lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null

    echo "=== weread exit $(date) ==="
} >> "$LOG" 2>&1
exit 0
