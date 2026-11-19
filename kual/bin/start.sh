#!/bin/sh
# start.sh — WereadK4_BasedDK 的 KUAL 启动器。
#
# KUAL 执行机制（k4weread.sh 取证）：菜单点击后 KUAL 自杀退出，本脚本经
# MKK su 在后台执行，stderr 追加到 /var/tmp/KUAL.log，cwd=扩展目录。
#
# framework 处理（koreader.sh K4 默认路径同款，完全可逆）：
#   framework 服务保留，仅对 cvm 发 SIGSTOP 防其重绘盖屏；应用退出后
#   SIGCONT + appmgrd 回主屏。不 stop framework、不碰 rc5（README 铁律）。
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

    # cvm SIGSTOP（framework 保留，可逆）
    if pidof cvm >/dev/null 2>&1; then
        killall -STOP cvm
        CVM_STOPPED=1
        echo "cvm SIGSTOPped"
    fi

    "$APP" "$SCRIPT" >> "$LOG" 2>&1
    rc=$?
    echo "app exit rc=$rc"

    if [ "$CVM_STOPPED" = "1" ]; then
        killall -CONT cvm
        echo "cvm SIGCONted"
    fi

    # 回主屏（cvm 恢复后由 framework 重绘；进程退出时已恢复原屏内容）
    lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null

    echo "=== weread exit $(date) ==="
} >> "$LOG" 2>&1
exit 0
