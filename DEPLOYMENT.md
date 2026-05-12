# Deploying MCP Server on Ubuntu EC2 (Production Guide)

This guide walks you through hosting `mcp_server.py` persistently on an Ubuntu EC2 instance using `systemd`, Nginx as a reverse proxy, and TLS via Let's Encrypt.

---

## Table of Contents

1. [Launch & Connect to EC2](#1-launch--connect-to-ec2)
2. [Install Dependencies](#2-install-dependencies)
3. [Clone the Repo & Set Up Virtualenv](#3-clone-the-repo--set-up-virtualenv)
4. [Test the Server Manually](#4-test-the-server-manually)
5. [Create a systemd Service](#5-create-a-systemd-service)
6. [View Logs](#6-view-logs)
7. [Set Up Nginx as a Reverse Proxy](#7-set-up-nginx-as-a-reverse-proxy)
8. [Add TLS with Let's Encrypt](#8-add-tls-with-lets-encrypt)
9. [Updating the Server](#9-updating-the-server)
10. [Best Practices Summary](#10-best-practices-summary)

---

## 1. Launch & Connect to EC2

1. Go to the **AWS Console → EC2 → Launch Instance**.
2. Choose **Ubuntu Server 22.04 LTS** as the AMI.
3. Select an instance type (e.g., `t3.micro` for light workloads).
4. Under **Security Group**, add the following inbound rules:

   | Port | Protocol | Source          | Purpose              |
   |------|----------|-----------------|----------------------|
   | 22   | TCP      | Your IP only    | SSH access           |
   | 80   | TCP      | 0.0.0.0/0       | HTTP (Nginx)         |
   | 443  | TCP      | 0.0.0.0/0       | HTTPS (Nginx + TLS)  |

   > **Do not open port 8000 publicly.** Nginx will proxy traffic to it internally.

5. Download your `.pem` key pair and connect:

```bash
chmod 400 your-key.pem
ssh -i your-key.pem ubuntu@<your-ec2-public-ip>
```

---

## 2. Install Dependencies

Once connected to the instance, update the system and install the required packages:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install python3 python3-pip python3-venv git nginx -y
```

---

## 3. Clone the Repo & Set Up Virtualenv

Install the application under `/opt` — the standard Linux location for self-contained apps:

```bash
cd /opt
sudo git clone https://github.com/yeshwanthlm/Create-Custom-MCP-Server.git mcp-server

# Give your user ownership so you don't need sudo for every command
sudo chown -R ubuntu:ubuntu /opt/mcp-server

cd /opt/mcp-server

# Create an isolated Python environment
python3 -m venv .venv
source .venv/bin/activate

# Install project dependencies
pip install -r requirements.txt
```

---

## 4. Test the Server Manually

Before setting up systemd, confirm the server starts without errors:

```bash
source /opt/mcp-server/.venv/bin/activate
python /opt/mcp-server/mcp_server.py
```

You should see FastMCP start and listen on `http://localhost:8000/mcp/`.

Press `Ctrl+C` to stop it, then proceed to the next step.

---

## 5. Create a systemd Service

`systemd` keeps the server running after you close the terminal, restarts it on failure, and starts it automatically on every reboot.

### Create the service file

```bash
sudo nano /etc/systemd/system/mcp-server.service
```

Paste the following content:

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

# Security hardening
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Enable and start the service

```bash
# Reload systemd to pick up the new service file
sudo systemctl daemon-reload

# Enable the service to start automatically on boot
sudo systemctl enable mcp-server

# Start the service now
sudo systemctl start mcp-server

# Verify it is running
sudo systemctl status mcp-server
```

Expected output:

```
● mcp-server.service - Custom MCP Calculator Server
     Loaded: loaded (/etc/systemd/system/mcp-server.service; enabled)
     Active: active (running) since ...
```

### Useful service management commands

```bash
sudo systemctl stop mcp-server      # Stop the server
sudo systemctl restart mcp-server   # Restart the server
sudo systemctl disable mcp-server   # Disable auto-start on boot
```

---

## 6. View Logs

All output from the server is captured by `journald`:

```bash
# Stream live logs
sudo journalctl -u mcp-server -f

# View the last 100 lines
sudo journalctl -u mcp-server -n 100

# View logs since last boot
sudo journalctl -u mcp-server -b
```

---

## 7. Set Up Nginx as a Reverse Proxy

Nginx sits in front of your MCP server, handles incoming HTTP/HTTPS traffic, and forwards requests to FastMCP running on `localhost:8000`. This keeps port 8000 closed to the outside world.

### Create the Nginx config

```bash
sudo nano /etc/nginx/sites-available/mcp-server
```

Paste the following:

```nginx
server {
    listen 80;
    server_name your-domain-or-ip;

    location /mcp/ {
        proxy_pass http://127.0.0.1:8000/mcp/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # Required for streamable-http (SSE / chunked transfer)
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
    }
}
```

> Replace `your-domain-or-ip` with your actual domain name or EC2 public IP.

### Enable the config and restart Nginx

```bash
# Create a symlink to enable the site
sudo ln -s /etc/nginx/sites-available/mcp-server /etc/nginx/sites-enabled/

# Test the config for syntax errors
sudo nginx -t

# Apply the changes
sudo systemctl restart nginx
```

Your MCP server is now accessible at:

```
http://your-domain-or-ip/mcp/
```

---

## 8. Add TLS with Let's Encrypt

> **Requires a domain name** pointed at your EC2 instance's public IP via an A record.

TLS encrypts all traffic between clients and your server. Certbot automates certificate issuance and renewal.

```bash
sudo apt install certbot python3-certbot-nginx -y

# Issue a certificate and auto-configure Nginx
sudo certbot --nginx -d your-domain.com
```

Follow the prompts. Certbot will:
- Obtain a free certificate from Let's Encrypt
- Update your Nginx config to redirect HTTP → HTTPS
- Set up automatic renewal via a cron job

Your MCP server will now be available at:

```
https://your-domain.com/mcp/
```

### Verify auto-renewal

```bash
sudo certbot renew --dry-run
```

---

## 9. Updating the Server

When you push new code to the repo, pull and restart on the server:

```bash
cd /opt/mcp-server
git pull

# Activate the virtualenv and update dependencies if requirements.txt changed
source .venv/bin/activate
pip install -r requirements.txt

# Restart the service to apply changes
sudo systemctl restart mcp-server

# Confirm it came back up
sudo systemctl status mcp-server
```

---

## 10. Best Practices Summary

| Practice | Reason |
|---|---|
| Use `systemd` over `nohup` / `screen` | Auto-restart on crash, starts on boot, centralized logging |
| Run as non-root user (`ubuntu`) | Limits damage if the process is ever compromised |
| Install app under `/opt` with a virtualenv | Isolated dependencies, clean separation from system Python |
| Use Nginx as a reverse proxy | TLS termination, hides internal port, enables rate limiting |
| Keep port 8000 closed in Security Group | Only Nginx (on localhost) should talk to FastMCP directly |
| Enable TLS via Let's Encrypt | Encrypts all traffic; free and auto-renewing |
| Set `Restart=on-failure` in systemd | Server recovers automatically without manual intervention |
| Use `proxy_buffering off` in Nginx | Required for streamable-http / SSE to work correctly |
| Restrict SSH (port 22) to your IP | Reduces attack surface on the instance |

---

## Architecture Overview

```
Internet
    │
    ▼
[ EC2 Security Group ]
  Port 80 / 443 open
    │
    ▼
[ Nginx (reverse proxy) ]
  Handles TLS, forwards /mcp/ traffic
    │
    ▼ localhost:8000
[ FastMCP Server (mcp_server.py) ]
  Managed by systemd
  Runs as 'ubuntu' user
```
