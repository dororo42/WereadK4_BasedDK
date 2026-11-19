#!/usr/bin/env bash
# deploy-kual.sh — 部署 KUAL 启动器三件到 /mnt/us/weread/（menu.json 绝对路径处）。
# 不改 menu.json/config.xml（isword 遗留定义原样保留，只补齐断链脚本）。
set -euo pipefail
K4_HOST="${K4_HOST:-root@192.168.2.151}"
K4_PORT="${K4_PORT:-2222}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for f in start.sh diagnose.sh recover.sh; do
    scp -P "$K4_PORT" -q "$ROOT/kual/bin/$f" "$K4_HOST:/mnt/us/weread/$f.new"
done
ssh -p "$K4_PORT" "$K4_HOST" '
    for f in start.sh diagnose.sh recover.sh; do
        mv "/mnt/us/weread/$f.new" "/mnt/us/weread/$f"
        chmod 755 "/mnt/us/weread/$f"
    done
    echo "kual scripts deployed:"
    ls -la /mnt/us/weread/*.sh'
