#!/bin/bash
# =============================================================================
# setup.sh — MCP Server Setup Script for Ubuntu EC2
#
# Run this script after SSHing into a fresh Ubuntu EC2 instance:
#   chmod +x setup.sh && ./setup.sh
#
# What it does:
#   1. Installs system dependencies (Python, Git, Nginx)
#   2. Clones the repo and sets up a Python virtualenv
#   3. Creates and starts a systemd service for the MCP server
#   4. Configures Nginx as a reverse proxy
# =============================================================================

set -euo pipefail

# ── Colours for output ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Colour

log()     { echo -e "${GREEN}[✔]${NC} $*"; }
info()    { echo -e "${BLUE}[→]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✘]${NC} $*"; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/yeshwanthlm/Create-Custom-MCP-Server.git"
APP_DIR="/opt/mcp-server"
SERVICE_NAME="mcp-server"
APP_USER="${SUDO_USER:-ubuntu}"

echo ""
echo "=============================================="
echo "   MCP Server Setup — Ubuntu EC2"
echo "=============================================="
echo ""

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Please run as root: sudo ./setup.sh"
fi

# ── Step 1: System packages ───────────────────────────────────────────────────
info "Step 1/6 — Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    git \
    nginx \
    curl
log "System packages installed"

# ── Step 2: Clone the repo ────────────────────────────────────────────────────
info "Step 2/6 — Cloning repository..."
if [[ -d "$APP_DIR" ]]; then
    warn "$APP_DIR already exists — pulling latest changes instead"
    git -C "$APP_DIR" pull
else
    git clone "$REPO_URL" "$APP_DIR"
fi
chown -R "$APP_USER":"$APP_USER" "$APP_DIR"
log "Repository ready at $APP_DIR"

# ── Step 3: Python virtualenv + dependencies ──────────────────────────────────
info "Step 3/6 — Setting up Python virtualenv..."
sudo -u "$APP_USER" python3 -m venv "$APP_DIR/.venv"
sudo -u "$APP_USER" "$APP_DIR/.venv/bin/pip" install --upgrade pip --quiet
sudo -u "$APP_USER" "$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt" --quiet
log "Python dependencies installed"

# ── Step 4: systemd service ───────────────────────────────────────────────────
info "Step 4/6 — Creating systemd service..."
cat > /etc/systemd/system/${SERVICE_NAME}.service << SYSTEMD
[Unit]
Description=Custom MCP Calculator Server
After=network.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/.venv/bin/python mcp_server.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# Wait for the server to start
sleep 3

if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "systemd service '$SERVICE_NAME' is running"
else
    error "Service failed to start. Check logs: sudo journalctl -u $SERVICE_NAME -n 50"
fi

# ── Step 5: Get public IP ─────────────────────────────────────────────────────
info "Step 5/6 — Detecting public IP..."

# Try IMDSv2 first (required on newer EC2 instances)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" --connect-timeout 2 || true)

if [[ -n "$TOKEN" ]]; then
    PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/public-ipv4 --connect-timeout 2 || true)
fi

# Fallback: IMDSv1
if [[ -z "${PUBLIC_IP:-}" ]]; then
    PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 \
        --connect-timeout 2 || true)
fi

# Fallback: external service
if [[ -z "${PUBLIC_IP:-}" ]]; then
    warn "EC2 metadata unavailable — trying external IP detection..."
    PUBLIC_IP=$(curl -s https://checkip.amazonaws.com --connect-timeout 5 || true)
fi

if [[ -z "${PUBLIC_IP:-}" ]]; then
    warn "Could not detect public IP automatically."
    read -rp "    Enter the public IP of this instance: " PUBLIC_IP
fi

log "Public IP: $PUBLIC_IP"

# ── Step 6: Nginx reverse proxy ───────────────────────────────────────────────
info "Step 6/6 — Configuring Nginx..."

cat > /etc/nginx/sites-available/${SERVICE_NAME} << NGINX
server {
    listen 80;
    server_name ${PUBLIC_IP};

    location /mcp {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host 127.0.0.1;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
    }
}
NGINX

# Enable site, remove default
ln -sf /etc/nginx/sites-available/${SERVICE_NAME} /etc/nginx/sites-enabled/${SERVICE_NAME}
rm -f /etc/nginx/sites-enabled/default

# Test and reload
nginx -t
systemctl enable nginx
systemctl restart nginx

if systemctl is-active --quiet nginx; then
    log "Nginx is running"
else
    error "Nginx failed to start. Check: sudo journalctl -u nginx -n 50"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo -e "   ${GREEN}Setup Complete!${NC}"
echo "=============================================="
echo ""
echo -e "  MCP Server URL : ${BLUE}http://${PUBLIC_IP}/mcp${NC}"
echo ""
echo "  Useful commands:"
echo "    sudo systemctl status $SERVICE_NAME     # Check server status"
echo "    sudo journalctl -u $SERVICE_NAME -f     # Live logs"
echo "    sudo systemctl restart $SERVICE_NAME    # Restart server"
echo ""
echo "  Test the endpoint (expect 406 — means it's working):"
echo "    curl -v http://${PUBLIC_IP}/mcp"
echo ""
echo "  Connect from your notebook:"
echo "    streamablehttp_client(\"http://${PUBLIC_IP}/mcp\")"
echo ""
