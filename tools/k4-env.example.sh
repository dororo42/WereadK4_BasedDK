# k4-env.example.sh — 设备地址模板（复制为 tools/k4-env.local.sh 后填真值）
#
# 为什么这样设计：设备地址属于本机部署环境，不随仓库发布（仓库是 public）。
# tools/k4-env.local.sh 已在 .gitignore 内；也可以只用环境变量，不建这个文件。
#
#   cp tools/k4-env.example.sh tools/k4-env.local.sh   # 然后填 K4_HOST
#   或： K4_HOST=root@<设备地址> tools/deploy-weread.sh
#
# deploy-k4.sh / deploy-weread.sh 的查找顺序：环境变量 > tools/k4-env.local.sh > 报错退出。

# SSH 目标，含用户名（Kindle 越狱后 usbnet 固定为 root）
K4_HOST="${K4_HOST:-root@<设备地址>}"

# usbnet SSH 端口，Kindle 侧固定 2222，一般不用改
K4_PORT="${K4_PORT:-2222}"
