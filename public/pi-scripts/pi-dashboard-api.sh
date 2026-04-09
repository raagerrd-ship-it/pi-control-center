#!/bin/bash
# Pi Dashboard API — lightweight HTTP server optimized for Pi Zero 2 W
# Uses /proc for stats (no heavy subprocesses), caches results
# Dynamic service registry from services.json + assignments.json
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

REGISTRY_FILE="/var/www/pi-dashboard/services.json"
ASSIGNMENTS_FILE="/etc/pi-dashboard/assignments.json"

mkdir -p "$STATUS_DIR" "$INSTALL_DIR"
sudo mkdir -p /etc/pi-dashboard 2>/dev/null || true

# Read git info once at startup
DASHBOARD_COMMIT=""
DASHBOARD_COMMIT_SHORT=""
DASHBOARD_BRANCH=""
if [ -d "$HOME/pi-dashboard/.git" ]; then
  DASHBOARD_COMMIT=$(git -C "$HOME/pi-dashboard" rev-parse HEAD 2>/dev/null || echo "")
  DASHBOARD_COMMIT_SHORT=$(git -C "$HOME/pi-dashboard" rev-parse --short HEAD 2>/dev/null || echo "")
  DASHBOARD_BRANCH=$(git -C "$HOME/pi-dashboard" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
fi

# Initialize assignments file if missing
[ -f "$ASSIGNMENTS_FILE" ] || echo '{}' | sudo tee "$ASSIGNMENTS_FILE" > /dev/null

user_systemctl() {
  XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" \
  DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS" \
  systemctl --user "$@"
}

# --- Dynamic registry helpers ---

# Get a field from services.json: registry_get <key> <field>
registry_get() {
  jq -r --arg k "$1" --arg f "$2" '.[] | select(.key == $k) | .[$f] // empty' "$REGISTRY_FILE" 2>/dev/null
}

# Get all service keys from registry
registry_keys() {
  jq -r '.[].key' "$REGISTRY_FILE" 2>/dev/null
}

# Get assignment field: assignment_get <key> <field>
assignment_get() {
  jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // empty' "$ASSIGNMENTS_FILE" 2>/dev/null
}

# Save assignment: assignment_set <key> <port> <core>
assignment_set() {
  local tmp
  tmp=$(jq --arg k "$1" --argjson p "$2" --argjson c "$3" '.[$k] = {"port": $p, "core": $c}' "$ASSIGNMENTS_FILE")
  echo "$tmp" | sudo tee "$ASSIGNMENTS_FILE" > /dev/null
}

# Remove assignment: assignment_remove <key>
assignment_remove() {
  local tmp
  tmp=$(jq --arg k "$1" 'del(.[$k])' "$ASSIGNMENTS_FILE")
  echo "$tmp" | sudo tee "$ASSIGNMENTS_FILE" > /dev/null
}

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
  local install_dir=$2
  local svc=$3

  if [ "$app" = "lotus-lantern" ]; then
    [ -d "$install_dir/.git" ] && [ -f "/etc/systemd/system/${svc}.service" ] && echo "true" || echo "false"
  else
    [ -d "$install_dir" ] && { [ -f "$HOME/.config/systemd/user/${svc}.service" ] || [ -f "/etc/systemd/system/${svc}.service" ]; } && echo "true" || echo "false"
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

  for app in $(registry_keys); do
    local svc install_dir port core online installed ver s_cpu s_ram s_core pid aff
    svc=$(registry_get "$app" "service")
    install_dir=$(eval echo "$(registry_get "$app" "installDir")")
    port=$(assignment_get "$app" "port")
    core=$(assignment_get "$app" "core")

    [ -z "$port" ] && port=0
    [ -z "$core" ] && core=-1

    online="false"
    [ "$port" -gt 0 ] && online=$(check_service "$port")
    installed=$(check_installed "$app" "$install_dir" "$svc")
    ver=$(get_version "$install_dir")
    s_cpu=0
    s_ram=0
    s_core=${core}

    if [ "$online" = "true" ]; then
      s_ram=$(get_service_ram "$svc")
      pid=$(systemctl show "${svc}.service" --property=MainPID 2>/dev/null | cut -d= -f2)
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
    svc_json="${svc_json}\"${app}\":{\"online\":${online},\"installed\":${installed},\"version\":\"${ver}\",\"cpu\":${s_cpu:-0},\"ramMb\":${s_ram:-0},\"cpuCore\":${s_core},\"port\":${port}}"
  done

  local dash_cpu dash_ram nginx_ram dash_pid
  dash_cpu=0
  dash_ram=$(get_service_ram "pi-dashboard-api")
  nginx_ram=$(get_service_ram "nginx")
  dash_ram=$((dash_ram + nginx_ram))
  dash_pid=$(systemctl show "pi-dashboard-api.service" --property=MainPID 2>/dev/null | cut -d= -f2)
  [ -n "$dash_pid" ] && [ "$dash_pid" != "0" ] && dash_cpu=$(ps -p "$dash_pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")

  echo "{\"cpu\":${cpu:-0},\"temp\":${temp:-0},\"ramUsed\":${ram_used:-0},\"ramTotal\":${ram_total:-0},\"diskUsed\":${disk_used:-0},\"diskTotal\":${disk_total:-0},\"uptime\":\"${uptime_str}\",\"dashboardCpu\":${dash_cpu:-0},\"dashboardRamMb\":${dash_ram:-0},\"commit\":\"${DASHBOARD_COMMIT_SHORT}\",\"branch\":\"${DASHBOARD_BRANCH}\",\"services\":{${svc_json}}}"
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
systemctl restart "$SERVICE"
EOF

  sudo chmod +x "$update_script"
}

install_lotus_lantern() {
  local repo log_file sf default_core default_port needs_reboot node_major overlay_file
  repo=$1
  log_file=$2
  sf=$3
  default_core=$4
  default_port=$5
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
Environment=CONFIG_PORT=${default_port}
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

  if ! sudo systemctl daemon-reload >> "$log_file" 2>&1 || ! sudo systemctl enable lotus-light >> "$log_file" 2>&1; then
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

progress() {
  local sf=$1 app=$2 msg=$3 start=$4
  local elapsed=$(( $(date +%s) - start ))
  local min=$((elapsed / 60)) sec=$((elapsed % 60))
  local time_str
  if [ "$min" -gt 0 ]; then time_str="${min}m ${sec}s"; else time_str="${sec}s"; fi
  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"${msg}\",\"elapsed\":\"${time_str}\"}" > "$sf"
}

do_install() {
  local app repo install_dir script svc sf install_message req_port req_core start_time
  app=$1
  req_port=$2
  req_core=$3
  repo=$(registry_get "$app" "repo")
  install_dir=$(eval echo "$(registry_get "$app" "installDir")")
  script=$(registry_get "$app" "installScript")
  svc=$(registry_get "$app" "service")
  sf="$INSTALL_DIR/${app}.json"
  install_message="Installation klar"
  start_time=$(date +%s)

  [ -z "$repo" ] && { echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Okänd app\"}" > "$sf"; return 1; }

  progress "$sf" "$app" "Startar installation..." "$start_time"

  export XDG_RUNTIME_DIR="$USER_RUNTIME_DIR"
  export DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS"

  if [ "$app" = "lotus-lantern" ]; then
    if ! install_message=$(install_lotus_lantern "$repo" "$INSTALL_DIR/${app}.log" "$sf" "$req_core" "$req_port" "$start_time"); then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi
  else
    progress "$sf" "$app" "Förbereder katalog..." "$start_time"
    [ -d "$install_dir" ] && rm -rf "$install_dir"
    mkdir -p "$(dirname "$install_dir")"

    progress "$sf" "$app" "Klonar repo..." "$start_time"
    if ! nice -n 15 git clone --depth 1 "$repo" "$install_dir" > "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Git clone misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi

    progress "$sf" "$app" "Verifierar installationsskript..." "$start_time"
    if [ ! -f "$install_dir/$script" ]; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript saknas\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi

    chmod +x "$install_dir/$script"

    progress "$sf" "$app" "Kör installationsskript (kan ta flera minuter)..." "$start_time"
    if ! nice -n 15 ionice -c 3 bash "$install_dir/$script" --port "$req_port" --core "$req_core" >> "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi

    progress "$sf" "$app" "Sparar konfiguration..." "$start_time"
  fi

  # Save assignment
  assignment_set "$app" "$req_port" "$req_core"

  rm -f "$CACHE_FILE"
  local total_elapsed=$(( $(date +%s) - start_time ))
  local t_min=$((total_elapsed / 60)) t_sec=$((total_elapsed % 60))
  local total_str
  if [ "$t_min" -gt 0 ]; then total_str="${t_min}m ${t_sec}s"; else total_str="${t_sec}s"; fi
  echo "{\"app\":\"${app}\",\"status\":\"success\",\"message\":\"${install_message} (${total_str})\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
}

do_uninstall() {
  local app install_dir svc uninstall_script
  app=$1
  install_dir=$(eval echo "$(registry_get "$app" "installDir")")
  svc=$(registry_get "$app" "service")
  uninstall_script=$(registry_get "$app" "uninstallScript")

  # Stop service
  sudo systemctl stop "${svc}.service" 2>/dev/null || user_systemctl stop "${svc}.service" 2>/dev/null || true
  sudo systemctl disable "${svc}.service" 2>/dev/null || user_systemctl disable "${svc}.service" 2>/dev/null || true

  # Run uninstall script if it exists
  if [ -n "$uninstall_script" ] && [ -f "$install_dir/$uninstall_script" ]; then
    chmod +x "$install_dir/$uninstall_script"
    bash "$install_dir/$uninstall_script" 2>/dev/null || true
  fi

  # Remove service files
  sudo rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/${svc}.service" 2>/dev/null || true
  sudo systemctl daemon-reload 2>/dev/null || true
  user_systemctl daemon-reload 2>/dev/null || true

  # Remove assignment
  assignment_remove "$app"
  rm -f "$CACHE_FILE"
}

handle_request() {
  local method path body content_length
  read -r method path _
  path=${path%$'\r'}

  # Read headers and body for POST
  content_length=0
  while IFS= read -r header; do
    header=${header%$'\r'}
    [ -z "$header" ] && break
    case "$header" in
      Content-Length:*|content-length:*) content_length=${header#*: } ;;
    esac
  done
  body=""
  if [ "$content_length" -gt 0 ] 2>/dev/null; then
    body=$(head -c "$content_length")
  fi

  local response status_line ct
  response=""
  status_line="HTTP/1.1 200 OK"
  ct="application/json"

  case "$method $path" in
    "GET /api/status")
      response=$(get_cached_status)
      ;;

    "GET /api/version")
      response="{\"name\":\"Pi Dashboard\",\"version\":\"1.0.0\",\"commit\":\"${DASHBOARD_COMMIT}\",\"commitShort\":\"${DASHBOARD_COMMIT_SHORT}\",\"branch\":\"${DASHBOARD_BRANCH}\"}"
      ;;

    "GET /api/available-services")
      if [ -f "$REGISTRY_FILE" ]; then
        response=$(< "$REGISTRY_FILE")
      else
        response="[]"
      fi
      ;;

    POST\ /api/install/*)
      local app req_port req_core
      app=${path#/api/install/}
      req_port=$(echo "$body" | jq -r '.port // 3000' 2>/dev/null)
      req_core=$(echo "$body" | jq -r '.core // 1' 2>/dev/null)
      if [ -z "$(registry_get "$app" "repo")" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        do_install "$app" "$req_port" "$req_core" &
        response="{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Startar installation...\"}"
      fi
      ;;

    GET\ /api/install-status/*)
      local app
      app=${path#/api/install-status/}
      [ -f "$INSTALL_DIR/${app}.json" ] && response=$(< "$INSTALL_DIR/${app}.json") || response="{\"app\":\"${app}\",\"status\":\"idle\"}"
      ;;

    POST\ /api/uninstall/*)
      local app
      app=${path#/api/uninstall/}
      if [ -z "$(registry_get "$app" "repo")" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        do_uninstall "$app"
        response="{\"app\":\"${app}\",\"status\":\"success\"}"
      fi
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
        # Copy services.json to deployed location
        [ -f "$ddir/public/services.json" ] && sudo cp "$ddir/public/services.json" "$ndir/" || true
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
      local app uscript update_json update_log
      app=${path#/api/update/}
      uscript=$(eval echo "$(registry_get "$app" "updateScript")")
      update_json="$STATUS_DIR/${app}.json"
      update_log="$STATUS_DIR/${app}.log"
      mkdir -p "$STATUS_DIR"
      if [ -z "$uscript" ] || [ ! -f "$uscript" ]; then
        echo "Uppdateringsskript saknas: $uscript" > "$update_log"
        echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Uppdateringsskript saknas\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
        response=$(< "$update_json")
      else
        echo "{\"app\":\"${app}\",\"status\":\"updating\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
        : > "$update_log"
        response=$(< "$update_json")
        (
          if [ "$app" = "lotus-lantern" ]; then
            sudo -n "$uscript"
          else
            nice -n 15 ionice -c 3 bash "$uscript"
          fi
          exit_code=$?
          if [ "$exit_code" -eq 0 ]; then
            echo "{\"app\":\"${app}\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
          else
            tail_err=$(tail -5 "$update_log" 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c1-200)
            echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"${tail_err:-Update failed}\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
          fi
        ) > "$update_log" 2>&1 &
      fi
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
      svc=$(registry_get "$app" "service")
      if [ -z "$svc" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        local svc_ok="false" svc_err="" log_file now
        log_file="$STATUS_DIR/${app}.log"
        now="$(date -Iseconds)"
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
      svc=$(registry_get "$app" "service")
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
      for app in $(registry_keys); do
        local install_dir repo local_v local_hash remote_hash has_update
        install_dir=$(eval echo "$(registry_get "$app" "installDir")")
        repo=$(registry_get "$app" "repo")
        local_v=""
        local_hash=""
        remote_hash=""
        if [ -d "$install_dir/.git" ]; then
          local_v=$(git -C "$install_dir" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
          local_v="${local_v,,}"
          local_hash=$(git -C "$install_dir" rev-parse --short HEAD 2>/dev/null)
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
