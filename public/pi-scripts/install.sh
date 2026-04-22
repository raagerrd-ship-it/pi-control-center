#!/bin/bash
# Pi Control Center — Installation script optimized for Pi Zero 2 W (512MB RAM)
# Run: curl -sL <url>/pi-scripts/install.sh | bash -s -- <repo-url>
set -e

REPO_URL="${1:-https://github.com/raagerrd-ship-it/pi-control-center.git}"
DASHBOARD_DIR="$HOME/pi-control-center"
NGINX_DIR="/var/www/pi-control-center"
API_PORT=8585

export NODE_OPTIONS="--max-old-space-size=256"

echo "=== Pi Control Center Installer (Pi Zero 2 W optimized) ==="

ensure_node24() {
  local current major
  current=$(node -v 2>/dev/null || true)
  major=${current#v}; major=${major%%.*}
  if [ "$major" != "24" ]; then
    echo "  Installing PCC Node.js 24 LTS runtime..."
    curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
    sudo apt-get install -y -qq nodejs
  fi
}

# 1. Ensure swap exists (critical for npm on 512MB)
echo "[1/7] Checking swap..."
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
echo "[2/7] Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq nginx socat git jq bluez dbus build-essential python3 libudev-dev libusb-1.0-0-dev
sudo apt-get install -y -qq polkitd 2>/dev/null || sudo apt-get install -y -qq policykit-1 2>/dev/null || true

ensure_node24
echo "  Node: $(node -v), npm: $(npm -v)"

# 3. Enable lingering + BLE prerequisites
echo "[3/7] Enabling user service lingering + BLE prerequisites..."
sudo loginctl enable-linger "$USER"
sudo usermod -aG bluetooth "$USER" 2>/dev/null || true
sudo mkdir -p /etc/polkit-1/rules.d
sudo tee /etc/polkit-1/rules.d/49-allow-pi-bluez.rules > /dev/null <<'EOF'
polkit.addRule(function(action, subject) {
  if (subject.user == "pi" && action.id.indexOf("org.bluez.") == 0) {
    return polkit.Result.YES;
  }
});
EOF

if [ -f /etc/bluetooth/main.conf ]; then
  if sudo grep -q '^DisablePlugins=' /etc/bluetooth/main.conf; then
    sudo sed -i 's/^DisablePlugins=.*/DisablePlugins=pnat/' /etc/bluetooth/main.conf
  elif sudo grep -q '^\[General\]' /etc/bluetooth/main.conf; then
    sudo sed -i '/^\[General\]/a DisablePlugins=pnat' /etc/bluetooth/main.conf
  else
    printf '\n[General]\nDisablePlugins=pnat\n' | sudo tee -a /etc/bluetooth/main.conf > /dev/null
  fi
else
  printf '[General]\nDisablePlugins=pnat\n' | sudo tee /etc/bluetooth/main.conf > /dev/null
fi

sudo systemctl enable --now bluetooth 2>/dev/null || true
sudo systemctl restart bluetooth 2>/dev/null || true

# 4. Clone (shallow)
echo "[4/7] Cloning Pi Control Center..."
if [ -d "$DASHBOARD_DIR" ]; then
  cd "$DASHBOARD_DIR" && git pull --quiet
else
  git clone --depth 1 "$REPO_URL" "$DASHBOARD_DIR"
  cd "$DASHBOARD_DIR"
fi

# 5. Build with resource limits
echo "[5/7] Building (this may take a few minutes on Pi Zero 2)..."
nice -n 15 ionice -c 3 npm install --no-audit --no-fund
sudo chown -R "$USER:$USER" node_modules 2>/dev/null || true
npx -y update-browserslist-db@latest 2>/dev/null || true
nice -n 15 ionice -c 3 npm run build
sudo mkdir -p "$NGINX_DIR"
sudo cp -r dist/* "$NGINX_DIR/"
# Copy services.json to deployed location for API registry
[ -f "$DASHBOARD_DIR/public/services.json" ] && sudo cp "$DASHBOARD_DIR/public/services.json" "$NGINX_DIR/"
rm -rf node_modules
npm cache clean --force 2>/dev/null || true

# 6. Configure Nginx (optimized for low-memory)
echo "[6/7] Configuring Nginx..."

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

sudo tee /etc/nginx/sites-available/pi-control-center > /dev/null << 'SITE'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/pi-control-center;
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

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/pi-control-center /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# 7. Set up API service + CPU pinning + scoped sudoers
echo "[7/7] Setting up API service + permissions..."
chmod +x "$DASHBOARD_DIR/public/pi-scripts/pi-control-center-api.sh"

sudo tee /etc/systemd/system/pi-control-center-api.service > /dev/null << EOF
[Unit]
Description=Pi Control Center API
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$DASHBOARD_DIR/public/pi-scripts/pi-control-center-api.sh $API_PORT
Restart=always
RestartSec=10
MemoryMax=30M
Nice=10
CPUAffinity=0
AllowedCPUs=0

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now pi-control-center-api.service

# Disable any legacy auto-update timers
for timer in $(systemctl list-timers --all --no-legend 2>/dev/null | awk '/-update\.timer/{print $NF}'); do
  sudo systemctl disable --now "$timer" 2>/dev/null && echo "  Disabled $timer" || true
done

# Pin Nginx to core 0 (hard limit)
sudo mkdir -p /etc/systemd/system/nginx.service.d
sudo tee /etc/systemd/system/nginx.service.d/cpu-pin.conf > /dev/null << 'OVER'
[Service]
CPUAffinity=0
AllowedCPUs=0
OVER

# Scoped sudoers — passwordless operations required by all PCC-managed app installers
sudo tee /etc/sudoers.d/pi-control-center > /dev/null << EOF
$USER ALL=(ALL) NOPASSWD: /usr/bin/true
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start pi-control-center-api.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop pi-control-center-api.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart pi-control-center-api.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart nginx.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start *.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl --no-block start *.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop *.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl --no-block stop *.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl enable *.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl disable *.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl try-restart *.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart *.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /etc/pi-control-center
$USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /var/log/pi-control-center
$USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /var/lib/pi-control-center
$USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /var/lib/pi-control-center/apps
$USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /var/lib/pi-control-center/apps/*
$USER ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/pi-control-center/*
$USER ALL=(ALL) NOPASSWD: /usr/bin/chmod * /var/lib/pi-control-center/apps/*
$USER ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/systemd/system/*.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /var/www/pi-control-center
$USER ALL=(ALL) NOPASSWD: /usr/bin/cp -r *
$USER ALL=(ALL) NOPASSWD: /usr/bin/cp *
$USER ALL=(ALL) NOPASSWD: /usr/bin/install -m 755 *
$USER ALL=(ALL) NOPASSWD: /usr/bin/git clone *
$USER ALL=(ALL) NOPASSWD: /usr/bin/chown *
$USER ALL=(ALL) NOPASSWD: /usr/bin/ln -sf *
$USER ALL=(ALL) NOPASSWD: /usr/bin/mv /tmp/pi-control-center/* /etc/pi-control-center/*
$USER ALL=(ALL) NOPASSWD: /usr/bin/sed -i * /etc/systemd/system/*.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/rm -rf /opt/*
$USER ALL=(ALL) NOPASSWD: /usr/bin/rm -rf /etc/systemd/system/*.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/rm -f /etc/systemd/system/*.service
$USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /opt/*
$USER ALL=(ALL) NOPASSWD: /usr/bin/journalctl *
$USER ALL=(ALL) NOPASSWD: /usr/bin/systemd-run *
EOF
sudo chmod 440 /etc/sudoers.d/pi-control-center

sudo systemctl daemon-reload

echo ""
echo "=== Done! ==="
echo "Pi Control Center:  http://$(hostname -I | awk '{print $1}')"
echo "API:                port $API_PORT"
echo "Updates:            all manual via Pi Control Center UI"
echo "CPU layout:         core 0=system, cores 1-3 assigned per service"
echo "Swap:               $(free -m | awk '/^Swap:/{print $2}')MB"
echo "RAM free:           $(free -m | awk '/^Mem:/{print $7}')MB available"
echo ""
echo "Idle footprint: ~7MB (Nginx ~5MB + API ~2MB)"
