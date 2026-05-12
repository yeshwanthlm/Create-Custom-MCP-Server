# Deploying MCP Server on Ubuntu EC2 (Production Guide)

This guide walks you through hosting `mcp_server.py` persistently on an Ubuntu EC2 instance using `systemd`, Nginx as a reverse proxy, and optionally TLS via Let's Encrypt.

---

## Table of Contents

1. [Option A: Automated Setup Script (Recommended)](#option-a-automated-setup-script-recommended)
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

## Option A: Automated Setup Script (Recommended)

A single script — `setup.sh` — handles the entire setup. Run it once after SSHing into a fresh Ubuntu EC2 instance.

### Step 1 — Launch an EC2 instance

1. Go to **AWS Console → EC2 → Launch Instance**
2. Choose **Ubuntu Server 22.04 LTS**
3. Select an instance type (e.g., `t3.micro`)
4. Open these Security Group inbound rules:

   | Port | Protocol | Source       | Purpose          |
   |------|----------|--------------|------------------|
   | 22   | TCP      | Your IP only | SSH access       |
   | 80   | TCP      | 0.0.0.0/0    | HTTP (Nginx)     |
   | 443  | TCP      | 0.0.0.0/0    | HTTPS (optional) |

   > **Do not open port 8000 publicly.** Nginx proxies to it internally.

### Step 2 — SSH in and run the setup script

```bash
# Connect to your instance
ssh -i your-key.pem ubuntu@<your-ec2-public-ip>

# Clone the repo
git clone https://github.com/yeshwanthlm/Create-Custom-MCP-Server.git
cd Create-Custom-MCP-Server

# Run the setup script
chmod +x setup.sh
sudo ./setup.sh
```

The script runs interactively with coloured output and shows progress at each step. It takes about 2–3 minutes on a fresh instance.

### What the script does

| Step | Action |
|------|--------|
| 1 | Installs Python, Git, Nginx |
| 2 | Clones the repo to `/opt/mcp-server` |
| 3 | Creates a Python virtualenv and installs dependencies |
| 4 | Creates and starts a `systemd` service |
| 5 | Detects the EC2 public IP (IMDSv2 with fallbacks) |
| 6 | Configures Nginx as a reverse proxy and starts it |

### Expected output

```
==============================================
   MCP Server Setup — Ubuntu EC2
==============================================

[→] Step 1/6 — Installing system packages...
[✔] System packages installed
[→] Step 2/6 — Cloning repository...
[✔] Repository ready at /opt/mcp-server
[→] Step 3/6 — Setting up Python virtualenv...
[✔] Python dependencies installed
[→] Step 4/6 — Creating systemd service...
[✔] systemd service 'mcp-server' is running
[→] Step 5/6 — Detecting public IP...
[✔] Public IP: 1.2.3.4
[→] Step 6/6 — Configuring Nginx...
[✔] Nginx is running

==============================================
   Setup Complete!
==============================================

  MCP Server URL : http://1.2.3.4/mcp

  Useful commands:
    sudo systemctl status mcp-server
    sudo journalctl -u mcp-server -f
    sudo systemctl restart mcp-server

  Test the endpoint (expect 406 — means it's working):
    curl -v http://1.2.3.4/mcp

  Connect from your notebook:
    streamablehttp_client("http://1.2.3.4/mcp")
```

### Re-running the script

The script is idempotent — safe to re-run after a `git pull` to pick up changes:

```bash
cd Create-Custom-MCP-Server
git pull
sudo ./setup.sh
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
sudo git clone https://github.com/yeshwanthlm/Create-Custom-MCP-Server.git /opt/mcp-server
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

> **Important Nginx config notes:**
> - Use `location /mcp` (prefix match, no trailing slash)
> - Use `proxy_pass http://127.0.0.1:8000` with no path suffix — Nginx forwards the original path as-is
> - Set `proxy_set_header Host 127.0.0.1` — FastMCP validates the Host header and rejects anything it doesn't recognise
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
        proxy_set_header Host 127.0.0.1;
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
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
```

**Verify** (expect `406 Not Acceptable` — means FastMCP is reachable):

```bash
curl -v http://<your-ec2-public-ip>/mcp
```

---

### 8. Add TLS with Let's Encrypt

> Requires a domain name with an A record pointing to your EC2 public IP.

```bash
sudo apt install certbot python3-certbot-nginx -y
sudo certbot --nginx -d your-domain.com
sudo certbot renew --dry-run   # verify auto-renewal
```

---

### 9. Updating the Server

```bash
cd /opt/mcp-server
git pull
source .venv/bin/activate
pip install -r requirements.txt   # only if requirements changed
sudo systemctl restart mcp-server
sudo systemctl status mcp-server
```

---

## Connecting from Your Client

Use this in your notebook or script. **No trailing slash** on the URL.

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
| `proxy_set_header Host 127.0.0.1` | FastMCP validates Host header — must match its bound address |
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
  location /mcp → proxy_pass 127.0.0.1:8000
  Host header rewritten to: 127.0.0.1
    │
    ▼ 127.0.0.1:8000
[ FastMCP Server (mcp_server.py) ]
  Managed by systemd
  Runs as 'ubuntu' user
  Auto-restarts on failure
```
