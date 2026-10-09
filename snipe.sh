#!/usr/bin/env bash
# ============================================================================
# Oracle Cloud 免费 ARM (Ampere A1 Flex) 自动抢机脚本 —— 交互式
#
# 原理: 免费 ARM 配额常年"无容量", 脚本循环调用创建实例 API, 抢到为止。
# 免费额度: VM.Standard.A1.Flex 最多 4 OCPU / 24GB 内存, 启动卷合计 200GB。
#
# 用法:
#   ./snipe.sh            # 交互式, 按提示填 OCI 凭证与配置
#   OCI_SNIPER_AUTO=1 ./snipe.sh   # 非交互(用已保存配置 + 环境变量覆盖)
#
# 配置保存在 ~/.oci/sniper.conf, 下次运行直接回车沿用上次的值。
# 建议在 tmux 里跑, 断开 SSH 也继续:  tmux new -s oci  →  ./snipe.sh
# 日志: ~/oci-arm-sniper.log   成功后实例信息: ~/oci-arm-instance.txt
# ============================================================================
set -u

OCI_DIR="$HOME/.oci"
OCI_CONFIG="$OCI_DIR/config"
CONF="$OCI_DIR/sniper.conf"
LOG="$HOME/oci-arm-sniper.log"
SUMMARY="$HOME/oci-arm-instance.txt"
SHAPE="VM.Standard.A1.Flex"

say()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
ok()   { echo -e "[$(date '+%F %T')] \033[32m✔ $*\033[0m" | tee -a "$LOG"; }
warn() { echo -e "[$(date '+%F %T')] \033[33m! $*\033[0m" | tee -a "$LOG"; }
err()  { echo -e "[$(date '+%F %T')] \033[31m✘ $*\033[0m" | tee -a "$LOG"; }

trap 'err "用户中断, 退出"; exit 130' INT

# 保存已填配置 (增量保存, 中断后重跑不用从头填)
save_conf() {
    {
        echo "# 更新于 $(date '+%F %T')"
        for v in TENANCY USER_OCID FINGERPRINT REGION KEY_FILE COMPARTMENT AD SUBNET \
                 IMAGE NAME OCPUS MEM BOOT_GB PUBKEY INTERVAL MAX_ATTEMPTS SPEC_CHO \
                 SSH_PASSWORD SSH_USER AD_CHO NET_CHO OS_CHO; do
            eval "val=\${$v:-}"
            [ -n "$val" ] && printf '%s=%q\n' "$v" "$val"
        done
    } > "$CONF"
    chmod 600 "$CONF"
}

# 给建网阶段的 API 调用加 120 秒超时, 避免无限卡住
ocit() { timeout 120 oci "$@"; }

# 用 python3 解析 JSON 列表, 每行一个值 (oci --raw-output 对列表的格式不可靠)
json_lines() { python3 -c 'import json,sys; [print(x) for x in json.load(sys.stdin)]'; }

# 去掉终端串入的转义序列 (某些终端会把 ^[[?6c 这类设备属性应答送进输入流,
# 导致 read 误以为用户输入了内容而不使用默认值)
strip_esc() { printf '%s' "$1" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][0-9A-B]//g'; }

# ---------- 交互式提问 ----------
ask() { # ask <变量名> <提示> [默认值]
    local var="$1" prompt="$2" def="${3-}" cur ans
    eval "cur=\${$var:-}"
    [ -n "$cur" ] && def="$cur"
    if [ -n "${OCI_SNIPER_AUTO:-}" ]; then
        printf -v "$var" '%s' "$def"
        return
    fi
    if [ -n "$def" ]; then
        read -rp "$prompt [$def]: " ans
        ans=$(strip_esc "$ans")
        ans="${ans:-$def}"
    else
        read -rp "$prompt: " ans
        ans=$(strip_esc "$ans")
    fi
    printf -v "$var" '%s' "$ans"
}

valid_ocid() { [[ "$1" =~ ^ocid1\.[a-z0-9_-]+\.oc[0-9]*\..+ ]]; }
valid_fp()   { [[ "$1" =~ ^([0-9a-fA-F]{2}:){15}[0-9a-fA-F]{2}$ ]]; }

ask_ocid() { # ask_ocid <变量名> <提示> [默认值]
    local var="$1" prompt="$2" def="${3-}" v raw extra line
    # 记住初始默认值, 失败时恢复(而不是清空, 避免用户被迫重输)
    if [ -n "${!var:-}" ]; then def="${!var}"; fi
    while true; do
        ask "$var" "$prompt" "$def"
        eval "raw=\$$var"
        # 排干粘贴残留: 从终端粘贴的 OCID 若被折成多行, 第一行之后的内容会留在输入缓冲里;
        # 不排掉的话它会污染下一个提示, 且当前行可能是被截断的值
        extra=""
        while read -t 0.3 -r line 2>/dev/null; do
            extra="${extra}${line}"
        done
        if [ -n "$extra" ]; then
            err "检测到粘贴的内容被换行截断了, 请直接回车使用默认值, 或复制完整单行 OCID 后重试"
            printf -v "$var" '%s' "$def"
            continue
        fi
        # 去掉回车/空格等多余空白
        v=$(printf '%s' "$raw" | tr -d '[:space:]')
        [ "$v" != "$raw" ] && warn "输入中包含多余空白, 已自动去除"
        printf -v "$var" '%s' "$v"
        if valid_ocid "$v"; then break; fi
        err "格式不对, OCID 应以 ocid1. 开头, 请重新输入"
        printf -v "$var" '%s' "$def"
    done
}

# ---------- 1. 检查 / 安装 oci-cli ----------
# 面板部署时 oci-cli 已在 venv；这里只在交互单独运行且 PATH 里没有 oci 时才尝试安装
if ! command -v oci >/dev/null 2>&1; then
    warn "未找到 oci 命令, 尝试自动安装 oci-cli ..."
    if [ -n "${VIRTUAL_ENV:-}" ] && [ -x "${VIRTUAL_ENV}/bin/pip" ]; then
        "${VIRTUAL_ENV}/bin/pip" install -q oci-cli \
            || { err "venv 安装 oci-cli 失败: ${VIRTUAL_ENV}/bin/pip install oci-cli"; exit 1; }
        PATH="${VIRTUAL_ENV}/bin:$PATH"
        export PATH
    else
        if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-pip \
                || { err "apt 安装 python3-pip 失败, 请手动安装后重试"; exit 1; }
        fi
        pip3 install --break-system-packages -q oci-cli \
            || { err "oci-cli 安装失败, 请手动执行: pip3 install --break-system-packages oci-cli"; exit 1; }
    fi
    ok "oci-cli 安装完成: $(oci --version 2>/dev/null)"
else
    say "oci-cli: $(oci --version 2>/dev/null)"
fi
mkdir -p "$OCI_DIR"

# ---------- 2. 读取上次配置 ----------
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    source "$CONF"
    say "已载入上次配置 $CONF (直接回车即沿用)"
fi

# 已有 oci config 则用它的值做默认值, 凭证不用重复输入
if [ -f "$OCI_CONFIG" ]; then
    cfg_val() { grep -E "^$1=" "$OCI_CONFIG" | head -1 | cut -d= -f2-; }
    [ -z "${TENANCY:-}" ] && TENANCY=$(cfg_val tenancy)
    [ -z "${USER_OCID:-}" ] && USER_OCID=$(cfg_val user)
    [ -z "${FINGERPRINT:-}" ] && FINGERPRINT=$(cfg_val fingerprint)
    [ -z "${REGION:-}" ] && REGION=$(cfg_val region)
    [ -z "${KEY_FILE:-}" ] && KEY_FILE=$(cfg_val key_file)
    [ -n "${TENANCY:-}" ] && say "检测到已有 API 配置, 凭证段直接回车即可沿用"
fi

# ---------- 3. OCI API 凭证 ----------
echo
echo "=== 1/8 OCI API 凭证 (在 OCI 控制台 → 右上角人像 → API 密钥 里获取) ==="
if valid_ocid "${TENANCY:-}" && valid_ocid "${USER_OCID:-}" && valid_fp "${FINGERPRINT:-}"; then
    say "使用已保存的 API 配置 (如需修改, 请删除 $OCI_CONFIG 后重跑)"
else
    ask_ocid TENANCY "Tenancy OCID (ocid1.tenancy.oc1..)"
    ask_ocid USER_OCID "User OCID (ocid1.user.oc1..)"
    while true; do
        ask FINGERPRINT "API 密钥指纹 (aa:bb:cc:... 共 16 组)"
        if valid_fp "$FINGERPRINT"; then break; fi
        err "指纹格式不对, 应为 16 组十六进制, 以冒号分隔"
        FINGERPRINT=""
    done
fi

if [ -n "${OCI_SNIPER_AUTO:-}" ] && [ -n "${REGION:-}" ]; then
    say "目标区域: $REGION (配置指定)"
else
echo
echo "目标区域 (免费 ARM 各区域都经常无货, 可多试几个):"
echo "  1) ap-tokyo-1    东京"
echo "  2) ap-osaka-1    大阪"
echo "  3) ap-singapore-1 新加坡"
echo "  4) ap-seoul-1    首尔"
echo "  5) ap-mumbai-1   孟买"
echo "  6) us-ashburn-1  美东 Ashburn"
echo "  7) us-phoenix-1  美西 凤凰城"
echo "  8) eu-frankfurt-1 法兰克福"
echo "  9) 手动输入"
REGION_DEF="1"
case "${REGION:-}" in
    ap-tokyo-1) REGION_DEF=1;; ap-osaka-1) REGION_DEF=2;;
    ap-singapore-1) REGION_DEF=3;; ap-seoul-1) REGION_DEF=4;;
    ap-mumbai-1) REGION_DEF=5;; us-ashburn-1) REGION_DEF=6;;
    us-phoenix-1) REGION_DEF=7;; eu-frankfurt-1) REGION_DEF=8;;
esac
ask REGION_CHO "选择" "$REGION_DEF"
case "$REGION_CHO" in
    1) REGION="ap-tokyo-1";; 2) REGION="ap-osaka-1";; 3) REGION="ap-singapore-1";;
    4) REGION="ap-seoul-1";; 5) REGION="ap-mumbai-1";; 6) REGION="us-ashburn-1";;
    7) REGION="us-phoenix-1";; 8) REGION="eu-frankfurt-1";;
    *) ask REGION "输入区域代码 (如 ap-tokyo-1)" ;;
esac
fi

KEY_FILE="${KEY_FILE:-$OCI_DIR/oci_api_key.pem}"
if [ ! -f "$KEY_FILE" ]; then
    echo
    echo "API 私钥文件不存在: $KEY_FILE"
    echo "  a) 输入本机已有的私钥路径  b) 直接粘贴私钥内容(空行后 Ctrl-D 结束)"
    ask KEY_CHO "选择 a/b" "a"
    if [ "$KEY_CHO" = "b" ]; then
        echo "请粘贴私钥 (-----BEGIN PRIVATE KEY----- ... ), 结束后空行 Ctrl-D:"
        cat > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    else
        ask KEY_FILE "私钥文件路径" "$KEY_FILE"
        [ -f "$KEY_FILE" ] || { err "找不到私钥文件: $KEY_FILE"; exit 1; }
    fi
fi
chmod 600 "$KEY_FILE" 2>/dev/null || true

cat > "$OCI_CONFIG" <<EOF
[DEFAULT]
user=$USER_OCID
fingerprint=$FINGERPRINT
tenancy=$TENANCY
region=$REGION
key_file=$KEY_FILE
EOF
chmod 600 "$OCI_CONFIG"
ok "API 配置已写入 $OCI_CONFIG"
save_conf

# ---------- 4. 验证凭证 ----------
echo
say "验证 API 凭证与区域连通性 ..."
if ! oci iam availability-domain list --compartment-id "$TENANCY" --region "$REGION" \
        --query 'data[].name' --output json >/dev/null 2>"$OCI_DIR/.ad_err"; then
    err "API 调用失败, 请检查 Tenancy/User OCID、指纹、私钥是否匹配:"
    head -5 "$OCI_DIR/.ad_err"
    exit 1
fi
ok "凭证有效"

# ---------- 5. Compartment 与可用性域 ----------
echo
echo "=== 2/8 Compartment / 可用性域 ==="
ask_ocid COMPARTMENT "Compartment OCID (回车=用 Tenancy 根)" "$TENANCY"

mapfile -t ADS < <(oci iam availability-domain list --compartment-id "$TENANCY" \
    --region "$REGION" --query 'data[].name' --output json | json_lines)
[ "${#ADS[@]}" -gt 0 ] || { err "未取到可用性域列表"; exit 1; }
echo "可用性域:"
i=1; for ad in "${ADS[@]}"; do echo "  $i) $ad"; i=$((i+1)); done
ask AD_CHO "选择" "1"
if [[ "$AD_CHO" =~ ^[0-9]+$ ]] && [ "$AD_CHO" -ge 1 ] && [ "$AD_CHO" -le "${#ADS[@]}" ]; then
    AD="${ADS[$((AD_CHO-1))]}"
else
    AD="$AD_CHO"
fi
say "可用性域: $AD"

# ---------- 6. 网络 ----------
echo
echo "=== 3/8 网络 (VCN / 子网) ==="
echo "  1) 自动新建 VCN+子网 (推荐, 带公网网关, 放行 22 端口)"
echo "  2) 使用已有的子网 OCID"
ask NET_CHO "选择" "1"
if [ "$NET_CHO" = "2" ]; then
    ask_ocid SUBNET "子网 OCID (ocid1.subnet.oc1..)"
else
    say "创建 VCN ..."
    VCN_ID=$(ocit network vcn create --compartment-id "$COMPARTMENT" \
        --cidr-block "10.0.0.0/16" --display-name "sniper-vcn" --dns-label "snipervcn" \
        --region "$REGION" --query 'data.id' --raw-output \
        --wait-for-state AVAILABLE --max-wait-seconds 120) || VCN_ID=""
    [ -n "$VCN_ID" ] || { err "VCN 创建失败"; exit 1; }
    ok "VCN: $VCN_ID"

    IGW_ID=$(ocit network internet-gateway create --compartment-id "$COMPARTMENT" \
        --is-enabled true --vcn-id "$VCN_ID" --display-name "sniper-igw" \
        --region "$REGION" --query 'data.id' --raw-output)
    RT_ID=$(ocit network vcn get --vcn-id "$VCN_ID" --region "$REGION" \
        --query 'data."default-route-table-id"' --raw-output)
    ocit network route-table update --rt-id "$RT_ID" --region "$REGION" --force \
        --route-rules "[{\"cidrBlock\":\"0.0.0.0/0\",\"networkEntityId\":\"$IGW_ID\"}]" >/dev/null \
        || { err "路由表更新失败 (超过 120 秒无响应或 API 报错), 请检查网络后重跑"; exit 1; }

    SL_ID=$(ocit network security-list create --compartment-id "$COMPARTMENT" \
        --vcn-id "$VCN_ID" --display-name "sniper-sl" --region "$REGION" \
        --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all"}]' \
        --ingress-security-rules '[{"protocol":"6","source":"0.0.0.0/0","tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},{"protocol":"1","source":"0.0.0.0/0"}]' \
        --query 'data.id' --raw-output)
    [ -n "$SL_ID" ] || { err "安全列表创建失败"; exit 1; }

    SUBNET=$(ocit network subnet create --compartment-id "$COMPARTMENT" \
        --vcn-id "$VCN_ID" --cidr-block "10.0.1.0/24" --display-name "sniper-subnet" \
        --dns-label "snipersub" --security-list-ids "[\"$SL_ID\"]" --route-table-id "$RT_ID" \
        --prohibit-public-ip-on-vnic false --region "$REGION" \
        --query 'data.id' --raw-output --wait-for-state AVAILABLE --max-wait-seconds 120) || SUBNET=""
    [ -n "$SUBNET" ] || { err "子网创建失败"; exit 1; }
    ok "子网: $SUBNET"
fi

# ---------- 7. 镜像 ----------
if [ -n "${IMAGE:-}" ]; then
    say "镜像: $IMAGE (配置指定，跳过选择)"
else
echo
echo "=== 4/8 系统镜像 (ARM) ==="
echo "  1) Oracle Linux (默认)"
echo "  2) Canonical Ubuntu"
echo "  3) 全部列出"
ask OS_CHO "选择" "1"
case "$OS_CHO" in
    2) OS_FILTER="Canonical Ubuntu";; 3) OS_FILTER="";;
    *) OS_FILTER="Oracle Linux";;
esac

IMG_Q=(oci compute image list --compartment-id "$TENANCY" --shape "$SHAPE"
       --sort-by TIMECREATED --sort-order DESC --limit 12 --region "$REGION"
       --query 'data[].[id,"display-name","time-created"]' --output json)
[ -n "$OS_FILTER" ] && IMG_Q+=(--operating-system "$OS_FILTER")
mapfile -t IMG_LINES < <("${IMG_Q[@]}" | python3 -c 'import json,sys
for r in json.load(sys.stdin):
    print(r[0] + "\t" + r[1] + "\t" + str(r[2])[:10])')
[ "${#IMG_LINES[@]}" -gt 0 ] || { err "未找到兼容 $SHAPE 的镜像"; exit 1; }
echo "可选镜像 (按发布时间倒序):"
i=1
for line in "${IMG_LINES[@]}"; do
    iname=$(echo "$line" | cut -f2)
    itime=$(echo "$line" | cut -f3 | cut -c1-10)
    printf '  %2d) %s  [%s]\n' "$i" "$iname" "$itime"
    i=$((i+1))
done
echo "   0) 手动输入镜像 OCID"
ask IMG_CHO "选择" "1"
if [ "$IMG_CHO" = "0" ]; then
    ask_ocid IMAGE "镜像 OCID (ocid1.image.oc1..)"
    say "镜像: $IMAGE"
elif [[ "$IMG_CHO" =~ ^[0-9]+$ ]] && [ "$IMG_CHO" -ge 1 ] && [ "$IMG_CHO" -le "${#IMG_LINES[@]}" ]; then
    IMAGE=$(echo "${IMG_LINES[$((IMG_CHO-1))]}" | cut -f1)
    say "镜像: $(echo "${IMG_LINES[$((IMG_CHO-1))]}" | cut -f2)"
else
    err "无效选择"; exit 1
fi
fi # IMAGE 未指定时才走交互选择

# ---------- 8. 实例规格 ----------
echo
echo "=== 5/8 实例规格 (免费额度内: ≤4 OCPU, ≤24GB 内存) ==="
ask NAME "实例显示名" "oci-arm-1"
echo "实例规格 (免费额度内: 总计 ≤4 OCPU / ≤24GB 内存):"
if [ -n "${OCI_SNIPER_AUTO:-}" ] && [[ "${OCPUS:-}" =~ ^[1-4]$ ]] \
    && [[ "${MEM:-}" =~ ^[0-9]+$ ]] && [ "$MEM" -ge 1 ] && [ "$MEM" -le 24 ]; then
    say "规格: ${OCPUS} OCPU / ${MEM}GB 内存 (配置指定)"
else
echo "  1) 1 OCPU / 6GB 内存"
echo "  2) 2 OCPU / 12GB 内存"
echo "  3) 4 OCPU / 24GB 内存 (默认, 免费拉满)"
echo "  4) 自定义"
SPEC_DEF="3"
if [ "${OCPUS:-}" = "1" ] && [ "${MEM:-}" = "6" ]; then SPEC_DEF="1"
elif [ "${OCPUS:-}" = "2" ] && [ "${MEM:-}" = "12" ]; then SPEC_DEF="2"; fi
ask SPEC_CHO "选择" "$SPEC_DEF"
case "$SPEC_CHO" in
    1) OCPUS=1; MEM=6;;
    2) OCPUS=2; MEM=12;;
    3) OCPUS=4; MEM=24;;
    4) ask OCPUS "OCPU 数 (1-4)" "4"
       ask MEM "内存 GB (1-24)" "24";;
    *) err "无效选择"; exit 1;;
esac
say "规格: ${OCPUS} OCPU / ${MEM}GB 内存"
fi
ask BOOT_GB "启动卷 GB (50-200)" "50"

# ---------- SSH 登录方式: 密钥 (默认) 或密码 ----------
SSH_ARGS=()
if [ -n "${SSH_PASSWORD:-}" ]; then
    SSH_USER="${SSH_USER:-opc}"
    say "SSH 登录方式: 密码 (用户名 $SSH_USER)"
    # 用 cloud-init 在首次启动时设置密码并开启密码认证
    USERDATA="$OCI_DIR/user-data.yaml"
    {
        printf '#cloud-config\nssh_pwauth: true\nchpasswd:\n  list: |\n    %s:' "$SSH_USER"
        printf '%s\n' "$SSH_PASSWORD"
        printf '  expire: false\nruncmd:\n'
        printf '  - sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config 2>/dev/null || true\n'
        printf '  - sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true\n'
        printf '  - (systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null) || true\n'
    } > "$USERDATA"
    chmod 600 "$USERDATA"
    SSH_ARGS=(--user-data-file "$USERDATA")
else
PUBKEY="${PUBKEY:-$HOME/.ssh/id_rsa.pub}"
if [ ! -f "$PUBKEY" ]; then
    warn "未找到 SSH 公钥 $PUBKEY, 自动生成一对 ..."
    ssh-keygen -t ed25519 -f "${PUBKEY%.pub}" -N "" -q \
        || { err "密钥生成失败"; exit 1; }
fi
ok "SSH 公钥: $PUBKEY"
SSH_ARGS=(--ssh-authorized-keys-file "$PUBKEY")
fi
SHAPE_JSON=$(printf '{"ocpus":%d,"memoryInGBs":%d}' "$OCPUS" "$MEM")

# ---------- 9. 重试策略 ----------
echo
echo "=== 6/8 重试策略 ==="
ask INTERVAL "每次失败后等待秒数" "45"
ask MAX_ATTEMPTS "最大尝试次数 (0=无限, 直到抢到)" "0"

# ---------- 保存配置 ----------
save_conf

echo
echo "================ 抢机配置汇总 ================"
echo "区域:       $REGION"
echo "可用性域:   $AD"
echo "实例名:     $NAME"
echo "规格:       ${OCPUS} OCPU / ${MEM}GB 内存 / ${BOOT_GB}GB 启动卷"
echo "镜像:       $IMAGE"
echo "子网:       $SUBNET"
echo "重试间隔:   ${INTERVAL}s   最大尝试: $([ "$MAX_ATTEMPTS" = "0" ] && echo 无限 || echo "$MAX_ATTEMPTS")"
echo "=============================================="
if [ -z "${OCI_SNIPER_AUTO:-}" ]; then
    read -rp "确认开始抢机? [Y/n]: " go
    [[ "$go" =~ ^[Nn]$ ]] && { say "已取消"; exit 0; }
fi

# ---------- 10. 抢机循环 ----------
attempt=0
unknown_streak=0
start_ts=$(date +%s)
say "开始抢机, 日志: $LOG"

while true; do
    attempt=$((attempt+1))
    if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
        err "已达最大尝试次数 ($MAX_ATTEMPTS), 退出"
        exit 1
    fi
    elapsed=$(( $(date +%s) - start_ts ))
    say "第 $attempt 次尝试 (已运行 $((elapsed/60)) 分钟)..."

    out=$(mktemp)
    if oci compute instance launch \
            --region "$REGION" \
            --availability-domain "$AD" \
            --compartment-id "$COMPARTMENT" \
            --shape "$SHAPE" \
            --shape-config "$SHAPE_JSON" \
            --subnet-id "$SUBNET" \
            --image-id "$IMAGE" \
            --display-name "$NAME" \
            --assign-public-ip true \
            "${SSH_ARGS[@]}" \
            --boot-volume-size-in-gbs "$BOOT_GB" \
            --query 'data.id' --raw-output >"$out" 2>&1; then
        IID=$(cat "$out"); rm -f "$out"
        ok "抢机成功! 实例 OCID: $IID"
        unknown_streak=0

        say "等待实例进入 RUNNING 状态 ..."
        oci compute instance get --region "$REGION" --instance-id "$IID" \
            --wait-for-state RUNNING --max-wait-seconds 600 --interval-seconds 10 \
            >/dev/null 2>&1 || warn "等待超时, 请稍后在控制台确认状态"

        PUBIP=$(oci compute instance list-vnics --region "$REGION" --instance-id "$IID" \
            --query 'data[0]."public-ip"' --raw-output 2>/dev/null)
        PRIIP=$(oci compute instance list-vnics --region "$REGION" --instance-id "$IID" \
            --query 'data[0]."private-ip"' --raw-output 2>/dev/null)
        {
            echo "实例名:  $NAME"
            echo "OCID:    $IID"
            echo "区域:    $REGION"
            echo "公网 IP: $PUBIP"
            echo "内网 IP: $PRIIP"
            if [ -n "${SSH_PASSWORD:-}" ]; then
                echo "SSH:     ssh ${SSH_USER}@$PUBIP  (密码登录, 用户名 ${SSH_USER})"
                echo "登录方式: 密码"
            else
                echo "SSH:     ssh -i <你的私钥> opc@$PUBIP   (Ubuntu 镜像用户名为 ubuntu)"
                echo "登录方式: 密钥"
            fi
        } | tee "$SUMMARY"
        ok "实例信息已保存到 $SUMMARY, 祝使用愉快!"
        exit 0
    fi

    errmsg=$(cat "$out"); rm -f "$out"
    low=$(printf '%s' "$errmsg" | tr 'A-Z' 'a-z')

    # 无容量 / 临时性错误 → 继续重试
    if [[ "$low" == *"out of capacity"* || "$low" == *"capacity"* || \
          "$low" == *"internalerror"* || "$low" == *"internal error"* || \
          "$low" == *"too many requests"* || "$low" == *"timeout"* || \
          "$low" == *"temporarily"* || "$low" == *" 500"* || "$low" == *" 502"* || \
          "$low" == *" 503"* || "$low" == *" 504"* ]]; then
        warn "无可用容量/服务端繁忙, ${INTERVAL}s 后重试"
        unknown_streak=0
        sleep "$INTERVAL"
        continue
    fi

    # 认证 / 参数错误 → 直接退出, 避免空转
    if [[ "$low" == *" 401"* || "$low" == *"notauthenticated"* || \
          "$low" == *"notauthorized"* || "$low" == *"authorization failed"* || \
          "$low" == *"invalidparameter"* || "$low" == *"invalid parameter"* || \
          "$low" == *" 400"* ]]; then
        err "请求被拒绝 (认证或参数错误), 停止重试:"
        printf '%s\n' "$errmsg" | head -12 | tee -a "$LOG"
        err "请检查: 1) API 密钥指纹与私钥是否匹配  2) OCID 是否正确  3) 区域/镜像/子网是否有效"
        exit 1
    fi

    # 未知错误 → 有限重试
    unknown_streak=$((unknown_streak+1))
    warn "未知错误 (连续 $unknown_streak 次), 60s 后重试:"
    printf '%s\n' "$errmsg" | head -8 | tee -a "$LOG"
    if [ "$unknown_streak" -ge 5 ]; then
        err "连续 5 次未知错误, 退出"; exit 1
    fi
    sleep 60
done
