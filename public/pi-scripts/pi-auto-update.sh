#!/bin/bash
# Auto-update script for Pi Dashboard only
# Runs via systemd timer every hour

DASHBOARD_DIR="$HOME/pi-dashboard"
NGINX_DIR="/var/www/pi-dashboard"
LOG="/tmp/pi-dashboard/auto-update.log"

mkdir -p /tmp/pi-dashboard

echo "[$(date -Iseconds)] Checking for dashboard updates..." >> "$LOG"

cd "$DASHBOARD_DIR" || exit 1

# Check for changes
git fetch origin main --quiet 2>> "$LOG"
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)

if [ "$LOCAL" = "$REMOTE" ]; then
  echo "[$(date -Iseconds)] Already up to date ($LOCAL)" >> "$LOG"
  exit 0
fi

echo "[$(date -Iseconds)] Updating from $LOCAL to $REMOTE..." >> "$LOG"

git pull origin main --quiet 2>> "$LOG" || { echo "[$(date -Iseconds)] git pull failed" >> "$LOG"; exit 1; }
npm install --production 2>> "$LOG" || { echo "[$(date -Iseconds)] npm install failed" >> "$LOG"; exit 1; }
npm run build 2>> "$LOG" || { echo "[$(date -Iseconds)] build failed" >> "$LOG"; exit 1; }

sudo cp -r dist/* "$NGINX_DIR/" 2>> "$LOG"
echo "[$(date -Iseconds)] Updated to $(git rev-parse --short HEAD)" >> "$LOG"

# Keep log trimmed
tail -100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
