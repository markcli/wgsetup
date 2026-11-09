#!/bin/bash
#
# WireGuard VPN Server Setup
# Operating System: Amazon Linux 2023
#

set -Eeuo pipefail

# ==================================================
# Configuration
# ==================================================

WG_PORT="31689"
WG_NETWORK="10.10.10.0/24"
SERVER_WG_IP="10.10.10.1/24"

CLIENT_NAME="client1"
CLIENT_WG_IP="10.10.10.2/32"

DNS_SERVER="1.1.1.1"

WG_INTERFACE="wg0"
WG_DIR="/etc/wireguard"

# ==================================================
# Helper functions
# ==================================================

log() {
    echo "[$(date '+%F %T')] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ==================================================
# Check prerequisites
# ==================================================

[[ $EUID -eq 0 ]] || die "Run this script as root."

source /etc/os-release

[[ "${ID}" == "amzn" && "${VERSION_ID%%.*}" == "2023" ]] \
    || die "This script supports Amazon Linux 2023 only."

[[ ! -e "${WG_DIR}/${WG_INTERFACE}.conf" ]] \
    || die "WireGuard configuration already exists."

[[ ! -e "${WG_DIR}/${CLIENT_NAME}.conf" ]] \
    || die "Client configuration already exists."

log "Checking network interface..."

SERVER_INTERFACE=$(ip -4 route show default |
    awk 'NR==1 {print $5}')

[[ -n "${SERVER_INTERFACE}" ]] \
    || die "Cannot detect default network interface."

log "Default interface: ${SERVER_INTERFACE}"

# ==================================================
# Install packages
# ==================================================

log "Updating package metadata..."

dnf makecache

log "Installing WireGuard dependencies..."

dnf install -y \
    wireguard-tools \
    iptables \
    qrencode \
    iproute \
    || die "Package installation failed."

command -v wg >/dev/null || die "wg command not found."
command -v wg-quick >/dev/null || die "wg-quick command not found."

# Load native kernel module
log "Loading WireGuard kernel module..."

modprobe wireguard || die "Cannot load WireGuard kernel module."

# ==================================================
# Detect public IP
# ==================================================

log "Detecting EC2 public IP..."

SERVER_PUBLIC_IP=""

# EC2 Instance Metadata Service v2
IMDS_TOKEN=$(curl -fsS --connect-timeout 3 \
    -X PUT \
    "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
    || true)

if [[ -n "${IMDS_TOKEN}" ]]; then
    SERVER_PUBLIC_IP=$(curl -fsS --connect-timeout 3 \
        -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
        "http://169.254.169.254/latest/meta-data/public-ipv4" \
        || true)
fi

# Fallback to external IP detection
if [[ -z "${SERVER_PUBLIC_IP}" ]]; then
    SERVER_PUBLIC_IP=$(curl -4 -fsS --connect-timeout 5 \
        https://api.ipify.org || true)
fi

[[ -n "${SERVER_PUBLIC_IP}" ]] \
    || die "Cannot detect public IP address."

log "Server public IP: ${SERVER_PUBLIC_IP}"

# ==================================================
# Generate keys
# ==================================================

log "Generating WireGuard keys..."

install -d -m 700 "${WG_DIR}"

umask 077

wg genkey > "${WG_DIR}/server_private.key"
wg pubkey < "${WG_DIR}/server_private.key" \
    > "${WG_DIR}/server_public.key"

wg genkey > "${WG_DIR}/${CLIENT_NAME}_private.key"
wg pubkey < "${WG_DIR}/${CLIENT_NAME}_private.key" \
    > "${WG_DIR}/${CLIENT_NAME}_public.key"

SERVER_PRIVATE_KEY=$(cat "${WG_DIR}/server_private.key")
SERVER_PUBLIC_KEY=$(cat "${WG_DIR}/server_public.key")

CLIENT_PRIVATE_KEY=$(cat "${WG_DIR}/${CLIENT_NAME}_private.key")
CLIENT_PUBLIC_KEY=$(cat "${WG_DIR}/${CLIENT_NAME}_public.key")

# ==================================================
# Enable IP forwarding
# ==================================================

log "Enabling IPv4 forwarding..."

cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward = 1
EOF

sysctl --system

# ==================================================
# Configure WireGuard server
# ==================================================

log "Creating server configuration..."

cat > "${WG_DIR}/${WG_INTERFACE}.conf" <<EOF
[Interface]
Address = ${SERVER_WG_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

# Forward VPN client traffic
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# NAT for VPN clients
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NETWORK} -o ${SERVER_INTERFACE} -j MASQUERADE

# Clean up firewall rules
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NETWORK} -o ${SERVER_INTERFACE} -j MASQUERADE

[Peer]
# ${CLIENT_NAME}
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_WG_IP}
EOF

chmod 600 "${WG_DIR}/${WG_INTERFACE}.conf"

# ==================================================
# Generate client configuration
# ==================================================

log "Creating client configuration..."

cat > "${WG_DIR}/${CLIENT_NAME}.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_WG_IP}
DNS = ${DNS_SERVER}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 "${WG_DIR}/${CLIENT_NAME}.conf"

# ==================================================
# Start WireGuard
# ==================================================

log "Starting WireGuard service..."

systemctl enable "wg-quick@${WG_INTERFACE}"
systemctl start "wg-quick@${WG_INTERFACE}"

systemctl is-active --quiet "wg-quick@${WG_INTERFACE}" \
    || die "WireGuard service failed to start."

# ==================================================
# Verify
# ==================================================

log "Verifying WireGuard interface..."

wg show "${WG_INTERFACE}"

ip addr show "${WG_INTERFACE}"

# ==================================================
# Completion
# ==================================================

echo
echo "=============================================="
echo " WireGuard installation completed!"
echo "=============================================="
echo
echo "Server public IP : ${SERVER_PUBLIC_IP}"
echo "Server UDP port  : ${WG_PORT}"
echo "VPN network      : ${WG_NETWORK}"
echo "Server VPN IP    : ${SERVER_WG_IP}"
echo "Client name      : ${CLIENT_NAME}"
echo "Client VPN IP    : ${CLIENT_WG_IP}"
echo
echo "Server config:"
echo "  ${WG_DIR}/${WG_INTERFACE}.conf"
echo
echo "Client config:"
echo "  ${WG_DIR}/${CLIENT_NAME}.conf"
echo
echo "Client configuration is ready to import."
echo
echo "IMPORTANT:"
echo "Allow UDP port ${WG_PORT} in the AWS Security Group."
echo
echo "=============================================="
