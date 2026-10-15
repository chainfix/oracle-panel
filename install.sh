#!/usr/bin/env bash
# 在目标服务器上安装 OCI ARM 抢机面板（systemd）
# 用法:
#   sudo ./install.sh [port]
#   curl -fsSL https://raw.githubusercontent.com/chainfix/oracle-panel/main/install.sh | sudo bash
set -euo pipefail

PORT="${1:-5887}"
PANEL_DIR=/opt/oci-panel
SERVICE=oci-panel
REPO_URL="${OCI_PANEL_REPO:-https://github.com/chainfix/oracle-panel.git}"
RUN_USER=oci-panel

if [[ "$(id -u)" -ne 0 ]]; then
    echo "请用 root 运行: sudo $0 ${PORT}" >&2
    exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
    echo "端口无效: $PORT" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
need_clone=0
if [[ ! -f "$SRC_DIR/app.py" || ! -f "$SRC_DIR/snipe.sh" || ! -f "$SRC_DIR/requirements.txt" ]]; then
    need_clone=1
fi

echo "=== 1. 系统依赖 ==="
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y python3 python3-venv python3-pip curl git openssh-client
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3 python3-pip git curl openssh-clients
elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 python3-pip git curl openssh-clients
else
    echo "当前系统没有 apt/dnf/yum，请先手动安装 python3、venv、pip、git、curl" >&2
    exit 1
fi

PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
python3 - <<'PY'
import sys
if sys.version_info < (3, 9):
    raise SystemExit("需要 Python 3.9+，当前: %s" % sys.version.split()[0])
PY

echo "=== 2. 安装文件到 $PANEL_DIR ==="
mkdir -p "$PANEL_DIR/templates" "$PANEL_DIR/tasks"
if [[ "$need_clone" -eq 1 ]]; then
    tmp="$(mktemp -d)"
    git clone --depth 1 "$REPO_URL" "$tmp/src"
    SRC_DIR="$tmp/src"
fi
install -m 644 "$SRC_DIR/app.py" "$PANEL_DIR/app.py"
install -m 644 "$SRC_DIR/templates/index.html" "$PANEL_DIR/templates/index.html"
install -m 644 "$SRC_DIR/templates/login.html" "$PANEL_DIR/templates/login.html"
install -m 755 "$SRC_DIR/snipe.sh" "$PANEL_DIR/snipe.sh"
install -m 644 "$SRC_DIR/requirements.txt" "$PANEL_DIR/requirements.txt"
install -m 644 "$SRC_DIR/panel.conf.example" "$PANEL_DIR/panel.conf.example"
install -m 755 "$SRC_DIR/install.sh" "$PANEL_DIR/install.sh" 2>/dev/null || install -m 755 "$0" "$PANEL_DIR/install.sh"
if [[ -f "$SRC_DIR/deploy.sh" ]]; then
    install -m 755 "$SRC_DIR/deploy.sh" "$PANEL_DIR/deploy.sh"
fi
if [[ "$need_clone" -eq 1 ]]; then
    rm -rf "$tmp"
fi

if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$PANEL_DIR" --shell /usr/sbin/nologin "$RUN_USER"
fi

echo "=== 3. Python 依赖（含 oci-cli） ==="
if [[ ! -x "$PANEL_DIR/venv/bin/python" ]]; then
    python3 -m venv "$PANEL_DIR/venv"
fi
"$PANEL_DIR/venv/bin/pip" install -U pip
"$PANEL_DIR/venv/bin/pip" install -r "$PANEL_DIR/requirements.txt"
"$PANEL_DIR/venv/bin/pip" install oci-cli
test -x "$PANEL_DIR/venv/bin/oci"

umask 077
# ---- 面板登录密码 ----
# 重装时沿用已有密码；想指定密码用 PANEL_PASSWORD 环境变量；否则随机生成并打印
EXIST_HASH="$(grep -E '^panel_password_sha256=' "$PANEL_DIR/panel.conf" 2>/dev/null | cut -d= -f2- || true)"
if [[ -n "${PANEL_PASSWORD:-}" ]]; then
    PANEL_PW="$PANEL_PASSWORD"
elif [[ -n "$EXIST_HASH" ]]; then
    PANEL_PW="(沿用已有密码)"
else
    PANEL_PW="$(python3 -c 'import secrets; a="abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"; print("".join(secrets.choice(a) for _ in range(20)))')"
fi
if [[ "$PANEL_PW" != "(沿用已有密码)" ]]; then
    PANEL_HASH="$(PANEL_PW="$PANEL_PW" python3 -c 'import hashlib,os; print(hashlib.sha256(os.environ["PANEL_PW"].encode()).hexdigest())')"
else
    PANEL_HASH="$EXIST_HASH"
fi
cat > "$PANEL_DIR/panel.conf" <<EOF
# OCI 抢机面板配置
port=$PORT
# 面板登录密码的 SHA256（必填，否则无法登录）
# 改密码：PANEL_PASSWORD=新密码 sudo -E ./install.sh，或手动改这一行后 systemctl restart oci-panel
panel_password_sha256=$PANEL_HASH
EOF
chmod 600 "$PANEL_DIR/panel.conf"
chown -R "$RUN_USER:$RUN_USER" "$PANEL_DIR"

echo "=== 4. systemd 服务 ==="
cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=OCI ARM Sniper Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
WorkingDirectory=$PANEL_DIR
Environment=PATH=$PANEL_DIR/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LANG=C.UTF-8
ExecStart=$PANEL_DIR/venv/bin/python $PANEL_DIR/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
sleep 2

echo "=== 5. 验证 ==="
if ! systemctl is-active --quiet "$SERVICE"; then
    echo "服务未启动，journalctl:" >&2
    journalctl -u "$SERVICE" -n 40 --no-pager >&2 || true
    exit 1
fi
# 未登录时首页 302 跳转到 /login 即为正常
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}/" || true)"
login_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}/login" || true)"
if [[ "$code" != "302" || "$login_code" != "200" ]]; then
    echo "本机 HTTP 状态异常: /=${code:-无响应} /login=${login_code:-无响应}" >&2
    journalctl -u "$SERVICE" -n 40 --no-pager >&2 || true
    exit 1
fi
echo "部署完成: http://<服务器IP>:${PORT}/"
echo "面板登录密码: ${PANEL_PW}"
echo "（密码只显示这一次，请收好发给使用者；改密码：PANEL_PASSWORD=新密码 sudo -E ./install.sh）"
echo "当前以用户 ${RUN_USER} 运行。"
echo "Python ${PYVER} / oci-cli: $("$PANEL_DIR/venv/bin/oci" --version 2>/dev/null | head -1)"
