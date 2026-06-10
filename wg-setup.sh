#!/bin/bash

set -euo pipefail

########################################
# Configuration
########################################

WG_INTERFACE="wg0"
WG_PORT="31689"

WG_NETWORK="10.10.10.0/24"
SERVER_WG_IP="10.10.10.1/24"

CLIENT_NAME="client1"
CLIENT_WG_IP="10.10.10.2/32"

DNS_SERVER="1.1.1.1"

########################################
# Root Check
########################################

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root"
    exit 1
fi

########################################
# Install Packages
########################################

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    wireguard \
    nftables \
    curl

########################################
# Determine Public IP
########################################

PUBLIC_IP=""

# AWS EC2 Metadata
if curl -s --connect-timeout 2 \
    http://169.254.169.254/latest/meta-data/public-ipv4 >/dev/null 2>&1
then
    PUBLIC_IP=$(curl -s \
        http://169.254.169.254/latest/meta-data/public-ipv4)
fi

# Fallback
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -s https://checkip.amazonaws.com || true)
fi

if [ -z "$PUBLIC_IP" ]; then
    echo "Unable to determine public IP"
    exit 1
fi

########################################
# Determine WAN Interface
########################################

WAN_IF=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

if [ -z "$WAN_IF" ]; then
    echo "Unable to determine WAN interface"
    exit 1
fi

########################################
# Enable Forwarding
########################################

cat >/etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl --system

########################################
# Create Keys
########################################

mkdir -p /etc/wireguard/keys
chmod 700 /etc/wireguard/keys

SERVER_PRIV="/etc/wireguard/keys/server.key"
SERVER_PUB="/etc/wireguard/keys/server.pub"

CLIENT_PRIV="/etc/wireguard/keys/${CLIENT_NAME}.key"
CLIENT_PUB="/etc/wireguard/keys/${CLIENT_NAME}.pub"

if [ ! -f "$SERVER_PRIV" ]; then
    wg genkey | tee "$SERVER_PRIV" | wg pubkey > "$SERVER_PUB"
fi

if [ ! -f "$CLIENT_PRIV" ]; then
    wg genkey | tee "$CLIENT_PRIV" | wg pubkey > "$CLIENT_PUB"
fi

chmod 600 /etc/wireguard/keys/*

SERVER_PRIVATE_KEY=$(cat "$SERVER_PRIV")
SERVER_PUBLIC_KEY=$(cat "$SERVER_PUB")

CLIENT_PRIVATE_KEY=$(cat "$CLIENT_PRIV")
CLIENT_PUBLIC_KEY=$(cat "$CLIENT_PUB")

########################################
# Configure nftables
########################################

cat >/etc/nftables.conf <<EOF
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0;

        iif lo accept
        ct state established,related accept

        tcp dport 22 accept
        udp dport ${WG_PORT} accept

        counter drop
    }

    chain forward {
        type filter hook forward priority 0;

        ct state established,related accept
        iifname "${WG_INTERFACE}" accept
    }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority 100;
        oifname "${WAN_IF}" masquerade
    }
}
EOF

systemctl enable nftables
systemctl restart nftables

########################################
# Configure WireGuard Server
########################################

mkdir -p /etc/wireguard

cat >/etc/wireguard/${WG_INTERFACE}.conf <<EOF
[Interface]
Address = ${SERVER_WG_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_WG_IP}
EOF

chmod 600 /etc/wireguard/${WG_INTERFACE}.conf

########################################
# Start WireGuard
########################################

systemctl enable wg-quick@${WG_INTERFACE}
systemctl restart wg-quick@${WG_INTERFACE}

########################################
# Generate Client Config
########################################

CLIENT_CONFIG="/root/${CLIENT_NAME}.conf"

cat >"${CLIENT_CONFIG}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_WG_IP}
DNS = ${DNS_SERVER}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 "${CLIENT_CONFIG}"

########################################
# Display Summary
########################################

echo
echo "======================================"
echo "WireGuard installation complete"
echo "======================================"
echo
echo "Server public key:"
echo "${SERVER_PUBLIC_KEY}"
echo
echo "Client configuration:"
echo "${CLIENT_CONFIG}"
echo
echo "Server endpoint:"
echo "${PUBLIC_IP}:${WG_PORT}"
echo
echo "WireGuard status:"
wg show
echo
