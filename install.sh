#!/usr/bin/env bash
# =============================================================================
# install-gateway-agent.sh
#
# Cài đặt tự động gateway-agent + WireGuard trên Ubuntu/Debian mới từ đầu.
# Tested on: Ubuntu 22.04 / 24.04 / 25.10 (sudo-rs), Debian 12.
#
# CÁCH DÙNG (chạy trên server VPN, với root hoặc sudo):
#
#   # Cách 1 — CLI flags:
#   curl -fsSL https://raw.githubusercontent.com/programersupernova/gateway-agent/main/install.sh \
#     | sudo bash -s -- \
#         --region UK-LON-1 \
#         --backend-url https://spn-vpn-api-dev.xfotoai.com \
#         --bootstrap-token supersecret-bootstrap-token
#
#   # Cách 2 — biến môi trường:
#   sudo REGION=UK-LON-1 \
#        BACKEND_URL=https://spn-vpn-api-dev.xfotoai.com \
#        BOOTSTRAP_TOKEN=supersecret-bootstrap-token \
#        bash install-gateway-agent.sh
#
# Script idempotent: chạy lại được để cập nhật (giữ nguyên keys + AGENT_TOKEN).
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults — có thể override qua env hoặc CLI flags
# -----------------------------------------------------------------------------
: "${REGION:=}"                 # BẮT BUỘC, tối đa 20 ký tự
: "${BACKEND_URL:=}"            # BẮT BUỘC
: "${BOOTSTRAP_TOKEN:=}"        # BẮT BUỘC
: "${VPN_CIDR:=10.10.0.0/16}"
: "${WG_GATEWAY_IP:=10.10.0.1}" # IP của server trong VPN subnet (thường .1)
: "${WG_PORT:=51820}"
: "${PORT:=8080}"
: "${WG_INTERFACE:=wg0}"
: "${AGENT_USER:=gwagent}"
: "${INSTALL_DIR:=/opt/gateway-agent}"
: "${REPO_URL:=https://github.com/programersupernova/gateway-agent.git}"
: "${REPO_BRANCH:=master}"
: "${PUBLIC_IFACE:=}"           # auto-detect nếu rỗng
: "${AGENT_BASE_URL:=}"         # auto: http://<public-ip>:<PORT>
: "${AGENT_TOKEN:=}"            # auto: random 32 bytes hex nếu rỗng
: "${ENABLE_UFW:=1}"            # 0 để bỏ qua bật ufw

# -----------------------------------------------------------------------------
# Parse CLI flags
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)          REGION="$2"; shift 2;;
    --backend-url)     BACKEND_URL="$2"; shift 2;;
    --bootstrap-token) BOOTSTRAP_TOKEN="$2"; shift 2;;
    --vpn-cidr)        VPN_CIDR="$2"; shift 2;;
    --gateway-ip)      WG_GATEWAY_IP="$2"; shift 2;;
    --wg-port)         WG_PORT="$2"; shift 2;;
    --port)            PORT="$2"; shift 2;;
    --public-iface)    PUBLIC_IFACE="$2"; shift 2;;
    --agent-base-url)  AGENT_BASE_URL="$2"; shift 2;;
    --agent-token)     AGENT_TOKEN="$2"; shift 2;;
    --repo-url)        REPO_URL="$2"; shift 2;;
    --repo-branch)     REPO_BRANCH="$2"; shift 2;;
    --install-dir)     INSTALL_DIR="$2"; shift 2;;
    --no-ufw)          ENABLE_UFW=0; shift;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 1;;
  esac
done

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Script cần chạy với quyền root (dùng sudo)."
[[ -n "$REGION" ]] || die "Thiếu REGION. Truyền qua --region hoặc biến môi trường."
[[ ${#REGION} -le 20 ]] || die "REGION='$REGION' dài ${#REGION} ký tự, backend giới hạn ≤20."
[[ -n "$BACKEND_URL" ]] || die "Thiếu BACKEND_URL."
[[ -n "$BOOTSTRAP_TOKEN" ]] || die "Thiếu BOOTSTRAP_TOKEN."

# Auto-detect interface public
if [[ -z "$PUBLIC_IFACE" ]]; then
  PUBLIC_IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
  [[ -n "$PUBLIC_IFACE" ]] || die "Không tìm được public interface. Truyền --public-iface."
fi
ip -o link show "$PUBLIC_IFACE" >/dev/null 2>&1 || die "Interface '$PUBLIC_IFACE' không tồn tại."

# Detect public IP (cho AGENT_BASE_URL)
if [[ -z "$AGENT_BASE_URL" ]]; then
  PUBLIC_IP=$(ip -o -4 addr show "$PUBLIC_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)
  [[ -n "$PUBLIC_IP" ]] || die "Không đọc được IP trên $PUBLIC_IFACE."
  AGENT_BASE_URL="http://${PUBLIC_IP}:${PORT}"
fi

# Subnet từ VPN_CIDR (ví dụ 10.10.0.0/16)
[[ "$VPN_CIDR" =~ ^[0-9.]+/[0-9]+$ ]] || die "VPN_CIDR='$VPN_CIDR' không hợp lệ."
VPN_PREFIX=$(echo "$VPN_CIDR" | cut -d/ -f2)

log "Cấu hình:"
cat <<EOF
  REGION          = $REGION
  BACKEND_URL     = $BACKEND_URL
  VPN_CIDR        = $VPN_CIDR
  WG_GATEWAY_IP   = $WG_GATEWAY_IP
  WG_PORT         = $WG_PORT
  PORT (API)      = $PORT
  PUBLIC_IFACE    = $PUBLIC_IFACE
  AGENT_BASE_URL  = $AGENT_BASE_URL
  INSTALL_DIR     = $INSTALL_DIR
  REPO            = $REPO_URL ($REPO_BRANCH)
  UFW             = $([[ $ENABLE_UFW -eq 1 ]] && echo "enable" || echo "skip")
EOF

# Luôn gọi wg bằng path tuyệt đối để bypass shim (/usr/local/bin/wg) khi
# install script chạy as root — shim dùng sudo -n, sudo-rs có thể reject
# khi caller là root, làm `wg --version` trả rỗng và `wg show` fail.
WG_REAL=/usr/bin/wg

# -----------------------------------------------------------------------------
# 0. Chuẩn bị hệ thống: swap + tắt background updater (tránh OOM 1GB RAM)
# -----------------------------------------------------------------------------
log "0/9 Chuẩn bị hệ thống (swap, background updaters)..."

# Swap: đảm bảo có ít nhất 1GB swap nếu RAM < 2GB
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
if [[ $MEM_MB -lt 2048 && $SWAP_MB -lt 1024 ]]; then
  log "  RAM=${MEM_MB}MB, swap=${SWAP_MB}MB → tạo /swapfile 2GB"
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile 2>/dev/null || true
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
  sysctl -qw vm.swappiness=10
else
  log "  RAM=${MEM_MB}MB, swap=${SWAP_MB}MB → OK, không cần swap thêm"
fi

# packagekit / unattended-upgrades thường chạy song song trên droplet mới,
# ăn RAM + giữ lock dpkg → xung đột với apt-get của script.
systemctl disable --now packagekit.service 2>/dev/null || true
systemctl disable --now unattended-upgrades.service 2>/dev/null || true
pkill -9 -f "unattended-upgr" 2>/dev/null || true

# Đảm bảo không bị kẹt dpkg lock từ lần cài trước
if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
  warn "  dpkg lock đang bị giữ — đợi 30s..."
  for _ in $(seq 1 30); do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
    sleep 1
  done
fi
dpkg --configure -a >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 1. APT packages + Node.js 20
# -----------------------------------------------------------------------------
log "1/9 Cài gói hệ thống + WireGuard + Node.js 20..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg lsb-release git \
  iproute2 iptables ufw wireguard wireguard-tools jq openssl

if ! command -v node >/dev/null || [[ "$(node -v 2>/dev/null | cut -d. -f1)" != "v20" ]]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y -qq nodejs
fi
log "  node=$(node -v)  wg=$("$WG_REAL" --version | awk '{print $2}')"

# -----------------------------------------------------------------------------
# 2. IP forwarding
# -----------------------------------------------------------------------------
log "2/9 Bật IP forwarding..."
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-wireguard.conf
sysctl --system >/dev/null
[[ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]] || die "Không bật được ip_forward."

# -----------------------------------------------------------------------------
# 3. WireGuard keys + wg0.conf
# -----------------------------------------------------------------------------
log "3/9 Cấu hình WireGuard ($WG_INTERFACE)..."
install -d -m 700 /etc/wireguard
if [[ ! -s /etc/wireguard/server.key ]]; then
  umask 077
  "$WG_REAL" genkey | tee /etc/wireguard/server.key | "$WG_REAL" pubkey > /etc/wireguard/server.pub
  chmod 600 /etc/wireguard/server.key
  chmod 644 /etc/wireguard/server.pub
  log "  generated new server keypair"
else
  log "  reusing existing /etc/wireguard/server.key"
fi
SERVER_PRIV=$(cat /etc/wireguard/server.key)
SERVER_PUB=$(cat /etc/wireguard/server.pub)

# Tắt wg0 hiện có trước khi ghi đè conf (tránh kẹt rule iptables cũ)
if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
  systemctl stop "wg-quick@${WG_INTERFACE}" || true
fi

cat > "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF
[Interface]
Address    = ${WG_GATEWAY_IP}/${VPN_PREFIX}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIV}
SaveConfig = false

PostUp   = iptables -t nat -A POSTROUTING -s ${VPN_CIDR} -o ${PUBLIC_IFACE} -j MASQUERADE
PostUp   = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT
PostUp   = iptables -A FORWARD -o ${WG_INTERFACE} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${VPN_CIDR} -o ${PUBLIC_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT
PostDown = iptables -D FORWARD -o ${WG_INTERFACE} -j ACCEPT
EOF
chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"
systemctl enable --now "wg-quick@${WG_INTERFACE}"
"$WG_REAL" show "$WG_INTERFACE" >/dev/null || die "WireGuard $WG_INTERFACE không up được."
log "  server public key: $SERVER_PUB"

# -----------------------------------------------------------------------------
# 4. User gwagent + clone source
# -----------------------------------------------------------------------------
log "4/9 Tạo user $AGENT_USER và clone source..."
id "$AGENT_USER" >/dev/null 2>&1 || \
  useradd --system --create-home --shell /usr/sbin/nologin "$AGENT_USER"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  sudo -u "$AGENT_USER" git -C "$INSTALL_DIR" fetch --quiet origin "$REPO_BRANCH"
  sudo -u "$AGENT_USER" git -C "$INSTALL_DIR" reset --hard "origin/${REPO_BRANCH}"
else
  rm -rf "$INSTALL_DIR"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 755 "$(dirname "$INSTALL_DIR")"
  sudo -u "$AGENT_USER" git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

# node_modules cũ có thể do user khác tạo → xoá sạch trước khi install
rm -rf "$INSTALL_DIR/node_modules"
chown -R "$AGENT_USER":"$AGENT_USER" "$INSTALL_DIR"

if [[ -f "$INSTALL_DIR/package-lock.json" ]]; then
  sudo -u "$AGENT_USER" bash -lc "cd '$INSTALL_DIR' && npm ci --omit=dev --no-audit --no-fund"
else
  sudo -u "$AGENT_USER" bash -lc "cd '$INSTALL_DIR' && npm install --omit=dev --no-audit --no-fund"
fi

# -----------------------------------------------------------------------------
# 5. Sudoers rule + shim wg
# -----------------------------------------------------------------------------
log "5/9 Cấp quyền gọi wg cho $AGENT_USER..."
[[ -x "$WG_REAL" ]] || die "Không tìm thấy binary wg tại $WG_REAL."
echo "$AGENT_USER ALL=(root) NOPASSWD: $WG_REAL" > /etc/sudoers.d/"$AGENT_USER"
chmod 0440 /etc/sudoers.d/"$AGENT_USER"
chown root:root /etc/sudoers.d/"$AGENT_USER"
visudo -c >/dev/null || die "sudoers syntax error."

cat > /usr/local/bin/wg <<EOF
#!/bin/sh
exec /usr/bin/sudo -n $WG_REAL "\$@"
EOF
chmod 755 /usr/local/bin/wg

# Test: gwagent gọi wg không cần password
sudo -u "$AGENT_USER" -H env PATH=/usr/local/bin:/usr/bin:/bin wg show "$WG_INTERFACE" public-key >/dev/null \
  || die "Test sudo wg thất bại — check sudoers + shim."

# -----------------------------------------------------------------------------
# 6. .env
# -----------------------------------------------------------------------------
log "6/9 Ghi $INSTALL_DIR/.env..."
if [[ -z "$AGENT_TOKEN" ]]; then
  if [[ -f "$INSTALL_DIR/.env" ]] && grep -q '^AGENT_TOKEN=.\+' "$INSTALL_DIR/.env"; then
    AGENT_TOKEN=$(grep '^AGENT_TOKEN=' "$INSTALL_DIR/.env" | cut -d= -f2-)
    log "  reusing existing AGENT_TOKEN"
  else
    AGENT_TOKEN=$(openssl rand -hex 32)
    log "  generated new AGENT_TOKEN"
  fi
fi

install -o "$AGENT_USER" -g "$AGENT_USER" -m 600 /dev/null "$INSTALL_DIR/.env"
cat > "$INSTALL_DIR/.env" <<EOF
PORT=${PORT}
AGENT_TOKEN=${AGENT_TOKEN}
WG_INTERFACE=${WG_INTERFACE}
WG_PORT=${WG_PORT}
BACKEND_URL=${BACKEND_URL}
BOOTSTRAP_TOKEN=${BOOTSTRAP_TOKEN}
REGION=${REGION}
VPN_CIDR=${VPN_CIDR}
AGENT_BASE_URL=${AGENT_BASE_URL}
EOF
chown "$AGENT_USER":"$AGENT_USER" "$INSTALL_DIR/.env"
chmod 600 "$INSTALL_DIR/.env"

# -----------------------------------------------------------------------------
# 7. systemd unit
# -----------------------------------------------------------------------------
log "7/9 Tạo systemd unit gateway-agent..."
cat > /etc/systemd/system/gateway-agent.service <<EOF
[Unit]
Description=VPN Gateway Agent
After=network-online.target wg-quick@${WG_INTERFACE}.service
Wants=network-online.target
Requires=wg-quick@${WG_INTERFACE}.service

[Service]
Type=simple
User=${AGENT_USER}
Group=${AGENT_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
Environment=NODE_ENV=production
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/bin/node src/index.js
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

# NoNewPrivileges phải false vì agent gọi sudo wg qua shim
NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gateway-agent
systemctl restart gateway-agent

# -----------------------------------------------------------------------------
# 8. Firewall + smoke test
# -----------------------------------------------------------------------------
if [[ $ENABLE_UFW -eq 1 ]]; then
  log "8/9 Cấu hình UFW..."
  ufw allow 22/tcp >/dev/null
  ufw allow "${WG_PORT}/udp" >/dev/null
  ufw allow "${PORT}/tcp" >/dev/null
  ufw --force enable >/dev/null
else
  log "8/9 Bỏ qua UFW (--no-ufw)"
fi

log "9/9 Smoke test..."

sleep 2

PING=$(curl -sS --max-time 5 "http://127.0.0.1:${PORT}/v1/ping" || true)
HEALTH=$(curl -sS --max-time 5 -H "x-agent-token: ${AGENT_TOKEN}" "http://127.0.0.1:${PORT}/v1/health" || true)
echo "  /v1/ping   → $PING"
echo "  /v1/health → $HEALTH"

echo
echo "==============================================================="
echo " Cài đặt xong"
echo "==============================================================="
echo "  Region             : $REGION"
echo "  Gateway IP (VPN)   : $WG_GATEWAY_IP"
echo "  WireGuard pubkey   : $SERVER_PUB"
echo "  WireGuard endpoint : UDP :$WG_PORT"
echo "  Agent API          : $AGENT_BASE_URL"
echo "  AGENT_TOKEN        : $AGENT_TOKEN"
echo
echo "  Log realtime : journalctl -u gateway-agent -f"
echo "  WG status    : wg show $WG_INTERFACE"
echo "  Re-register  : curl -XPOST -H \"x-agent-token: \$TOKEN\" $AGENT_BASE_URL/v1/register"
echo
if echo "$HEALTH" | grep -q '"wgUp":true'; then
  echo "  Status: OK"
else
  echo "  Status: KIỂM TRA LẠI — /v1/health không trả wgUp=true"
  exit 1
fi
