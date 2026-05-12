# Deploying MCP Server on Ubuntu EC2 (Production Guide)

This guide walks you through hosting `mcp_server.py` persistently on an Ubuntu EC2 instance using `systemd`, Nginx as a reverse proxy, and optionally TLS via Let's Encrypt.

---

## Table of Contents

1. [Option A: Automated Setup via EC2 User Data (Recommended)](#option-a-automated-setup-via-ec2-user-data-recommended)
2. [Option B: Manual Step-by-Step Setup](#option-b-manual-step-by-step-setup)
   - [Launch & Connect to EC2](#1-launch--connect-to-ec2)
   - [Install Dependencies](#2-install-dependencies)
   - [Clone the Repo & Set Up Virtualenv](#3-clone-the-repo--set-up-virtualenv)
   - [Test the Server Manually](#4-test-the-server-manually)
   - [Create a systemd Service](#5-create-a-systemd-service)
   - [View Logs](#6-view-logs)
   - [Set Up Nginx as a Reverse Proxy](#7-set-up-nginx-as-a-reverse-proxy)
   - [Add TLS with Let's Encrypt](#8-add-tls-with-lets-encrypt)
   - [Updating the Server](#9-updating-the-server)
3. [Connecting from Your Client](#connecting-from-your-client)
4. [Best Practices Summary](#best-practices-summary)
5. [Architecture Overview](#architecture-overview)

---

## Option A: Automated Setup via EC2 User Data (Recommended)

You can fully automate the entire server setup by pasting the script below into the **User Data** field when launching your EC2 instance. It runs once on first boot and sets everything up — no SSH required for initial configuration.

### How to use it

1. Go to **AWS Console → EC2 → Launch Instance**
2. Choose **Ubuntu Server 22.04 LTS**
3. Under **Advanced Details → User Data**, paste the script below
4. Under **Security Group**, open these ports:

   | Port | Protocol | Source       | Purpose             |
   |------|----------|--------------|---------------------|
   | 22   | TCP      | Your IP only | SSH access          |
   | 80   | TCP      | 0.0.0.0/0    | HTTP (Nginx)        |
   | 443  | TCP      | 0.0.0.0/0    | HTTPS (optional)    |

   > **Do not open port 8000 publicly.** Nginx proxies to it internally.

5. Launch the instance. Setup completes automatically within ~2 minutes of boot.

### User Data Script

```bash
#!/bin/bash

# ── Log everything to /var/log/mcp-setup.log ──────────────────────────────────
LOG=/var/log/mcp-setup.log
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== MCP Server Setup Started ==="

# ── System update and package install ─────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >> "$LOG" 2>&1
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" >> "$LOG" 2>&1
apt-get install -y python3 python3-pip python3-venv git nginx >> "$LOG" 2>&1
log "Packages installed"

# ── Clone the repo ─────────────────────────────────────────────────────────────
git clone https://github.com/yeshwanthlm/Create-Custom-MCP-Server.git /opt/mcp-server >> "$LOG" 2>&1
chown -R ubuntu:ubuntu /opt/mcp-server
log "Repo cloned"

# ── Set up Python virtualenv and install dependencies ─────────────────────────
sudo -u ubuntu python3 -m venv /opt/mcp-server/.venv >> "$LOG" 2>&1
sudo -u ubuntu /opt/mcp-server/.venv/bin/pip install --upgrade pip >> "$LOG" 2>&1
sudo -u ubuntu /opt/mcp-server/.venv/bin/pip install -r /opt/mcp-server/requirements.txt >> "$LOG" 2>&1
log "Python dependencies installed"

# ── Create systemd service ─────────────────────────────────────────────────────
cat > /etc/systemd/system/mcp-server.service << 'SYSTEMD'
[Unit]
Description=Custom MCP Calculator Server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/mcp-server
ExecStart=/opt/mcp-server/.venv/bin/python mcp_server.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload >> "$LOG" 2>&1
systemctl enable mcp-server >> "$LOG" 2>&1
systemctl start mcp-server >> "$LOG" 2>&1
log "systemd service started"

# ── Get the public IP of this instance (IMDSv2) ───────────────────────────────
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
log "Public IP: $PUBLIC_IP"

# ── Configure Nginx as reverse proxy ──────────────────────────────────────────
# Note: all Nginx variables ($remote_addr etc.) must be escaped with \$
# Use a quoted heredoc tag (NGINX) to prevent shell from expanding them
cat > /etc/nginx/sites-available/mcp-server << NGINX
server {
    listen 80;
    server_name ${PUBLIC_IP};

    location /mcp {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host localhost;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
    }
}
NGINX

# Enable the site and remove the default
ln -sf /etc/nginx/sites-available/mcp-server /etc/nginx/sites-enabled/mcp-server
rm -f /etc/nginx/sites-enabled/default

nginx -t >> "$LOG" 2>&1
systemctl enable nginx >> "$LOG" 2>&1
systemctl restart nginx >> "$LOG" 2>&1
log "Nginx configured and started"

log "=== MCP Server Setup Complete ==="
log "=== Server available at: http://${PUBLIC_IP}/mcp ==="
```

### Verify the setup after launch

SSH in and check:

```bash
# Check setup log
cat /var/log/mcp-setup.log

# Check MCP server status
sudo systemctl status mcp-server

# Check Nginx status
sudo systemctl status nginx

# Confirm port 8000 is listening
ss -tlnp | grep 8000

# Test the endpoint (expect 406 Not Acceptable — that means it's working)
curl -v http://localhost:8000/mcp
```

---

## Option B: Manual Step-by-Step Setup

Follow this if you prefer to set things up yourself or need to troubleshoot.

### 1. Launch & Connect to EC2

1. Go to **AWS Console → EC2 → Launch Instance**
2. Choose **Ubuntu Server 22.04 LTS**
3. Select an instance type (e.g., `t3.micro` for light workloads)
4. Open these Security Group inbound rules:

   | Port | Protocol | Source       | Purpose          |
   |------|----------|--------------|------------------|
   | 22   | TCP      | Your IP only | SSH access       |
   | 80   | TCP      | 0.0.0.0/0    | HTTP (Nginx)     |
   | 443  | TCP      | 0.0.0.0/0    | HTTPS (optional) |

5. Connect via SSH:

```bash
chmod 400 your-key.pem
ssh -i your-key.pem ubuntu@<your-ec2-public-ip>
```

---

### 2. Install Dependencies

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install python3 python3-pip python3-venv git nginx -y
```

---

### 3. Clone the Repo & Set Up Virtualenv

```bash
cd /opt
sudo git clone https://github.com/yeshwanthlm/Create-Custom-MCP-Server.git mcp-server
sudo chown -R ubuntu:ubuntu /opt/mcp-server

cd /opt/mcp-server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

---

### 4. Test the Server Manually

```bash
source /opt/mcp-server/.venv/bin/activate
python /opt/mcp-server/mcp_server.py
```

FastMCP will start and listen on `http://localhost:8000`. Press `Ctrl+C` to stop it, then proceed.

---

### 5. Create a systemd Service

```bash
sudo nano /etc/systemd/system/mcp-server.service
```

```ini
[Unit]
Description=Custom MCP Calculator Server
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/opt/mcp-server
ExecStart=/opt/mcp-server/.venv/bin/python mcp_server.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable mcp-server
sudo systemctl start mcp-server
sudo systemctl status mcp-server
```

**Useful commands:**

```bash
sudo systemctl stop mcp-server      # Stop
sudo systemctl restart mcp-server   # Restart
sudo systemctl disable mcp-server   # Disable auto-start
```

---

### 6. View Logs

```bash
sudo journalctl -u mcp-server -f        # Live logs
sudo journalctl -u mcp-server -n 100    # Last 100 lines
sudo journalctl -u mcp-server -b        # Since last boot
```

---

### 7. Set Up Nginx as a Reverse Proxy

> **Important Nginx config notes (learned from production):**
> - Use `location /mcp` (prefix match, no trailing slash) — not `location /mcp/`
> - Use `proxy_pass http://127.0.0.1:8000` (no path suffix) so Nginx forwards the original path as-is
> - Set `proxy_set_header Host localhost` — FastMCP rejects requests with an IP in the Host header (`421 Misdirected Request`)
> - Set `proxy_buffering off` — required for streamable-http / SSE to work correctly

```bash
sudo nano /etc/nginx/sites-available/mcp-server
```

```nginx
server {
    listen 80;
    server_name <your-ec2-public-ip>;

    location /mcp {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host localhost;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/mcp-server /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default   # remove default site
sudo nginx -t
sudo systemctl restart nginx
```

**Verify it's working** (expect `406 Not Acceptable` — this is correct, it means FastMCP is reachable):

```bash
curl -v http://<your-ec2-public-ip>/mcp
```

---

### 8. Add TLS with Let's Encrypt

> Requires a domain name with an A record pointing to your EC2 public IP.

```bash
sudo apt install certbot python3-certbot-nginx -y
sudo certbot --nginx -d your-domain.com
```

Certbot will obtain a certificate, update Nginx to redirect HTTP → HTTPS, and set up auto-renewal.

```bash
# Verify auto-renewal
sudo certbot renew --dry-run
```

---

### 9. Updating the Server

```bash
cd /opt/mcp-server
git pull
source .venv/bin/activate
pip install -r requirements.txt       # only needed if requirements changed
sudo systemctl restart mcp-server
sudo systemctl status mcp-server
```

---

## Connecting from Your Client

Once the server is running, use this in your notebook or script. Note: **no trailing slash** on the URL.

```python
from mcp.client.streamable_http import streamablehttp_client
from strands import Agent
from strands.tools.mcp.mcp_client import MCPClient

def create_streamable_http_transport():
    return streamablehttp_client("http://<your-ec2-public-ip>/mcp")  # no trailing slash

mcp_client = MCPClient(create_streamable_http_transport)

with mcp_client:
    tools = mcp_client.list_tools_sync()
    agent = Agent(tools=tools)
    response = agent("What is 125 plus 375?")
```

---

## Best Practices Summary

| Practice | Reason |
|---|---|
| Use `systemd` over `nohup` / `screen` | Auto-restart on crash, starts on boot, centralized logging |
| Run as non-root user (`ubuntu`) | Limits damage if the process is ever compromised |
| Install app under `/opt` with a virtualenv | Isolated dependencies, clean separation from system Python |
| Use Nginx as a reverse proxy | Hides internal port, handles TLS, enables rate limiting |
| Keep port 8000 closed in Security Group | Only Nginx (on localhost) should reach FastMCP directly |
| `proxy_set_header Host localhost` | Prevents FastMCP `421 Misdirected Request` errors |
| `location /mcp` prefix match in Nginx | Covers all MCP sub-paths including session IDs |
| `proxy_pass` without a path suffix | Nginx forwards the original path as-is, avoids redirect loops |
| No trailing slash in client URL | FastMCP redirects `/mcp/` → `/mcp`; MCP client doesn't follow redirects |
| `proxy_buffering off` in Nginx | Required for streamable-http / SSE to work correctly |
| Enable TLS via Let's Encrypt | Encrypts all traffic; free and auto-renewing |
| Restrict SSH (port 22) to your IP | Reduces attack surface on the instance |

---

## Architecture Overview

```
Internet
    │
    ▼
[ EC2 Security Group ]
  Port 80 / 443 open
  Port 8000 closed (internal only)
    │
    ▼
[ Nginx (reverse proxy) ]
  server_name: EC2 public IP
  location /mcp → proxy_pass localhost:8000
  Host header rewritten to: localhost
    │
    ▼ 127.0.0.1:8000
[ FastMCP Server (mcp_server.py) ]
  Managed by systemd
  Runs as 'ubuntu' user
  Auto-restarts on failure
```
