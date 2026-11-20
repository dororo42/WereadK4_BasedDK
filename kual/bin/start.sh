#!/bin/sh
# start.sh — WereadK4_BasedDK 的 KUAL 启动器（v3：cvm SIGSTOP 模式，退出无缝无 logo）。
#
# KUAL 执行机制（k4weread.sh 取证）：菜单点击后 KUAL 自杀退出，本脚本经 MKK su
# 在后台执行，stderr 追加到 /var/tmp/KUAL.log，cwd=扩展目录。menu.json 启动项
# exitmenu:true 已修复（v2 时为 false：framework stop 强杀活 KUAL → framework
# 弹"发生错误"+重启，用户实证）。
#
# framework 处理（v3 = koreader.sh K4 默认路径同款，退出无缝无树 logo）：
#   framework 服务保留，cvm SIGSTOP 冻结（防盖屏）、volumd SIGSTOP（抑制 USBMS）；
#   应用退出 → fb 恢复原屏（应用内 wr_cleanup）→ CONT cvm/volumd →
#   `echo 'send 139' >/proc/keypad`×2 注入 Menu 键，让刚解冻的 cvm 自己重绘
#   home——与 KOReader 退出完全同款，不重启 framework。
#   （v2 的 framework stop/start 会经 init 固有 logo_screen 画树 logo，用户
#   实证不理想，已弃用；git 历史可回溯。）
#   风险注记：v1（cvm SIGSTOP + exitmenu:false）曾于退出时 framework 弹窗——
#   根因是 exitmenu:false 冻结了活 KUAL；exitmenu:true 后该崩溃源已消除。

APP=/mnt/us/weread/weread-dyn
SCRIPT=/mnt/us/weread/lua/menu.lua
LOGDIR=/mnt/us/weread/data
LOG="$LOGDIR/start.log"

mkdir -p "$LOGDIR"

{
    echo "=== weread start $(date) ==="

    # 防重复：结束旧实例（TERM → 进程内清理：恢复原屏/释放 EVIOCGRAB）
    killall weread-dyn 2>/dev/null && sleep 1

    # cvm/volumd SIGSTOP（framework 服务保留，可逆；KOReader K4 默认路径同款）
    if pidof volumd >/dev/null 2>&1; then
        killall -STOP volumd
        VOLUMD_STOPPED=1
        echo "volumd SIGSTOPped"
    fi
    if pidof cvm >/dev/null 2>&1; then
        killall -STOP cvm
        CVM_STOPPED=1
        echo "cvm SIGSTOPped"
    fi

    "$APP" "$SCRIPT" >> "$LOG" 2>&1
    rc=$?
    echo "app exit rc=$rc"

    # 应用退出时已把进入前的原屏写回 fb（wr_cleanup）；此处解冻并让 framework
    # 自己重绘 home（KOReader 同款 send 139 = Menu 键注入，两次）。
    if [ "$VOLUMD_STOPPED" = "1" ]; then
        killall -CONT volumd
        echo "volumd SIGCONted"
    fi
    if [ "$CVM_STOPPED" = "1" ]; then
        killall -CONT cvm
        echo "cvm SIGCONted"
        echo 'send 139' > /proc/keypad 2>/dev/null
        sleep 1
        echo 'send 139' > /proc/keypad 2>/dev/null
    fi

    echo "=== weread exit $(date) ==="
} >> "$LOG" 2>&1
exit 0
