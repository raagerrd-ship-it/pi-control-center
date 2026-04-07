#!/bin/bash
# Pi Dashboard — Installation script
# Run on your Pi Zero 2 W: curl -sL <url>/pi-scripts/install.sh | bash
set -e

REPO_URL="${1:-https://github.com/YOUR_USER/pi-dashboard.git}"
DASHBOARD_DIR="$HOME/pi-dashboard"
NGINX_DIR="/var/www/pi-dashboard"
API_PORT=8585

echo "=== Pi Dashboard Installer ==="

# 1. Install dependencies
echo "[1/6] Installing packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq nginx socat git

# Install Node.js if missing
if ! command -v node &>/dev/null; then
  echo "  Installing Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y -qq nodejs
fi

# 2. Clone/update dashboard repo
echo "[2/6] Setting up dashboard..."
if [ -d "$DASHBOARD_DIR" ]; then
  cd "$DASHBOARD_DIR" && git pull --quiet
else
  git clone "$REPO_URL" "$DASHBOARD_DIR"
  cd "$DASHBOARD_DIR"
fi

# 3. Build
echo "[3/6] Building..."
npm install --production
npm run build
sudo mkdir -p "$NGINX_DIR"
sudo cp -r dist/* "$NGINX_DIR/"

# 4. Configure Nginx
echo "[4/6] Configuring Nginx..."
sudo tee /etc/nginx/sites-available/pi-dashboard > /dev/null << 'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/pi-dashboard;
    index index.html;
    server_name _;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Cache static assets
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 7d;
        add_header Cache-Control "public, immutable";
    }
}
NGINX

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/pi-dashboard /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# 5. Set up API service
echo "[5/6] Setting up API service..."
chmod +x "$DASHBOARD_DIR/public/pi-scripts/pi-dashboard-api.sh"
chmod +x "$DASHBOARD_DIR/public/pi-scripts/pi-auto-update.sh"

sudo tee /etc/systemd/system/pi-dashboard-api.service > /dev/null << EOF
[Unit]
Description=Pi Dashboard API
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$DASHBOARD_DIR/public/pi-scripts/pi-dashboard-api.sh $API_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now pi-dashboard-api.service

# 6. Set up auto-update timer (hourly, dashboard only)
echo "[6/6] Setting up auto-update timer..."
sudo tee /etc/systemd/system/pi-dashboard-update.service > /dev/null << EOF
[Unit]
Description=Pi Dashboard Auto Update

[Service]
Type=oneshot
User=$USER
ExecStart=$DASHBOARD_DIR/public/pi-scripts/pi-auto-update.sh
EOF

sudo tee /etc/systemd/system/pi-dashboard-update.timer > /dev/null << 'EOF'
[Unit]
Description=Pi Dashboard hourly update check

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now pi-dashboard-update.timer

# Disable other apps' auto-update timers (they'll be updated manually via the dashboard)
for timer in lotus-light-update cast-away-update sonos-proxy-update; do
  if systemctl is-enabled "${timer}.timer" &>/dev/null; then
    echo "  Disabling ${timer}.timer (use dashboard for manual updates)"
    sudo systemctl disable --now "${timer}.timer" 2>/dev/null || true
  fi
done

echo ""
echo "=== Done! ==="
echo "Dashboard: http://$(hostname -I | awk '{print $1}')"
echo "API: port $API_PORT"
echo "Auto-update: every hour (dashboard only)"
echo "Other apps: update manually via dashboard buttons"
