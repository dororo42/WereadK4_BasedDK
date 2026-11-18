#!/usr/bin/env bash
# deploy-weread.sh — DK-1 部署：weread 主进程 + lua 脚本 + 字体 到 K4 并跑 SMOKE。
#
# 用法: tools/deploy-weread.sh [--interactive]
#   默认: SMOKE 自动验收（渲染一帧 + 像素自检，不进按键循环）
#   --interactive: 交互模式（需 KOReader 已退出释放输入；五向键导航，Back 退出）
# 布局: /mnt/us/weread/{weread, lua/menu.lua, fonts/wqy-microhei.ttc}
set -euo pipefail

K4_HOST="${K4_HOST:-root@<K4_HOST>}"
K4_PORT="${K4_PORT:-2222}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/weread"
MODE="${1:---smoke}"

[ -x "$BIN" ] || { echo "缺 $BIN —— 先 make weread" >&2; exit 1; }

echo "=== 部署到 $K4_HOST:$K4_PORT:/mnt/us/weread/ ==="
ssh -p "$K4_PORT" "$K4_HOST" "mkdir -p /mnt/us/weread/lua /mnt/us/weread/fonts"
scp -P "$K4_PORT" -q "$BIN" "$K4_HOST:/mnt/us/weread/weread.new"
scp -P "$K4_PORT" -q "$ROOT/src/lua/menu.lua" "$K4_HOST:/mnt/us/weread/lua/menu.lua"
if ! ssh -p "$K4_PORT" "$K4_HOST" "test -s /mnt/us/weread/fonts/wqy-microhei.ttc"; then
    scp -P "$K4_PORT" -q "$ROOT/vendor/duokan/fonts/wqy-microhei.ttc" \
        "$K4_HOST:/mnt/us/weread/fonts/wqy-microhei.ttc"
    echo "(字体首次部署 5.2MB)"
fi
ssh -p "$K4_PORT" "$K4_HOST" \
    "mv /mnt/us/weread/weread.new /mnt/us/weread/weread && chmod +x /mnt/us/weread/weread"

echo "=== 执行（$MODE） ==="
if [ "$MODE" = "--interactive" ]; then
    exec ssh -t -p "$K4_PORT" "$K4_HOST" "/mnt/us/weread/weread /mnt/us/weread/lua/menu.lua"
else
    ssh -p "$K4_PORT" "$K4_HOST" \
        "/mnt/us/weread/weread /mnt/us/weread/lua/menu.lua --smoke; rc=\$?; echo EXIT=\$rc; echo '--- dmesg tail ---'; dmesg | tail -n 5"
fi
