#!/bin/bash
# Pi Dashboard — Update script (Pi Zero 2 W optimized)
# Pulls latest code, rebuilds, and deploys to Nginx
# Usage: bash ~/pi-dashboard/public/pi-scripts/update-dashboard.sh

set -e

DASHBOARD_DIR="$HOME/pi-dashboard"
NGINX_DIR="/var/www/pi-dashboard"

export NODE_OPTIONS="--max-old-space-size=256"

echo "=== Updating Pi Dashboard ==="

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

echo "[1/5] Pulling latest code..."
git checkout -- . 2>/dev/null
git pull

echo "[2/5] Installing dependencies..."
nice -n 15 ionice -c 3 npm install --no-audit --no-fund

echo "[3/5] Building (this may take a few minutes)..."
nice -n 15 ionice -c 3 npm run build

echo "[4/5] Deploying to Nginx..."
sudo cp -r dist/* "$NGINX_DIR/"

echo "[5/5] Cleaning up..."
rm -rf node_modules
npm cache clean --force 2>/dev/null || true

sudo systemctl restart pi-dashboard-api

echo ""
echo "=== Done! ==="
echo "Dashboard:  http://$(hostname -I | awk '{print $1}')"
echo "RAM free:   $(free -m | awk '/^Mem:/{print $7}')MB available"
