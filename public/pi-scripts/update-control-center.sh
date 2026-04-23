#!/bin/bash
# Pi Control Center — Update script (Pi Zero 2 W optimized)
# Pulls latest code, rebuilds, and deploys to Nginx
# Usage: bash ~/pi-control-center/public/pi-scripts/update-control-center.sh

set -euo pipefail

DASHBOARD_DIR="$HOME/pi-control-center"
NGINX_DIR="/var/www/pi-control-center"
API_SCRIPT="$DASHBOARD_DIR/public/pi-scripts/pi-control-center-api.sh"
SYSTEM_API_SCRIPT="/usr/local/bin/pi-control-center-api.sh"

export NODE_OPTIONS="--max-old-space-size=256"

echo "=== Updating Pi Control Center ==="

ensure_node24() {
  local current major
  current=$(node -v 2>/dev/null || true)
  major=${current#v}; major=${major%%.*}
  if [ "$major" != "24" ]; then
    echo "  Installing PCC Node.js 24 LTS runtime..."
    curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
    sudo apt-get install -y -qq nodejs
  fi
  echo "  Node: $(node -v), npm: $(npm -v)"
}

repair_ble_permissions() {
  echo "  Re-applying BLE/Noble permissions..."
  sudo loginctl enable-linger "$USER" 2>/dev/null || true
  sudo usermod -aG bluetooth,netdev,audio "$USER" 2>/dev/null || true
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
  sudo rfkill unblock bluetooth 2>/dev/null || true
  sudo hciconfig hci0 up 2>/dev/null || true
  sudo systemctl enable --now bluetooth 2>/dev/null || true
  sudo systemctl restart bluetooth 2>/dev/null || true
}

cd "$DASHBOARD_DIR"

echo "[1/6] Pulling latest code..."
git checkout -- . 2>/dev/null || true
REMOTE_BRANCH=$(git remote show origin 2>/tmp/pcc-update-git-fetch.err | awk '/HEAD branch/ {print $NF}' | head -1)
[ -n "$REMOTE_BRANCH" ] || REMOTE_BRANCH="main"
if git fetch origin "$REMOTE_BRANCH" --depth=1 --prune --quiet 2>/tmp/pcc-update-git-fetch.err; then
  git reset --hard "origin/$REMOTE_BRANCH"
else
  git fetch origin --depth=1 --prune --quiet 2>>/tmp/pcc-update-git-fetch.err
  git reset --hard "origin/$REMOTE_BRANCH"
fi
sed -i 's/\r$//' "$DASHBOARD_DIR/public/pi-scripts/"*.sh
chmod +x "$DASHBOARD_DIR/public/pi-scripts/"*.sh

echo "[2/6] Installing dependencies..."
ensure_node24
rm -rf node_modules
nice -n 15 ionice -c 3 npm install --no-audit --no-fund
sudo chown -R "$USER:$USER" node_modules 2>/dev/null || true

echo "[3/6] Building (this may take a few minutes)..."
nice -n 15 ionice -c 3 npm run build

echo "[4/6] Deploying to Nginx..."
sudo mkdir -p "$NGINX_DIR"
sudo cp -r dist/* "$NGINX_DIR/"

echo "[5/6] Deploying services registry & API..."
if [ -f "$DASHBOARD_DIR/public/services.json" ]; then
  sudo cp "$DASHBOARD_DIR/public/services.json" "$NGINX_DIR/"
fi
if [ -f "$API_SCRIPT" ]; then
  # Hoppa över om målet redan är en symlänk till samma fil (cp/install skulle annars
  # ge "are the same file" eller skriva över symlänken med en kopia).
  if [ -L "$SYSTEM_API_SCRIPT" ] && \
     [ "$(readlink -f "$SYSTEM_API_SCRIPT")" = "$(readlink -f "$API_SCRIPT")" ]; then
    echo "  ↳ $SYSTEM_API_SCRIPT är redan en symlänk till källan — hoppar över kopiering"
  else
    sudo install -m 755 "$API_SCRIPT" "$SYSTEM_API_SCRIPT"
  fi
fi
sudo mkdir -p "$NGINX_DIR/pi-scripts"
sudo cp -r "$DASHBOARD_DIR/public/pi-scripts/." "$NGINX_DIR/pi-scripts/"
sudo chmod +x "$NGINX_DIR/pi-scripts/"*.sh 2>/dev/null || true

echo "[6/6] Cleaning up & restarting..."
repair_ble_permissions
rm -rf node_modules
npm cache clean --force 2>/dev/null || true
sudo systemctl restart pi-control-center-api 2>/dev/null || true

echo ""
echo "=== Done! ==="
echo "Pi Control Center:  http://$(hostname -I | awk '{print $1}')"
echo "RAM free:           $(free -m | awk '/^Mem:/{print $7}')MB available"
