#!/usr/bin/env bash
# 部署 OCI ARM 抢机面板到远程服务器
# 用法: ./deploy.sh [user@host] [port]
# 示例: ./deploy.sh root@1.2.3.4 5887
set -e

REMOTE="${1:?请指定服务器，如 ./deploy.sh root@1.2.3.4}"
PORT="${2:-5887}"
PANEL_DIR=/opt/oci-panel
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== 1. 传文件到 $REMOTE ==="
ssh "$REMOTE" "mkdir -p $PANEL_DIR/templates $PANEL_DIR/tasks"
scp "$SRC_DIR/app.py" "$REMOTE:$PANEL_DIR/"
scp "$SRC_DIR/templates/index.html" "$REMOTE:$PANEL_DIR/templates/"
scp "$SRC_DIR/snipe.sh" "$REMOTE:$PANEL_DIR/"
scp "$SRC_DIR/requirements.txt" "$REMOTE:$PANEL_DIR/"
ssh "$REMOTE" "chmod +x $PANEL_DIR/snipe.sh"

echo "=== 2. Python 依赖 ==="
ssh "$REMOTE" "$PANEL_DIR/venv/bin/python -V 2>/dev/null || python3 -m venv $PANEL_DIR/venv"
ssh "$REMOTE" "$PANEL_DIR/venv/bin/pip install -q -r $PANEL_DIR/requirements.txt 2>&1 | tail -1"

echo "=== 3. 面板配置 ==="
ssh "$REMOTE" "cat > $PANEL_DIR/panel.conf <<EOF
# OCI 抢机面板配置
port=$PORT
EOF
chmod 600 $PANEL_DIR/panel.conf"

echo "=== 4. systemd 服务 ==="
ssh "$REMOTE" "cat > /etc/systemd/system/oci-panel.service <<EOF
[Unit]
Description=OCI ARM Sniper Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=$PANEL_DIR
ExecStart=$PANEL_DIR/venv/bin/python $PANEL_DIR/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable oci-panel
systemctl restart oci-panel
sleep 3
systemctl is-active oci-panel"

echo "=== 5. 验证 ==="
ssh "$REMOTE" "curl -s -o /dev/null -w '本机 HTTP 状态: %{http_code}\n' http://127.0.0.1:$PORT/ --max-time 10"
echo "部署完成"
