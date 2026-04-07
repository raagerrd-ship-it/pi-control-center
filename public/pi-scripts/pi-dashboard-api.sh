#!/bin/bash
# Pi Dashboard API — lightweight HTTP server optimized for Pi Zero 2 W
# Uses /proc for stats (no heavy subprocesses), caches results
# Usage: ./pi-dashboard-api.sh [port]

PORT="${1:-8585}"
STATUS_DIR="/tmp/pi-dashboard"
INSTALL_DIR="/tmp/pi-dashboard/install"
CACHE_FILE="$STATUS_DIR/status-cache.json"
CACHE_MAX_AGE=2  # seconds — avoid re-reading /proc on rapid polls

mkdir -p "$STATUS_DIR" "$INSTALL_DIR"

# App configs
declare -A APP_REPOS=(
  ["lotus-lantern"]="https://github.com/YOUR_USER/lotus-light.git"
  ["cast-away"]="https://github.com/YOUR_USER/cast-away.git"
  ["sonos-gateway"]="https://github.com/YOUR_USER/sonos-proxy.git"
)

declare -A APP_DIRS=(
  ["lotus-lantern"]="/opt/lotus-light"
  ["cast-away"]="$HOME/.local/share/cast-away"
  ["sonos-gateway"]="$HOME/sonos-proxy"
)

declare -A APP_INSTALL_SCRIPTS=(
  ["lotus-lantern"]="pi/install.sh"
  ["cast-away"]="install.sh"
  ["sonos-gateway"]="install.sh"
)

declare -A APP_UPDATE_SCRIPTS=(
  ["lotus-lantern"]="/opt/lotus-light/pi/update-services.sh"
  ["cast-away"]="$HOME/.local/share/cast-away/update.sh"
  ["sonos-gateway"]="$HOME/sonos-proxy/update.sh"
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

# CPU core assignments: core 0 = system/dashboard, 1-3 = apps
declare -A APP_CORES=(
  ["lotus-lantern"]="1"
  ["cast-away"]="2"
  ["sonos-gateway"]="3"
)

# ---------- Lightweight system stats via /proc (no subprocesses) ----------

# CPU: read /proc/stat twice with 0.2s gap — fast and accurate
get_cpu() {
  local c1 c2
  c1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
  sleep 0.2
  c2=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
  
  local total1=$(echo "$c1" | awk '{print $1}')
  local idle1=$(echo "$c1" | awk '{print $2}')
  local total2=$(echo "$c2" | awk '{print $1}')
  local idle2=$(echo "$c2" | awk '{print $2}')
  
  local total_diff=$((total2 - total1))
  local idle_diff=$((idle2 - idle1))
  
  if [ "$total_diff" -gt 0 ]; then
    echo $(( (total_diff - idle_diff) * 100 / total_diff ))
  else
    echo 0
  fi
}

# Temperature: direct read, no subprocess
get_temp() {
  if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    local raw=$(< /sys/class/thermal/thermal_zone0/temp)
    echo "scale=1; $raw / 1000" | bc 2>/dev/null || echo $(( raw / 1000 ))
  else
    echo "0"
  fi
}

# RAM: read /proc/meminfo directly
get_ram() {
  local total avail used
  total=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
  avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
  used=$((total - avail))
  echo "${used},${total}"
}

# Disk: single df call
get_disk() {
  df -BG / | awk 'NR==2{gsub("G","",$3); gsub("G","",$2); print $3","$2}'
}

# Uptime: read /proc/uptime directly
get_uptime() {
  local secs=$(awk '{print int($1)}' /proc/uptime)
  local days=$((secs / 86400))
  local hours=$(( (secs % 86400) / 3600 ))
  local mins=$(( (secs % 3600) / 60 ))
  
  if [ "$days" -gt 0 ]; then
    echo "${days}d ${hours}h ${mins}m"
  elif [ "$hours" -gt 0 ]; then
    echo "${hours}h ${mins}m"
  else
    echo "${mins}m"
  fi
}

# Port check: use /proc/net/tcp instead of ss (no subprocess)
check_service() {
  local port=$1
  local hex_port=$(printf '%04X' "$port")
  if grep -q ":${hex_port} " /proc/net/tcp 2>/dev/null || \
     grep -q ":${hex_port} " /proc/net/tcp6 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

check_installed() {
  local dir=$1
  [ -d "$dir/.git" ] && echo "true" || echo "false"
}

get_version() {
  local dir=$1
  [ -d "$dir/.git" ] && git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo ""
}

# Get CPU% and RAM (MB) for a systemd service via cgroup
get_service_cpu() {
  local svc=$1
  systemctl show "${svc}.service" --property=CPUUsageNSec 2>/dev/null | awk -F= '{printf "%.1f", $2/1000000000}' || echo "0"
}

get_service_ram() {
  local svc=$1
  systemctl show "${svc}.service" --property=MemoryCurrent 2>/dev/null | awk -F= '{if($2 ~ /^\[/) print 0; else printf "%d", $2/1048576}' || echo "0"
}

# ---------- Cached status builder ----------

build_status_json() {
  local cpu=$(get_cpu)
  local temp=$(get_temp)
  local ram=$(get_ram)
  local disk=$(get_disk)
  local uptime_str=$(get_uptime)

  local ram_used=${ram%%,*}
  local ram_total=${ram##*,}
  local disk_used=${disk%%,*}
  local disk_total=${disk##*,}

  local services_json=""
  for app in lotus-lantern cast-away sonos-gateway; do
    local port=${APP_PORTS[$app]}
    local dir=${APP_DIRS[$app]}
    local svc=${APP_SERVICES[$app]}
    local is_online=$(check_service "$port")
    local is_installed=$(check_installed "$dir")
    local ver=$(get_version "$dir")
    local svc_cpu=0
    local svc_ram=0
    local svc_core=${APP_CORES[$app]:-0}

    # Only fetch resource usage if the service is running
    if [ "$is_online" = "true" ]; then
      svc_ram=$(get_service_ram "$svc")
      local mainpid=$(systemctl show "${svc}.service" --property=MainPID 2>/dev/null | cut -d= -f2)
      if [ -n "$mainpid" ] && [ "$mainpid" != "0" ]; then
        svc_cpu=$(ps -p "$mainpid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
        # Read actual CPU affinity
        local affinity=$(taskset -p "$mainpid" 2>/dev/null | awk '{print $NF}')
        case "$affinity" in
          2) svc_core=1 ;; 4) svc_core=2 ;; 8) svc_core=3 ;; 1) svc_core=0 ;; *) svc_core=${APP_CORES[$app]:-0} ;;
        esac
      fi
    fi
    
    [ -n "$services_json" ] && services_json="${services_json},"
    services_json="${services_json}\"${app}\":{\"online\":${is_online},\"installed\":${is_installed},\"version\":\"${ver}\",\"cpu\":${svc_cpu:-0},\"ramMb\":${svc_ram:-0},\"cpuCore\":${svc_core}}"
  done

  echo "{\"cpu\":${cpu:-0},\"temp\":${temp:-0},\"ramUsed\":${ram_used:-0},\"ramTotal\":${ram_total:-0},\"diskUsed\":${disk_used:-0},\"diskTotal\":${disk_total:-0},\"uptime\":\"${uptime_str}\",\"services\":{${services_json}}}"
}

get_cached_status() {
  # Return cached version if fresh enough (avoids re-reading /proc on every poll)
  if [ -f "$CACHE_FILE" ]; then
    local cache_age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
    if [ "$cache_age" -lt "$CACHE_MAX_AGE" ]; then
      cat "$CACHE_FILE"
      return
    fi
  fi
  
  local json=$(build_status_json)
  echo "$json" > "$CACHE_FILE"
  echo "$json"
}

# ---------- Install with resource limits ----------

do_install() {
  local app=$1
  local repo=${APP_REPOS[$app]}
  local dir=${APP_DIRS[$app]}
  local script=${APP_INSTALL_SCRIPTS[$app]}
  local status_file="$INSTALL_DIR/${app}.json"

  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Klonar repo...\"}" > "$status_file"

  [ -d "$dir" ] && rm -rf "$dir"
  mkdir -p "$(dirname "$dir")"

  # Shallow clone to save bandwidth and disk
  if ! nice -n 15 git clone --depth 1 "$repo" "$dir" > "$INSTALL_DIR/${app}.log" 2>&1; then
    echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Git clone misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$status_file"
    return 1
  fi

  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Kör installationsskript...\"}" > "$status_file"

  if [ -f "$dir/$script" ]; then
    chmod +x "$dir/$script"
    # Run with low priority to not starve other services
    if ! nice -n 15 ionice -c 3 bash "$dir/$script" >> "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$status_file"
      return 1
    fi
  fi

  echo "{\"app\":\"${app}\",\"status\":\"success\",\"message\":\"Installation klar\",\"timestamp\":\"$(date -Iseconds)\"}" > "$status_file"
}

# ---------- Request handler ----------

handle_request() {
  local method path
  read -r method path _
  path=$(echo "$path" | tr -d '\r')

  local response=""
  local status_line="HTTP/1.1 200 OK"
  local content_type="application/json"

  case "$method $path" in
    "GET /api/status")
      response=$(get_cached_status)
      ;;

    POST\ /api/install/*)
      local app=$(echo "$path" | sed 's|/api/install/||')
      if [ -z "${APP_REPOS[$app]}" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        do_install "$app" &
        response="{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Startar installation...\"}"
      fi
      ;;

    GET\ /api/install-status/*)
      local app=$(echo "$path" | sed 's|/api/install-status/||')
      if [ -f "$INSTALL_DIR/${app}.json" ]; then
        response=$(cat "$INSTALL_DIR/${app}.json")
      else
        response="{\"app\":\"${app}\",\"status\":\"idle\"}"
      fi
      ;;

    "POST /api/update/dashboard")
      echo '{"status":"updating"}' > "$STATUS_DIR/dashboard.json"
      local DASHBOARD_DIR="$HOME/pi-dashboard"
      local NGINX_DIR="/var/www/pi-dashboard"
      (
        cd "$DASHBOARD_DIR" 2>/dev/null || exit 1
        nice -n 15 git fetch origin main --depth=1 --quiet 2>/dev/null
        nice -n 15 git pull origin main --quiet 2>/dev/null || exit 1
        NODE_OPTIONS="--max-old-space-size=256" nice -n 15 ionice -c 3 npm install --production --no-audit --no-fund 2>/dev/null
        NODE_OPTIONS="--max-old-space-size=256" nice -n 15 ionice -c 3 npm run build 2>/dev/null || exit 1
        sudo cp -r dist/* "$NGINX_DIR/" 2>/dev/null
      ) > "$STATUS_DIR/dashboard.log" 2>&1
      if [ $? -eq 0 ]; then
        echo "{\"app\":\"dashboard\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/dashboard.json"
      else
        echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Update failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/dashboard.json"
      fi
      response=$(cat "$STATUS_DIR/dashboard.json")
      ;;

    "POST /api/update/lotus-lantern"|"POST /api/update/cast-away"|"POST /api/update/sonos-gateway")
      local app=$(echo "$path" | sed 's|/api/update/||')
      local update_script=${APP_UPDATE_SCRIPTS[$app]}
      echo '{"status":"updating"}' > "$STATUS_DIR/${app}.json"
      if nice -n 15 ionice -c 3 bash "$update_script" > "$STATUS_DIR/${app}.log" 2>&1; then
        echo "{\"app\":\"${app}\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/${app}.json"
      else
        echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Update failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/${app}.json"
      fi
      response=$(cat "$STATUS_DIR/${app}.json")
      ;;

    GET\ /api/update-status/*)
      local app=$(echo "$path" | sed 's|/api/update-status/||')
      if [ -f "$STATUS_DIR/${app}.json" ]; then
        response=$(cat "$STATUS_DIR/${app}.json")
      else
        response="{\"app\":\"${app}\",\"status\":\"idle\"}"
      fi
      ;;

    POST\ /api/service/*/start|POST\ /api/service/*/stop|POST\ /api/service/*/restart)
      local app=$(echo "$path" | awk -F/ '{print $4}')
      local action=$(echo "$path" | awk -F/ '{print $5}')
      local svc_name=${APP_SERVICES[$app]}
      if [ -z "$svc_name" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        if sudo systemctl "$action" "${svc_name}.service" 2>/dev/null; then
          # Invalidate status cache after service action
          rm -f "$CACHE_FILE"
          response="{\"app\":\"${app}\",\"action\":\"${action}\",\"status\":\"success\"}"
        else
          response="{\"app\":\"${app}\",\"action\":\"${action}\",\"status\":\"error\",\"message\":\"systemctl ${action} failed\"}"
        fi
      fi
      ;;

    GET\ /api/update-log/*)
      local app=$(echo "$path" | sed 's|/api/update-log/||')
      local logfile="$STATUS_DIR/${app}.log"
      if [ -f "$logfile" ]; then
        local log_content=$(tail -50 "$logfile" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/  /g' | tr '\n' '|' | sed 's/|/\\n/g')
        response="{\"log\":\"${log_content}\"}"
      else
        response="{\"log\":\"Inga loggar tillgängliga\"}"
      fi
      ;;

    GET\ /api/install-log/*)
      local app=$(echo "$path" | sed 's|/api/install-log/||')
      local logfile="$INSTALL_DIR/${app}.log"
      if [ -f "$logfile" ]; then
        local log_content=$(tail -50 "$logfile" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/  /g' | tr '\n' '|' | sed 's/|/\\n/g')
        response="{\"log\":\"${log_content}\"}"
      else
        response="{\"log\":\"Inga loggar tillgängliga\"}"
      fi
      ;;

    "OPTIONS "*)
      response=""
      ;;

    *)
      status_line="HTTP/1.1 404 Not Found"
      response='{"error":"not found"}'
      ;;
  esac

  local len=${#response}
  printf "%s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n%s" \
    "$status_line" "$content_type" "$len" "$response"
}

echo "Pi Dashboard API listening on port $PORT"
while true; do
  socat TCP-LISTEN:${PORT},reuseaddr,fork SYSTEM:"bash -c 'handle_request'" 2>/dev/null ||
  while true; do
    { handle_request; } | nc -l -p ${PORT} -q 1 2>/dev/null || break
  done
done
