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
GIT_FETCH_ERR="/tmp/pcc-update-git-fetch.${USER}.err"
rm -f "$GIT_FETCH_ERR" 2>/dev/null || sudo rm -f "$GIT_FETCH_ERR" 2>/dev/null || true
git checkout -- . 2>/dev/null || true
REMOTE_BRANCH=$(git remote show origin 2>>"$GIT_FETCH_ERR" | awk '/HEAD branch/ {print $NF}' | head -1)
[ -n "$REMOTE_BRANCH" ] || REMOTE_BRANCH="main"
: > "$GIT_FETCH_ERR"
for attempt in 1 2 3; do
  echo "  Git fetch attempt $attempt/3 ($REMOTE_BRANCH)..."
  if git -c http.version=HTTP/1.1 -c protocol.version=2 fetch origin "$REMOTE_BRANCH" --depth=1 --prune --no-tags 2>>"$GIT_FETCH_ERR"; then
    git reset --hard "origin/$REMOTE_BRANCH"
    break
  fi
  if [ "$REMOTE_BRANCH" = "main" ] && git -c http.version=HTTP/1.1 fetch origin master --depth=1 --prune --no-tags 2>>"$GIT_FETCH_ERR"; then
    git reset --hard origin/master
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    echo "Git fetch failed:"
    tail -8 "$GIT_FETCH_ERR"
    exit 1
  fi
  sleep 2
done
sed -i 's/\r$//' "$DASHBOARD_DIR/public/pi-scripts/"*.sh
chmod +x "$DASHBOARD_DIR/public/pi-scripts/"*.sh

echo "[2/6] Installing dependencies..."
ensure_node24
DEPS_HASH_FILE="node_modules/.pcc-deps-hash"
CURRENT_DEPS_HASH=$(sha256sum package.json package-lock.json 2>/dev/null | sha256sum | awk '{print $1}')
SAVED_DEPS_HASH=""
[ -f "$DEPS_HASH_FILE" ] && SAVED_DEPS_HASH=$(cat "$DEPS_HASH_FILE" 2>/dev/null || true)
if [ "${FORCE:-0}" != "1" ] && [ -d node_modules ] && [ -n "$CURRENT_DEPS_HASH" ] && [ "$CURRENT_DEPS_HASH" = "$SAVED_DEPS_HASH" ]; then
  echo "  ↳ package.json oförändrad — hoppar över npm install"
else
  rm -rf node_modules
  nice -n 15 ionice -c 3 npm install --no-audit --no-fund
  sudo chown -R "$USER:$USER" node_modules 2>/dev/null || true
  echo "$CURRENT_DEPS_HASH" > "$DEPS_HASH_FILE"
fi

echo "[3/6] Building (this may take a few minutes)..."
CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
BUILD_STAMP="dist/.pcc-build-stamp"
SAVED_BUILD_STAMP=""
[ -f "$BUILD_STAMP" ] && SAVED_BUILD_STAMP=$(cat "$BUILD_STAMP" 2>/dev/null || true)
EXPECTED_BUILD_STAMP="${CURRENT_COMMIT}:${CURRENT_DEPS_HASH}"
SKIP_BUILD=0
if [ "${FORCE:-0}" != "1" ] && [ -f dist/index.html ] && [ -f "$NGINX_DIR/index.html" ] && [ "$EXPECTED_BUILD_STAMP" = "$SAVED_BUILD_STAMP" ]; then
  echo "  ↳ Källkod oförändrad sedan förra builden — hoppar över"
  SKIP_BUILD=1
else
  nice -n 15 ionice -c 3 npm run build
  echo "$EXPECTED_BUILD_STAMP" > "$BUILD_STAMP"
fi

echo "[4/6] Deploying to Nginx..."
sudo mkdir -p "$NGINX_DIR"
if [ "$SKIP_BUILD" = "1" ]; then
  echo "  ↳ Nginx redan i synk — hoppar över kopiering"
else
  sudo cp -r dist/* "$NGINX_DIR/"
fi

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
sudo chmod +x "$DASHBOARD_DIR/public/pi-scripts/pi-control-center-api.py" 2>/dev/null || true

# Migrate systemd unit to the Python HTTP frontend (replaces the legacy
# bash+socat per-request server). Idempotent — rewrites every run so config
# changes (MemoryMax, ExecStart) propagate cleanly.
echo "  ↳ Skriver om systemd-unit till Python-servern..."
API_PY="$DASHBOARD_DIR/public/pi-scripts/pi-control-center-api.py"
API_PORT_ENV="$(systemctl show pi-control-center-api.service -p Environment --value 2>/dev/null | tr ' ' '\n' | awk -F= '$1=="PORT"{print $2}')"
[ -z "$API_PORT_ENV" ] && API_PORT_ENV="8585"
sudo tee /etc/systemd/system/pi-control-center-api.service > /dev/null << EOF
[Unit]
Description=Pi Control Center API (Python HTTP + bash backend)
After=network.target

[Service]
Type=simple
User=$USER
Environment=PORT=$API_PORT_ENV
ExecStart=/usr/bin/python3 -u $API_PY
Restart=always
RestartSec=10
MemoryMax=64M
Nice=10
CPUAffinity=0
AllowedCPUs=0
KillMode=mixed
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload

echo "[6/6] Cleaning up & restarting..."
repair_ble_permissions
rm -rf node_modules
npm cache clean --force 2>/dev/null || true
sudo systemctl restart pi-control-center-api 2>/dev/null || true

echo "  ↳ Synkar --max-old-space-size i installerade unit-filer mot services.json..."
sudo bash "$SYSTEM_API_SCRIPT" --sync-heap-limits 2>&1 | sed 's/^/    /' || true

echo ""
echo "=== Done! ==="
echo "Pi Control Center:  http://$(hostname -I | awk '{print $1}')"
echo "RAM free:           $(free -m | awk '/^Mem:/{print $7}')MB available"
