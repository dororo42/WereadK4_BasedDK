#!/bin/sh
# diagnose.sh — 只读诊断报告（KUAL 菜单"生成兼容报告"）。不改变任何状态。
OUT=/mnt/us/weread/data/diagnose.txt
{
    echo "=== WereadK4 diagnose $(date) ==="
    echo "--- version ---"
    /mnt/us/weread/weread-dyn lua/net_smoke.lua 2>/dev/null | head -3
    echo "--- processes ---"
    ps -A | grep -e weread -e cvm -e koreader -e framework | grep -v grep
    echo "--- cvm state (T=stopped) ---"
    ps -A | grep cvm | grep -v grep
    echo "--- fb ---"
    ls -la /dev/fb0
    echo "--- auth.json (keys only, values masked) ---"
    ls -la /mnt/us/weread/data/auth.json 2>/dev/null
    echo "--- start.log tail ---"
    tail -n 15 /mnt/us/weread/data/start.log 2>/dev/null
    echo "--- dmesg tail ---"
    dmesg | tail -n 5
    echo "=== diagnose end ==="
} > "$OUT" 2>&1
exit 0
