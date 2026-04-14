#!/bin/bash
# Pi Control Center API — lightweight HTTP server optimized for Pi Zero 2 W
# Uses /proc for stats (no heavy subprocesses), caches results
# Dynamic service registry from services.json + assignments.json
# Usage: ./pi-control-center-api.sh [port]

REQUEST_MODE="${1:-}"
INSTALL_APP=""
INSTALL_PORT=""
INSTALL_CORE=""

case "$REQUEST_MODE" in
  --handle-request)
    shift
    PORT="${1:-8585}"
    ;;
  --run-install)
    shift
    INSTALL_APP="${1:-}"
    INSTALL_PORT="${2:-3000}"
    INSTALL_CORE="${3:-1}"
    PORT="8585"
    ;;
  *)
    PORT="${1:-8585}"
    ;;
esac
SCRIPT_PATH="$(readlink -f "$0")"
PI_HOME="/home/pi"
STATUS_DIR="/tmp/pi-control-center"
INSTALL_DIR="/tmp/pi-control-center/install"
CACHE_FILE="$STATUS_DIR/status-cache.json"
CACHE_MAX_AGE=4  # seconds
USER_ID="$(id -u)"
USER_RUNTIME_DIR="/run/user/$USER_ID"
USER_BUS_ADDRESS="unix:path=$USER_RUNTIME_DIR/bus"

REGISTRY_FILE="/var/www/pi-control-center/services.json"
ASSIGNMENTS_FILE="/etc/pi-control-center/assignments.json"

HEALTH_DIR="$STATUS_DIR/health"

mkdir -p "$STATUS_DIR" "$INSTALL_DIR" "$HEALTH_DIR"
sudo mkdir -p /etc/pi-control-center 2>/dev/null || true

# Read git info once at startup
DASHBOARD_COMMIT=""
DASHBOARD_COMMIT_SHORT=""
DASHBOARD_BRANCH=""
if [ -d "$PI_HOME/pi-control-center/.git" ]; then
  DASHBOARD_COMMIT=$(git -C "$PI_HOME/pi-control-center" rev-parse HEAD 2>/dev/null || echo "")
  DASHBOARD_COMMIT_SHORT=$(git -C "$PI_HOME/pi-control-center" rev-parse --short HEAD 2>/dev/null || echo "")
  DASHBOARD_BRANCH=$(git -C "$PI_HOME/pi-control-center" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
fi

# Initialize assignments file if missing
[ -f "$ASSIGNMENTS_FILE" ] || echo '{}' | sudo tee "$ASSIGNMENTS_FILE" > /dev/null

# Fixed port mapping: UI = 3000 + core, Engine = 3050 + core
port_for_core() { echo $((3000 + ${1:-1})); }
engine_port_for_core() { echo $((3050 + ${1:-1})); }

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

# Get a component field: registry_get_component <key> <component> <field>
registry_get_component() {
  jq -r --arg k "$1" --arg c "$2" --arg f "$3" '.[] | select(.key == $k) | .components[$c][$f] // empty' "$REGISTRY_FILE" 2>/dev/null
}

# Check if service uses components format
registry_has_components() {
  local val
  val=$(jq -r --arg k "$1" '.[] | select(.key == $k) | .components // empty' "$REGISTRY_FILE" 2>/dev/null)
  [ -n "$val" ] && [ "$val" != "null" ] && echo "true" || echo "false"
}

# Get all service keys from registry
registry_keys() {
  jq -r '.[].key' "$REGISTRY_FILE" 2>/dev/null
}

# Check if a service is managed by PCC (defaults to true if field absent)
registry_is_managed() {
  local val
  val=$(jq -r --arg k "$1" '.[] | select(.key == $k) | .managed // true' "$REGISTRY_FILE" 2>/dev/null)
  [ "$val" != "false" ] && echo "true" || echo "false"
}

# Get assignment core: assignment_get_core <key>
assignment_get_core() {
  local val
  val=$(jq -r --arg k "$1" '.[$k] // empty' "$ASSIGNMENTS_FILE" 2>/dev/null)
  # Support both new format (bare number) and legacy format (object with .core)
  if [ -n "$val" ] && echo "$val" | jq -e 'type == "number"' >/dev/null 2>&1; then
    echo "$val"
  elif [ -n "$val" ] && echo "$val" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "$val" | jq -r '.core // empty' 2>/dev/null
  fi
}

# Save assignment: assignment_set <key> <core>
assignment_set() {
  local tmp tmpfile
  tmpfile="/tmp/pi-control-center/assignments.tmp.$$"
  if ! jq empty "$ASSIGNMENTS_FILE" 2>/dev/null; then
    echo '{}' | sudo tee "$ASSIGNMENTS_FILE" > /dev/null
  fi
  tmp=$(jq --arg k "$1" --argjson c "$2" '.[$k] = $c' "$ASSIGNMENTS_FILE" 2>/dev/null)
  if [ -n "$tmp" ] && echo "$tmp" | jq empty 2>/dev/null; then
    echo "$tmp" > "$tmpfile"
    sudo mv "$tmpfile" "$ASSIGNMENTS_FILE"
  else
    rm -f "$tmpfile"
    echo "WARNING: assignment_set failed for $1, keeping existing file" >&2
  fi
}

# Remove assignment: assignment_remove <key>
assignment_remove() {
  local tmp tmpfile
  tmpfile="/tmp/pi-control-center/assignments.tmp.$$"
  if ! jq empty "$ASSIGNMENTS_FILE" 2>/dev/null; then
    echo '{}' | sudo tee "$ASSIGNMENTS_FILE" > /dev/null
  fi
  tmp=$(jq --arg k "$1" 'del(.[$k])' "$ASSIGNMENTS_FILE" 2>/dev/null)
  if [ -n "$tmp" ] && echo "$tmp" | jq empty 2>/dev/null; then
    echo "$tmp" > "$tmpfile"
    sudo mv "$tmpfile" "$ASSIGNMENTS_FILE"
  else
    rm -f "$tmpfile"
    echo "WARNING: assignment_remove failed for $1, keeping existing file" >&2
  fi
}

# --- Health polling ---
# Polls /api/health on each active engine and caches the result as JSON files.
# Called in the background every 30 seconds.

poll_engine_health() {
  local app=$1 port=$2 health_file="$HEALTH_DIR/${app}.json"
  local resp
  resp=$(curl -sf --max-time 5 "http://127.0.0.1:${port}/api/health" 2>/dev/null)
  if [ -n "$resp" ]; then
    echo "$resp" > "$health_file"
  else
    echo '{"status":"unreachable"}' > "$health_file"
  fi
}

HEAL_FAIL_DIR="$STATUS_DIR/heal-fails"
mkdir -p "$HEAL_FAIL_DIR"

try_heal_component() {
  local app=$1 svc=$2 comp_label=$3 comp_port=$4
  local fail_file="$HEAL_FAIL_DIR/${app}-${comp_label}"
  local prev_fails=0
  [ -f "$fail_file" ] && prev_fails=$(cat "$fail_file" 2>/dev/null)

  if [ "$prev_fails" -ge 3 ]; then
    return
  fi

  local port_up
  port_up=$(check_service "$comp_port")
  if [ "$port_up" = "true" ]; then
    echo 0 > "$fail_file"
    return
  fi

  prev_fails=$((prev_fails + 1))
  echo "$prev_fails" > "$fail_file"
  echo "SELF-HEAL: $app/$comp_label not listening on port $comp_port (attempt $prev_fails/3), restarting $svc" >&2
  user_systemctl restart "${svc}.service" 2>/dev/null || systemctl restart "${svc}.service" 2>/dev/null
}

health_poll_loop() {
  local cleanup_counter=0
  while true; do
    for app in $(registry_keys); do
      local has_comp core port engine_port engine_svc engine_active
      has_comp=$(registry_has_components "$app")
      core=$(assignment_get_core "$app")
      [ -z "$core" ] || [ "$core" -lt 1 ] 2>/dev/null && continue
      port=$(port_for_core "$core")

      if [ "$has_comp" = "true" ]; then
        engine_svc=$(registry_get_component "$app" "engine" "service")
        [ -z "$engine_svc" ] && continue
        engine_active=$(service_is_active "$engine_svc")
        [ "$engine_active" != "true" ] && { echo '{"status":"offline"}' > "$HEALTH_DIR/${app}.json"; continue; }
        engine_port=$(engine_port_for_core "$core")
        poll_engine_health "$app" "$engine_port"

        local ui_svc
        ui_svc=$(registry_get_component "$app" "ui" "service")
        if [ -n "$ui_svc" ]; then
          try_heal_component "$app" "$ui_svc" "ui" "$port"
        fi

        try_heal_component "$app" "$engine_svc" "engine" "$engine_port"
      else
        local svc_active
        svc_active=$(service_is_active "$(registry_get "$app" "service")")
        [ "$svc_active" != "true" ] && { echo '{"status":"offline"}' > "$HEALTH_DIR/${app}.json"; continue; }
        poll_engine_health "$app" "$port"
      fi
    done
    sleep 30
    cleanup_counter=$((cleanup_counter + 1))
    if [ $((cleanup_counter % 10)) -eq 0 ]; then
      find "$STATUS_DIR" -maxdepth 1 -name '*.json' ! -name 'status-cache.json' ! -name 'factory-reset.json' -mmin +10 -delete 2>/dev/null
      find "$INSTALL_DIR" -maxdepth 1 -name '*.json' -mmin +10 -delete 2>/dev/null
      echo 0 > "$HEAL_FAIL_DIR"/* 2>/dev/null || true
    fi
  done
}

get_health() {
  local app=$1
  local hf="$HEALTH_DIR/${app}.json"
  if [ -f "$hf" ]; then
    cat "$hf"
  else
    echo '{"status":"unknown"}'
  fi
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

get_cpu_per_core() {
  # Read per-core stats from /proc/stat (cpu0, cpu1, cpu2, ...)
  local cores_before=()
  local i=0
  while IFS=' ' read -r label u n s idle w x y _rest; do
    [[ "$label" =~ ^cpu[0-9]+$ ]] || continue
    local total=$((u + n + s + idle + w + x + y))
    cores_before+=("$total:$idle")
    i=$((i + 1))
  done < /proc/stat

  sleep 0.2

  local cores_after=()
  while IFS=' ' read -r label u n s idle w x y _rest; do
    [[ "$label" =~ ^cpu[0-9]+$ ]] || continue
    local total=$((u + n + s + idle + w + x + y))
    cores_after+=("$total:$idle")
  done < /proc/stat

  local result=""
  for j in $(seq 0 $((${#cores_before[@]} - 1))); do
    local t1=${cores_before[$j]%%:*} i1=${cores_before[$j]##*:}
    local t2=${cores_after[$j]%%:*} i2=${cores_after[$j]##*:}
    local td=$((t2 - t1)) id=$((i2 - i1))
    local pct=0
    [ "$td" -gt 0 ] && pct=$(((td - id) * 100 / td))
    [ -n "$result" ] && result="${result},"
    result="${result}${pct}"
  done
  echo "[${result}]"
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

service_is_active() {
  local svc=$1
  if systemctl is-active --quiet "${svc}.service" 2>/dev/null || user_systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

get_service_pid() {
  local svc=$1 pid
  pid=$(user_systemctl show "$svc.service" --property=MainPID 2>/dev/null | cut -d= -f2)
  if [ -z "$pid" ] || [ "$pid" = "0" ]; then
    pid=$(systemctl show "$svc.service" --property=MainPID 2>/dev/null | cut -d= -f2)
  fi

  if [ -n "$pid" ] && [ "$pid" != "0" ]; then
    echo "$pid"
  else
    echo ""
  fi
}

check_installed() {
  local app=$1
  local install_dir=$2
  local svc=$3

  [ -d "$install_dir" ] && { [ -f "$PI_HOME/.config/systemd/user/${svc}.service" ] || [ -f "/etc/systemd/system/${svc}.service" ]; } && echo "true" || echo "false"
}

get_version() {
  local install_dir="$1" port="$2"
  # 1) Ask the service's own API if it's running
  if [ -n "$port" ] && [ "$port" -gt 0 ] 2>/dev/null; then
    local api_ver
    api_ver=$(curl -sf --max-time 1 "http://127.0.0.1:${port}/api/version" 2>/dev/null)
    if [ -n "$api_ver" ]; then
      # Try to extract "version" field from JSON
      local parsed
      parsed=$(echo "$api_ver" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
      if [ -n "$parsed" ]; then echo "$parsed"; return; fi
      # If not JSON, check it's not HTML before using raw response
      case "$api_ver" in
        *"<"*">"*|*"<!doctype"*|*"<html"*) ;; # HTML response, skip
        *) echo "$api_ver"; return ;;
      esac
    fi
  fi
  # 2) Git commit date
  if [ -d "$install_dir/.git" ]; then
    local raw
    raw=$(git -C "$install_dir" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
    if [ -n "$raw" ]; then echo "${raw,,}"; return; fi
  fi
  # 3) VERSION file
  if [ -f "$install_dir/VERSION" ]; then
    cat "$install_dir/VERSION" 2>/dev/null
    return
  fi
  # 4) package.json version
  if [ -f "$install_dir/package.json" ]; then
    local pv
    pv=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$install_dir/package.json" 2>/dev/null | head -1 | cut -d'"' -f4)
    if [ -n "$pv" ]; then echo "$pv"; return; fi
  fi
  echo ""
}

get_service_ram() {
  local val pid
  val=$(systemctl show "$1.service" --property=MemoryCurrent 2>/dev/null | cut -d= -f2)
  if [ -z "$val" ] || [ "$val" = "[not set]" ] || [ "$val" = "infinity" ]; then
    val=$(user_systemctl show "$1.service" --property=MemoryCurrent 2>/dev/null | cut -d= -f2)
  fi
  if [ -n "$val" ] && [ "$val" != "[not set]" ] && [ "$val" != "infinity" ] && [ "$val" != "0" ] && [ "$val" != "" ]; then
    echo $((val / 1048576))
  else
    # Fallback: read VmRSS from /proc/<PID>/status
    pid=$(get_service_pid "$1")
    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/status" ]; then
      val=$(grep '^VmRSS:' "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
      if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
        echo $((val / 1024))
        return
      fi
    fi
    echo "0"
  fi
}

build_status_json() {
  local cpu temp ram disk uptime_str ram_used ram_total disk_used disk_total svc_json cpu_cores
  cpu=$(get_cpu)
  cpu_cores=$(get_cpu_per_core)
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
    local svc install_dir port core online installed ver s_cpu s_ram s_core pid aff running has_comp
    svc=$(registry_get "$app" "service")
    install_dir=$(eval echo "$(registry_get "$app" "installDir")")
    core=$(assignment_get_core "$app")
    has_comp=$(registry_has_components "$app")

    [ -z "$core" ] && core=-1
    # Derive port from core using fixed mapping
    if [ "$core" -ge 1 ] 2>/dev/null; then
      port=$(port_for_core "$core")
    else
      port=0
    fi

    # For component-based services, check if ANY component is active
    if [ "$has_comp" = "true" ]; then
      local engine_svc ui_svc engine_online ui_online engine_cpu engine_ram ui_cpu ui_ram engine_ver ui_ver engine_port
      engine_svc=$(registry_get_component "$app" "engine" "service")
      ui_svc=$(registry_get_component "$app" "ui" "service")
      engine_port=$(engine_port_for_core "$core")
      engine_online="false"; ui_online="false"
      engine_cpu=0; engine_ram=0; ui_cpu=0; ui_ram=0
      engine_ver=""; ui_ver=""

      [ -n "$engine_svc" ] && engine_online=$(service_is_active "$engine_svc")
      if [ "$engine_online" != "true" ] && [ "$engine_port" -gt 0 ] 2>/dev/null; then
        engine_online=$(check_service "$engine_port")
      fi

      [ -n "$ui_svc" ] && ui_online=$(service_is_active "$ui_svc")
      if [ "$ui_online" != "true" ] && [ "$port" -gt 0 ] 2>/dev/null; then
        ui_online=$(check_service "$port")
      fi

      if [ "$engine_online" = "true" ] && [ -n "$engine_svc" ]; then
        engine_ram=$(get_service_ram "$engine_svc")
        local epid
        epid=$(get_service_pid "$engine_svc")
        [ -n "$epid" ] && [ "$epid" != "0" ] && engine_cpu=$(ps -p "$epid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
      fi
      if [ "$ui_online" = "true" ] && [ -n "$ui_svc" ]; then
        ui_ram=$(get_service_ram "$ui_svc")
        local upid
        upid=$(get_service_pid "$ui_svc")
        [ -n "$upid" ] && [ "$upid" != "0" ] && ui_cpu=$(ps -p "$upid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
      fi

      online="false"
      [ "$engine_online" = "true" ] || [ "$ui_online" = "true" ] && online="true"

      # Check installed: need install_dir + at least one service file
      installed="false"
      if [ -d "$install_dir" ]; then
        { [ -n "$engine_svc" ] && [ -f "$PI_HOME/.config/systemd/user/${engine_svc}.service" ]; } || \
        { [ -n "$ui_svc" ] && [ -f "$PI_HOME/.config/systemd/user/${ui_svc}.service" ]; } && installed="true"
      fi

      # Use engine port for version check (UI port serves static HTML, not API)
      ver=$(get_version "$install_dir" "$engine_port")
      engine_ver="$ver"; ui_ver="$ver"

      local total_cpu total_ram
      total_cpu=$(echo "$engine_cpu + $ui_cpu" | bc 2>/dev/null || echo "0")
      total_ram=$((engine_ram + ui_ram))

      # Read cached health data for engine
      local health_json
      health_json=$(get_health "$app")
      local health_status health_uptime health_mem_rss
      health_status=$(echo "$health_json" | jq -r '.status // "unknown"' 2>/dev/null)
      health_uptime=$(echo "$health_json" | jq -r '.uptime // 0' 2>/dev/null)
      health_mem_rss=$(echo "$health_json" | jq -r '.memory.rss // 0' 2>/dev/null)

      [ -n "$svc_json" ] && svc_json="${svc_json},"
      svc_json="${svc_json}\"${app}\":{\"online\":${online},\"installed\":${installed},\"version\":\"${ver}\",\"cpu\":${total_cpu:-0},\"ramMb\":${total_ram:-0},\"cpuCore\":${core},\"port\":${port},\"health\":{\"status\":\"${health_status}\",\"uptime\":${health_uptime:-0},\"memoryRss\":${health_mem_rss:-0}},\"components\":{\"engine\":{\"online\":${engine_online},\"version\":\"${engine_ver}\",\"cpu\":${engine_cpu:-0},\"ramMb\":${engine_ram:-0},\"service\":\"${engine_svc}\",\"port\":${engine_port},\"cpuCore\":${core}},\"ui\":{\"online\":${ui_online},\"version\":\"${ui_ver}\",\"cpu\":${ui_cpu:-0},\"ramMb\":${ui_ram:-0},\"service\":\"${ui_svc}\",\"port\":${port},\"cpuCore\":0}}}"
    else
      # Legacy single-service
      running=$(service_is_active "$svc")
      online="$running"
      if [ "$online" != "true" ] && [ "$port" -gt 0 ]; then
        online=$(check_service "$port")
      fi
      installed=$(check_installed "$app" "$install_dir" "$svc")
      ver=$(get_version "$install_dir" "$port")
      s_cpu=0
      s_ram=0
      s_core=${core}

      if [ "$online" = "true" ]; then
        s_ram=$(get_service_ram "$svc")
        pid=$(get_service_pid "$svc")
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
    fi
  done

  local dash_cpu dash_ram nginx_ram dash_pid
  dash_cpu=0
  dash_ram=$(get_service_ram "pi-control-center-api")
  nginx_ram=$(get_service_ram "nginx")
  dash_ram=$((dash_ram + nginx_ram))
  dash_pid=$(systemctl show "pi-control-center-api.service" --property=MainPID 2>/dev/null | cut -d= -f2)
  [ -n "$dash_pid" ] && [ "$dash_pid" != "0" ] && dash_cpu=$(ps -p "$dash_pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")

  echo "{\"cpu\":${cpu:-0},\"cpuCores\":${cpu_cores:-[]},\"temp\":${temp:-0},\"ramUsed\":${ram_used:-0},\"ramTotal\":${ram_total:-0},\"diskUsed\":${disk_used:-0},\"diskTotal\":${disk_total:-0},\"uptime\":\"${uptime_str}\",\"dashboardCpu\":${dash_cpu:-0},\"dashboardRamMb\":${dash_ram:-0},\"commit\":\"${DASHBOARD_COMMIT_SHORT}\",\"branch\":\"${DASHBOARD_BRANCH}\",\"services\":{${svc_json}}}"
}

get_cached_status() {
  # Always serve from cache — background loop keeps it fresh
  if [ -f "$CACHE_FILE" ]; then
    cat "$CACHE_FILE"
  else
    echo '{"cpu":0,"temp":0,"ramUsed":0,"ramTotal":0,"diskUsed":0,"diskTotal":0,"uptime":"—","services":{}}'
  fi
}

# Background loop that refreshes the status cache every CACHE_MAX_AGE seconds
status_cache_loop() {
  # Build initial cache immediately
  local json
  json=$(build_status_json 2>/dev/null)
  [ -n "$json" ] && echo "$json" > "$CACHE_FILE"
  while true; do
    sleep "$CACHE_MAX_AGE"
    json=$(build_status_json 2>/dev/null)
    [ -n "$json" ] && echo "$json" > "$CACHE_FILE"
  done
}


progress() {
  local sf=$1 app=$2 msg=$3 start=$4
  local elapsed=$(( $(date +%s) - start ))
  local min=$((elapsed / 60)) sec=$((elapsed % 60))
  local time_str
  if [ "$min" -gt 0 ]; then time_str="${min}m ${sec}s"; else time_str="${sec}s"; fi
  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"${msg}\",\"elapsed\":\"${time_str}\"}" > "$sf"
}

queue_install() {
  local app=$1 req_port=$2 req_core=$3 unit_name
  unit_name="pi-control-center-install-${app}-$(date +%s)"
  sudo systemd-run --quiet --collect --no-block --unit "$unit_name" \
    -p Type=exec \
    -p User="$(whoami)" \
    -p Group="$(id -gn)" \
    -p MemoryMax=256M \
    -p Environment="XDG_RUNTIME_DIR=$USER_RUNTIME_DIR" \
    -p Environment="DBUS_SESSION_BUS_ADDRESS=$USER_BUS_ADDRESS" \
    "$SCRIPT_PATH" --run-install "$app" "$req_port" "$req_core"
}

do_install_release() {
  local app=$1 req_port=$2 req_core=$3 sf=$4 start_time=$5
  local release_url install_dir svc download_url

  release_url=$(registry_get "$app" "releaseUrl")
  install_dir=$(eval echo "$(registry_get "$app" "installDir")")
  svc=$(registry_get "$app" "service")

  [ -z "$release_url" ] && return 1

  progress "$sf" "$app" "Hämtar release-info från GitHub..." "$start_time"
  download_url=$(curl -sf "$release_url" 2>/dev/null | jq -r '.assets[] | select(.name == "dist.tar.gz") | .browser_download_url' 2>/dev/null)

  [ -z "$download_url" ] || [ "$download_url" = "null" ] && return 1

  progress "$sf" "$app" "Förbereder katalog..." "$start_time"
  [ -d "$install_dir" ] && sudo rm -rf "$install_dir"
  sudo mkdir -p "$install_dir"
  sudo chown "$(whoami):$(whoami)" "$install_dir"

  progress "$sf" "$app" "Laddar ner förbyggd release..." "$start_time"
  if ! curl -sfL "$download_url" -o "/tmp/pi-control-center/${app}-dist.tar.gz" >> "$INSTALL_DIR/${app}.log" 2>&1; then
    return 1
  fi

  progress "$sf" "$app" "Packar upp..." "$start_time"
  if ! tar xzf "/tmp/pi-control-center/${app}-dist.tar.gz" -C "$install_dir" >> "$INSTALL_DIR/${app}.log" 2>&1; then
    echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Uppackning misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
    rm -f "/tmp/pi-control-center/${app}-dist.tar.gz"
    return 1
  fi
  rm -f "/tmp/pi-control-center/${app}-dist.tar.gz"

  # Verify extraction produced files
  local file_count
  file_count=$(find "$install_dir" -mindepth 1 -maxdepth 1 | head -1)
  if [ -z "$file_count" ]; then
    echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Uppackning tom — inga filer extraherades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
    return 1
  fi

  # Run npm install if runInstallOnRelease is set (for native modules that need rebuilding)
  local run_install_on_release
  run_install_on_release=$(registry_get "$app" "runInstallOnRelease")
  if [ "$run_install_on_release" = "true" ]; then
    # Find directories containing package.json and run npm install in each
    local pkg_dirs
    pkg_dirs=$(find "$install_dir" -name "package.json" -not -path "*/node_modules/*" -exec dirname {} \;)
    for pkg_dir in $pkg_dirs; do
      if [ -d "$pkg_dir/node_modules" ]; then
        progress "$sf" "$app" "Bygger om native-moduler i ${pkg_dir##*/}..." "$start_time"
        if ! sudo systemd-run --scope --quiet -p MemoryMax=256M \
          bash -lc "cd '$pkg_dir' && NPM_CONFIG_CACHE='${install_dir}/.npm-cache' nice -n 15 ionice -c 3 npm rebuild --no-audit --no-fund" >> "$INSTALL_DIR/${app}.log" 2>&1; then
          progress "$sf" "$app" "npm rebuild misslyckades i ${pkg_dir##*/}, försöker npm install..." "$start_time"
          sudo systemd-run --scope --quiet -p MemoryMax=256M \
            bash -lc "cd '$pkg_dir' && NPM_CONFIG_CACHE='${install_dir}/.npm-cache' nice -n 15 ionice -c 3 npm install --omit=dev --no-audit --no-fund" >> "$INSTALL_DIR/${app}.log" 2>&1 || {
            echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"npm install misslyckades i ${pkg_dir##*/}\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
            return 1
          }
        fi
      fi
    done

    # Also run installScript if it exists (for additional setup like config files)
    local install_script
    install_script=$(registry_get "$app" "installScript")
    if [ -n "$install_script" ] && [ -f "$install_dir/$install_script" ]; then
      progress "$sf" "$app" "Kör installationsskript..." "$start_time"
      chmod +x "$install_dir/$install_script"
      find "$install_dir" -name '*.sh' -exec sed -i 's/\r$//' {} +
      sudo systemd-run --scope --quiet -p MemoryMax=256M \
        nice -n 15 ionice -c 3 bash "$install_dir/$install_script" --port "$req_port" --core "$req_core" >> "$INSTALL_DIR/${app}.log" 2>&1 || true
    fi
  fi

  # Skip systemd service generation if managed: false
  if [ "$(registry_is_managed "$app")" = "false" ]; then
    progress "$sf" "$app" "Hanteras externt – hoppar över systemd-service..." "$start_time"
    return 0
  fi

  progress "$sf" "$app" "Skapar systemd-service..." "$start_time"

  local has_comp
  has_comp=$(registry_has_components "$app")

  if [ "$has_comp" = "true" ]; then
    # Component-based: create separate services for engine and ui
    # Fixed ports: UI = 3000 + core, Engine = 3050 + core
    local engine_port=$(engine_port_for_core "$req_core")
    mkdir -p "$PI_HOME/.config/systemd/user" || return 1
    mkdir -p "${install_dir}/.npm-cache" || return 1

    for comp in engine ui; do
      local comp_type comp_entry comp_svc comp_always_on comp_exec comp_port
      comp_type=$(registry_get_component "$app" "$comp" "type")
      comp_entry=$(registry_get_component "$app" "$comp" "entrypoint")
      comp_svc=$(registry_get_component "$app" "$comp" "service")
      comp_always_on=$(registry_get_component "$app" "$comp" "alwaysOn")

      [ -z "$comp_svc" ] && continue

      if [ "$comp" = "engine" ]; then
        comp_port=$engine_port
      else
        comp_port=$req_port
      fi

      # Determine working directory: use the entrypoint's parent directory
      # so that Node.js can find node_modules/ adjacent to the entrypoint.
      # E.g. entrypoint="pi/dist/index.js" → work_dir="${install_dir}/pi"
      local comp_work_dir="${install_dir}"
      if [ "$comp_type" = "node" ] && [ -n "$comp_entry" ]; then
        # Strip filename to get relative dir, then strip trailing subdirs to find package root
        local entry_dir
        entry_dir=$(dirname "$comp_entry")  # e.g. "pi/dist"
        # Walk up from entry_dir to find where package.json lives
        local search_dir="${install_dir}/${entry_dir}"
        while [ "$search_dir" != "$install_dir" ] && [ "$search_dir" != "/" ]; do
          if [ -f "${search_dir}/package.json" ]; then
            comp_work_dir="$search_dir"
            break
          fi
          search_dir=$(dirname "$search_dir")
        done
        comp_exec="/usr/bin/node ${install_dir}/${comp_entry}"
      else
        comp_exec="/usr/bin/python3 ${PI_HOME}/pi-control-center/public/pi-scripts/static-spa-server.py --root ${install_dir}/${comp_entry:-dist} --port ${comp_port} --host 0.0.0.0"
      fi

      local restart_policy="on-failure"
      [ "$comp_always_on" = "true" ] && restart_policy="always"

      # Only pin engine to a specific core; UI is lightweight and can float
      local cpu_pin_lines=""
      if [ "$comp" = "engine" ]; then
        cpu_pin_lines="CPUAffinity=${req_core}
AllowedCPUs=${req_core}"
      else
        # UI: pin to core 0 (shared with dashboard) – minimal CPU usage
        cpu_pin_lines="CPUAffinity=0
AllowedCPUs=0"
      fi

      local comp_security_lines="PrivateTmp=true
NoNewPrivileges=true"
      local comp_env_lines=""
      if [ "$comp" = "engine" ] && [ "$comp_type" = "node" ]; then
        comp_security_lines="PrivateTmp=true
NoNewPrivileges=false
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN"
        comp_env_lines="Environment=DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket"
      fi

      local comp_svc_file="$PI_HOME/.config/systemd/user/${comp_svc}.service"
      # Remove any root-owned service file left by installScript (which runs via sudo)
      [ -f "$comp_svc_file" ] && [ ! -w "$comp_svc_file" ] && sudo rm -f "$comp_svc_file"

      # Remove conflicting system-level service file that overrides user-level
      local sys_svc_file="/etc/systemd/system/${comp_svc}.service"
      if [ -f "$sys_svc_file" ]; then
        log "Removing conflicting system-level service: ${sys_svc_file}"
        sudo systemctl stop "${comp_svc}.service" 2>/dev/null || true
        sudo systemctl disable "${comp_svc}.service" 2>/dev/null || true
        sudo rm -f "$sys_svc_file"
        sudo systemctl daemon-reload
      fi
      if ! cat > "$comp_svc_file" <<UNIT
[Unit]
Description=${app} ${comp} service
After=network.target

[Service]
Type=simple
WorkingDirectory=${comp_work_dir}
ExecStart=${comp_exec}
Environment=NPM_CONFIG_CACHE=${install_dir}/.npm-cache
Environment=PORT=${comp_port}
Environment=ENGINE_PORT=${engine_port}
Environment=UI_PORT=${req_port}
${comp_env_lines}
${cpu_pin_lines}
MemoryMax=128M
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${install_dir}
${comp_security_lines}
Restart=${restart_policy}
RestartSec=5

[Install]
WantedBy=default.target
UNIT
      then
        return 1
      fi

      user_systemctl daemon-reload || return 1
      user_systemctl enable "${comp_svc}.service" || return 1
      user_systemctl --no-block start "${comp_svc}.service" || return 1
    done
  else
    # Legacy single-service
    local svc_file="$PI_HOME/.config/systemd/user/${svc}.service"
    local app_type entrypoint exec_start
    app_type=$(registry_get "$app" "type")
    entrypoint=$(registry_get "$app" "entrypoint")
    mkdir -p "$PI_HOME/.config/systemd/user"
    mkdir -p "${install_dir}/.npm-cache"

    # Determine working directory from entrypoint's package.json location
    local legacy_work_dir="${install_dir}"
    local legacy_security_lines="PrivateTmp=true
NoNewPrivileges=true"
    local legacy_env_lines=""
    if [ "$app_type" = "node" ] && [ -n "$entrypoint" ]; then
      local entry_dir
      entry_dir=$(dirname "$entrypoint")
      local search_dir="${install_dir}/${entry_dir}"
      while [ "$search_dir" != "$install_dir" ] && [ "$search_dir" != "/" ]; do
        if [ -f "${search_dir}/package.json" ]; then
          legacy_work_dir="$search_dir"
          break
        fi
        search_dir=$(dirname "$search_dir")
      done
      exec_start="/usr/bin/node ${install_dir}/${entrypoint}"
      legacy_security_lines="PrivateTmp=true
NoNewPrivileges=false
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN"
      legacy_env_lines="Environment=DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket"
    else
      exec_start="/usr/bin/python3 ${PI_HOME}/pi-control-center/public/pi-scripts/static-spa-server.py --root ${install_dir}/dist --port ${req_port} --host 0.0.0.0"
    fi

    # Remove any root-owned service file left by installScript (which runs via sudo)
    [ -f "$svc_file" ] && [ ! -w "$svc_file" ] && sudo rm -f "$svc_file"

    # Remove conflicting system-level service file that overrides user-level
    local sys_svc_file="/etc/systemd/system/${svc}.service"
    if [ -f "$sys_svc_file" ]; then
      log "Removing conflicting system-level service: ${sys_svc_file}"
      sudo systemctl stop "${svc}.service" 2>/dev/null || true
      sudo systemctl disable "${svc}.service" 2>/dev/null || true
      sudo rm -f "$sys_svc_file"
      sudo systemctl daemon-reload
    fi
    cat > "$svc_file" <<UNIT
[Unit]
Description=${app} service
After=network.target

[Service]
Type=simple
WorkingDirectory=${legacy_work_dir}
ExecStart=${exec_start}
Environment=NPM_CONFIG_CACHE=${install_dir}/.npm-cache
Environment=PORT=${req_port}
CPUAffinity=${req_core}
AllowedCPUs=${req_core}
MemoryMax=128M
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${install_dir}
${legacy_security_lines}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT

    user_systemctl daemon-reload
    user_systemctl enable "${svc}.service"
    user_systemctl --no-block start "${svc}.service"
  fi

  return 0
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
  start_time=$(date +%s)

  [ -z "$repo" ] && { echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Okänd app\"}" > "$sf"; return 1; }

  progress "$sf" "$app" "Startar installation..." "$start_time"

  export XDG_RUNTIME_DIR="$USER_RUNTIME_DIR"
  export DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS"

  # Try release-based install first
  if do_install_release "$app" "$req_port" "$req_core" "$sf" "$start_time"; then
    install_message="Installation klar (release)"
  else
    # Fallback to legacy git clone + build
    install_message="Installation klar"

    progress "$sf" "$app" "Förbereder katalog..." "$start_time"
    [ -d "$install_dir" ] && sudo rm -rf "$install_dir"
    sudo mkdir -p "$(dirname "$install_dir")"

    progress "$sf" "$app" "Klonar repo..." "$start_time"
    if ! nice -n 15 sudo git clone --depth 1 "$repo" "$install_dir" > "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Git clone misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi
    sudo chown -R "$(whoami):$(whoami)" "$install_dir"

    # Fix CRLF line endings in all shell scripts
    find "$install_dir" -name '*.sh' -exec sed -i 's/\r$//' {} +

    progress "$sf" "$app" "Verifierar installationsskript..." "$start_time"
    if [ ! -f "$install_dir/$script" ]; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript saknas\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi

    chmod +x "$install_dir/$script"

    progress "$sf" "$app" "Kör installationsskript (kan ta flera minuter)..." "$start_time"
    if ! sudo systemd-run --scope --quiet -p MemoryMax=256M \
      nice -n 15 ionice -c 3 bash "$install_dir/$script" --port "$req_port" --core "$req_core" >> "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi
  fi

  progress "$sf" "$app" "Sparar konfiguration..." "$start_time"

  # Save assignment
  assignment_set "$app" "$req_core"

  rm -f "$CACHE_FILE"
  local total_elapsed=$(( $(date +%s) - start_time ))
  local t_min=$((total_elapsed / 60)) t_sec=$((total_elapsed % 60))
  local total_str
  if [ "$t_min" -gt 0 ]; then total_str="${t_min}m ${t_sec}s"; else total_str="${t_sec}s"; fi
  echo "{\"app\":\"${app}\",\"status\":\"success\",\"message\":\"${install_message} (${total_str})\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
}

do_uninstall() {
  local app install_dir svc uninstall_script has_comp
  app=$1
  install_dir=$(eval echo "$(registry_get "$app" "installDir")")
  svc=$(registry_get "$app" "service")
  uninstall_script=$(registry_get "$app" "uninstallScript")
  has_comp=$(registry_has_components "$app")

  if [ "$has_comp" = "true" ]; then
    # Stop all component services
    for comp in engine ui; do
      local comp_svc
      comp_svc=$(registry_get_component "$app" "$comp" "service")
      [ -z "$comp_svc" ] && continue
      user_systemctl stop "${comp_svc}.service" 2>/dev/null || true
      user_systemctl disable "${comp_svc}.service" 2>/dev/null || true
      rm -f "$PI_HOME/.config/systemd/user/${comp_svc}.service" 2>/dev/null || true
    done
  else
    # Legacy single service
    sudo systemctl stop "${svc}.service" 2>/dev/null || user_systemctl stop "${svc}.service" 2>/dev/null || true
    sudo systemctl disable "${svc}.service" 2>/dev/null || user_systemctl disable "${svc}.service" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
    rm -f "$PI_HOME/.config/systemd/user/${svc}.service" 2>/dev/null || true
  fi

  # Run uninstall script if it exists
  if [ -n "$uninstall_script" ] && [ -f "$install_dir/$uninstall_script" ]; then
    chmod +x "$install_dir/$uninstall_script"
    bash "$install_dir/$uninstall_script" 2>/dev/null || true
  fi

  sudo systemctl daemon-reload 2>/dev/null || true
  user_systemctl daemon-reload 2>/dev/null || true

  # Remove install directory
  if [ -n "$install_dir" ] && [ -d "$install_dir" ]; then
    sudo rm -rf "$install_dir"
  fi

  # Remove assignment
  assignment_remove "$app"
  rm -f "$CACHE_FILE"
  rm -f "$HEALTH_DIR/${app}.json"
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
    "GET /api/ping")
      response='{"pong":true}'
      ;;

    "GET /api/status")
      response=$(get_cached_status)
      ;;

    "GET /api/version")
      response="{\"name\":\"Pi Control Center\",\"version\":\"1.0.0\",\"commit\":\"${DASHBOARD_COMMIT}\",\"commitShort\":\"${DASHBOARD_COMMIT_SHORT}\",\"branch\":\"${DASHBOARD_BRANCH}\"}"
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
      req_core=$(echo "$body" | jq -r '.core // 1' 2>/dev/null)
      req_port=$(port_for_core "$req_core")
      if [ -z "$(registry_get "$app" "repo")" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        # Clear stale status and log before starting new install
        echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Startar installation...\"}" > "$INSTALL_DIR/${app}.json"
        rm -f "$INSTALL_DIR/${app}.log"
        if queue_install "$app" "$req_port" "$req_core"; then
          response="{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Startar installation...\"}"
        else
          status_line="HTTP/1.1 500 Internal Server Error"
          echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Kunde inte starta installationsjobb\",\"timestamp\":\"$(date -Iseconds)\"}" > "$INSTALL_DIR/${app}.json"
          response=$(< "$INSTALL_DIR/${app}.json")
        fi
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

    "POST /api/factory-reset")
      # Uninstall ALL services, clear assignments, clear caches
      local reset_log="$STATUS_DIR/factory-reset.log"
      : > "$reset_log"
      echo '{"status":"resetting"}' > "$STATUS_DIR/factory-reset.json"
      response='{"status":"resetting"}'
      (
        for fapp in $(registry_keys); do
          local fassign
          fassign=$(assignment_get_core "$fapp")
          if [ -n "$fassign" ]; then
            echo "Avinstallerar $fapp..." >> "$reset_log"
            do_uninstall "$fapp" >> "$reset_log" 2>&1
          fi
        done
        # Remove all install dirs under /opt (services only)
        for fapp in $(registry_keys); do
          local fdir
          fdir=$(eval echo "$(registry_get "$fapp" "installDir")" 2>/dev/null)
          [ -n "$fdir" ] && [ -d "$fdir" ] && sudo rm -rf "$fdir" >> "$reset_log" 2>&1
        done

        # Kill any remaining user systemd services (except PCC itself)
        echo "Rensar kvarvarande systemd-tjänster..." >> "$reset_log"
        local user_services
        user_services=$(sudo -u pi XDG_RUNTIME_DIR="/run/user/$(id -u pi)" systemctl --user list-units --type=service --no-legend --plain 2>/dev/null | awk '{print $1}' || true)
        for svc in $user_services; do
          case "$svc" in
            pi-control-center-*|dbus*|init.scope) continue ;;
            *)
              echo "  Stoppar och inaktiverar $svc" >> "$reset_log"
              sudo -u pi XDG_RUNTIME_DIR="/run/user/$(id -u pi)" systemctl --user stop "$svc" 2>/dev/null || true
              sudo -u pi XDG_RUNTIME_DIR="/run/user/$(id -u pi)" systemctl --user disable "$svc" 2>/dev/null || true
              ;;
          esac
        done

        # Remove leftover user service files (except PCC)
        local user_svc_dir="$PI_HOME/.config/systemd/user"
        if [ -d "$user_svc_dir" ]; then
          find "$user_svc_dir" -name '*.service' ! -name 'pi-control-center-*' -exec rm -f {} \; 2>/dev/null || true
          sudo -u pi XDG_RUNTIME_DIR="/run/user/$(id -u pi)" systemctl --user daemon-reload 2>/dev/null || true
        fi

        # Kill any stray processes on service ports (3000-3010, 3050-3060)
        for port in $(seq 3000 3010) $(seq 3050 3060); do
          local pid
          pid=$(sudo lsof -ti ":$port" 2>/dev/null || true)
          if [ -n "$pid" ]; then
            echo "  Dödar process på port $port (PID $pid)" >> "$reset_log"
            sudo kill -9 $pid 2>/dev/null || true
          fi
        done

        # Clear assignments
        echo '{}' | sudo tee "$ASSIGNMENTS_FILE" > /dev/null
        # Clear health cache and status files
        rm -rf "$HEALTH_DIR"/* "$STATUS_DIR"/*.json "$INSTALL_DIR"/*.json "$INSTALL_DIR"/*.log 2>/dev/null
        mkdir -p "$HEALTH_DIR"
        rm -f "$CACHE_FILE"
        # Clear activity log in browser will happen client-side
        echo '{"status":"success","timestamp":"'"$(date -Iseconds)"'"}' > "$STATUS_DIR/factory-reset.json"
        echo "Fabriksåterställning klar." >> "$reset_log"
      ) &

      ;;

    "POST /api/pi-reset")
      # Full Pi reset: uninstall all services + reinstall latest Pi Control Center
      local reset_log="$STATUS_DIR/factory-reset.log"
      : > "$reset_log"
      echo '{"status":"resetting","phase":"services"}' > "$STATUS_DIR/factory-reset.json"
      response='{"status":"resetting","phase":"services"}'
      (
        echo "=== Återställ Pi ===" >> "$reset_log"

        # 1) Uninstall all services
        echo '{"status":"resetting","phase":"Avinstallerar tjänster..."}' > "$STATUS_DIR/factory-reset.json"
        for fapp in $(registry_keys); do
          local fassign
          fassign=$(assignment_get_core "$fapp")
          if [ -n "$fassign" ]; then
            echo "Avinstallerar $fapp..." >> "$reset_log"
            do_uninstall "$fapp" >> "$reset_log" 2>&1
          fi
        done

        # Remove install dirs
        for fapp in $(registry_keys); do
          local fdir
          fdir=$(eval echo "$(registry_get "$fapp" "installDir")" 2>/dev/null)
          [ -n "$fdir" ] && [ -d "$fdir" ] && sudo rm -rf "$fdir" >> "$reset_log" 2>&1
        done

        # Kill any remaining user systemd services (except PCC itself)
        echo "Rensar kvarvarande systemd-tjänster..." >> "$reset_log"
        local user_services
        user_services=$(sudo -u pi XDG_RUNTIME_DIR="/run/user/$(id -u pi)" systemctl --user list-units --type=service --no-legend --plain 2>/dev/null | awk '{print $1}' || true)
        for svc in $user_services; do
          case "$svc" in
            pi-control-center-*|dbus*|init.scope) continue ;;
            *)
              echo "  Stoppar och inaktiverar $svc" >> "$reset_log"
              sudo -u pi XDG_RUNTIME_DIR="/run/user/$(id -u pi)" systemctl --user stop "$svc" 2>/dev/null || true
              sudo -u pi XDG_RUNTIME_DIR="/run/user/$(id -u pi)" systemctl --user disable "$svc" 2>/dev/null || true
              ;;
          esac
        done

        # Remove leftover user service files (except PCC)
        local user_svc_dir="$PI_HOME/.config/systemd/user"
        if [ -d "$user_svc_dir" ]; then
          find "$user_svc_dir" -name '*.service' ! -name 'pi-control-center-*' -exec rm -f {} \; 2>/dev/null || true
          sudo -u pi XDG_RUNTIME_DIR="/run/user/$(id -u pi)" systemctl --user daemon-reload 2>/dev/null || true
        fi

        # Kill any stray processes on service ports (3000-3010, 3050-3060)
        for port in $(seq 3000 3010) $(seq 3050 3060); do
          local pid
          pid=$(sudo lsof -ti ":$port" 2>/dev/null || true)
          if [ -n "$pid" ]; then
            echo "  Dödar process på port $port (PID $pid)" >> "$reset_log"
            sudo kill -9 $pid 2>/dev/null || true
          fi
        done

        echo '{}' | sudo tee "$ASSIGNMENTS_FILE" > /dev/null
        rm -rf "$HEALTH_DIR"/* "$STATUS_DIR"/*.json "$INSTALL_DIR"/*.json "$INSTALL_DIR"/*.log 2>/dev/null
        mkdir -p "$HEALTH_DIR"
        rm -f "$CACHE_FILE"

        # 2) Reinstall latest Pi Control Center
        echo '{"status":"resetting","phase":"Uppdaterar Pi Control Center..."}' > "$STATUS_DIR/factory-reset.json"
        local ddir="$PI_HOME/pi-control-center"
        local ndir="/var/www/pi-control-center"
        local remote_ref="origin/main"
        cd "$ddir" 2>/dev/null || { echo '{"status":"error","message":"Dashboard-katalog saknas"}' > "$STATUS_DIR/factory-reset.json"; exit 1; }

        echo "Hämtar senaste kod..." >> "$reset_log"
        git checkout -- . 2>/dev/null || true
        git clean -fd -e node_modules >/dev/null 2>&1 || true
        nice -n 15 git fetch origin main --depth=1 --quiet 2>/dev/null || nice -n 15 git fetch origin master --depth=1 --quiet 2>/dev/null || true
        git rev-parse origin/main >/dev/null 2>&1 || remote_ref="origin/master"
        git reset --hard "$remote_ref" --quiet 2>> "$reset_log" || true
        git clean -fd -e node_modules >/dev/null 2>&1 || true
        sed -i 's/\r$//' "$ddir/public/pi-scripts/"*.sh
        chmod +x "$ddir/public/pi-scripts/"*.sh

        echo '{"status":"resetting","phase":"Installerar dependencies..."}' > "$STATUS_DIR/factory-reset.json"
        echo "Installerar dependencies..." >> "$reset_log"
        if [ "$(swapon --show | wc -l)" -lt 2 ] && [ -f /etc/dphys-swapfile ]; then
          sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=512/' /etc/dphys-swapfile
          sudo dphys-swapfile setup || true
          sudo dphys-swapfile swapon || true
        fi
        sudo systemd-run --scope --quiet -p MemoryMax=512M bash -lc "cd '$ddir' && NODE_OPTIONS='--max-old-space-size=384' nice -n 15 ionice -c 3 npm install --omit=dev --no-audit --no-fund" >> "$reset_log" 2>&1 || true

        echo '{"status":"resetting","phase":"Bygger dashboard..."}' > "$STATUS_DIR/factory-reset.json"
        echo "Bygger dashboard..." >> "$reset_log"
        sudo rm -rf "$ddir/dist"
        sudo systemd-run --scope --quiet -p MemoryMax=384M bash -lc "cd '$ddir' && NODE_OPTIONS='--max-old-space-size=320' nice -n 15 ionice -c 3 npx vite build" >> "$reset_log" 2>&1 || true

        echo '{"status":"resetting","phase":"Deployar..."}' > "$STATUS_DIR/factory-reset.json"
        sudo mkdir -p "$ndir"
        sudo cp -r dist/* "$ndir/" 2>> "$reset_log" || true
        sudo chown -R pi:pi "$ddir/dist" 2>/dev/null || true
        [ -f "$ddir/public/services.json" ] && sudo cp "$ddir/public/services.json" "$ndir/" || true
        [ -f "$ddir/public/pi-scripts/pi-control-center-api.sh" ] && sudo install -m 755 "$ddir/public/pi-scripts/pi-control-center-api.sh" /usr/local/bin/pi-control-center-api.sh || true

        echo '{"status":"success","timestamp":"'"$(date -Iseconds)"'"}' > "$STATUS_DIR/factory-reset.json"
        echo "Återställning klar. Startar om API..." >> "$reset_log"
        sudo systemctl restart pi-control-center-api >/dev/null 2>&1 || true
      ) >> "$reset_log" 2>&1 &
      ;;

    "GET /api/factory-reset-status")
      [ -f "$STATUS_DIR/factory-reset.json" ] && response=$(< "$STATUS_DIR/factory-reset.json") || response='{"status":"idle"}'
      ;;

    "POST /api/update/dashboard")
      local sf ddir ndir dashboard_log remote_ref start_time
      sf="$STATUS_DIR/dashboard.json"
      ddir="$PI_HOME/pi-control-center"
      ndir="/var/www/pi-control-center"
      dashboard_log="$STATUS_DIR/dashboard.log"
      remote_ref="origin/main"
      start_time=$(date +%s)
      mkdir -p "$STATUS_DIR"
      echo '{"app":"dashboard","status":"updating","progress":"Köar uppdatering..."}' > "$sf"
      : > "$dashboard_log"
      response=$(< "$sf")
      (
        dashboard_progress() {
          local msg=$1
          local elapsed min sec time_str
          elapsed=$(( $(date +%s) - start_time ))
          min=$((elapsed / 60))
          sec=$((elapsed % 60))
          if [ "$min" -gt 0 ]; then time_str="${min}m ${sec}s"; else time_str="${sec}s"; fi
          echo "{\"app\":\"dashboard\",\"status\":\"updating\",\"progress\":\"${msg}\",\"elapsed\":\"${time_str}\"}" > "$sf"
        }

        dashboard_fail() {
          local msg=$1
          echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"${msg}\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
        }

        trap 'code=$?; if [ "$code" -ne 0 ] && grep -q "\"status\":\"updating\"" "$sf" 2>/dev/null; then dashboard_fail "Uppdateringen avbröts oväntat"; fi' EXIT

        cd "$ddir" 2>/dev/null || { dashboard_fail "Dashboard-katalog saknas"; exit 1; }

        dashboard_progress "Återställer lokala ändringar..."
        git checkout -- . 2>/dev/null || true
        git clean -fd -e node_modules >/dev/null 2>&1 || true

        dashboard_progress "Hämtar senaste kod..."
        nice -n 15 git fetch origin main --depth=1 --quiet 2>/dev/null || nice -n 15 git fetch origin master --depth=1 --quiet 2>/dev/null || { dashboard_fail "Git fetch misslyckades"; exit 1; }
        git rev-parse origin/main >/dev/null 2>&1 || remote_ref="origin/master"
        git reset --hard "$remote_ref" --quiet || { dashboard_fail "Git reset misslyckades"; exit 1; }
        git clean -fd -e node_modules >/dev/null 2>&1 || true
        sed -i 's/\r$//' "$ddir/public/pi-scripts/"*.sh
        chmod +x "$ddir/public/pi-scripts/"*.sh

        dashboard_progress "Säkerställer swap..."
        if [ "$(swapon --show | wc -l)" -lt 2 ] && [ -f /etc/dphys-swapfile ]; then
          sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=768/' /etc/dphys-swapfile
          sudo dphys-swapfile setup || true
          sudo dphys-swapfile swapon || true
        fi

        prev_hash=""
        [ -f node_modules/.package-hash ] && prev_hash=$(cat node_modules/.package-hash 2>/dev/null || true)
        curr_hash=$(md5sum package.json | awk '{print $1}')

        if [ ! -d node_modules ] || [ "$prev_hash" != "$curr_hash" ]; then
          dashboard_progress "Installerar dependencies..."
          if ! sudo systemd-run --scope --quiet -p MemoryMax=400M bash -lc "cd '$ddir' && NODE_OPTIONS='--max-old-space-size=352' nice -n 15 ionice -c 3 npm install --omit=dev --no-audit --no-fund"; then
            dashboard_fail "npm install misslyckades eller dödades (troligen minnesbrist)"
            exit 1
          fi
          echo "$curr_hash" > node_modules/.package-hash
          npx -y update-browserslist-db@latest >/dev/null 2>&1 || true
        else
          echo "Dependencies unchanged — skipping npm install"
        fi

        dashboard_progress "Bygger dashboard..."
        sudo rm -rf "$ddir/dist"
        if ! sudo systemd-run --scope --quiet -p MemoryMax=384M bash -lc "cd '$ddir' && NODE_OPTIONS='--max-old-space-size=320' nice -n 15 ionice -c 3 npx vite build"; then
          dashboard_fail "Build misslyckades eller dödades (troligen minnesbrist)"
          exit 1
        fi

        dashboard_progress "Deployar..."
        sudo mkdir -p "$ndir"
        sudo cp -r dist/* "$ndir/" || { dashboard_fail "Deploy misslyckades"; exit 1; }
        sudo chown -R pi:pi "$ddir/dist" 2>/dev/null || true
        [ -f "$ddir/public/services.json" ] && sudo cp "$ddir/public/services.json" "$ndir/" || true
        if [ -f "$ddir/public/pi-scripts/pi-control-center-api.sh" ]; then
          sudo install -m 755 "$ddir/public/pi-scripts/pi-control-center-api.sh" /usr/local/bin/pi-control-center-api.sh || true
        fi

        dashboard_progress "Städar upp..."
        avail_mb=$(df -m "$ddir" | awk 'NR==2{print $4}')
        if [ "${avail_mb:-0}" -lt 200 ]; then
          rm -rf node_modules
          npm cache clean --force >/dev/null 2>&1 || true
        fi

        elapsed=$(( $(date +%s) - start_time ))
        t_min=$((elapsed / 60))
        t_sec=$((elapsed % 60))
        if [ "$t_min" -gt 0 ]; then total_str="${t_min}m ${t_sec}s"; else total_str="${t_sec}s"; fi
        echo "{\"app\":\"dashboard\",\"status\":\"success\",\"message\":\"Dashboard uppdaterad (${total_str})\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
        sudo systemctl restart pi-control-center-api >/dev/null 2>&1 || true
      ) >> "$dashboard_log" 2>&1 &
      ;;

    POST\ /api/update/*)
      local app uscript update_json update_log
      app=${path#/api/update/}
      uscript=$(eval echo "$(registry_get "$app" "updateScript")")
      update_json="$STATUS_DIR/${app}.json"
      update_log="$STATUS_DIR/${app}.log"
      mkdir -p "$STATUS_DIR"

      echo "{\"app\":\"${app}\",\"status\":\"updating\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
      : > "$update_log"
      response=$(< "$update_json")

      (
        local release_url install_dir svc download_url
        release_url=$(registry_get "$app" "releaseUrl")
        install_dir=$(eval echo "$(registry_get "$app" "installDir")")
        svc=$(registry_get "$app" "service")

        updated=false

        # Try release-based update first
        if [ -n "$release_url" ]; then
          download_url=$(curl -sf "$release_url" 2>/dev/null | jq -r '.assets[] | select(.name == "dist.tar.gz") | .browser_download_url' 2>/dev/null)
          if [ -n "$download_url" ] && [ "$download_url" != "null" ]; then
            echo "Laddar ner ny release..." >> "$update_log"
            if curl -sfL "$download_url" -o "/tmp/pi-control-center/${app}-dist.tar.gz" 2>> "$update_log"; then
              echo "Packar upp..." >> "$update_log"
              rm -rf "$install_dir/dist"
              tar xzf "/tmp/pi-control-center/${app}-dist.tar.gz" -C "$install_dir" 2>> "$update_log"
              rm -f "/tmp/pi-control-center/${app}-dist.tar.gz"

              export XDG_RUNTIME_DIR="$USER_RUNTIME_DIR"
              export DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS"
              # Restart services (skip if managed: false)
              if [ "$(registry_is_managed "$app")" != "false" ]; then
                local has_comp_upd
                has_comp_upd=$(registry_has_components "$app")
                if [ "$has_comp_upd" = "true" ]; then
                  for comp_upd in engine ui; do
                    local comp_svc_upd
                    comp_svc_upd=$(registry_get_component "$app" "$comp_upd" "service")
                    [ -n "$comp_svc_upd" ] && user_systemctl restart "${comp_svc_upd}.service" 2>> "$update_log" || true
                  done
                else
                  user_systemctl restart "${svc}.service" 2>> "$update_log" || sudo systemctl restart "${svc}.service" 2>> "$update_log" || true
                fi
              fi

              updated=true
              echo "{\"app\":\"${app}\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
            fi
          fi
        fi

        # Fallback to legacy update script
        if [ "$updated" = "false" ]; then
          if [ -z "$uscript" ] || [ ! -f "$uscript" ]; then
            echo "Uppdateringsskript saknas: $uscript" >> "$update_log"
            echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Uppdateringsskript saknas\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
          else
            nice -n 15 ionice -c 3 bash "$uscript" >> "$update_log" 2>&1
            exit_code=$?
            if [ "$exit_code" -eq 0 ]; then
              echo "{\"app\":\"${app}\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
            else
              tail_err=$(tail -5 "$update_log" 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c1-200)
              echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"${tail_err:-Update failed}\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
            fi
          fi
        fi
      ) &
      ;;

    GET\ /api/update-status/*)
      local app
      app=${path#/api/update-status/}
      [ -f "$STATUS_DIR/${app}.json" ] && response=$(< "$STATUS_DIR/${app}.json") || response="{\"app\":\"${app}\",\"status\":\"idle\"}"
      ;;

    POST\ /api/service/*/*)
      local rest app action_with_query action query_string component svc
      rest=${path#/api/service/}
      app=${rest%%/*}
      action_with_query=${rest#*/}
      action=${action_with_query%%\?*}
      query_string=""
      component=""
      if [[ "$action_with_query" == *"?"* ]]; then
        query_string=${action_with_query#*\?}
        component=$(echo "$query_string" | grep -o 'component=[^&]*' | cut -d= -f2)
      fi

      # Resolve the actual systemd service name
      if [ -n "$component" ]; then
        svc=$(registry_get_component "$app" "$component" "service")
      else
        svc=$(registry_get "$app" "service")
      fi

      if [ -z "$svc" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app or component: ${app}/${component}\"}"
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

    "GET /api/version/"*)
      local vapp=${method_path#GET /api/version/}
      vapp="${vapp%%[?#]*}"
      vapp="${vapp//[^a-zA-Z0-9_-]/}"
      local v_install_dir v_repo v_local v_local_hash v_remote_hash v_has_update
      if [ "$vapp" = "dashboard" ]; then
        v_local=""
        v_local_hash=""
        v_remote_hash=""
        local ddir="$PI_HOME/pi-control-center"
        local d_repo_url
        d_repo_url=$(grep -A1 '\[remote "origin"\]' "$ddir/.git/config" 2>/dev/null | grep 'url' | sed 's/.*= //')
        if [ -d "$ddir/.git" ]; then
          v_local_hash=$(cat "$ddir/.git/refs/heads/main" 2>/dev/null || cat "$ddir/.git/refs/heads/master" 2>/dev/null)
          v_local_hash=${v_local_hash:0:7}
          v_local=$(sudo -u pi git -C "$ddir" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
          v_local="${v_local,,}"
        fi
        [ -n "$d_repo_url" ] && v_remote_hash=$(git ls-remote --heads "$d_repo_url" main 2>/dev/null | cut -c1-7)
        [ -z "$v_remote_hash" ] && [ -n "$d_repo_url" ] && v_remote_hash=$(git ls-remote --heads "$d_repo_url" master 2>/dev/null | cut -c1-7)
        v_has_update="false"
        [ -n "$v_local_hash" ] && [ -n "$v_remote_hash" ] && [ "$v_local_hash" != "$v_remote_hash" ] && v_has_update="true"
        response="{\"local\":\"${v_local}\",\"remote\":\"${v_remote_hash}\",\"hasUpdate\":${v_has_update}}"
      else
        v_install_dir=$(eval echo "$(registry_get "$vapp" "installDir")" 2>/dev/null)
        v_repo=$(registry_get "$vapp" "repo" 2>/dev/null)
        local v_release_url
        v_release_url=$(registry_get "$vapp" "releaseUrl" 2>/dev/null)
        if [ -z "$v_install_dir" ]; then
          status_line="HTTP/1.1 404 Not Found"
          response="{\"error\":\"unknown service: ${vapp}\"}"
        else
          v_local=""
          v_local_hash=""
          v_remote_hash=""
          v_has_update="false"

          if [ -f "$v_install_dir/VERSION.json" ]; then
            # Release-based install: compare tag from VERSION.json against latest GitHub release
            v_local_hash=$(jq -r '.tag // .version // empty' "$v_install_dir/VERSION.json" 2>/dev/null)
            v_local=$(jq -r '.version // .tag // empty' "$v_install_dir/VERSION.json" 2>/dev/null)
            if [ -n "$v_release_url" ]; then
              v_remote_hash=$(curl -sf --max-time 10 "$v_release_url" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
            fi
            [ -n "$v_local_hash" ] && [ -n "$v_remote_hash" ] && [ "$v_local_hash" != "$v_remote_hash" ] && v_has_update="true"
          elif [ -d "$v_install_dir/.git" ]; then
            # Legacy git-based install: compare commit hashes
            v_local=$(git -C "$v_install_dir" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
            v_local="${v_local,,}"
            v_local_hash=$(git -C "$v_install_dir" rev-parse --short HEAD 2>/dev/null)
            v_remote_hash=$(git ls-remote --heads "$v_repo" main 2>/dev/null | cut -c1-7)
            [ -z "$v_remote_hash" ] && v_remote_hash=$(git ls-remote --heads "$v_repo" master 2>/dev/null | cut -c1-7)
            [ -n "$v_local_hash" ] && [ -n "$v_remote_hash" ] && [ "$v_local_hash" != "$v_remote_hash" ] && v_has_update="true"
          fi

          response="{\"local\":\"${v_local}\",\"remote\":\"${v_remote_hash}\",\"hasUpdate\":${v_has_update}}"
        fi
      fi
      ;;

    "GET /api/versions")
      local vj
      vj=""
      for app in $(registry_keys); do
        local install_dir repo local_v local_hash remote_hash has_update rel_url
        install_dir=$(eval echo "$(registry_get "$app" "installDir")")
        repo=$(registry_get "$app" "repo")
        rel_url=$(registry_get "$app" "releaseUrl")
        local_v=""
        local_hash=""
        remote_hash=""
        has_update="false"

        if [ -f "$install_dir/VERSION.json" ]; then
          # Release-based install
          local_hash=$(jq -r '.tag // .version // empty' "$install_dir/VERSION.json" 2>/dev/null)
          local_v=$(jq -r '.version // .tag // empty' "$install_dir/VERSION.json" 2>/dev/null)
          if [ -n "$rel_url" ]; then
            remote_hash=$(curl -sf --max-time 10 "$rel_url" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
          fi
          [ -n "$local_hash" ] && [ -n "$remote_hash" ] && [ "$local_hash" != "$remote_hash" ] && has_update="true"
        elif [ -d "$install_dir/.git" ]; then
          # Legacy git-based install
          local_v=$(git -C "$install_dir" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
          local_v="${local_v,,}"
          local_hash=$(git -C "$install_dir" rev-parse --short HEAD 2>/dev/null)
          remote_hash=$(git ls-remote --heads "$repo" main 2>/dev/null | cut -c1-7)
          [ -z "$remote_hash" ] && remote_hash=$(git ls-remote --heads "$repo" master 2>/dev/null | cut -c1-7)
          [ -n "$local_hash" ] && [ -n "$remote_hash" ] && [ "$local_hash" != "$remote_hash" ] && has_update="true"
        fi

        [ -n "$vj" ] && vj="${vj},"
        vj="${vj}\"${app}\":{\"local\":\"${local_v}\",\"remote\":\"${remote_hash}\",\"hasUpdate\":${has_update}}"
      done

      local d_local d_hash d_remote_hash d_update d_repo_url
      d_local=""
      d_hash=""
      d_remote_hash=""
      local ddir2="$PI_HOME/pi-control-center"
      d_repo_url=$(grep -A1 '\[remote "origin"\]' "$ddir2/.git/config" 2>/dev/null | grep 'url' | sed 's/.*= //')
      if [ -d "$ddir2/.git" ]; then
        d_hash=$(cat "$ddir2/.git/refs/heads/main" 2>/dev/null || cat "$ddir2/.git/refs/heads/master" 2>/dev/null)
        d_hash=${d_hash:0:7}
        d_local=$(sudo -u pi git -C "$ddir2" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
        d_local="${d_local,,}"
      fi
      [ -n "$d_repo_url" ] && d_remote_hash=$(git ls-remote --heads "$d_repo_url" main 2>/dev/null | cut -c1-7)
      [ -z "$d_remote_hash" ] && [ -n "$d_repo_url" ] && d_remote_hash=$(git ls-remote --heads "$d_repo_url" master 2>/dev/null | cut -c1-7)
      d_update="false"
      [ -n "$d_hash" ] && [ -n "$d_remote_hash" ] && [ "$d_hash" != "$d_remote_hash" ] && d_update="true"
      vj="${vj},\"dashboard\":{\"local\":\"${d_local}\",\"remote\":\"${d_remote_hash}\",\"hasUpdate\":${d_update}}"
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

if [ "$REQUEST_MODE" = "--run-install" ]; then
  [ -n "$INSTALL_APP" ] || exit 1
  mkdir -p "$INSTALL_DIR"
  exec >> "$INSTALL_DIR/${INSTALL_APP}.log" 2>&1
  do_install "$INSTALL_APP" "$INSTALL_PORT" "$INSTALL_CORE"
  exit $?
fi

# --- Startup: remove conflicting system-level service files ---
startup_cleanup_system_services() {
  local cleaned=0
  for app in $(registry_keys); do
    local has_comp svc_names=""
    has_comp=$(registry_has_components "$app")
    if [ "$has_comp" = "true" ]; then
      for comp in engine ui; do
        local cs
        cs=$(registry_get_component "$app" "$comp" "service")
        [ -n "$cs" ] && svc_names="$svc_names $cs"
      done
    else
      local s
      s=$(registry_get "$app" "service")
      [ -n "$s" ] && svc_names="$s"
    fi
    for svc_name in $svc_names; do
      local sys_file="/etc/systemd/system/${svc_name}.service"
      if [ -f "$sys_file" ]; then
        log "Startup cleanup: removing conflicting system-level service ${sys_file}"
        sudo systemctl stop "${svc_name}.service" 2>/dev/null || true
        sudo systemctl disable "${svc_name}.service" 2>/dev/null || true
        sudo rm -f "$sys_file"
        cleaned=1
      fi
    done
  done
  [ "$cleaned" -eq 1 ] && sudo systemctl daemon-reload
}
startup_cleanup_system_services

# --- Migrate legacy assignments.json format ---
# Old: {"app": {"port": 3001, "core": 1}}  →  New: {"app": 1}
migrate_assignments() {
  [ -f "$ASSIGNMENTS_FILE" ] || return
  local needs_migrate=false
  for key in $(jq -r 'keys[]' "$ASSIGNMENTS_FILE" 2>/dev/null); do
    if jq -e --arg k "$key" '.[$k] | type == "object"' "$ASSIGNMENTS_FILE" >/dev/null 2>&1; then
      needs_migrate=true
      break
    fi
  done
  [ "$needs_migrate" = "false" ] && return
  echo "Migrating assignments.json to new format (core-only)..."
  local migrated
  migrated=$(jq 'with_entries(if .value | type == "object" then .value = .value.core else . end)' "$ASSIGNMENTS_FILE" 2>/dev/null)
  if [ -n "$migrated" ] && echo "$migrated" | jq empty 2>/dev/null; then
    echo "$migrated" > "/tmp/pi-control-center/assignments.migrate.$$"
    sudo mv "/tmp/pi-control-center/assignments.migrate.$$" "$ASSIGNMENTS_FILE"
    echo "Migration complete: $(cat "$ASSIGNMENTS_FILE")"
  fi
}
migrate_assignments

echo "Pi Control Center API listening on port $PORT"

# Start health polling in background
health_poll_loop &
HEALTH_PID=$!

# Start status cache refresh in background
status_cache_loop &
CACHE_PID=$!

trap "kill $HEALTH_PID $CACHE_PID 2>/dev/null; exit" EXIT INT TERM

while true; do
  socat TCP-LISTEN:${PORT},reuseaddr,fork EXEC:"${SCRIPT_PATH} --handle-request ${PORT}" 2>/dev/null || sleep 1
done
