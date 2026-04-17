#!/bin/bash
# ============================================================
# Pi Control Center — Auto-Setup
# ============================================================
#
# USAGE (pick one):
#
# A) SSH one-liner (recommended):
#    ssh pi@<pi-ip>
#    curl -sL https://raw.githubusercontent.com/raagerrd-ship-it/pi-control-center/main/public/pi-scripts/first-boot-setup.sh | sudo bash
#
#    Or with custom repo:
#    curl -sL <url>/first-boot-setup.sh | sudo PI_REPO=https://github.com/you/repo.git bash
#
# B) Pre-baked on SD card (advanced):
#    Mount rootfs, copy script + service, boot — see prep-sd-card.sh
#
# The script runs ONCE, installs everything, and marks itself done.
# Progress: /var/log/pi-control-center-setup.log
# LED: slow blink=network, fast blink=installing, solid=done
#
# ============================================================

set -euo pipefail

LOG="/var/log/pi-control-center-setup.log"
MARKER="/opt/.pi-control-center-installed"
REPO_URL="${PI_REPO:-https://github.com/raagerrd-ship-it/pi-control-center.git}"
API_PORT=8585

# Auto-detect user (works via SSH or systemd)
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  PI_USER="$SUDO_USER"
elif [ -d "/home/pi" ]; then
  PI_USER="pi"
else
  PI_USER="$(ls /home/ | head -1)"
fi
DASHBOARD_DIR="/home/$PI_USER/pi-control-center"
NGINX_DIR="/var/www/pi-control-center"
LED="/sys/class/leds/ACT/brightness"
LED_TRIGGER="/sys/class/leds/ACT/trigger"

# --- LED helper functions ---
led_setup() {
  echo none | sudo tee "$LED_TRIGGER" > /dev/null 2>&1 || true
}

led_blink() {
  local interval="${1:-0.3}"
  while true; do
    echo 1 | sudo tee "$LED" > /dev/null 2>&1
    sleep "$interval"
    echo 0 | sudo tee "$LED" > /dev/null 2>&1
    sleep "$interval"
  done
}

led_solid() {
  kill "$BLINK_PID" 2>/dev/null || true
  echo 1 | sudo tee "$LED" > /dev/null 2>&1
}

led_error() {
  kill "$BLINK_PID" 2>/dev/null || true
  while true; do
    for _ in 1 2 3; do
      echo 1 | sudo tee "$LED" > /dev/null 2>&1; sleep 0.1
      echo 0 | sudo tee "$LED" > /dev/null 2>&1; sleep 0.1
    done
    sleep 1
  done
}

led_restore() {
  [ -n "${BLINK_PID:-}" ] && kill "$BLINK_PID" 2>/dev/null || true
  echo mmc0 | sudo tee "$LED_TRIGGER" > /dev/null 2>&1 || true
}

trap 'led_restore' EXIT

# Redirect all output to log
exec > >(tee -a "$LOG") 2>&1

echo ""
echo "========================================"
echo " Pi Control Center — First Boot Setup"
echo " $(date)"
echo "========================================"
echo ""

# Guard: don't run twice
if [ -f "$MARKER" ]; then
  echo "Already installed. Exiting."
  exit 0
fi

# Start LED: slow blink = waiting for network
led_setup
led_blink 0.8 &
BLINK_PID=$!

# Wait for network (WiFi may take a moment)
echo "[0/9] Waiting for network..."
for i in $(seq 1 60); do
  if ping -c1 -W2 8.8.8.8 &>/dev/null; then
    echo "  Network ready after ${i}s"
    break
  fi
  sleep 2
done

if ! ping -c1 -W2 8.8.8.8 &>/dev/null; then
  echo "ERROR: No network after 120s. Aborting."
  led_error &
  exit 1
fi

# Switch to fast blink = installing
kill "$BLINK_PID" 2>/dev/null || true
led_blink 0.15 &
BLINK_PID=$!

# 0. sudo health (must run before any apt/sudo calls)
echo "[0b/9] Verifying sudo health..."
SUDO_FIX_SCRIPT="$(dirname "$0")/fix-sudo.sh"
if [ -f "$SUDO_FIX_SCRIPT" ]; then
  chmod +x "$SUDO_FIX_SCRIPT" 2>/dev/null || true
  bash "$SUDO_FIX_SCRIPT" || echo "  WARN: fix-sudo.sh reported issues, continuing anyway"
else
  echo "  WARN: fix-sudo.sh not found at $SUDO_FIX_SCRIPT"
fi

# 1. Swap (critical for 512MB Pi Zero 2)
echo "[1/9] Setting up swap..."
if [ "$(swapon --show | wc -l)" -lt 2 ]; then
  if [ -f /etc/dphys-swapfile ]; then
    sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
    sudo dphys-swapfile setup
    sudo dphys-swapfile swapon
  else
    sudo fallocate -l 512M /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=512
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  fi
fi
echo "  Swap: $(free -m | awk '/^Swap:/{print $2}')MB"

# 2. System packages
echo "[2/9] Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq nginx socat git jq bluez dbus polkitd build-essential python3 libudev-dev libusb-1.0-0-dev

# 3. Node.js
echo "[3/9] Installing Node.js..."
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y -qq nodejs
fi
echo "  Node: $(node -v), npm: $(npm -v)"

# 4. Enable lingering + BLE prerequisites
echo "[4/9] Enabling user service lingering + BLE prerequisites..."
sudo loginctl enable-linger "$PI_USER"
sudo usermod -aG bluetooth "$PI_USER"
sudo mkdir -p /etc/polkit-1/rules.d
sudo tee /etc/polkit-1/rules.d/49-allow-pi-bluez.rules > /dev/null <<'EOF'
polkit.addRule(function(action, subject) {
  if (subject.user == "pi" && action.id.indexOf("org.bluez.") == 0) {
    return polkit.Result.YES;
  }
});
EOF

if ! grep -q '^DisablePlugins=pnat' /etc/bluetooth/main.conf 2>/dev/null; then
  printf '\n[General]\nDisablePlugins=pnat\n' | sudo tee -a /etc/bluetooth/main.conf > /dev/null
fi

sudo systemctl enable --now bluetooth
sudo systemctl restart bluetooth

# 5. Clone & build
echo "[5/9] Cloning Pi Control Center..."
export NODE_OPTIONS="--max-old-space-size=256"

if [ -d "$DASHBOARD_DIR" ]; then
  cd "$DASHBOARD_DIR" && git pull --quiet
else
  sudo -u "$PI_USER" git clone --depth 1 "$REPO_URL" "$DASHBOARD_DIR"
fi
cd "$DASHBOARD_DIR"

echo "[6/9] Building (this takes ~5-10 min on Pi Zero 2)..."
sudo -u "$PI_USER" NODE_OPTIONS="--max-old-space-size=256" nice -n 15 ionice -c 3 npm install --no-audit --no-fund
sudo -u "$PI_USER" NODE_OPTIONS="--max-old-space-size=256" nice -n 15 ionice -c 3 npm run build
sudo mkdir -p "$NGINX_DIR"
sudo cp -r dist/* "$NGINX_DIR/"
# Copy services.json to deployed location for API registry
[ -f "$DASHBOARD_DIR/public/services.json" ] && sudo cp "$DASHBOARD_DIR/public/services.json" "$NGINX_DIR/"
# Expose pi-scripts/ at a stable path so other apps (Lotus, Cast Away, Brew Monitor)
# can locate fix-sudo.sh and other shared scripts via thin wrappers.
sudo mkdir -p "$NGINX_DIR/pi-scripts"
sudo cp -r "$DASHBOARD_DIR/public/pi-scripts/." "$NGINX_DIR/pi-scripts/"
sudo chmod +x "$NGINX_DIR/pi-scripts/"*.sh 2>/dev/null || true
# Compatibility symlink for apps that look under /var/www/pi-dashboard/pi-scripts/
sudo mkdir -p /var/www/pi-dashboard
sudo ln -sfn "$NGINX_DIR/pi-scripts" /var/www/pi-dashboard/pi-scripts
sudo -u "$PI_USER" rm -rf node_modules
sudo -u "$PI_USER" npm cache clean --force 2>/dev/null || true

# 7. Nginx config
echo "[7/9] Configuring Nginx..."

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

# 8. API service with hard CPU pinning
echo "[8/9] Setting up API service..."
chmod +x "$DASHBOARD_DIR/public/pi-scripts/pi-control-center-api.sh"

sudo tee /etc/systemd/system/pi-control-center-api.service > /dev/null << EOF
[Unit]
Description=Pi Control Center API
After=network.target

[Service]
Type=simple
User=$PI_USER
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

# Pin Nginx to core 0 (hard limit)
sudo mkdir -p /etc/systemd/system/nginx.service.d
sudo tee /etc/systemd/system/nginx.service.d/cpu-pin.conf > /dev/null << 'OVER'
[Service]
CPUAffinity=0
AllowedCPUs=0
OVER

# 9. Scoped sudoers — only allow managing user services and specific system operations
echo "[9/9] Configuring permissions..."
sudo tee /etc/sudoers.d/pi-control-center > /dev/null << EOF
# Pi Control Center — scoped permissions
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start pi-control-center-api.service
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop pi-control-center-api.service
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart pi-control-center-api.service
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart nginx.service
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl daemon-reload
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /etc/pi-control-center
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/pi-control-center/*
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /var/www/pi-control-center
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/cp -r *
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/install -m 755 *
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/git clone *
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/chown *
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/rm -rf /opt/*
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir -p /opt/*
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/journalctl *
$PI_USER ALL=(ALL) NOPASSWD: /usr/bin/systemd-run *
EOF
sudo chmod 440 /etc/sudoers.d/pi-control-center

sudo systemctl daemon-reload

# Mark as installed & disable first-boot service (if it exists)
touch "$MARKER"
sudo systemctl disable first-boot-setup.service 2>/dev/null || true

# Done! LED solid green for 30s, then restore to kernel default
led_solid
IP=$(hostname -I | awk '{print $1}')
echo ""
echo "========================================"
echo " ✓ Installation klar!"
echo "========================================"
echo ""
echo " Pi Control Center:  http://${IP}"
echo " API:                http://${IP}:${API_PORT}"
echo ""
echo " CPU-layout:"
echo "   Core 0 → System + Pi Control Center + Nginx"
echo "   Core 1-3 → Tilldelas per tjänst via dashboarden"
echo ""
echo " LED-mönster:"
echo "   Långsam blink → väntar på nätverk"
echo "   Snabb blink   → installerar"
echo "   Fast sken     → klart!"
echo ""
echo " RAM:  $(free -m | awk '/^Mem:/{print $7}')MB ledigt"
echo " Swap: $(free -m | awk '/^Swap:/{print $2}')MB"
echo ""
echo " Öppna Pi Control Center på din mobil: http://${IP}"
echo "========================================"

# Keep LED solid for 30s so user sees it, then restore
sleep 30
led_restore
