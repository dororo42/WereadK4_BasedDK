#!/usr/bin/env bash
# deploy-weread.sh — DK-1 部署：weread 主进程 + lua 脚本 + 字体 到 K4 并跑 SMOKE。
#
# 用法: tools/deploy-weread.sh [--interactive]
#   默认: SMOKE 自动验收（渲染一帧 + 像素自检，不进按键循环）
#   --interactive: 交互模式（需 KOReader 已退出释放输入；五向键导航，Back 退出）
# 前置: 设备地址由 K4_HOST 环境变量或 tools/k4-env.local.sh 提供（本机 only，不入库）
# 布局: /mnt/us/weread/{weread, lua/menu.lua, fonts/wqy-microhei.ttc}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 设备地址属本机部署环境，不入库：环境变量优先，其次 tools/k4-env.local.sh（模板 k4-env.example.sh）
if [ -z "${K4_HOST:-}" ] && [ -f "$ROOT/tools/k4-env.local.sh" ]; then
    . "$ROOT/tools/k4-env.local.sh"
fi
: "${K4_HOST:?需要 K4_HOST —— cp tools/k4-env.example.sh tools/k4-env.local.sh 并填设备地址}"
K4_PORT="${K4_PORT:-2222}"
BIN="${BIN:-$ROOT/build/weread-dyn}"
MODE="${1:---smoke}"

[ -x "$BIN" ] || { echo "缺 $BIN —— 先 make weread" >&2; exit 1; }

echo "=== 部署到 $K4_HOST:$K4_PORT:/mnt/us/weread/ ==="
ssh -p "$K4_PORT" "$K4_HOST" "mkdir -p /mnt/us/weread/lua/lib /mnt/us/weread/fonts /mnt/us/weread/lib /mnt/us/weread/data"
scp -P "$K4_PORT" -q "$BIN" "$K4_HOST:/mnt/us/weread/weread.new"
for f in "$ROOT"/src/lua/*.lua; do
    scp -P "$K4_PORT" -q "$f" "$K4_HOST:/mnt/us/weread/lua/$(basename "$f")"
done
for f in "$ROOT"/src/lua/lib/*.lua; do
    scp -P "$K4_PORT" -q "$f" "$K4_HOST:/mnt/us/weread/lua/lib/$(basename "$f")"
done
# DK-2 动态变体 + 复用多看 libcurl（vendor/duokan/lib，NOTICE 标注）
if [ -x "$ROOT/build/weread-dyn" ]; then
    scp -P "$K4_PORT" -q "$ROOT/build/weread-dyn" "$K4_HOST:/mnt/us/weread/weread-dyn.new"
fi
if ! ssh -p "$K4_PORT" "$K4_HOST" "test -s /mnt/us/weread/lib/libcurl.so.4"; then
    scp -P "$K4_PORT" -q "$ROOT/vendor/duokan/lib/libcurl.so.4.3.0" \
        "$K4_HOST:/mnt/us/weread/lib/libcurl.so.4.new"
    echo "(libcurl 首次部署 1.9MB)"
fi
if ! ssh -p "$K4_PORT" "$K4_HOST" "test -s /mnt/us/weread/fonts/wqy-microhei.ttc"; then
    scp -P "$K4_PORT" -q "$ROOT/vendor/duokan/fonts/wqy-microhei.ttc" \
        "$K4_HOST:/mnt/us/weread/fonts/wqy-microhei.ttc"
    echo "(字体首次部署 5.2MB)"
fi
ssh -p "$K4_PORT" "$K4_HOST" \
    "mv /mnt/us/weread/weread.new /mnt/us/weread/weread && chmod +x /mnt/us/weread/weread; \
     [ -f /mnt/us/weread/weread-dyn.new ] && mv /mnt/us/weread/weread-dyn.new /mnt/us/weread/weread-dyn && chmod +x /mnt/us/weread/weread-dyn; \
     [ -f /mnt/us/weread/lib/libcurl.so.4.new ] && mv /mnt/us/weread/lib/libcurl.so.4.new /mnt/us/weread/lib/libcurl.so.4; \
     true"

echo "=== 执行（$MODE） ==="
if [ "$MODE" = "--interactive" ]; then
    exec ssh -t -p "$K4_PORT" "$K4_HOST" "/mnt/us/weread/weread /mnt/us/weread/lua/menu.lua"
elif [ "$MODE" = "--net-smoke" ]; then
    ssh -p "$K4_PORT" "$K4_HOST" "/mnt/us/weread/weread-dyn /mnt/us/weread/lua/net_smoke.lua; echo EXIT=\$?"
else
    ssh -p "$K4_PORT" "$K4_HOST" \
        "/mnt/us/weread/weread /mnt/us/weread/lua/menu.lua --smoke; rc=\$?; echo EXIT=\$rc; echo '--- dmesg tail ---'; dmesg | tail -n 5"
fi
