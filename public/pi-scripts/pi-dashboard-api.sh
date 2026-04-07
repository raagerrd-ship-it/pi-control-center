#!/bin/bash
# Pi Dashboard API — lightweight HTTP server optimized for Pi Zero 2 W
# Uses /proc for stats (no heavy subprocesses), caches results
# Usage: ./pi-dashboard-api.sh [port]

PORT="${1:-8585}"
STATUS_DIR="/tmp/pi-dashboard"
INSTALL_DIR="/tmp/pi-dashboard/install"
CACHE_FILE="$STATUS_DIR/status-cache.json"
CACHE_MAX_AGE=2  # seconds

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

declare -A APP_CORES=(
  ["lotus-lantern"]="1"
  ["cast-away"]="2"
  ["sonos-gateway"]="3"
)

# ---------- Lightweight system stats via /proc ----------

# CPU: read /proc/stat twice, pure bash math where possible
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

  [ "$td" -gt 0 ] && echo $(( (td - id) * 100 / td )) || echo 0
}

# Temperature: pure bash, no bc
get_temp() {
  if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    local raw=$(< /sys/class/thermal/thermal_zone0/temp)
    local whole=$((raw / 1000))
    local frac=$(( (raw % 1000) / 100 ))
    echo "${whole}.${frac}"
  else
    echo "0"
  fi
}

# RAM: single awk call reading both values
get_ram() {
  awk '/^MemTotal:/{t=int($2/1024)} /^MemAvailable:/{a=int($2/1024)} END{print (t-a)","t}' /proc/meminfo
}

# Disk: single call
get_disk() {
  df -BG / | awk 'NR==2{gsub("G","",$3); gsub("G","",$2); print $3","$2}'
}

# Uptime: pure bash
get_uptime() {
  local secs
  read -r secs _ < /proc/uptime
  secs=${secs%%.*}
  local d=$((secs / 86400)) h=$(( (secs % 86400) / 3600 )) m=$(( (secs % 3600) / 60 ))

  if [ "$d" -gt 0 ]; then echo "${d}d ${h}h ${m}m"
  elif [ "$h" -gt 0 ]; then echo "${h}h ${m}m"
  else echo "${m}m"
  fi
}

# Port check via /proc/net/tcp (no subprocess for grep)
check_service() {
  local hex_port=$(printf '%04X' "$1")
  grep -q ":${hex_port} " /proc/net/tcp 2>/dev/null || \
  grep -q ":${hex_port} " /proc/net/tcp6 2>/dev/null
  [ $? -eq 0 ] && echo "true" || echo "false"
}

check_installed() {
  [ -d "$1/.git" ] && echo "true" || echo "false"
}

get_version() {
  if [ -d "$1/.git" ]; then
    # Return short date like "7 apr"
    local raw=$(git -C "$1" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
    # Lowercase month for Swedish style
    echo "${raw,,}"
  else
    echo ""
  fi
}

# Per-service RAM via systemd cgroup
get_service_ram() {
  systemctl show "$1.service" --property=MemoryCurrent 2>/dev/null | awk -F= '{
    if ($2 ~ /^\[/ || $2 == "") print 0; else printf "%d", $2/1048576
  }' || echo "0"
}

# ---------- Cached status builder ----------

build_status_json() {
  local cpu=$(get_cpu)
  local temp=$(get_temp)
  local ram=$(get_ram)
  local disk=$(get_disk)
  local uptime_str=$(get_uptime)

  local ram_used=${ram%%,*} ram_total=${ram##*,}
  local disk_used=${disk%%,*} disk_total=${disk##*,}

  local svc_json=""
  for app in lotus-lantern cast-away sonos-gateway; do
    local port=${APP_PORTS[$app]}
    local dir=${APP_DIRS[$app]}
    local svc=${APP_SERVICES[$app]}
    local online=$(check_service "$port")
    local installed=$(check_installed "$dir")
    local ver=$(get_version "$dir")
    local s_cpu=0 s_ram=0 s_core=${APP_CORES[$app]:-0}

    if [ "$online" = "true" ]; then
      s_ram=$(get_service_ram "$svc")
      local pid=$(systemctl show "${svc}.service" --property=MainPID 2>/dev/null | cut -d= -f2)
      if [ -n "$pid" ] && [ "$pid" != "0" ]; then
        s_cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
        # Read actual CPU affinity from taskset bitmask
        local aff=$(taskset -p "$pid" 2>/dev/null | awk '{print $NF}')
        case "$aff" in
          1) s_core=0;; 2) s_core=1;; 4) s_core=2;; 8) s_core=3;;
        esac
      fi
    fi

    [ -n "$svc_json" ] && svc_json="${svc_json},"
    svc_json="${svc_json}\"${app}\":{\"online\":${online},\"installed\":${installed},\"version\":\"${ver}\",\"cpu\":${s_cpu:-0},\"ramMb\":${s_ram:-0},\"cpuCore\":${s_core}}"
  done

  echo "{\"cpu\":${cpu:-0},\"temp\":${temp:-0},\"ramUsed\":${ram_used:-0},\"ramTotal\":${ram_total:-0},\"diskUsed\":${disk_used:-0},\"diskTotal\":${disk_total:-0},\"uptime\":\"${uptime_str}\",\"services\":{${svc_json}}}"
}

get_cached_status() {
  if [ -f "$CACHE_FILE" ]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$CACHE_MAX_AGE" ]; then
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
  local app=$1 repo=${APP_REPOS[$app]} dir=${APP_DIRS[$app]} script=${APP_INSTALL_SCRIPTS[$app]}
  local sf="$INSTALL_DIR/${app}.json"

  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Klonar repo...\"}" > "$sf"

  [ -d "$dir" ] && rm -rf "$dir"
  mkdir -p "$(dirname "$dir")"

  if ! nice -n 15 git clone --depth 1 "$repo" "$dir" > "$INSTALL_DIR/${app}.log" 2>&1; then
    echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Git clone misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
    return 1
  fi

  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Kör installationsskript...\"}" > "$sf"

  if [ -f "$dir/$script" ]; then
    chmod +x "$dir/$script"
    if ! nice -n 15 ionice -c 3 bash "$dir/$script" >> "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi
  fi

  echo "{\"app\":\"${app}\",\"status\":\"success\",\"message\":\"Installation klar\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
}

# ---------- Request handler ----------

handle_request() {
  local method path
  read -r method path _
  path=${path%$'\r'}

  local response="" status_line="HTTP/1.1 200 OK" ct="application/json"

  case "$method $path" in
    "GET /api/status")
      response=$(get_cached_status)
      ;;

    POST\ /api/install/*)
      local app=${path#/api/install/}
      if [ -z "${APP_REPOS[$app]}" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        do_install "$app" &
        response="{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Startar installation...\"}"
      fi
      ;;

    GET\ /api/install-status/*)
      local app=${path#/api/install-status/}
      [ -f "$INSTALL_DIR/${app}.json" ] && response=$(< "$INSTALL_DIR/${app}.json") || response="{\"app\":\"${app}\",\"status\":\"idle\"}"
      ;;

    "POST /api/update/dashboard")
      local sf="$STATUS_DIR/dashboard.json"
      echo '{"app":"dashboard","status":"updating"}' > "$sf"
      response='{"app":"dashboard","status":"updating"}'
      # Run update in background so HTTP response returns immediately
      (
        local DDIR="$HOME/pi-dashboard" NDIR="/var/www/pi-dashboard"
        cd "$DDIR" 2>/dev/null || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Dir not found\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        nice -n 15 git fetch origin main --depth=1 --quiet 2>/dev/null
        nice -n 15 git pull origin main --quiet 2>/dev/null || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Git pull failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        NODE_OPTIONS="--max-old-space-size=256" nice -n 15 ionice -c 3 npm install --production --no-audit --no-fund 2>/dev/null
        NODE_OPTIONS="--max-old-space-size=256" nice -n 15 ionice -c 3 npm run build 2>/dev/null || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Build failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        sudo cp -r dist/* "$NDIR/" 2>/dev/null
        echo "{\"app\":\"dashboard\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      ) >> "$STATUS_DIR/dashboard.log" 2>&1 &
      ;;

    POST\ /api/update/*)
      local app=${path#/api/update/}
      local uscript=${APP_UPDATE_SCRIPTS[$app]}
      echo '{"status":"updating"}' > "$STATUS_DIR/${app}.json"
      if nice -n 15 ionice -c 3 bash "$uscript" > "$STATUS_DIR/${app}.log" 2>&1; then
        echo "{\"app\":\"${app}\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/${app}.json"
      else
        echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Update failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/${app}.json"
      fi
      response=$(< "$STATUS_DIR/${app}.json")
      ;;

    GET\ /api/update-status/*)
      local app=${path#/api/update-status/}
      [ -f "$STATUS_DIR/${app}.json" ] && response=$(< "$STATUS_DIR/${app}.json") || response="{\"app\":\"${app}\",\"status\":\"idle\"}"
      ;;

    POST\ /api/service/*/*)
      local rest=${path#/api/service/}
      local app=${rest%%/*} action=${rest#*/}
      local svc=${APP_SERVICES[$app]}
      if [ -z "$svc" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      elif sudo systemctl "$action" "${svc}.service" 2>/dev/null; then
        rm -f "$CACHE_FILE"
        response="{\"app\":\"${app}\",\"action\":\"${action}\",\"status\":\"success\"}"
      else
        response="{\"app\":\"${app}\",\"action\":\"${action}\",\"status\":\"error\",\"message\":\"systemctl ${action} failed\"}"
      fi
      ;;

    GET\ /api/update-log/*|GET\ /api/install-log/*)
      local logtype=${path#/api/}
      logtype=${logtype%%/*}
      local app=${path##*/}
      local lf
      [ "$logtype" = "install-log" ] && lf="$INSTALL_DIR/${app}.log" || lf="$STATUS_DIR/${app}.log"
      if [ -f "$lf" ]; then
        local lc=$(tail -50 "$lf" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/  /g' | tr '\n' '|' | sed 's/|/\\n/g')
        response="{\"log\":\"${lc}\"}"
      else
        response="{\"log\":\"Inga loggar tillgängliga\"}"
      fi
      ;;

    "GET /api/versions")
      # Check remote HEAD for each app + dashboard (lightweight ls-remote)
      local vj=""
      for app in lotus-lantern cast-away sonos-gateway; do
        local dir=${APP_DIRS[$app]} repo=${APP_REPOS[$app]}
        local local_v="" remote_v=""
        [ -d "$dir/.git" ] && local_v=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
        remote_v=$(git ls-remote --heads "$repo" main 2>/dev/null | cut -c1-7)
        [ -n "$vj" ] && vj="${vj},"
        local has_update="false"
        [ -n "$local_v" ] && [ -n "$remote_v" ] && [ "$local_v" != "$remote_v" ] && has_update="true"
        vj="${vj}\"${app}\":{\"local\":\"${local_v}\",\"remote\":\"${remote_v}\",\"hasUpdate\":${has_update}}"
      done
      # Dashboard
      local d_local="" d_remote=""
      [ -d "$HOME/pi-dashboard/.git" ] && d_local=$(git -C "$HOME/pi-dashboard" rev-parse --short HEAD 2>/dev/null)
      d_remote=$(git ls-remote --heads "$(git -C "$HOME/pi-dashboard" remote get-url origin 2>/dev/null)" main 2>/dev/null | cut -c1-7)
      local d_update="false"
      [ -n "$d_local" ] && [ -n "$d_remote" ] && [ "$d_local" != "$d_remote" ] && d_update="true"
      vj="${vj},\"dashboard\":{\"local\":\"${d_local}\",\"remote\":\"${d_remote}\",\"hasUpdate\":${d_update}}"
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

  local len=${#response}
  printf "%s\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n%s" \
    "$status_line" "$ct" "$len" "$response"
}

echo "Pi Dashboard API listening on port $PORT"
while true; do
  socat TCP-LISTEN:${PORT},reuseaddr,fork SYSTEM:"bash -c 'handle_request'" 2>/dev/null ||
  while true; do
    { handle_request; } | nc -l -p ${PORT} -q 1 2>/dev/null || break
  done
done
