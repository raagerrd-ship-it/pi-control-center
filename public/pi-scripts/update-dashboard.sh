#!/bin/bash
# Pi Control Center — Update script (Pi Zero 2 W optimized)
# Pulls latest code, rebuilds, and deploys to Nginx
# Usage: bash ~/pi-control-center/public/pi-scripts/update-dashboard.sh

set -euo pipefail

DASHBOARD_DIR="$HOME/pi-control-center"
# Fallback to old location if new doesn't exist
[ ! -d "$DASHBOARD_DIR" ] && DASHBOARD_DIR="$HOME/pi-dashboard"
NGINX_DIR="/var/www/pi-control-center"
API_SCRIPT="$DASHBOARD_DIR/public/pi-scripts/pi-dashboard-api.sh"
SYSTEM_API_SCRIPT="/usr/local/bin/pi-dashboard-api.sh"

export NODE_OPTIONS="--max-old-space-size=256"

echo "=== Updating Pi Control Center ==="

# Ensure swap is available (critical for 512MB)
if [ "$(swapon --show | wc -l)" -lt 2 ]; then
  echo "[0] Setting up swap..."
  if [ -f /etc/dphys-swapfile ]; then
    sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
    sudo dphys-swapfile setup 2>/dev/null
    sudo dphys-swapfile swapon 2>/dev/null
  fi
fi

cd "$DASHBOARD_DIR"

echo "[1/7] Pulling latest code..."
git checkout -- . 2>/dev/null
git pull
sed -i 's/\r$//' "$DASHBOARD_DIR/public/pi-scripts/"*.sh
chmod +x "$DASHBOARD_DIR/public/pi-scripts/"*.sh

echo "[2/7] Installing dependencies..."
rm -rf node_modules package-lock.json
nice -n 15 ionice -c 3 npm install --no-audit --no-fund

echo "[3/7] Updating browserslist..."
npx -y update-browserslist-db@latest 2>/dev/null || true

echo "[4/7] Building (this may take a few minutes)..."
nice -n 15 ionice -c 3 npm run build

echo "[5/7] Deploying to Nginx..."
sudo mkdir -p "$NGINX_DIR"
sudo cp -r dist/* "$NGINX_DIR/"

echo "[6/7] Deploying services registry..."
if [ -f "$DASHBOARD_DIR/public/services.json" ]; then
  sudo cp "$DASHBOARD_DIR/public/services.json" "$NGINX_DIR/"
fi
if [ -f "$API_SCRIPT" ]; then
  sudo install -m 755 "$API_SCRIPT" "$SYSTEM_API_SCRIPT"
fi

echo "[7/7] Cleaning up..."
rm -rf node_modules
npm cache clean --force 2>/dev/null || true

# Restart API (try new name first, fallback to old)
sudo systemctl restart pi-control-center-api 2>/dev/null || sudo systemctl restart pi-dashboard-api 2>/dev/null || true

echo ""
echo "=== Done! ==="
echo "Pi Control Center:  http://$(hostname -I | awk '{print $1}')"
echo "RAM free:           $(free -m | awk '/^Mem:/{print $7}')MB available"
