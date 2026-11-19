#!/usr/bin/env bash
# deploy-k4.sh — DK-0 部署验证：推送 fbtest 到 K4 并真机跑一轮。
#
# 用法: tools/deploy-k4.sh [屏幕停留秒数，默认 5]
# 前置: K4 在线，设备地址由 K4_HOST 环境变量或 tools/k4-env.local.sh 提供（本机 only，不入库）；
#       build/fbtest 已由 make fbtest 编出。
# 安全: 只新建 /mnt/us/weread-trial/（新目录）；fbtest 自身备份并恢复原屏内容，
#       不触碰 KOReader/weread_K4 安装。验证标准：屏幕可见变化 + EXIT=0 + dmesg 无报错。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${K4_HOST:-}" ] && [ -f "$ROOT/tools/k4-env.local.sh" ]; then
    . "$ROOT/tools/k4-env.local.sh"
fi
: "${K4_HOST:?需要 K4_HOST —— cp tools/k4-env.example.sh tools/k4-env.local.sh 并填设备地址}"
K4_PORT="${K4_PORT:-2222}"
DELAY="${1:-5}"
BIN="$ROOT/build/fbtest"

[ -x "$BIN" ] || { echo "缺 $BIN —— 先 make fbtest" >&2; exit 1; }
[[ "$DELAY" =~ ^[0-9]+$ ]] || { echo "停留秒数必须为数字: $DELAY" >&2; exit 1; }

echo "=== 部署到 $K4_HOST:$K4_PORT:/mnt/us/weread-trial/ ==="
ssh -p "$K4_PORT" "$K4_HOST" "mkdir -p /mnt/us/weread-trial"
scp -P "$K4_PORT" -q "$BIN" "$K4_HOST:/mnt/us/weread-trial/fbtest.new"
ssh -p "$K4_PORT" "$K4_HOST" \
    "mv /mnt/us/weread-trial/fbtest.new /mnt/us/weread-trial/fbtest && chmod +x /mnt/us/weread-trial/fbtest"

echo "=== 真机执行（屏幕停留 ${DELAY}s，期间请观察：白底+边框+16级渐变条+中央黑块） ==="
ssh -p "$K4_PORT" "$K4_HOST" "cd /mnt/us/weread-trial && ./fbtest $DELAY; rc=\$?; echo EXIT=\$rc; echo '--- dmesg tail ---'; dmesg | tail -n 8"
