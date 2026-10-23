#!/usr/bin/env bash
# Temporary AI SSH sandbox using an Arch Linux container image on Debian/Ubuntu/Pop!_OS and Arch-family hosts.
# Run: sudo bash ai-sandbox-arch-no-proxy.sh
#
# 停止所有正在运行的容器
#	sudo docker stop $(sudo docker ps -aq) 2>/dev/null || true
#
# 一键清理所有 docker 容器和镜像
#	sudo docker system prune -a --volumes -f
# ==============================================================================

set -Eeuo pipefail
umask 077

DURATION_SECONDS="${DURATION_SECONDS:-7200}"
SSH_PORT="${SSH_PORT:-2222}"
BASE_IMAGE="${BASE_IMAGE:-archlinux:latest}"
STAMP="$(date +%s)-$$"
CONTAINER_NAME="ai-sandbox-${STAMP}"
IMAGE_NAME="ai-sandbox-ephemeral:${STAMP}"
BUILD_DIR="$(mktemp -d /tmp/ai-sandbox-build.XXXXXX)"
PASSWORD=""
EXPIRY_UNIT="ai-sandbox-expire-${STAMP}.service"

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

[[ $EUID -eq 0 ]] || die "请使用 sudo bash $0 运行。"
[[ "$DURATION_SECONDS" =~ ^[0-9]+$ ]] || die "DURATION_SECONDS 必须是秒数。"
(( DURATION_SECONDS >= 60 )) || die "时长至少为 60 秒。"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "SSH_PORT 无效。"
command -v systemctl >/dev/null 2>&1 || die "需要 systemd。"
command -v ip >/dev/null 2>&1 || die "缺少 iproute2，请先安装 iproute2。"
command -v docker >/dev/null 2>&1 || die "未找到 Docker。请先安装并启动 Docker。"

. /etc/os-release
case "${ID:-}" in
  debian|ubuntu|linuxmint|pop)
    log "检测到 Debian 系主机：${PRETTY_NAME:-$ID}"
    # Do not install docker.io here: this machine may already use Docker CE.
    # Install only utility packages; keep the host's existing Docker package family intact.
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl ca-certificates iproute2
    ;;
  arch|manjaro|endeavouros)
    log "检测到 Arch 系主机：${PRETTY_NAME:-$ID}"
    pacman -Sy --needed --noconfirm curl openssl ca-certificates iproute2
    ;;
  *)
    die "暂不支持发行版：${ID:-unknown}。支持 Debian/Ubuntu/Pop!_OS 和 Arch 系。"
    ;;
esac

log "检查并启动现有 Docker 服务（不切换 docker.io/docker-ce 软件包来源）..."
systemctl enable --now docker
docker info >/dev/null 2>&1 || die "Docker 服务不可用，请检查 systemctl status docker。"

if command -v ss >/dev/null 2>&1; then
  if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${SSH_PORT}$"; then
    die "端口 ${SSH_PORT} 已被占用。可用 sudo env SSH_PORT=2223 bash $0 更换端口。"
  fi
else
  log "未找到 ss，跳过本机端口预检查；Docker 启动时仍会验证端口。"
fi

PASSWORD="$(openssl rand -hex 16)"
log "生成一次性 SSH 密码并准备 Arch Linux 容器镜像..."

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

cat > "$BUILD_DIR/entrypoint.sh" <<'ENTRYPOINT'
#!/bin/bash
set -eu
: "${AI_PASSWORD:?AI_PASSWORD must be set}"
echo "ai:${AI_PASSWORD}" | chpasswd
ssh-keygen -A

# 容器内部定时终止：达到时长后，向 1 号进程发送终止信号自杀
if [ -n "\${LIFETIME_SECONDS:-}" ]; then
  ( sleep "\${LIFETIME_SECONDS}" && kill -TERM 1 ) >/dev/null 2>&1 &
fi

exec "$(command -v sshd)" -D -e
ENTRYPOINT
chmod 0755 "$BUILD_DIR/entrypoint.sh"

log "构建 Arch Linux 临时镜像（不使用代理）..."
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
  

log "启动临时 SSH 容器..."
# No host directories, Docker socket, host networking, or privileged mode are mounted.
# sudo is intentionally usable inside the container; it does not grant host root.
#  --security-opt seccomp=default \

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart=no \
  --pids-limit=256 \
  --memory=1200m \
  --cpus=1 \
  --tmpfs /run:rw,nosuid,size=64m \
  --tmpfs /tmp:rw,nosuid,size=256m \
  --tmpfs /var/tmp:rw,nosuid,size=64m \
  -p "0.0.0.0:${SSH_PORT}:22" \
  -e "AI_PASSWORD=$PASSWORD" \
  -v /home/john:/home/ai/work/host_john:rw \
  "$IMAGE_NAME" >/dev/null

docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || die "容器启动后检查失败。"

# Host-side systemd timer: survives closing the terminal and container process changes.
# At expiry, remove this specific container and this run's unique image.
log "启动后台定时清理任务（${DURATION_SECONDS} 秒后）..."
nohup bash -c "
  sleep ${DURATION_SECONDS}
  /usr/bin/docker rm -f '${CONTAINER_NAME}' >/dev/null 2>&1
  /usr/bin/docker image rm '${IMAGE_NAME}' >/dev/null 2>&1
" >/dev/null 2>&1 &

: '
CLEANUP_SCRIPT="/run/${EXPIRY_UNIT%.service}.sh"
cat > "$CLEANUP_SCRIPT" <<CLEANUP
#!/bin/bash
set +e
/usr/bin/docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1
/usr/bin/docker image rm "${IMAGE_NAME}" >/dev/null 2>&1
rm -f -- "${CLEANUP_SCRIPT}"
CLEANUP
chmod 0700 "$CLEANUP_SCRIPT"
systemd-run --quiet --unit="${EXPIRY_UNIT%.service}" --on-active="${DURATION_SECONDS}s" "$CLEANUP_SCRIPT" \
  || die "无法创建 systemd 到期清理任务；为安全起见停止并删除容器。"
'



# Detect private IPv4 addresses on this host.
LAN_IPS=()
while IFS= read -r addr; do
  [[ -n "$addr" ]] && LAN_IPS+=("$addr")
done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u)

# This is a directly observed outbound IP, NOT proof of inbound reachability.
EXTERNAL_IP=""
if command -v curl >/dev/null 2>&1; then
  EXTERNAL_IP="$(curl --connect-timeout 5 --max-time 10 -fsS https://api.ipify.org 2>/dev/null || true)"
  [[ "$EXTERNAL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || EXTERNAL_IP=""
fi

printf '\n'
printf '%s\n' '=================================================================='
printf '%s\n' '🎉 AI Docker 沙盒启动成功！请将以下信息提供给 AI 智能体：'
printf '%s\n' '------------------------------------------------------------------'
if ((${#LAN_IPS[@]})); then
  for addr in "${LAN_IPS[@]}"; do
    printf '📌 内网登录命令: ssh ai@%s -p %s\n' "$addr" "$SSH_PORT"
  done
else
  printf '%s\n' '📌 未检测到内网 IPv4 地址。'
fi
if [[ -n "$EXTERNAL_IP" ]]; then
  printf '📌 当前网络出口 IP（不保证可入站）: %s\n' "$EXTERNAL_IP"
  printf '📌 若已配置路由器端口转发，可尝试: ssh ai@%s -p %s\n' "$EXTERNAL_IP" "$SSH_PORT"
else
  printf '%s\n' '📌 未能检测网络出口 IP；请在路由器或网络管理端确认公网入口。'
fi
printf '%s\n' '📌 用户名  : ai'
printf '📌 密  码  : %s\n' "$PASSWORD"
printf '📌 端口号  : %s\n' "$SSH_PORT"
printf '%s\n' '📌 提  权  : 容器内部免密 sudo（不授予主机 sudo 权限）'
printf '%s\n' '📌 工作目录: /home/ai/work'
printf '📌 到期时间: %s\n' "$(date -d "@$(( $(date +%s) + DURATION_SECONDS ))" '+%F %T %Z' 2>/dev/null || date)"
printf '%s\n' '------------------------------------------------------------------'
printf '%s\n' '⚠️ 到期后由主机 systemd 定时任务删除容器和本次专用镜像。'
printf '%s\n' '⚠️ 容器内文件会丢失；请及时把需要保留的代码复制到可信存储。'
printf '%s\n' '⚠️ 公网 SSH 需正确配置路由器端口转发与防火墙；检测到的出口 IP 不一定是服务器公网入口。'
printf '%s\n' '⚠️ 无法保证清除系统日志、网络设备记录或其他系统级痕迹。'
printf '%s\n' '=================================================================='
