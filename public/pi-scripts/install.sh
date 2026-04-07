#!/bin/bash
# Pi Dashboard — Installation script optimized for Pi Zero 2 W (512MB RAM)
# Run: curl -sL <url>/pi-scripts/install.sh | bash -s -- <repo-url>
set -e

REPO_URL="${1:-https://github.com/YOUR_USER/pi-dashboard.git}"
DASHBOARD_DIR="$HOME/pi-dashboard"
NGINX_DIR="/var/www/pi-dashboard"
API_PORT=8585

# Limit Node.js memory for 512MB Pi
export NODE_OPTIONS="--max-old-space-size=256"

echo "=== Pi Dashboard Installer (Pi Zero 2 W optimized) ==="

# 1. Ensure swap exists (critical for npm on 512MB)
echo "[1/7] Checking swap..."
if [ "$(swapon --show | wc -l)" -lt 2 ]; then
  echo "  Setting up 512MB swap file..."
  sudo dphys-swapfile swapoff 2>/dev/null || true
  sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile 2>/dev/null || {
    # Fallback: manual swap
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
echo "[2/7] Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq nginx socat git bc

# Install Node.js 20 if missing (use LTS for stability)
if ! command -v node &>/dev/null; then
  echo "  Installing Node.js 20 LTS..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y -qq nodejs
fi
echo "  Node: $(node -v), npm: $(npm -v)"

# 3. Clone dashboard (shallow to save disk + RAM)
echo "[3/7] Cloning dashboard..."
if [ -d "$DASHBOARD_DIR" ]; then
  cd "$DASHBOARD_DIR" && git pull --quiet
else
  git clone --depth 1 "$REPO_URL" "$DASHBOARD_DIR"
  cd "$DASHBOARD_DIR"
fi

# 4. Build with resource limits
echo "[4/7] Building (this may take a few minutes on Pi Zero 2)..."
nice -n 15 ionice -c 3 npm install --production --no-audit --no-fund
nice -n 15 ionice -c 3 npm run build
sudo mkdir -p "$NGINX_DIR"
sudo cp -r dist/* "$NGINX_DIR/"

# Clean npm cache to free disk
npm cache clean --force 2>/dev/null || true

# 5. Configure Nginx (with gzip for faster loads)
echo "[5/7] Configuring Nginx..."
sudo tee /etc/nginx/sites-available/pi-dashboard > /dev/null << 'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/pi-dashboard;
    index index.html;
    server_name _;

    # Gzip compression — saves bandwidth on Pi's slow WiFi
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml;
    gzip_min_length 256;
    gzip_vary on;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Cache static assets aggressively
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
NGINX

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/pi-dashboard /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# Optimize Nginx for low-memory system
sudo tee /etc/nginx/conf.d/pi-optimize.conf > /dev/null << 'CONF'
# Pi Zero 2 W optimizations
worker_processes 2;
worker_connections 64;
keepalive_timeout 30;
client_body_buffer_size 8k;
client_max_body_size 1m;
CONF
sudo nginx -t && sudo systemctl reload nginx

# 6. Set up API service with resource limits
echo "[6/6] Setting up API service..."
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
# Pin dashboard + API to core 0 (cores 1-3 reserved for apps)
CPUAffinity=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now pi-dashboard-api.service

# Disable all auto-update timers (everything is updated manually via dashboard)
for timer in lotus-light-update cast-away-update sonos-proxy-update pi-dashboard-update; do
  if systemctl is-enabled "${timer}.timer" &>/dev/null; then
    echo "  Disabling ${timer}.timer (use dashboard for manual updates)"
    sudo systemctl disable --now "${timer}.timer" 2>/dev/null || true
  fi
done

# Allow passwordless systemctl for the API to start/stop services
echo "  Setting up sudoers for service control..."
sudo tee /etc/sudoers.d/pi-dashboard > /dev/null << EOF
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start lotus-light.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop lotus-light.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart lotus-light.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start cast-away.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop cast-away.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart cast-away.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start sonos-proxy.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop sonos-proxy.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart sonos-proxy.service
EOF
sudo chmod 440 /etc/sudoers.d/pi-dashboard

# Pin app services to dedicated CPU cores
echo "  Setting up CPU core pinning..."
echo "  Core 0: System + Dashboard API"
echo "  Core 1: Lotus Lantern"
echo "  Core 2: Cast Away"
echo "  Core 3: Sonos Gateway"

for svc_core in "lotus-light:1" "cast-away:2" "sonos-proxy:3"; do
  svc="${svc_core%%:*}"
  core="${svc_core##*:}"
  override_dir="/etc/systemd/system/${svc}.service.d"
  if systemctl cat "${svc}.service" &>/dev/null; then
    sudo mkdir -p "$override_dir"
    sudo tee "$override_dir/cpu-pin.conf" > /dev/null << OVERRIDE
[Service]
CPUAffinity=${core}
OVERRIDE
    echo "  Pinned ${svc}.service → core ${core}"
  fi
done

sudo systemctl daemon-reload

echo ""
echo "=== Done! ==="
echo "Dashboard:   http://$(hostname -I | awk '{print $1}')"
echo "API:         port $API_PORT"
echo "Updates:     all manual via dashboard UI"
echo "CPU layout:  core 0=system, 1=lotus, 2=castaway, 3=sonos"
echo "Swap:        $(free -m | awk '/^Swap:/{print $2}')MB"
echo "RAM free:    $(free -m | awk '/^Mem:/{print $7}')MB available"
echo ""
echo "Resource footprint:"
echo "  Nginx:  ~5MB RAM"
echo "  API:    ~2MB RAM (shell + socat)"
echo "  Total:  ~7MB idle"
