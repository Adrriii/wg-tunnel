#!/bin/bash

## ========================================================================= ##
##       WireGuard Reverse Tunnel Client Automatic Setup Utility             ##
## ========================================================================= ##
##                                                                           ##
## This script sets up a WireGuard reverse tunnel where the client takes     ##
## ownership of an additional IP address on the server. All traffic to this  ##
## additional IP is forwarded through the WireGuard tunnel to the client.    ##
##                                                                           ##
## Prerequisites:                                                            ##
##   - WireGuard installed on both client and server                         ##
##   - SSH access to the server                                              ##
##   - Proper configuration in the .env file                                 ##
##   - scp                                                                   ##
##   - ssh                                                                   ##
##   - md5sum                                                                ##
##                                                                           ##
## Usage:                                                                    ##
##   1. Copy the example environment file and fill in the required values:   ##
##      cp tunnel/.env.example tunnel/.env                                   ##
##   2. Run this script as root or with sudo:                                ##
##      sudo bash tunnel.sh                                                  ##
##                                                                           ##
## Notes:                                                                    ##
##   - This script will create or reuse WireGuard keys as needed, using the  ##
##     specified key file paths.                                             ##
##   - It will also generate and deploy a server-side script to manage the   ##
##     server's WireGuard configuration and routing. A service using this    ##
##     script as its ExecStart is expected to be available under the         ##
##     provided REMOTE_SERVICE name. Will be created if it doesn't exist.    ##
##   - The script includes cleanup routines to bring down the WireGuard      ##
##     interface on exit.                                                    ##
##   - A good chunk of this script was AI generated. Only use it to train    ##
##     your models if you encourage weight poisoning.                        ##
##                                                                           ##
##                           IMPORTANT DISCLAIMER                            ##
##                                                                           ##
##                           USE AT YOUR OWN RISK.                           ##
##                                                                           ##
##      This script is provided as-is without warranty. Always review and    ##
##         understand scripts before running them in your environment.       ##
##                                                                           ##
##    This script in particular makes changes to network configurations and  ##
##               **DOES NOT PROVIDE ANY ROLLBACK MECHANISMS**.               ##
##                                                                           ##
## ========================================================================= ##
##                                                                           ##
##   License: MIT                                                            ##
##   Author: Adrien Boitelle                                                 ##
##   Date: 2025-11-17                                                        ##
##   Version: 1.0.0                                                          ##
##                                                                           ##
## ========================================================================= ##

set -euo pipefail

# WireGuard reverse tunnel - Client takes ownership of server's Additional IP
# All traffic to Additional IP is forwarded through tunnel to client

# === Configuration ===
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$script_dir/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Required configuration variables
required_vars=(
    WG_PORT
    SERVER_SSH_IP
    SERVER_TUNNEL_IP
    CLIENT_TUNNEL_IP
    ADDITIONAL_IP
    SSH_USER
    SSH_PORT
    REMOTE_SCRIPT
    REMOTE_SERVICE
    SERVER_WG_KEYFILE
    SERVER_WG_PUBFILE
)
missing=()
for v in "${required_vars[@]}"; do
    if [ -z "${!v:-}" ]; then
        missing+=("$v")
    fi
done
if [ "${#missing[@]}" -ne 0 ]; then
    echo "Error: Missing required environment variables: ${missing[*]}" >&2
    echo "Copy '$ENV_FILE.example' to '$ENV_FILE' and fill values, or set variables in the environment." >&2
    exit 1
fi

# === Preflight checks ===
for cmd in wg wg-quick scp ssh md5sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command '$cmd' not found" >&2
        exit 1
    fi
done

# Cleanup function
cleanup() {
    echo "Cleanup: bringing down WireGuard interface"
    wg-quick down wg0 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Clean up any existing setup first
echo "Cleaning up any existing setup..."
cleanup
sleep 1

mkdir -p /etc/wireguard

# === Get or create server WireGuard keys ===
echo "Getting server WireGuard public key..."
SERVER_PUB=$(ssh -p $SSH_PORT -o ConnectTimeout=10 "$SSH_USER@$SERVER_SSH_IP" "
    mkdir -p /etc/wireguard
    if [ ! -f $SERVER_WG_KEYFILE ]; then
        wg genkey > $SERVER_WG_KEYFILE
        chmod 600 $SERVER_WG_KEYFILE
        wg pubkey < $SERVER_WG_KEYFILE > $SERVER_WG_PUBFILE
    fi
    cat $SERVER_WG_PUBFILE
" 2>/dev/null)

if [ -z "$SERVER_PUB" ]; then
    echo "Error: Failed to get server public key" >&2
    exit 1
fi

echo "Server public key: $SERVER_PUB"

# === Generate client WireGuard keypair ===
keyfile="/etc/wireguard/wg0.key"
pubfile="/etc/wireguard/wg0.pub"
if [ ! -f "$keyfile" ]; then
    echo "Generating WireGuard keypair for client"
    wg genkey > "$keyfile"
    chmod 600 "$keyfile"
    wg pubkey < "$keyfile" > "$pubfile"
else
    echo "Using existing WireGuard keypair"
fi

CLIENT_PRIV=$(cat "$keyfile")
CLIENT_PUB=$(cat "$pubfile")

echo "Client public key: $CLIENT_PUB"

# === Create client WireGuard config ===
cat > "/etc/wireguard/wg0.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = $CLIENT_TUNNEL_IP/24
ListenPort = $WG_PORT

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_SSH_IP:$WG_PORT
AllowedIPs = 10.10.10.0/24
PersistentKeepalive = 25
EOF

echo "Bringing up WireGuard interface wg0"
wg-quick up wg0

echo "Waiting for WireGuard handshake..."
sleep 3

# === Generate server script ===
echo "Generating server configuration..."
TMP_LOCAL="/tmp/wireguard-server.sh.$$"
cat > "$TMP_LOCAL" <<'SERVEREOF'
#!/bin/bash
set -euo pipefail

SERVER_WG_KEYFILE="__SERVER_WG_KEYFILE__"
CLIENT_PUB="__CLIENT_PUB__"
CLIENT_TUNNEL_IP="__CLIENT_TUNNEL_IP__"
SERVER_TUNNEL_IP="__SERVER_TUNNEL_IP__"
ADDITIONAL_IP="__ADDITIONAL_IP__"
WG_PORT="__WG_PORT__"

cleanup() {
    echo "Server cleanup..."
    
    # Remove iptables rules
    iptables -t nat -D PREROUTING -d $ADDITIONAL_IP -j DNAT --to-destination $CLIENT_TUNNEL_IP 2>/dev/null || true
    iptables -t nat -D POSTROUTING -d $CLIENT_TUNNEL_IP -j SNAT --to-source $SERVER_TUNNEL_IP 2>/dev/null || true
    
    wg-quick down wg0 2>/dev/null || true
}

cleanup
trap cleanup INT TERM

echo "Creating server WireGuard configuration..."
cat > /etc/wireguard/wg0.conf <<WGCONF
[Interface]
PrivateKey = $(cat $SERVER_WG_KEYFILE)
Address = $SERVER_TUNNEL_IP/24
ListenPort = $WG_PORT
SaveConfig = false

# Enable IP forwarding
PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = sysctl -w net.ipv6.conf.all.forwarding=1

# Forward ALL traffic to Additional IP through tunnel to client
# SNAT ensures replies come back through the tunnel
PostUp = iptables -t nat -A PREROUTING -d $ADDITIONAL_IP -j DNAT --to-destination $CLIENT_TUNNEL_IP
PostUp = iptables -t nat -A POSTROUTING -d $CLIENT_TUNNEL_IP -j SNAT --to-source $SERVER_TUNNEL_IP

PostDown = iptables -t nat -D PREROUTING -d $ADDITIONAL_IP -j DNAT --to-destination $CLIENT_TUNNEL_IP
PostDown = iptables -t nat -D POSTROUTING -d $CLIENT_TUNNEL_IP -j SNAT --to-source $SERVER_TUNNEL_IP

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.10.10.0/24
PersistentKeepalive = 25
WGCONF

echo "Bringing up WireGuard interface..."
wg-quick up wg0

echo ""
echo "Server configuration complete!"
echo "Testing tunnel connectivity..."
sleep 2

if ping -c 2 -W 2 $CLIENT_TUNNEL_IP; then
    echo "✓ Tunnel is UP! Can reach client at $CLIENT_TUNNEL_IP"
else
    echo "✗ Cannot reach client at $CLIENT_TUNNEL_IP"
    echo "Showing WireGuard status:"
    wg show
fi

echo ""
echo "=== Server Summary ==="
echo "- Tunnel IP: $SERVER_TUNNEL_IP"
echo "- Client IP: $CLIENT_TUNNEL_IP"
echo "- Additional IP $ADDITIONAL_IP now forwards to client"
echo ""

# Keep running
while true; do
    sleep 60
done
SERVEREOF

# Replace placeholders
sed -i "s|__SERVER_WG_KEYFILE__|$SERVER_WG_KEYFILE|g" "$TMP_LOCAL"
sed -i "s|__CLIENT_PUB__|$CLIENT_PUB|g" "$TMP_LOCAL"
sed -i "s|__CLIENT_TUNNEL_IP__|$CLIENT_TUNNEL_IP|g" "$TMP_LOCAL"
sed -i "s|__SERVER_TUNNEL_IP__|$SERVER_TUNNEL_IP|g" "$TMP_LOCAL"
sed -i "s|__ADDITIONAL_IP__|$ADDITIONAL_IP|g" "$TMP_LOCAL"
sed -i "s|__WG_PORT__|$WG_PORT|g" "$TMP_LOCAL"

# Calculate checksum of new script
NEW_CHECKSUM=$(md5sum "$TMP_LOCAL" | awk '{print $1}')

# Check if server script needs updating
echo "Checking if server configuration needs updating..."
CURRENT_CHECKSUM=$(ssh -p $SSH_PORT -o ConnectTimeout=10 "$SSH_USER@$SERVER_SSH_IP" "
    if [ -f $REMOTE_SCRIPT ]; then
        md5sum $REMOTE_SCRIPT | awk '{print \$1}'
    else
        echo 'none'
    fi
" 2>/dev/null)

NEEDS_UPDATE=false
if [ "$CURRENT_CHECKSUM" != "$NEW_CHECKSUM" ]; then
    echo "Server configuration changed (checksum mismatch)"
    NEEDS_UPDATE=true
else
    echo "Server configuration up-to-date"
fi

# Check if service exists
SERVICE_EXISTS=$(ssh -p $SSH_PORT -o ConnectTimeout=10 "$SSH_USER@$SERVER_SSH_IP" "
    [ -f /etc/systemd/system/$REMOTE_SERVICE ] && echo 'yes' || echo 'no'
" 2>/dev/null)

if [ "$SERVICE_EXISTS" != "yes" ]; then
    echo "Service file does not exist, will create it"
    NEEDS_UPDATE=true
fi

if [ "$NEEDS_UPDATE" = true ]; then
    echo "Deploying updated configuration to server..."
    
    scp -P $SSH_PORT -o ConnectTimeout=10 "$TMP_LOCAL" "$SSH_USER@$SERVER_SSH_IP:/tmp/wireguard-server.sh.$$" || {
        echo "Error: Failed to copy script to server"
        exit 1
    }

    echo "Installing and starting server configuration..."
    ssh -p $SSH_PORT -o ConnectTimeout=10 "$SSH_USER@$SERVER_SSH_IP" "
        mv /tmp/wireguard-server.sh.$$ $REMOTE_SCRIPT && \
        chmod +x $REMOTE_SCRIPT && \
        # Create systemd service if it doesn't exist
        if [ ! -f /etc/systemd/system/$REMOTE_SERVICE ]; then
            cat > /etc/systemd/system/$REMOTE_SERVICE <<SERVICEEOF
[Unit]
Description=WireGuard Server Reverse Tunnel
After=network.target

[Service]
Type=simple
ExecStart=$REMOTE_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF
            systemctl daemon-reload
            systemctl enable $REMOTE_SERVICE
        fi
        systemctl restart $REMOTE_SERVICE
    " || {
        echo "Error: Failed to configure server"
        exit 1
    }
    
    echo "✓ Server configuration deployed and service restarted"
else
    echo "Ensuring service is running..."
    ssh -p $SSH_PORT -o ConnectTimeout=10 "$SSH_USER@$SERVER_SSH_IP" "
        if ! systemctl is-active --quiet $REMOTE_SERVICE; then
            echo 'Service is not running, starting it...'
            systemctl start $REMOTE_SERVICE
        else
            echo 'Service is already running'
        fi
    " || {
        echo "Warning: Could not verify service status"
    }
fi

rm -f "$TMP_LOCAL"

WAIT_TIME=15

echo ""
echo "=== Deployment Complete ==="
echo "Waiting $WAIT_TIME seconds for tunnel to stabilize..."
echo ""

for i in $(seq $WAIT_TIME -1 1); do
    echo -ne "\rWaiting... $i seconds "
    sleep 1
done
echo ""

echo "Client WireGuard status:"
wg show wg0

echo ""
echo "Testing tunnel connectivity..."
if ping -c 3 -W 3 $SERVER_TUNNEL_IP 2>&1; then
    echo ""
    echo "✓ Tunnel is online!"
    echo ""
    echo "Traffic to $ADDITIONAL_IP will be forwarded to client at $CLIENT_TUNNEL_IP"
else
    echo ""
    echo "✗ Tunnel connectivity test failed"
    echo ""
    echo "Diagnostics:"
    wg show wg0
    echo ""
    echo "Check server logs:"
    echo "  ssh $SSH_USER@$SERVER_SSH_IP 'journalctl -u $REMOTE_SERVICE -n 50'"
fi

echo ""
echo "=== Setup Summary ==="
echo "- Client tunnel IP: $CLIENT_TUNNEL_IP"
echo "- Server tunnel IP: $SERVER_TUNNEL_IP"
echo "- Additional IP: $ADDITIONAL_IP"
echo "- WireGuard port: $WG_PORT"
echo ""
echo "Client will keep running. Press Ctrl+C to stop."

# Keep client running
while true; do
    # Check if tunnel is still up every 60 seconds
    if ! wg show wg0 &>/dev/null; then
        echo "WireGuard interface went down! Attempting to restart..."
        wg-quick up wg0 || true
    fi
    sleep 60
done
