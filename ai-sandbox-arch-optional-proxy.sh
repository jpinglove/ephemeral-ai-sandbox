#!/usr/bin/env bash
# ==============================================================================
# AI Temporary SSH Sandbox Launcher (Arch Linux Environment)
# AI 临时 SSH 沙盒启动脚本（基于 Arch Linux 容器环境）
#
# ------------------------------------------------------------------------------
# [EN] USAGE INSTRUCTIONS:
# This script creates an ephemeral, isolated Arch Linux Docker sandbox.
# It supports both Direct Connection and Proxy Mode, strictly controlled by PROXY_URL.
# If PROXY_URL is empty, proxy env vars are forcefully cleared (even if system/docker proxies exist).
#
# Mode 1: Direct Mode (No Proxy)
#   Method 1a: sudo env PROXY_URL= bash ai-sandbox-arch-optional-proxy.sh
#   Method 1b: Set PROXY_URL="" inside this script, then: sudo bash ai-sandbox-arch-optional-proxy.sh
#
# Mode 2: Proxy Mode
#   Method 2a: sudo env PROXY_URL=http://192.168.200.1:10810 bash ai-sandbox-arch-optional-proxy.sh
#   Method 2b: Set PROXY_URL="http://192.168.200.1:10810" inside this script, then: sudo bash ai-sandbox-arch-optional-proxy.sh
#
# Custom duration & port:
#   sudo env DURATION_SECONDS=3600 SSH_PORT=2223 bash ai-sandbox-arch-optional-proxy.sh
#
# ------------------------------------------------------------------------------
# [ZH] 使用说明：
# 本脚本在宿主机上构建并运行一个带有时效限制的 Arch Linux 隔离 SSH 沙盒环境。
# 支持“直连模式”与“代理模式”，通过 PROXY_URL 严格判定。
# 当 PROXY_URL 为空时，无论系统环境变量或 Docker 配置是否有代理，均强制清空走直连。
#
# 模式一：直连模式（不走代理）
#   方式 1a（命令行覆盖）:
#     sudo env PROXY_URL= bash ai-sandbox-arch-optional-proxy.sh
#   方式 1b（修改脚本内变量）:
#     将脚本下方 PROXY_URL 默认值留空：PROXY_URL="${PROXY_URL:-}"
#     然后执行: sudo bash ai-sandbox-arch-optional-proxy.sh
#
# 模式二：代理模式（指定代理）
#   方式 2a（命令行指定）:
#     sudo env PROXY_URL=http://192.168.200.1:10810 bash ai-sandbox-arch-optional-proxy.sh
#   方式 2b（修改脚本内变量）:
#     修改下方 PROXY_URL 默认值，例如：PROXY_URL="${PROXY_URL:-http://192.168.200.1:10810}"
#     然后执行: sudo bash ai-sandbox-arch-optional-proxy.sh
#
# 自定义端口与时长：
#   sudo env DURATION_SECONDS=3600 SSH_PORT=2223 bash ai-sandbox-arch-optional-proxy.sh
#
#
#
# 停止所有正在运行的容器
#	sudo docker stop $(sudo docker ps -aq) 2>/dev/null || true
#
# 一键清理所有 docker 容器和镜像
#	sudo docker system prune -a --volumes -f
# ==============================================================================

set -Eeuo pipefail
umask 077

# ==================== 核心配置变量 (Core Configurations) ====================
DURATION_SECONDS="${DURATION_SECONDS:-7200}"                # 默认运行时长：2小时 (7200秒)
SSH_PORT="${SSH_PORT:-2222}"                                # 映射到主机的 SSH 端口
PROXY_URL="${PROXY_URL:-}"
#PROXY_URL="${PROXY_URL:-http://192.168.200.1:10810}"        # 默认代理配置，留空即为默认直连
BASE_IMAGE="${BASE_IMAGE:-archlinux:latest}"
STAMP="$(date +%s)-$$"
CONTAINER_NAME="ai-sandbox-${STAMP}"
IMAGE_NAME="ai-sandbox-ephemeral:${STAMP}"
BUILD_DIR="$(mktemp -d /tmp/ai-sandbox-build.XXXXXX)"
PASSWORD=""

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '\n错误：%s\n' "$*" >&2; exit 1; }

cleanup_build() { rm -rf -- "$BUILD_DIR"; }
on_exit() {
  rc=$?
  cleanup_build
  if [[ $rc -ne 0 ]]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker image rm "$IMAGE_NAME" >/dev/null 2>&1 || true
  fi
}
trap on_exit EXIT

# 检查 Root 权限
[[ $EUID -eq 0 ]] || die "请使用 sudo bash $0 运行。"
[[ "$DURATION_SECONDS" =~ ^[0-9]+$ ]] || die "DURATION_SECONDS 必须是秒数。"
(( DURATION_SECONDS >= 60 )) || die "时长至少为 60 秒。"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT 无效。"

# ==================== 1. 系统与 Docker 安装检查 ====================
log "检查系统环境与基础依赖..."
. /etc/os-release
printf '%s\n' "-> 宿主操作系统: ${PRETTY_NAME:-$ID}"
printf '%s\n' "-> 内核版本    : $(uname -r)"

if ! command -v docker >/dev/null 2>&1; then
  printf '\n⚠️  未检测到 Docker 环境！\n'
  read -r -p "是否现在自动安装 Docker？[Y/n]: " user_choice
  user_choice="${user_choice:-Y}"
  if [[ "$user_choice" =~ ^[Yy]$ ]]; then
    log "开始下载并安装 Docker (get.docker.com)..."
    INSTALL_SCRIPT="$(mktemp /tmp/get-docker.XXXXXX.sh)"
    
    # 根据网络设置决定 curl 是否使用代理
    if [[ -n "$PROXY_URL" ]]; then
      curl --proxy "$PROXY_URL" -fsSL https://get.docker.com -o "$INSTALL_SCRIPT" || die "Docker 安装脚本下载失败，请检查网络/代理。"
    else
      curl -fsSL https://get.docker.com -o "$INSTALL_SCRIPT" || die "Docker 安装脚本下载失败，请检查直连网络。"
    fi
    
    sh "$INSTALL_SCRIPT" || die "Docker 安装脚本执行失败。"
    rm -f -- "$INSTALL_SCRIPT"

    log "验证 Docker 安装结果..."
    if ! command -v docker >/dev/null 2>&1; then
      die "Docker 安装失败，未找到可执行文件。"
    fi
    docker --version
    log "Docker 安装成功！继续配置启动..."
  else
    printf '\n用户取消安装 Docker，脚本退出。\n'
    exit 0
  fi
else
  printf '%s\n' "-> 已安装 Docker: $(docker --version)"
fi

# 确保依赖及 Docker 服务已运行
command -v systemctl >/dev/null 2>&1 || die "需要 systemd。"
systemctl enable --now docker
docker info >/dev/null 2>&1 || die "Docker 服务不可用，请检查 systemctl status docker。"

# ==================== 2. 代理模式判定与网络环境隔离 ====================
if [[ -n "$PROXY_URL" ]]; then
  export IS_PROXY_MODE=true
  log "【网络模式】: 代理模式 (Proxy Mode)"
  printf '%s\n' "-> 代理服务器地址: $PROXY_URL"

  # 覆盖当前脚本进程中的代理环境变量，防止被宿主机残留的其他代理串扰
  export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
  export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
  export ALL_PROXY="$PROXY_URL"  all_proxy="$PROXY_URL"
  export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
else
  export IS_PROXY_MODE=false
  log "【网络模式】: 直连模式 (Direct Mode - 禁用所有代理)"

  # 强制清空所有代理环境变量，即使宿主机原本有配置，也确保直连
  unset http_proxy https_proxy ftp_proxy all_proxy
  unset HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY
  unset NO_PROXY no_proxy
fi

# ==================== 3. 宿主机基础工具包补全 ====================
log "检查宿主工具包 (curl, openssl, iproute2)..."
case "${ID:-}" in
  debian|ubuntu|linuxmint|pop)
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl openssl ca-certificates iproute2 >/dev/null
    ;;
  arch|manjaro|endeavouros)
    pacman -Sy --needed --noconfirm curl openssl ca-certificates iproute2 >/dev/null
    ;;
esac

# 检查端口占用
if command -v ss >/dev/null 2>&1; then
  if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${SSH_PORT}$"; then
    die "端口 ${SSH_PORT} 已被宿主机占用。请用 sudo env SSH_PORT=xxxx bash $0 更换端口。"
  fi
fi

# PASSWORD="$(openssl rand -hex 16)"
# PASSWORD="$(python3 -c 'import os; print(os.urandom(16).hex())')"

# Attempt to use the original OpenSSL method; fallback to Python if it fails
if ! PASSWORD="$(openssl rand -hex 16 2>/dev/null)"; then
  log "⚠️  OpenSSL command failed. Using Python backup method for password generation."
  PASSWORD="$(python3 -c 'import os; print(os.urandom(16).hex())')"
fi
# PASSWORD="$(openssl rand -hex 16 2>/dev/null || python3 -c 'import os; print(os.urandom(16).hex())')"

log "生成一次性 SSH 访问凭证..."

# ==================== 4. 构建沙盒 Dockerfile 与 Entrypoint ====================
# 编写 entrypoint.sh：融合【方案 B：容器内部定时自杀机制】
cat > "$BUILD_DIR/entrypoint.sh" <<'ENTRYPOINT'
#!/bin/bash
set -eu
: "${AI_PASSWORD:?AI_PASSWORD must be set}"
echo "ai:${AI_PASSWORD}" | chpasswd
ssh-keygen -A

# 【方案 B - 内部自杀】如果设置了生命周期秒数，后台延时向 1 号进程发送 SIGTERM
if [ -n "${LIFETIME_SECONDS:-}" ] && [ "${LIFETIME_SECONDS}" -gt 0 ]; then
  (
    sleep "${LIFETIME_SECONDS}"
    echo "[Sandbox] Lifetime expired (${LIFETIME_SECONDS}s). Exiting container gracefully..."
    kill -TERM 1
  ) >/dev/null 2>&1 &
fi

exec "$(command -v sshd)" -D -e
ENTRYPOINT
chmod 0755 "$BUILD_DIR/entrypoint.sh"

# 根据是否开启代理构建 Dockerfile
if [[ "$IS_PROXY_MODE" == true ]]; then
cat > "$BUILD_DIR/Dockerfile" <<DOCKERFILE
ARG BASE_IMAGE=archlinux:latest
FROM \${BASE_IMAGE}
ARG PROXY_URL
ENV http_proxy=\${PROXY_URL} https_proxy=\${PROXY_URL} HTTP_PROXY=\${PROXY_URL} HTTPS_PROXY=\${PROXY_URL}
RUN pacman -Syu --noconfirm --needed openssh sudo bash ca-certificates curl git procps-ng iproute2 base-devel python python-pip shadow \
 && pacman -Scc --noconfirm \
 && mkdir -p /run/sshd /home/ai/work /etc/sudoers.d \
 && useradd -m -s /bin/bash -u 1000 ai \
 && chown -R ai:ai /home/ai \
 && printf 'ai ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/ai \
 && chmod 0440 /etc/sudoers.d/ai \
 && printf '\nPasswordAuthentication yes\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAllowUsers ai\nX11Forwarding no\nAllowTcpForwarding no\nPermitTunnel no\n' >> /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/ai-sandbox-entrypoint
RUN chmod 0755 /usr/local/bin/ai-sandbox-entrypoint
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/ai-sandbox-entrypoint"]
DOCKERFILE
else
cat > "$BUILD_DIR/Dockerfile" <<'DOCKERFILE'
ARG BASE_IMAGE=archlinux:latest
FROM ${BASE_IMAGE}
RUN pacman -Syu --noconfirm --needed openssh sudo bash ca-certificates curl git procps-ng iproute2 base-devel python python-pip shadow \
 && pacman -Scc --noconfirm \
 && mkdir -p /run/sshd /home/ai/work /etc/sudoers.d \
 && useradd -m -s /bin/bash -u 1000 ai \
 && chown -R ai:ai /home/ai \
 && printf 'ai ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/ai \
 && chmod 0440 /etc/sudoers.d/ai \
 && printf '\nPasswordAuthentication yes\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAllowUsers ai\nX11Forwarding no\nAllowTcpForwarding no\nPermitTunnel no\n' >> /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/ai-sandbox-entrypoint
RUN chmod 0755 /usr/local/bin/ai-sandbox-entrypoint
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/ai-sandbox-entrypoint"]
DOCKERFILE
fi

# ==================== 5. Docker 镜像构建 ====================
log "构建临时 Arch Linux 镜像..."
if [[ "$IS_PROXY_MODE" == true ]]; then
  docker build --pull \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg "PROXY_URL=$PROXY_URL" \
    --build-arg "http_proxy=$PROXY_URL" \
    --build-arg "https_proxy=$PROXY_URL" \
    --build-arg "HTTP_PROXY=$PROXY_URL" \
    --build-arg "HTTPS_PROXY=$PROXY_URL" \
    -t "$IMAGE_NAME" "$BUILD_DIR"
else
  # 直连模式：显式将所有的 proxy build-arg 强制清空，覆盖系统或 Docker daemon 的代理配置
  docker build --pull \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg http_proxy= \
    --build-arg https_proxy= \
    --build-arg ftp_proxy= \
    --build-arg all_proxy= \
    --build-arg HTTP_PROXY= \
    --build-arg HTTPS_PROXY= \
    --build-arg FTP_PROXY= \
    --build-arg ALL_PROXY= \
    -t "$IMAGE_NAME" "$BUILD_DIR"
fi

# ==================== 6. 容器启动 (融合方案 B: --rm 及注入 LIFETIME_SECONDS) ====================
log "启动临时沙盒容器..."

DOCKER_RUN_CMD=(
  docker run -d
  --name "$CONTAINER_NAME"
  --rm                                         # 方案 B 核心：一旦进程退出，自动清理容器
  --restart=no
  --pids-limit=256
  --memory=1200m
  --cpus=1
  --tmpfs /run:rw,nosuid,size=64m
  --tmpfs /tmp:rw,nosuid,size=256m
  --tmpfs /var/tmp:rw,nosuid,size=64m
  -p "0.0.0.0:${SSH_PORT}:22"
  -e "AI_PASSWORD=$PASSWORD"
  -e "LIFETIME_SECONDS=$DURATION_SECONDS"      # 方案 B 核心：将超时时间传入容器
  -v /home/john:/home/ai/work/host_john:rw
)

if [[ "$IS_PROXY_MODE" == true ]]; then
  DOCKER_RUN_CMD+=(
    -e "http_proxy=$PROXY_URL" -e "https_proxy=$PROXY_URL"
    -e "HTTP_PROXY=$PROXY_URL" -e "HTTPS_PROXY=$PROXY_URL"
    -e "NO_PROXY=localhost,127.0.0.1,::1"
  )
else
  DOCKER_RUN_CMD+=(
    -e "http_proxy=" -e "https_proxy="
    -e "HTTP_PROXY=" -e "HTTPS_PROXY="
    -e "NO_PROXY="
  )
fi

DOCKER_RUN_CMD+=("$IMAGE_NAME")
"${DOCKER_RUN_CMD[@]}" >/dev/null

docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || die "容器未能成功运行。"

# ==================== 7. 超时销毁机制 (融合方案 A: 宿主机 nohup 兜底) ====================
# 方案 A 负责兜底：即便容器发生死锁/未自杀，宿主机后台 nohup 也会在到期后强制 rm 容器并彻底清理专属镜像
log "注册宿主机守护清理任务（双保险机制就绪，时长: ${DURATION_SECONDS} 秒）..."
nohup bash -c "
  sleep ${DURATION_SECONDS}
  # 强制杀死容器（若方案B已自动删除，此处不报错）
  /usr/bin/docker rm -f '${CONTAINER_NAME}' >/dev/null 2>&1 || true
  # 清理本次运行生成的临时镜像
  /usr/bin/docker image rm '${IMAGE_NAME}' >/dev/null 2>&1 || true
" >/dev/null 2>&1 &

# ==================== 8. IP 与网络环境回显 ====================
LAN_IPS=()
while IFS= read -r addr; do
  [[ -n "$addr" ]] && LAN_IPS+=("$addr")
done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u)

EGRESS_IP=""
if command -v curl >/dev/null 2>&1; then
  if [[ "$IS_PROXY_MODE" == true ]]; then
    EGRESS_IP="$(curl --proxy "$PROXY_URL" --connect-timeout 5 --max-time 10 -fsS https://api.ipify.org 2>/dev/null || true)"
  else
    EGRESS_IP="$(curl --connect-timeout 5 --max-time 10 -fsS https://api.ipify.org 2>/dev/null || true)"
  fi
  [[ "$EGRESS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || EGRESS_IP=""
fi

# ==================== 9. 输出信息看板 ====================
printf '\n'
printf '%s\n' '=================================================================='
printf '%s\n' '🎉 AI Docker 沙盒启动成功！请将以下信息提供给 AI 智能体：'
printf '%s\n' '------------------------------------------------------------------'
if [[ "$IS_PROXY_MODE" == true ]]; then
  printf '🌐 当前网络模式: 【代理模式】 (Proxy: %s)\n' "$PROXY_URL"
else
  printf '%s\n' '🌐 当前网络模式: 【直连模式】 (Direct Connection - 纯净无代理)'
fi
printf '%s\n' '------------------------------------------------------------------'
if ((${#LAN_IPS[@]})); then
  for addr in "${LAN_IPS[@]}"; do
    printf '📌 内网登录命令: ssh ai@%s -p %s\n' "$addr" "$SSH_PORT"
  done
else
  printf '%s\n' '📌 未检测到内网 IPv4 地址。'
fi

if [[ -n "$EGRESS_IP" ]]; then
  printf '📌 出口公网 IP (不保证入站): %s\n' "$EGRESS_IP"
  printf '📌 若已配置路由器映射，可测试: ssh ai@%s -p %s\n' "$EGRESS_IP" "$SSH_PORT"
fi

printf '📌 用户名      : ai\n'
printf '📌 一次性密码  : %s\n' "$PASSWORD"
printf '📌 SSH 端口    : %s\n' "$SSH_PORT"
printf '📌 内部提权    : 容器内免密 sudo (隔离环境，无宿主Root权限)\n'
printf '📌 挂载共享    : /home/ai/work/host_john -> /home/john\n'
printf '📌 到期时间    : %s\n' "$(date -d "@$(( $(date +%s) + DURATION_SECONDS ))" '+%F %T %Z' 2>/dev/null || date)"
printf '%s\n' '------------------------------------------------------------------'
printf '%s\n' '🛡️ 双重销毁保障生效中：'
printf '%s\n' '  - 内部保障: 容器内部定时触发 SIGTERM 并由 --rm 立即自动销毁。'
printf '%s\n' '  - 宿主保障: 宿主机后台守护线程独立计时，到期兜底清理容器与临时镜像。'
printf '%s\n' '⚠️ 容器销毁后内部未保存数据将丢失，请知悉！'
printf '%s\n' '=================================================================='