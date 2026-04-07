#!/bin/bash
# Auto-update script for Pi Dashboard only
# Runs via systemd timer every hour
# Optimized for Pi Zero 2 W (512MB RAM)

DASHBOARD_DIR="$HOME/pi-dashboard"
NGINX_DIR="/var/www/pi-dashboard"
LOG="/tmp/pi-dashboard/auto-update.log"

# Limit Node.js memory for Pi Zero 2 W
export NODE_OPTIONS="--max-old-space-size=256"

mkdir -p /tmp/pi-dashboard

echo "[$(date -Iseconds)] Checking for dashboard updates..." >> "$LOG"

cd "$DASHBOARD_DIR" || exit 1

# Check for changes (shallow fetch to save bandwidth)
git fetch origin main --depth=1 --quiet 2>> "$LOG"
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main 2>/dev/null || git rev-parse FETCH_HEAD)

if [ "$LOCAL" = "$REMOTE" ]; then
  echo "[$(date -Iseconds)] Already up to date (${LOCAL:0:7})" >> "$LOG"
  exit 0
fi

echo "[$(date -Iseconds)] Updating ${LOCAL:0:7} → ${REMOTE:0:7}..." >> "$LOG"

# Pull with low CPU/IO priority to not starve running services
nice -n 15 ionice -c 3 git pull origin main --quiet 2>> "$LOG" || {
  echo "[$(date -Iseconds)] git pull failed" >> "$LOG"
  exit 1
}

nice -n 15 ionice -c 3 npm install --production --no-audit --no-fund 2>> "$LOG" || {
  echo "[$(date -Iseconds)] npm install failed" >> "$LOG"
  exit 1
}

nice -n 15 ionice -c 3 npm run build 2>> "$LOG" || {
  echo "[$(date -Iseconds)] build failed" >> "$LOG"
  exit 1
}

sudo cp -r dist/* "$NGINX_DIR/" 2>> "$LOG"
echo "[$(date -Iseconds)] Updated to $(git rev-parse --short HEAD)" >> "$LOG"

# Keep log trimmed
tail -100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
