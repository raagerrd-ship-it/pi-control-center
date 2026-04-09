#!/bin/bash
# Pi Dashboard API — lightweight HTTP server optimized for Pi Zero 2 W
# Uses /proc for stats (no heavy subprocesses), caches results
# Usage: ./pi-dashboard-api.sh [port]

REQUEST_MODE="${1:-}"
if [ "$REQUEST_MODE" = "--handle-request" ]; then
  shift
fi

PORT="${1:-8585}"
SCRIPT_PATH="$(readlink -f "$0")"
STATUS_DIR="/tmp/pi-dashboard"
INSTALL_DIR="/tmp/pi-dashboard/install"
CACHE_FILE="$STATUS_DIR/status-cache.json"
CACHE_MAX_AGE=2  # seconds
USER_ID="$(id -u)"
USER_RUNTIME_DIR="/run/user/$USER_ID"
USER_BUS_ADDRESS="unix:path=$USER_RUNTIME_DIR/bus"

mkdir -p "$STATUS_DIR" "$INSTALL_DIR"

user_systemctl() {
  XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" \
  DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS" \
  systemctl --user "$@"
}

# App configs
declare -A APP_REPOS=(
  ["lotus-lantern"]="https://github.com/raagerrd-ship-it/lotus-light-link.git"
  ["cast-away"]="https://github.com/raagerrd-ship-it/hromecast.git"
  ["sonos-gateway"]="https://github.com/raagerrd-ship-it/sonos-gateway.git"
)

declare -A APP_DIRS=(
  ["lotus-lantern"]="/opt/lotus-light"
  ["cast-away"]="$HOME/.local/share/hromecast"
  ["sonos-gateway"]="$HOME/.local/share/sonos-proxy"
)

declare -A APP_INSTALL_DIRS=(
  ["lotus-lantern"]="/opt/lotus-light"
  ["cast-away"]="$HOME/.local/share/cast-away"
  ["sonos-gateway"]="$HOME/.local/share/sonos-proxy"
)

declare -A APP_INSTALL_SCRIPTS=(
  ["lotus-lantern"]="pi/setup-lotus.sh"
  ["cast-away"]="bridge-pi/install-linux.sh"
  ["sonos-gateway"]="bridge/install-linux.sh"
)

declare -A APP_UPDATE_SCRIPTS=(
  ["lotus-lantern"]="/opt/lotus-light/pi/dashboard-update.sh"
  ["cast-away"]="$HOME/.local/share/hromecast/bridge-pi/update.sh"
  ["sonos-gateway"]="$HOME/.local/share/sonos-proxy/bridge/update.sh"
)

declare -A APP_PORTS=(
  ["lotus-lantern"]="3001"
  ["cast-away"]="3000"
  ["sonos-gateway"]="3002"
)

declare -A APP_SERVICES=(
  ["lotus-lantern"]="lotus-light"
  ["cast-away"]="cast-away"
  ["sonos-gateway"]="sonos-proxy"
)

declare -A APP_CORES=(
  ["lotus-lantern"]="1"
  ["cast-away"]="2"
  ["sonos-gateway"]="3"
)

get_cpu() {
  read -r _ t1_u t1_n t1_s t1_i t1_w t1_x t1_y _ < /proc/stat
  local total1=$((t1_u + t1_n + t1_s + t1_i + t1_w + t1_x + t1_y))
  local idle1=$t1_i

  sleep 0.2

  read -r _ t2_u t2_n t2_s t2_i t2_w t2_x t2_y _ < /proc/stat
  local total2=$((t2_u + t2_n + t2_s + t2_i + t2_w + t2_x + t2_y))
  local idle2=$t2_i

  local td=$((total2 - total1))
  local id=$((idle2 - idle1))

  [ "$td" -gt 0 ] && echo $(((td - id) * 100 / td)) || echo 0
}

get_temp() {
  if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    local raw=$(< /sys/class/thermal/thermal_zone0/temp)
    local whole=$((raw / 1000))
    local frac=$(((raw % 1000) / 100))
    echo "${whole}.${frac}"
  else
    echo "0"
  fi
}

get_ram() {
  awk '/^MemTotal:/{t=int($2/1024)} /^MemAvailable:/{a=int($2/1024)} END{print (t-a)","t}' /proc/meminfo
}

get_disk() {
  df -BG / | awk 'NR==2{gsub("G","",$3); gsub("G","",$2); print $3","$2}'
}

get_uptime() {
  local secs
  read -r secs _ < /proc/uptime
  secs=${secs%%.*}
  local d=$((secs / 86400)) h=$(((secs % 86400) / 3600)) m=$(((secs % 3600) / 60))

  if [ "$d" -gt 0 ]; then echo "${d}d ${h}h ${m}m"
  elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
  else echo "${m}m"
  fi
}

check_service() {
  local hex_port
  hex_port=$(printf '%04X' "$1")
  if grep -q ":${hex_port} " /proc/net/tcp 2>/dev/null || \
     grep -q ":${hex_port} " /proc/net/tcp6 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

check_installed() {
  local app=$1
  local path=$2
  local service=${APP_SERVICES[$app]}

  if [ "$app" = "lotus-lantern" ]; then
    [ -d "$path/.git" ] && [ -f "/etc/systemd/system/${service}.service" ] && echo "true" || echo "false"
  elif [ "$app" = "cast-away" ]; then
    [ -d "$path" ] && [ -f "$HOME/.config/systemd/user/${service}.service" ] && echo "true" || echo "false"
  elif [ "$app" = "sonos-gateway" ]; then
    [ -d "$path" ] && [ -f "$HOME/.config/systemd/user/${service}.service" ] && echo "true" || echo "false"
  else
    [ -d "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ] && echo "true" || echo "false"
  fi
}

get_version() {
  if [ -d "$1/.git" ]; then
    local raw
    raw=$(git -C "$1" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
    echo "${raw,,}"
  else
    echo ""
  fi
}

get_service_ram() {
  local val
  val=$(systemctl show "$1.service" --property=MemoryCurrent 2>/dev/null | cut -d= -f2)
  # Try user-level if system-level returns nothing useful
  if [ -z "$val" ] || [ "$val" = "[not set]" ] || [ "$val" = "infinity" ]; then
    val=$(user_systemctl show "$1.service" --property=MemoryCurrent 2>/dev/null | cut -d= -f2)
  fi
  if [ -n "$val" ] && [ "$val" != "[not set]" ] && [ "$val" != "infinity" ] && [ "$val" != "" ]; then
    echo $((val / 1048576))
  else
    echo "0"
  fi
}

build_status_json() {
  local cpu temp ram disk uptime_str ram_used ram_total disk_used disk_total svc_json
  cpu=$(get_cpu)
  temp=$(get_temp)
  ram=$(get_ram)
  disk=$(get_disk)
  uptime_str=$(get_uptime)

  ram_used=${ram%%,*}
  ram_total=${ram##*,}
  disk_used=${disk%%,*}
  disk_total=${disk##*,}
  svc_json=""

  for app in lotus-lantern cast-away sonos-gateway; do
    local port dir install_dir svc online installed ver s_cpu s_ram s_core pid aff
    port=${APP_PORTS[$app]}
    dir=${APP_DIRS[$app]}
    install_dir=${APP_INSTALL_DIRS[$app]:-$dir}
    svc=${APP_SERVICES[$app]}
    online=$(check_service "$port")
    installed=$(check_installed "$app" "$install_dir")
    ver=$(get_version "$dir")
    s_cpu=0
    s_ram=0
    s_core=${APP_CORES[$app]:-0}

    if [ "$online" = "true" ]; then
      s_ram=$(get_service_ram "$svc")
      pid=$(systemctl show "${svc}.service" --property=MainPID 2>/dev/null | cut -d= -f2)
      # Try user-level if system-level PID is 0
      if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        pid=$(user_systemctl show "${svc}.service" --property=MainPID 2>/dev/null | cut -d= -f2)
      fi
      if [ -n "$pid" ] && [ "$pid" != "0" ]; then
        s_cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
        aff=$(taskset -p "$pid" 2>/dev/null | awk '{print $NF}')
        case "$aff" in
          1) s_core=0 ;;
          2) s_core=1 ;;
          4) s_core=2 ;;
          8) s_core=3 ;;
        esac
      fi
    fi

    [ -n "$svc_json" ] && svc_json="${svc_json},"
    svc_json="${svc_json}\"${app}\":{\"online\":${online},\"installed\":${installed},\"version\":\"${ver}\",\"cpu\":${s_cpu:-0},\"ramMb\":${s_ram:-0},\"cpuCore\":${s_core}}"
  done

  local dash_cpu dash_ram nginx_ram dash_pid
  dash_cpu=0
  dash_ram=$(get_service_ram "pi-dashboard-api")
  nginx_ram=$(get_service_ram "nginx")
  dash_ram=$((dash_ram + nginx_ram))
  dash_pid=$(systemctl show "pi-dashboard-api.service" --property=MainPID 2>/dev/null | cut -d= -f2)
  [ -n "$dash_pid" ] && [ "$dash_pid" != "0" ] && dash_cpu=$(ps -p "$dash_pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")

  echo "{\"cpu\":${cpu:-0},\"temp\":${temp:-0},\"ramUsed\":${ram_used:-0},\"ramTotal\":${ram_total:-0},\"diskUsed\":${disk_used:-0},\"diskTotal\":${disk_total:-0},\"uptime\":\"${uptime_str}\",\"dashboardCpu\":${dash_cpu:-0},\"dashboardRamMb\":${dash_ram:-0},\"services\":{${svc_json}}}"
}

get_cached_status() {
  if [ -f "$CACHE_FILE" ]; then
    local age
    age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$CACHE_MAX_AGE" ]; then
      cat "$CACHE_FILE"
      return
    fi
  fi

  local json
  json=$(build_status_json)
  echo "$json" > "$CACHE_FILE"
  echo "$json"
}

write_lotus_update_script() {
  local update_script
  update_script="/opt/lotus-light/pi/dashboard-update.sh"

  sudo tee "$update_script" > /dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

APP_DIR="/opt/lotus-light"
PI_DIR="$APP_DIR/pi"
SERVICE="lotus-light"
REMOTE_REF="origin/main"

[ -d "$APP_DIR/.git" ] || exit 1

cd "$APP_DIR"
git fetch origin main --quiet 2>/dev/null || git fetch origin master --quiet 2>/dev/null || exit 1
git rev-parse origin/main >/dev/null 2>&1 || REMOTE_REF="origin/master"

LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
REMOTE_HEAD=$(git rev-parse "$REMOTE_REF" 2>/dev/null || echo "")
[ -n "$REMOTE_HEAD" ] || exit 1
[ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] && exit 0

git reset --hard "$REMOTE_REF" -q

cat > "$PI_DIR/src/node-record-lpcm16.d.ts" <<'TYPES'
declare module "node-record-lpcm16";
TYPES

cat > "$PI_DIR/src/eventsource.d.ts" <<'TYPES'
declare module "eventsource";
TYPES

sed -i 's/noble\.state/noble._state/g' "$PI_DIR/src/nobleBle.ts"
python3 - <<'PY'
from pathlib import Path

alsa_mic = Path("/opt/lotus-light/pi/src/alsaMic.ts")
if alsa_mic.exists():
    source = alsa_mic.read_text()
    original = "import { fft, util as fftUtil } from 'fft-js';"
    replacement = "import fftJs from 'fft-js';\nconst { fft, util: fftUtil } = fftJs;"
    if original in source and replacement not in source:
        alsa_mic.write_text(source.replace(original, replacement))
PY

cd "$PI_DIR"
NODE_OPTIONS="--max-old-space-size=256" npm install --no-audit --no-fund
NODE_OPTIONS="--max-old-space-size=256" npm run build
npm prune --production 2>/dev/null || true
systemctl restart "$SERVICE"
EOF

  sudo chmod +x "$update_script"
}

install_lotus_lantern() {
  local repo log_file sf default_core overlay_file needs_reboot node_major
  repo=$1
  log_file=$2
  sf=$3
  default_core=$4
  needs_reboot="false"
  overlay_file="/boot/config.txt"
  [ -f /boot/firmware/config.txt ] && overlay_file="/boot/firmware/config.txt"

  export DEBIAN_FRONTEND=noninteractive

  echo '{"app":"lotus-lantern","status":"installing","progress":"Installerar systempaket..."}' > "$sf"
  if ! sudo apt-get update -qq >> "$log_file" 2>&1 || ! sudo apt-get install -y -qq bluez libbluetooth-dev libasound2-dev alsa-utils git curl >> "$log_file" 2>&1; then
    return 1
  fi

  node_major=$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v' || echo 0)
  if [ -z "$node_major" ] || [ "$node_major" -lt 20 ]; then
    echo '{"app":"lotus-lantern","status":"installing","progress":"Installerar Node.js 20..."}' > "$sf"
    if ! curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >> "$log_file" 2>&1 || ! sudo apt-get install -y -qq nodejs >> "$log_file" 2>&1; then
      return 1
    fi
  fi

  if ! sudo grep -q 'googlevoicehat-soundcard' "$overlay_file" 2>/dev/null; then
    echo 'dtoverlay=googlevoicehat-soundcard' | sudo tee -a "$overlay_file" > /dev/null
    needs_reboot="true"
  fi

  echo '{"app":"lotus-lantern","status":"installing","progress":"Klonar repo..."}' > "$sf"
  sudo rm -rf /opt/lotus-light
  if ! sudo git clone --depth 1 "$repo" /opt/lotus-light >> "$log_file" 2>&1; then
    return 1
  fi

  echo '{"app":"lotus-lantern","status":"installing","progress":"Applicerar byggfixar..."}' > "$sf"
  sudo sed -i 's/noble\.state/noble._state/g' /opt/lotus-light/pi/src/nobleBle.ts
  printf 'declare module "node-record-lpcm16";\n' | sudo tee /opt/lotus-light/pi/src/node-record-lpcm16.d.ts > /dev/null
  printf 'declare module "eventsource";\n' | sudo tee /opt/lotus-light/pi/src/eventsource.d.ts > /dev/null
  sudo python3 - <<'PY'
from pathlib import Path

alsa_mic = Path('/opt/lotus-light/pi/src/alsaMic.ts')
if alsa_mic.exists():
    source = alsa_mic.read_text()
    original = "import { fft, util as fftUtil } from 'fft-js';"
    replacement = "import fftJs from 'fft-js';\nconst { fft, util: fftUtil } = fftJs;"
    if original in source and replacement not in source:
        alsa_mic.write_text(source.replace(original, replacement))
PY

  echo '{"app":"lotus-lantern","status":"installing","progress":"Installerar dependencies och bygger..."}' > "$sf"
  if ! sudo bash -lc 'set -e; cd /opt/lotus-light/pi; rm -rf node_modules; npm cache clean --force; NODE_OPTIONS="--max-old-space-size=256" npm install --no-audit --no-fund; NODE_OPTIONS="--max-old-space-size=256" npm run build; npm prune --production 2>/dev/null || true' >> "$log_file" 2>&1; then
    return 1
  fi

  sudo setcap cap_net_raw+eip "$(readlink -f "$(which node)")" >> "$log_file" 2>&1 || true
  write_lotus_update_script

  echo '{"app":"lotus-lantern","status":"installing","progress":"Skapar systemtjänster..."}' > "$sf"
  sudo tee /etc/systemd/system/lotus-light.service > /dev/null <<EOF
[Unit]
Description=Lotus Light Link — Audio-reactive BLE LED controller
After=network.target bluetooth.target
Wants=bluetooth.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lotus-light/pi
ExecStart=/usr/bin/node dist/index.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=BRIDGE_URL=http://localhost:3000/api/sonos
Environment=CONFIG_PORT=3001
Environment=TICK_MS=50
MemoryMax=128M
AllowedCPUs=${default_core}
CPUQuota=100%
Nice=-5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=lotus-light

[Install]
WantedBy=multi-user.target
EOF

  sudo tee /etc/systemd/system/lotus-update.service > /dev/null <<'EOF'
[Unit]
Description=Lotus Light Link — Auto-update from dashboard

[Service]
Type=oneshot
ExecStart=/opt/lotus-light/pi/dashboard-update.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=lotus-update
EOF

  sudo tee /etc/systemd/system/lotus-update.timer > /dev/null <<'EOF'
[Unit]
Description=Lotus Light Link — Auto-update timer (every 5 min)

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  if ! sudo systemctl daemon-reload >> "$log_file" 2>&1 || ! sudo systemctl enable lotus-light >> "$log_file" 2>&1 || ! sudo systemctl enable --now lotus-update.timer >> "$log_file" 2>&1; then
    return 1
  fi

  if ! sudo test -f /etc/systemd/system/lotus-light.service; then
    echo "lotus-light.service saknas efter installation" >> "$log_file"
    return 1
  fi

  sudo systemctl start lotus-light >> "$log_file" 2>&1 || true
  sleep 2
  if ! sudo systemctl is-active --quiet lotus-light; then
    sudo journalctl -u lotus-light -n 40 --no-pager >> "$log_file" 2>&1 || true
    echo "lotus-light.service startade men avslutades direkt" >> "$log_file"
    return 1
  fi

  if [ "$needs_reboot" = "true" ]; then
    echo 'Installation klar — reboot kan krävas'
  else
    echo 'Installation klar'
  fi
}

do_install() {
  local app repo dir script sf install_message
  app=$1
  repo=${APP_REPOS[$app]}
  dir=${APP_DIRS[$app]}
  script=${APP_INSTALL_SCRIPTS[$app]}
  sf="$INSTALL_DIR/${app}.json"
  install_message="Installation klar"

  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Startar installation...\"}" > "$sf"

  export XDG_RUNTIME_DIR="$USER_RUNTIME_DIR"
  export DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS"

  local default_port=${APP_PORTS[$app]}
  local default_core=${APP_CORES[$app]}

  if [ "$app" = "lotus-lantern" ]; then
    if ! install_message=$(install_lotus_lantern "$repo" "$INSTALL_DIR/${app}.log" "$sf" "$default_core"); then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi
  else
    [ -d "$dir" ] && rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"

    echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Klonar repo...\"}" > "$sf"
    if ! nice -n 15 git clone --depth 1 "$repo" "$dir" > "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Git clone misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi

    echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Kör installationsskript...\"}" > "$sf"
    if [ ! -f "$dir/$script" ]; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript saknas\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi

    chmod +x "$dir/$script"
    if [ "$app" = "cast-away" ]; then
      if ! printf '\n%s\n' "$default_core" | nice -n 15 ionice -c 3 bash "$dir/$script" >> "$INSTALL_DIR/${app}.log" 2>&1; then
        echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
        return 1
      fi
    else
      if ! printf '%s\n%s\n' "$default_port" "$default_core" | nice -n 15 ionice -c 3 bash "$dir/$script" >> "$INSTALL_DIR/${app}.log" 2>&1; then
        echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
        return 1
      fi
    fi
  fi

  rm -f "$CACHE_FILE"
  echo "{\"app\":\"${app}\",\"status\":\"success\",\"message\":\"${install_message}\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
}

handle_request() {
  local method path
  read -r method path _
  path=${path%$'\r'}

  local response status_line ct
  response=""
  status_line="HTTP/1.1 200 OK"
  ct="application/json"

  case "$method $path" in
    "GET /api/status")
      response=$(get_cached_status)
      ;;

    POST\ /api/install/*)
      local app
      app=${path#/api/install/}
      if [ -z "${APP_REPOS[$app]}" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        do_install "$app" &
        response="{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Startar installation...\"}"
      fi
      ;;

    GET\ /api/install-status/*)
      local app
      app=${path#/api/install-status/}
      [ -f "$INSTALL_DIR/${app}.json" ] && response=$(< "$INSTALL_DIR/${app}.json") || response="{\"app\":\"${app}\",\"status\":\"idle\"}"
      ;;

    "POST /api/update/dashboard")
      local sf ddir ndir dashboard_log remote_ref
      sf="$STATUS_DIR/dashboard.json"
      ddir="$HOME/pi-dashboard"
      ndir="/var/www/pi-dashboard"
      dashboard_log="$STATUS_DIR/dashboard.log"
      remote_ref="origin/main"
      mkdir -p "$STATUS_DIR"
      echo '{"app":"dashboard","status":"updating"}' > "$sf"
      : > "$dashboard_log"
      response='{"app":"dashboard","status":"updating"}'
      (
        cd "$ddir" 2>/dev/null || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Dir not found\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        nice -n 15 git fetch origin main --depth=1 --quiet 2>/dev/null || nice -n 15 git fetch origin master --depth=1 --quiet 2>/dev/null || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Git fetch failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        git rev-parse origin/main >/dev/null 2>&1 || remote_ref="origin/master"
        git reset --hard "$remote_ref" --quiet || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Git reset failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        git clean -fd >/dev/null 2>&1 || true
        sed -i 's/\r$//' "$ddir/public/pi-scripts/"*.sh
        chmod +x "$ddir/public/pi-scripts/"*.sh
        NODE_OPTIONS="--max-old-space-size=256" nice -n 15 ionice -c 3 npm install --no-audit --no-fund || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"npm install failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        npx -y update-browserslist-db@latest >/dev/null 2>&1 || true
        NODE_OPTIONS="--max-old-space-size=256" nice -n 15 ionice -c 3 npm run build || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Build failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        sudo mkdir -p "$ndir"
        sudo cp -r dist/* "$ndir/" || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Deploy failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        if [ -f "$ddir/public/pi-scripts/pi-dashboard-api.sh" ]; then
          sudo install -m 755 "$ddir/public/pi-scripts/pi-dashboard-api.sh" /usr/local/bin/pi-dashboard-api.sh || true
        fi
        rm -rf node_modules
        npm cache clean --force >/dev/null 2>&1 || true
        echo "{\"app\":\"dashboard\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
        sudo systemctl restart pi-dashboard-api >/dev/null 2>&1 || true
      ) >> "$dashboard_log" 2>&1 &
      ;;

    POST\ /api/update/*)
      local app uscript
      app=${path#/api/update/}
      uscript=${APP_UPDATE_SCRIPTS[$app]}
      echo '{"status":"updating"}' > "$STATUS_DIR/${app}.json"
      if [ ! -f "$uscript" ]; then
        echo "Uppdateringsskript saknas: $uscript" > "$STATUS_DIR/${app}.log"
        echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Uppdateringsskript saknas\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/${app}.json"
      elif nice -n 15 ionice -c 3 bash "$uscript" > "$STATUS_DIR/${app}.log" 2>&1; then
        echo "{\"app\":\"${app}\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/${app}.json"
      else
        local tail_err
        tail_err=$(tail -5 "$STATUS_DIR/${app}.log" 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c1-200)
        echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"${tail_err:-Update failed}\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/${app}.json"
      fi
      response=$(< "$STATUS_DIR/${app}.json")
      ;;

    GET\ /api/update-status/*)
      local app
      app=${path#/api/update-status/}
      [ -f "$STATUS_DIR/${app}.json" ] && response=$(< "$STATUS_DIR/${app}.json") || response="{\"app\":\"${app}\",\"status\":\"idle\"}"
      ;;

    POST\ /api/service/*/*)
      local rest app action svc
      rest=${path#/api/service/}
      app=${rest%%/*}
      action=${rest#*/}
      svc=${APP_SERVICES[$app]}
      if [ -z "$svc" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        local svc_ok="false" svc_err="" log_file now
        log_file="$STATUS_DIR/${app}.log"
        now="$(date -Iseconds)"
        # Try system-level first, then user-level with explicit user bus env
        if sudo systemctl "$action" "${svc}.service" 2>/tmp/svc-err-$$; then
          svc_ok="true"
        elif user_systemctl "$action" "${svc}.service" 2>/tmp/svc-err-$$; then
          svc_ok="true"
        else
          svc_err=$(cat /tmp/svc-err-$$ 2>/dev/null | head -1 | sed 's/"/\\"/g')
        fi
        rm -f /tmp/svc-err-$$
        if [ "$svc_ok" = "true" ]; then
          rm -f "$CACHE_FILE"
          printf "[%s] service %s %s: success\n" "$now" "$svc" "$action" >> "$log_file"
          response="{\"app\":\"${app}\",\"action\":\"${action}\",\"status\":\"success\"}"
        else
          printf "[%s] service %s %s: %s\n" "$now" "$svc" "$action" "${svc_err:-systemctl ${action} failed}" >> "$log_file"
          response="{\"app\":\"${app}\",\"action\":\"${action}\",\"status\":\"error\",\"message\":\"${svc_err:-systemctl ${action} failed}\"}"
        fi
      fi
      ;;

    GET\ /api/service-log/*)
      local app svc lc tmp_err
      app=${path#/api/service-log/}
      svc=${APP_SERVICES[$app]}
      if [ -z "$svc" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        tmp_err="/tmp/service-log-$$.err"
        lc=$(
          timeout 3s sudo -n journalctl -u "${svc}.service" -n 60 --no-pager 2>"$tmp_err" ||
          timeout 3s journalctl -u "${svc}.service" -n 60 --no-pager 2>>"$tmp_err" ||
          timeout 3s systemctl status "${svc}.service" --no-pager -n 40 2>>"$tmp_err" ||
          cat "$tmp_err"
        )
        rm -f "$tmp_err"
        lc=$(printf "%s" "$lc" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/  /g' | tr '\n' '|' | sed 's/|/\\n/g')
        [ -z "$lc" ] && lc="Inga tjänstloggar tillgängliga"
        response="{\"log\":\"${lc}\"}"
      fi
      ;;

    GET\ /api/update-log/*|GET\ /api/install-log/*)
      local logtype app lf lc
      logtype=${path#/api/}
      logtype=${logtype%%/*}
      app=${path##*/}
      [ "$logtype" = "install-log" ] && lf="$INSTALL_DIR/${app}.log" || lf="$STATUS_DIR/${app}.log"
      if [ -f "$lf" ]; then
        lc=$(tail -50 "$lf" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/  /g' | tr '\n' '|' | sed 's/|/\\n/g')
        response="{\"log\":\"${lc}\"}"
      else
        response="{\"log\":\"Inga loggar tillgängliga\"}"
      fi
      ;;

    "GET /api/versions")
      local vj
      vj=""
      for app in lotus-lantern cast-away sonos-gateway; do
        local dir repo local_v local_hash remote_hash has_update
        dir=${APP_DIRS[$app]}
        repo=${APP_REPOS[$app]}
        local_v=""
        local_hash=""
        remote_hash=""
        if [ -d "$dir/.git" ]; then
          local_v=$(git -C "$dir" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
          local_v="${local_v,,}"
          local_hash=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
        fi
        remote_hash=$(git ls-remote --heads "$repo" main 2>/dev/null | cut -c1-7)
        [ -n "$vj" ] && vj="${vj},"
        has_update="false"
        [ -n "$local_hash" ] && [ -n "$remote_hash" ] && [ "$local_hash" != "$remote_hash" ] && has_update="true"
        vj="${vj}\"${app}\":{\"local\":\"${local_v}\",\"remote\":\"\",\"hasUpdate\":${has_update}}"
      done

      local d_local d_hash d_remote_hash d_update
      d_local=""
      d_hash=""
      d_remote_hash=""
      if [ -d "$HOME/pi-dashboard/.git" ]; then
        d_local=$(git -C "$HOME/pi-dashboard" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
        d_local="${d_local,,}"
        d_hash=$(git -C "$HOME/pi-dashboard" rev-parse --short HEAD 2>/dev/null)
      fi
      d_remote_hash=$(git ls-remote --heads "$(git -C "$HOME/pi-dashboard" remote get-url origin 2>/dev/null)" main 2>/dev/null | cut -c1-7)
      d_update="false"
      [ -n "$d_hash" ] && [ -n "$d_remote_hash" ] && [ "$d_hash" != "$d_remote_hash" ] && d_update="true"
      vj="${vj},\"dashboard\":{\"local\":\"${d_local}\",\"remote\":\"\",\"hasUpdate\":${d_update}}"
      response="{${vj}}"
      ;;

    "OPTIONS "*)
      response=""
      ;;

    *)
      status_line="HTTP/1.1 404 Not Found"
      response='{"error":"not found"}'
      ;;
  esac

  local len
  len=${#response}
  printf "%s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n%s" \
    "$status_line" "$ct" "$len" "$response"
}

if [ "$REQUEST_MODE" = "--handle-request" ]; then
  handle_request
  exit 0
fi

echo "Pi Dashboard API listening on port $PORT"
while true; do
  socat TCP-LISTEN:${PORT},reuseaddr,fork EXEC:"${SCRIPT_PATH} --handle-request ${PORT}" 2>/dev/null || sleep 1
done
