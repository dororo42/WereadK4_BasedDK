#!/usr/bin/env bash
# deploy-k4.sh — DK-0 部署验证：推送 fbtest 到 K4 并真机跑一轮。
#
# 用法: tools/deploy-k4.sh [屏幕停留秒数，默认 5]
# 前置: K4 (root@<K4_HOST>:2222) 在线；build/fbtest 已由 make fbtest 编出。
# 安全: 只新建 /mnt/us/weread-trial/（新目录）；fbtest 自身备份并恢复原屏内容，
#       不触碰 KOReader/weread_K4 安装。验证标准：屏幕可见变化 + EXIT=0 + dmesg 无报错。
set -euo pipefail

K4_HOST="${K4_HOST:-root@<K4_HOST>}"
K4_PORT="${K4_PORT:-2222}"
DELAY="${1:-5}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/fbtest"

[ -x "$BIN" ] || { echo "缺 $BIN —— 先 make fbtest" >&2; exit 1; }

echo "=== 部署到 $K4_HOST:$K4_PORT:/mnt/us/weread-trial/ ==="
ssh -p "$K4_PORT" "$K4_HOST" "mkdir -p /mnt/us/weread-trial"
scp -P "$K4_PORT" -q "$BIN" "$K4_HOST:/mnt/us/weread-trial/fbtest.new"
ssh -p "$K4_PORT" "$K4_HOST" \
    "mv /mnt/us/weread-trial/fbtest.new /mnt/us/weread-trial/fbtest && chmod +x /mnt/us/weread-trial/fbtest"

echo "=== 真机执行（屏幕停留 ${DELAY}s，期间请观察：白底+边框+16级渐变条+中央黑块） ==="
ssh -p "$K4_PORT" "$K4_HOST" "cd /mnt/us/weread-trial && ./fbtest $DELAY; rc=\$?; echo EXIT=\$rc; echo '--- dmesg tail ---'; dmesg | tail -n 8"
