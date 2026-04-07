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
    local is_online=$(check_service "$port")
    local is_installed=$(check_installed "$dir")
    local ver=$(get_version "$dir")
    
    [ -n "$services_json" ] && services_json="${services_json},"
    services_json="${services_json}\"${app}\":{\"online\":${is_online},\"installed\":${is_installed},\"version\":\"${ver}\"}"
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

    "POST /api/update/lotus-lantern"|"POST /api/update/cast-away"|"POST /api/update/sonos-gateway")
      local app=$(echo "$path" | sed 's|/api/update/||')
      local update_script=${APP_UPDATE_SCRIPTS[$app]}
      echo '{"status":"updating"}' > "$STATUS_DIR/${app}.json"
      # Run with low priority
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
