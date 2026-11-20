#!/usr/bin/env bash
# deploy-kual.sh — 部署 KUAL 启动器三件到 /mnt/us/weread/（menu.json 绝对路径处）。
# 不改 menu.json/config.xml（isword 遗留定义原样保留，只补齐断链脚本）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 设备地址属本机部署环境，不入库（与 deploy-weread.sh 同配方）：环境变量优先，
# 其次 tools/k4-env.local.sh。这里曾写死内网 IP 当默认值——公开仓库里不该有它。
if [ -z "${K4_HOST:-}" ] && [ -f "$ROOT/tools/k4-env.local.sh" ]; then
    . "$ROOT/tools/k4-env.local.sh"
fi
: "${K4_HOST:?需要 K4_HOST —— cp tools/k4-env.example.sh tools/k4-env.local.sh 并填设备地址}"
K4_PORT="${K4_PORT:-2222}"

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
