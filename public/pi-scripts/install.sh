#!/bin/bash
# Pi Dashboard — Installation script optimized for Pi Zero 2 W (512MB RAM)
# Run: curl -sL <url>/pi-scripts/install.sh | bash -s -- <repo-url>
set -e

REPO_URL="${1:-https://github.com/raagerrd-ship-it/pi-control-center.git}"
DASHBOARD_DIR="$HOME/pi-dashboard"
NGINX_DIR="/var/www/pi-dashboard"
API_PORT=8585

export NODE_OPTIONS="--max-old-space-size=256"

echo "=== Pi Dashboard Installer (Pi Zero 2 W optimized) ==="

# 1. Ensure swap exists (critical for npm on 512MB)
echo "[1/6] Checking swap..."
if [ "$(swapon --show | wc -l)" -lt 2 ]; then
  echo "  Setting up 512MB swap file..."
  sudo dphys-swapfile swapoff 2>/dev/null || true
  sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile 2>/dev/null || {
    sudo fallocate -l 512M /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=512
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  }
  sudo dphys-swapfile setup 2>/dev/null && sudo dphys-swapfile swapon 2>/dev/null || true
  echo "  Swap: $(free -m | awk '/^Swap:/{print $2}')MB"
fi

# 2. Install dependencies
echo "[2/6] Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq nginx socat git

if ! command -v node &>/dev/null; then
  echo "  Installing Node.js 20 LTS..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y -qq nodejs
fi
echo "  Node: $(node -v), npm: $(npm -v)"

# 3. Clone dashboard (shallow)
echo "[3/6] Cloning dashboard..."
if [ -d "$DASHBOARD_DIR" ]; then
  cd "$DASHBOARD_DIR" && git pull --quiet
else
  git clone --depth 1 "$REPO_URL" "$DASHBOARD_DIR"
  cd "$DASHBOARD_DIR"
fi

# 4. Build with resource limits
echo "[4/6] Building (this may take a few minutes on Pi Zero 2)..."
nice -n 15 ionice -c 3 npm install --no-audit --no-fund
npx -y update-browserslist-db@latest 2>/dev/null || true
nice -n 15 ionice -c 3 npm run build
sudo mkdir -p "$NGINX_DIR"
sudo cp -r dist/* "$NGINX_DIR/"
rm -rf node_modules
npm cache clean --force 2>/dev/null || true

# 5. Configure Nginx (optimized for Pi Zero 2 W)
echo "[5/6] Configuring Nginx..."

# Main nginx.conf optimized for low-memory
sudo tee /etc/nginx/nginx.conf > /dev/null << 'CONF'
user www-data;
worker_processes 2;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 64;
    multi_accept off;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log off;
    error_log /var/log/nginx/error.log crit;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml;
    gzip_min_length 256;
    gzip_vary on;

    keepalive_timeout 30;
    client_body_buffer_size 8k;
    client_max_body_size 1m;

    include /etc/nginx/sites-enabled/*;
}
CONF

sudo tee /etc/nginx/sites-available/pi-dashboard > /dev/null << 'SITE'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/pi-dashboard;
    index index.html;
    server_name _;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
SITE

sudo rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/pi-optimize.conf
sudo ln -sf /etc/nginx/sites-available/pi-dashboard /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# 6. Set up API service + security + CPU pinning
echo "[6/6] Setting up API service + CPU pinning..."
chmod +x "$DASHBOARD_DIR/public/pi-scripts/pi-dashboard-api.sh"

sudo tee /etc/systemd/system/pi-dashboard-api.service > /dev/null << EOF
[Unit]
Description=Pi Dashboard API
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$DASHBOARD_DIR/public/pi-scripts/pi-dashboard-api.sh $API_PORT
Restart=always
RestartSec=10
MemoryMax=30M
Nice=10
CPUAffinity=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now pi-dashboard-api.service

# Disable any legacy auto-update timers
for timer in $(systemctl list-timers --all --no-legend 2>/dev/null | awk '/-update\.timer/{print $NF}'); do
  sudo systemctl disable --now "$timer" 2>/dev/null && echo "  Disabled $timer" || true
done

# Sudoers — allow dashboard API to manage any systemd service
sudo tee /etc/sudoers.d/pi-dashboard > /dev/null << EOF
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start *
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop *
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart *
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable *
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl disable *
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
EOF
sudo chmod 440 /etc/sudoers.d/pi-dashboard

# Pin Nginx + API to core 0
sudo mkdir -p /etc/systemd/system/nginx.service.d
sudo tee /etc/systemd/system/nginx.service.d/cpu-pin.conf > /dev/null << 'OVER'
[Service]
CPUAffinity=0
OVER

sudo systemctl daemon-reload

echo ""
echo "=== Done! ==="
echo "Dashboard:   http://$(hostname -I | awk '{print $1}')"
echo "API:         port $API_PORT"
echo "Updates:     all manual via dashboard UI"
echo "CPU layout:  core 0=system, cores 1-3 assigned per service"
echo "Swap:        $(free -m | awk '/^Swap:/{print $2}')MB"
echo "RAM free:    $(free -m | awk '/^Mem:/{print $7}')MB available"
echo ""
echo "Idle footprint: ~7MB (Nginx ~5MB + API ~2MB)"
