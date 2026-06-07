#!/usr/bin/env bash
# ============================================================
# Oracle Cloud ARM 实例抢购脚本
# 不停重试创建 Ampere A1 实例，直到成功
# 依赖: oci CLI (pip install oci-cli)
# 用法:
#   chmod +x oci-arm-snatch.sh
#   ./oci-arm-snatch.sh
# ============================================================

set -euo pipefail

# ====== 配置区 (按需修改) ======
COMPARTMENT_ID=""            # 你的 Compartment OCID
AVAILABILITY_DOMAIN=""       # 留空自动检测，或指定 "AD-1"/"AD-2"/"AD-3"
SHAPE="VM.Standard.A1.Flex"  # ARM 实例规格
OCPUS=4                      # CPU 核心数 (免费最多 4)
MEMORY_GB=24                 # 内存 (免费最多 24G)
SSH_KEY=""                   # 可选: 你的公钥路径，如 ~/.ssh/id_rsa.pub
IMAGE_SOURCE_ID=""           # 留空自动选最新 Canonical Ubuntu 22.04 ARM
SUBNET_ID=""                 # 子网 OCID (必填)
RETRY_INTERVAL=30            # 重试间隔 (秒)
MAX_RETRIES=999              # 最大重试次数 (默认一直跑)
NOTIFY_CMD=""                # 成功通知命令, 如 "osascript -e 'display notification...'"
# ==============================

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}" >&2; }

# 检查依赖
check_deps() {
    if ! command -v oci &>/dev/null; then
        err "oci CLI 未安装！请先安装: pip install oci-cli"
        exit 1
    fi
    if ! oci iam region list &>/dev/null; then
        err "oci CLI 未配置！请先运行: oci setup config"
        exit 1
    fi
}

# 自动补全配置
auto_config() {
    [[ -z "$COMPARTMENT_ID" ]] && COMPARTMENT_ID=$(oci iam compartment list --all 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for c in data.get('data', []):
    if c['lifecycle-state']=='ACTIVE':
        print(c['id'])
        break
")
    [[ -n "$COMPARTMENT_ID" ]] && ok "Compartment: $COMPARTMENT_ID"

    # 自动检测可用域
    if [[ -z "$AVAILABILITY_DOMAIN" ]]; then
        AD_LIST=$(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for ad in data.get('data', []):
    print(ad['name'])
" 2>/dev/null || echo "")
        if [[ -n "$AD_LIST" ]]; then
            # 尝试每个 AD，选第一个能用的
            AVAILABILITY_DOMAIN=$(echo "$AD_LIST" | head -1)
            ok "可用域: $AVAILABILITY_DOMAIN"
        else
            warn "无法检测可用域，请手动设置 AVAILABILITY_DOMAIN"
        fi
    fi

    # 自动选 Ubuntu 22.04 ARM 镜像
    if [[ -z "$IMAGE_SOURCE_ID" ]]; then
        IMAGE_SOURCE_ID=$(oci compute image list \
            --compartment-id "$COMPARTMENT_ID" \
            --shape "$SHAPE" \
            --operating-system "Canonical Ubuntu" \
            --operating-system-version "22" \
            --sort-by TIMECREATED 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for img in data.get('data', []):
    if 'aarch64' in (img.get('display-name','').lower()) or 'arm' in (img.get('display-name','').lower()) or 'minimal' in (img.get('display-name','').lower()):
        print(img['id'])
        break
else:
    if data.get('data'):
        print(data['data'][0]['id'])
" 2>/dev/null || echo "")
        [[ -n "$IMAGE_SOURCE_ID" ]] && ok "镜像: ${IMAGE_SOURCE_ID:0:20}..."
    fi

    # 检查必填项
    local missing=()
    [[ -z "$COMPARTMENT_ID" ]] && missing+=("COMPARTMENT_ID")
    [[ -z "$SUBNET_ID" ]]      && missing+=("SUBNET_ID (子网 OCID)")
    [[ -z "$IMAGE_SOURCE_ID" ]] && missing+=("IMAGE_SOURCE_ID")
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "缺少必要配置: ${missing[*]}"
        echo ""
        echo "请先获取子网 OCID:"
        echo "  oci network subnet list --compartment-id <你的compartment>"
        echo ""
        echo "然后把 SUBNET_ID 填到脚本配置区"
        exit 1
    fi
}

# 构建创建实例命令
build_cmd() {
    local cmd="oci compute instance launch"
    cmd+=" --compartment-id \"$COMPARTMENT_ID\""
    cmd+=" --shape \"$SHAPE\""
    cmd+=" --shape-config \"{\\\"ocpus\\\":\\\"$OCPUS\\\",\\\"memory-in-gbs\\\":\\\"$MEMORY_GB\\\"}\""
    cmd+=" --availability-domain \"$AVAILABILITY_DOMAIN\""
    cmd+=" --subnet-id \"$SUBNET_ID\""
    cmd+=" --image-id \"$IMAGE_SOURCE_ID\""
    cmd+=" --assign-public-ip true"
    cmd+=" --display-name \"arm-snatcher-$(date +%m%d-%H%M%S)\""

    if [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]]; then
        cmd+=" --ssh-authorized-keys-file \"$SSH_KEY\""
    fi

    echo "$cmd"
}

# 检查当前容量状态
check_capacity() {
    local ad="$1"
    oci limits resource-availability get \
        --compartment-id "$COMPARTMENT_ID" \
        --service-name "core" \
        --limit-name "standard-a1-core-count" \
        --availability-domain "$ad" 2>/dev/null | python3 -c "
import json,sys
try:
    data=json.load(sys.stdin).get('data',{})
    avail = data.get('available', 0)
    max_val = data.get('max', 0)
    print(f'{avail}/{max_val}')
except:
    print('unknown')
" 2>/dev/null || echo "unknown"
}

# 主循环
main() {
    echo ""
    echo "=========================================="
    echo "  Oracle Cloud ARM 抢购机器人 🤖"
    echo "  规格: $OCPUS 核 / $MEMORY_GB GB"
    echo "  重试间隔: ${RETRY_INTERVAL}s"
    echo "=========================================="
    echo ""

    local attempt=0

    while true; do
        attempt=$((attempt + 1))

        # 容量检查
        local cap
        cap=$(check_capacity "$AVAILABILITY_DOMAIN")
        log "[$attempt/$MAX_RETRIES] 可用容量: ${cap} 核  | AD: $AVAILABILITY_DOMAIN"

        if [[ "$cap" =~ ^[0-9] ]] && [[ "${cap%/*}" -lt "$OCPUS" ]]; then
            warn "容量不足 (需要 $OCPUS 核, 可用 $cap)，${RETRY_INTERVAL}s 后重试..."
            sleep "$RETRY_INTERVAL"
            continue
        fi

        # 尝试创建
        log "尝试创建实例..."
        local cmd
        cmd=$(build_cmd)

        local output
        output=$(eval "$cmd" 2>&1) || true

        if echo "$output" | grep -q "Out of capacity\|LimitExceeded\|InsufficientCapacity\|400\|429\|500\|503"; then
            warn "创建失败，容量不足 (${attempt}次)，${RETRY_INTERVAL}s 后重试..."
            sleep "$RETRY_INTERVAL"
            continue
        fi

        if echo "$output" | grep -q "etag\|display-name\|lifecycle-state"; then
            ok "🎉 实例创建成功！"
            local inst_id
            inst_id=$(echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data'].get('id','unknown'))" 2>/dev/null || echo "unknown")
            echo ""
            echo "  ID:     $inst_id"
            echo "  规格:   $SHAPE ($OCPUS 核 / $MEMORY_GB GB)"
            echo "  区域:   $AVAILABILITY_DOMAIN"
            echo ""
            echo "查看详情: oci compute instance get --instance-id \"$inst_id\""

            # 通知
            if [[ -n "$NOTIFY_CMD" ]]; then
                eval "$NOTIFY_CMD" 2>/dev/null || true
            fi

            break
        fi

        # 其他错误
        err "未知错误: $(echo "$output" | head -3)"
        warn "${RETRY_INTERVAL}s 后重试..."
        sleep "$RETRY_INTERVAL"
    done
}

# ---- 执行 ----
check_deps
auto_config
main "$@"
