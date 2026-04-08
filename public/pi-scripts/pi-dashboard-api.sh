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

mkdir -p "$STATUS_DIR" "$INSTALL_DIR"

# App configs
declare -A APP_REPOS=(
  ["lotus-lantern"]="https://github.com/raagerrd-ship-it/lotus-light.git"
  ["cast-away"]="https://github.com/raagerrd-ship-it/cast-away.git"
  ["sonos-gateway"]="https://github.com/raagerrd-ship-it/sonos-gateway.git"
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
  [ -d "$1/.git" ] && echo "true" || echo "false"
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
  systemctl show "$1.service" --property=MemoryCurrent 2>/dev/null | awk -F= '{
    if ($2 ~ /^\[/ || $2 == "") print 0; else printf "%d", $2/1048576
  }' || echo "0"
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
    local port dir svc online installed ver s_cpu s_ram s_core pid aff
    port=${APP_PORTS[$app]}
    dir=${APP_DIRS[$app]}
    svc=${APP_SERVICES[$app]}
    online=$(check_service "$port")
    installed=$(check_installed "$dir")
    ver=$(get_version "$dir")
    s_cpu=0
    s_ram=0
    s_core=${APP_CORES[$app]:-0}

    if [ "$online" = "true" ]; then
      s_ram=$(get_service_ram "$svc")
      pid=$(systemctl show "${svc}.service" --property=MainPID 2>/dev/null | cut -d= -f2)
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

do_install() {
  local app repo dir script sf
  app=$1
  repo=${APP_REPOS[$app]}
  dir=${APP_DIRS[$app]}
  script=${APP_INSTALL_SCRIPTS[$app]}
  sf="$INSTALL_DIR/${app}.json"

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
      local sf
      sf="$STATUS_DIR/dashboard.json"
      echo '{"app":"dashboard","status":"updating"}' > "$sf"
      response='{"app":"dashboard","status":"updating"}'
      (
        local DDIR NDIR
        DDIR="$HOME/pi-dashboard"
        NDIR="/var/www/pi-dashboard"
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
      local app uscript
      app=${path#/api/update/}
      uscript=${APP_UPDATE_SCRIPTS[$app]}
      echo '{"status":"updating"}' > "$STATUS_DIR/${app}.json"
      if nice -n 15 ionice -c 3 bash "$uscript" > "$STATUS_DIR/${app}.log" 2>&1; then
        echo "{\"app\":\"${app}\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/${app}.json"
      else
        echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Update failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$STATUS_DIR/${app}.json"
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
      elif sudo systemctl "$action" "${svc}.service" 2>/dev/null; then
        rm -f "$CACHE_FILE"
        response="{\"app\":\"${app}\",\"action\":\"${action}\",\"status\":\"success\"}"
      else
        response="{\"app\":\"${app}\",\"action\":\"${action}\",\"status\":\"error\",\"message\":\"systemctl ${action} failed\"}"
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
