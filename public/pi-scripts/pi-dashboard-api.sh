#!/bin/bash
# Pi Dashboard API — lightweight HTTP server using socat
# Serves system status, handles update and install triggers
# Usage: ./pi-dashboard-api.sh [port]

PORT="${1:-8585}"
STATUS_DIR="/tmp/pi-dashboard"
INSTALL_DIR="/tmp/pi-dashboard/install"
mkdir -p "$STATUS_DIR" "$INSTALL_DIR"

# App install configs: repo URL and install directory
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

get_cpu() { top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}'; }
get_temp() { cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}' || echo "0"; }
get_ram() { free -m | awk '/^Mem:/{print $3","$2}'; }
get_disk() { df -BG / | awk 'NR==2{gsub("G","",$3); gsub("G","",$2); print $3","$2}'; }
get_uptime() { uptime -p | sed 's/up //'; }

check_service() {
  local port=$1
  if ss -tlnp | grep -q ":${port} " 2>/dev/null; then echo "true"; else echo "false"; fi
}

check_installed() {
  local dir=$1
  if [ -d "$dir" ] && [ -d "$dir/.git" ]; then echo "true"; else echo "false"; fi
}

get_version() {
  local dir=$1
  if [ -d "$dir/.git" ]; then
    git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo ""
  else
    echo ""
  fi
}

do_install() {
  local app=$1
  local repo=${APP_REPOS[$app]}
  local dir=${APP_DIRS[$app]}
  local script=${APP_INSTALL_SCRIPTS[$app]}
  local status_file="$INSTALL_DIR/${app}.json"

  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Klonar repo...\"}" > "$status_file"

  # Clone repo
  if [ -d "$dir" ]; then
    rm -rf "$dir"
  fi

  mkdir -p "$(dirname "$dir")"
  if ! git clone "$repo" "$dir" > "$INSTALL_DIR/${app}.log" 2>&1; then
    echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Git clone misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$status_file"
    return 1
  fi

  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Kör installationsskript...\"}" > "$status_file"

  # Run install script if it exists
  if [ -f "$dir/$script" ]; then
    chmod +x "$dir/$script"
    if ! bash "$dir/$script" >> "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$status_file"
      return 1
    fi
  fi

  echo "{\"app\":\"${app}\",\"status\":\"success\",\"message\":\"Installation klar\",\"timestamp\":\"$(date -Iseconds)\"}" > "$status_file"
  return 0
}

handle_request() {
  local method path
  read -r method path _
  path=$(echo "$path" | tr -d '\r')

  local response=""
  local status_line="HTTP/1.1 200 OK"
  local content_type="application/json"

  case "$method $path" in
    "GET /api/status")
      local cpu=$(get_cpu)
      local temp=$(get_temp)
      local ram=$(get_ram)
      local disk=$(get_disk)
      local uptime_str=$(get_uptime)

      local ram_used=$(echo "$ram" | cut -d, -f1)
      local ram_total=$(echo "$ram" | cut -d, -f2)
      local disk_used=$(echo "$disk" | cut -d, -f1)
      local disk_total=$(echo "$disk" | cut -d, -f2)

      # Build services JSON dynamically
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

      response="{\"cpu\":${cpu:-0},\"temp\":${temp:-0},\"ramUsed\":${ram_used:-0},\"ramTotal\":${ram_total:-0},\"diskUsed\":${disk_used:-0},\"diskTotal\":${disk_total:-0},\"uptime\":\"${uptime_str}\",\"services\":{${services_json}}}"
      ;;

    POST\ /api/install/*)
      local app=$(echo "$path" | sed 's|/api/install/||')
      if [ -z "${APP_REPOS[$app]}" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        # Run install in background
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
      if bash "$update_script" > "$STATUS_DIR/${app}.log" 2>&1; then
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
