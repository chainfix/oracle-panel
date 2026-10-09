#!/usr/bin/env bash
# 从本机把仓库推到远程服务器，再执行服务器本地安装器 install.sh
# 用法: ./deploy.sh user@host [port]
# 示例: ./deploy.sh root@1.2.3.4 5887
set -euo pipefail

REMOTE="${1:?请指定服务器，如 ./deploy.sh root@1.2.3.4}"
PORT="${2:-5887}"
PANEL_DIR=/opt/oci-panel
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$SRC_DIR/install.sh" || ! -f "$SRC_DIR/app.py" ]]; then
    echo "请在仓库根目录执行: ./deploy.sh user@host [port]" >&2
    exit 1
fi

echo "=== 1. 同步文件到 $REMOTE:$PANEL_DIR ==="
ssh "$REMOTE" "mkdir -p $PANEL_DIR/templates $PANEL_DIR/tasks"
scp \
    "$SRC_DIR/app.py" \
    "$SRC_DIR/snipe.sh" \
    "$SRC_DIR/requirements.txt" \
    "$SRC_DIR/panel.conf.example" \
    "$SRC_DIR/install.sh" \
    "$SRC_DIR/deploy.sh" \
    "$REMOTE:$PANEL_DIR/"
scp "$SRC_DIR/templates/index.html" "$REMOTE:$PANEL_DIR/templates/"
ssh "$REMOTE" "chmod +x $PANEL_DIR/install.sh $PANEL_DIR/deploy.sh $PANEL_DIR/snipe.sh"

echo "=== 2. 远端执行 install.sh ==="
ssh -t "$REMOTE" "bash $PANEL_DIR/install.sh $PORT"
echo "远端部署完成: http://<服务器IP>:${PORT}/"
