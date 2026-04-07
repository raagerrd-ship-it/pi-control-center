#!/bin/bash
# Pi Dashboard API — lightweight HTTP server using socat
# Serves system status and handles update triggers
# Usage: ./pi-dashboard-api.sh [port]

PORT="${1:-8585}"
STATUS_DIR="/tmp/pi-dashboard"
mkdir -p "$STATUS_DIR"

get_cpu() { top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}'; }
get_temp() { cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}' || echo "0"; }
get_ram() { free -m | awk '/^Mem:/{print $3","$2}'; }
get_disk() { df -BG / | awk 'NR==2{gsub("G","",$3); gsub("G","",$2); print $3","$2}'; }
get_uptime() { uptime -p | sed 's/up //'; }

check_service() {
  local port=$1
  if ss -tlnp | grep -q ":${port} " 2>/dev/null; then echo "true"; else echo "false"; fi
}

get_version() {
  local dir=$1
  if [ -d "$dir/.git" ]; then
    git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo ""
  else
    echo ""
  fi
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

      local ll_online=$(check_service 3001)
      local ll_ver=$(get_version /opt/lotus-light)
      local ca_online=$(check_service 3000)
      local ca_ver=$(get_version "$HOME/.local/share/cast-away")
      local sg_online=$(check_service 3002)
      local sg_ver=$(get_version "$HOME/sonos-proxy")

      response="{\"cpu\":${cpu:-0},\"temp\":${temp:-0},\"ramUsed\":${ram_used:-0},\"ramTotal\":${ram_total:-0},\"diskUsed\":${disk_used:-0},\"diskTotal\":${disk_total:-0},\"uptime\":\"${uptime_str}\",\"services\":{\"lotus-lantern\":{\"online\":${ll_online},\"version\":\"${ll_ver}\"},\"cast-away\":{\"online\":${ca_online},\"version\":\"${ca_ver}\"},\"sonos-gateway\":{\"online\":${sg_online},\"version\":\"${sg_ver}\"}}}"
      ;;

    "POST /api/update/lotus-lantern")
      echo '{"status":"updating"}' > "$STATUS_DIR/lotus-lantern.json"
      if /opt/lotus-light/pi/update-services.sh > "$STATUS_DIR/lotus-lantern.log" 2>&1; then
        echo "{\"app\":\"lotus-lantern\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/lotus-lantern.json"
      else
        echo "{\"app\":\"lotus-lantern\",\"status\":\"error\",\"message\":\"Update failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/lotus-lantern.json"
      fi
      response=$(cat "$STATUS_DIR/lotus-lantern.json")
      ;;

    "POST /api/update/cast-away")
      echo '{"status":"updating"}' > "$STATUS_DIR/cast-away.json"
      if "$HOME/.local/share/cast-away/update.sh" > "$STATUS_DIR/cast-away.log" 2>&1; then
        echo "{\"app\":\"cast-away\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/cast-away.json"
      else
        echo "{\"app\":\"cast-away\",\"status\":\"error\",\"message\":\"Update failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/cast-away.json"
      fi
      response=$(cat "$STATUS_DIR/cast-away.json")
      ;;

    "POST /api/update/sonos-gateway")
      echo '{"status":"updating"}' > "$STATUS_DIR/sonos-gateway.json"
      if "$HOME/sonos-proxy/update.sh" > "$STATUS_DIR/sonos-gateway.log" 2>&1; then
        echo "{\"app\":\"sonos-gateway\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/sonos-gateway.json"
      else
        echo "{\"app\":\"sonos-gateway\",\"status\":\"error\",\"message\":\"Update failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/sonos-gateway.json"
      fi
      response=$(cat "$STATUS_DIR/sonos-gateway.json")
      ;;

    GET\ /api/update-status/*)
      local app=$(echo "$path" | sed 's|/api/update-status/||')
      if [ -f "$STATUS_DIR/${app}.json" ]; then
        response=$(cat "$STATUS_DIR/${app}.json")
      else
        response="{\"app\":\"${app}\",\"status\":\"idle\"}"
      fi
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
