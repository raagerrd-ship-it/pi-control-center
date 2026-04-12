#!/bin/bash
# Pi Control Center API — lightweight HTTP server optimized for Pi Zero 2 W
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

HEALTH_DIR="$STATUS_DIR/health"

mkdir -p "$STATUS_DIR" "$INSTALL_DIR" "$HEALTH_DIR"
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

health_poll_loop() {
  while true; do
    for app in $(registry_keys); do
      local has_comp port engine_port engine_svc engine_active
      has_comp=$(registry_has_components "$app")
      port=$(assignment_get "$app" "port")
      [ -z "$port" ] || [ "$port" = "0" ] && continue

      if [ "$has_comp" = "true" ]; then
        engine_svc=$(registry_get_component "$app" "engine" "service")
        [ -z "$engine_svc" ] && continue
        engine_active=$(service_is_active "$engine_svc")
        [ "$engine_active" != "true" ] && { echo '{"status":"offline"}' > "$HEALTH_DIR/${app}.json"; continue; }
        engine_port=$((port + 50))
        poll_engine_health "$app" "$engine_port"
      else
        # Legacy services: try health endpoint on their main port
        local svc_active
        svc_active=$(service_is_active "$(registry_get "$app" "service")")
        [ "$svc_active" != "true" ] && { echo '{"status":"offline"}' > "$HEALTH_DIR/${app}.json"; continue; }
        poll_engine_health "$app" "$port"
      fi
    done
    sleep 30
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

check_installed() {
  local app=$1
  local install_dir=$2
  local svc=$3

  [ -d "$install_dir" ] && { [ -f "$HOME/.config/systemd/user/${svc}.service" ] || [ -f "/etc/systemd/system/${svc}.service" ]; } && echo "true" || echo "false"
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
      # If not JSON, use raw response
      echo "$api_ver"; return
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
    local svc install_dir port core online installed ver s_cpu s_ram s_core pid aff running has_comp
    svc=$(registry_get "$app" "service")
    install_dir=$(eval echo "$(registry_get "$app" "installDir")")
    port=$(assignment_get "$app" "port")
    core=$(assignment_get "$app" "core")
    has_comp=$(registry_has_components "$app")

    [ -z "$port" ] && port=0
    [ -z "$core" ] && core=-1

    # For component-based services, check if ANY component is active
    if [ "$has_comp" = "true" ]; then
      local engine_svc ui_svc engine_online ui_online engine_cpu engine_ram ui_cpu ui_ram engine_ver ui_ver
      engine_svc=$(registry_get_component "$app" "engine" "service")
      ui_svc=$(registry_get_component "$app" "ui" "service")
      engine_online="false"; ui_online="false"
      engine_cpu=0; engine_ram=0; ui_cpu=0; ui_ram=0
      engine_ver=""; ui_ver=""

      [ -n "$engine_svc" ] && engine_online=$(service_is_active "$engine_svc")
      [ -n "$ui_svc" ] && ui_online=$(service_is_active "$ui_svc")

      if [ "$engine_online" = "true" ] && [ -n "$engine_svc" ]; then
        engine_ram=$(get_service_ram "$engine_svc")
        local epid
        epid=$(user_systemctl show "${engine_svc}.service" --property=MainPID 2>/dev/null | cut -d= -f2)
        [ -n "$epid" ] && [ "$epid" != "0" ] && engine_cpu=$(ps -p "$epid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
      fi
      if [ "$ui_online" = "true" ] && [ -n "$ui_svc" ]; then
        ui_ram=$(get_service_ram "$ui_svc")
        local upid
        upid=$(user_systemctl show "${ui_svc}.service" --property=MainPID 2>/dev/null | cut -d= -f2)
        [ -n "$upid" ] && [ "$upid" != "0" ] && ui_cpu=$(ps -p "$upid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
      fi

      online="false"
      [ "$engine_online" = "true" ] || [ "$ui_online" = "true" ] && online="true"

      # Check installed: need install_dir + at least one service file
      installed="false"
      if [ -d "$install_dir" ]; then
        { [ -n "$engine_svc" ] && [ -f "$HOME/.config/systemd/user/${engine_svc}.service" ]; } || \
        { [ -n "$ui_svc" ] && [ -f "$HOME/.config/systemd/user/${ui_svc}.service" ]; } && installed="true"
      fi

      ver=$(get_version "$install_dir" "$port")
      engine_ver="$ver"; ui_ver="$ver"
      local engine_port=$((port + 50))

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
      svc_json="${svc_json}\"${app}\":{\"online\":${online},\"installed\":${installed},\"version\":\"${ver}\",\"cpu\":${total_cpu:-0},\"ramMb\":${total_ram:-0},\"cpuCore\":${core},\"port\":${port},\"health\":{\"status\":\"${health_status}\",\"uptime\":${health_uptime:-0},\"memoryRss\":${health_mem_rss:-0}},\"components\":{\"engine\":{\"online\":${engine_online},\"version\":\"${engine_ver}\",\"cpu\":${engine_cpu:-0},\"ramMb\":${engine_ram:-0},\"service\":\"${engine_svc}\",\"port\":${engine_port}},\"ui\":{\"online\":${ui_online},\"version\":\"${ui_ver}\",\"cpu\":${ui_cpu:-0},\"ramMb\":${ui_ram:-0},\"service\":\"${ui_svc}\",\"port\":${port}}}}"
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
    fi
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


progress() {
  local sf=$1 app=$2 msg=$3 start=$4
  local elapsed=$(( $(date +%s) - start ))
  local min=$((elapsed / 60)) sec=$((elapsed % 60))
  local time_str
  if [ "$min" -gt 0 ]; then time_str="${min}m ${sec}s"; else time_str="${sec}s"; fi
  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"${msg}\",\"elapsed\":\"${time_str}\"}" > "$sf"
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
  if ! curl -sfL "$download_url" -o "/tmp/pi-dashboard/${app}-dist.tar.gz" >> "$INSTALL_DIR/${app}.log" 2>&1; then
    return 1
  fi

  progress "$sf" "$app" "Packar upp..." "$start_time"
  tar xzf "/tmp/pi-dashboard/${app}-dist.tar.gz" -C "$install_dir" >> "$INSTALL_DIR/${app}.log" 2>&1
  rm -f "/tmp/pi-dashboard/${app}-dist.tar.gz"

  progress "$sf" "$app" "Skapar systemd-service..." "$start_time"

  local has_comp
  has_comp=$(registry_has_components "$app")

  if [ "$has_comp" = "true" ]; then
    # Component-based: create separate services for engine and ui
    # Engine port = UI port + 50 (e.g. UI=3002 → Engine=3052)
    local engine_port=$((req_port + 50))
    for comp in engine ui; do
      local comp_type comp_entry comp_svc comp_always_on comp_exec comp_port
      comp_type=$(registry_get_component "$app" "$comp" "type")
      comp_entry=$(registry_get_component "$app" "$comp" "entrypoint")
      comp_svc=$(registry_get_component "$app" "$comp" "service")
      comp_always_on=$(registry_get_component "$app" "$comp" "alwaysOn")

      [ -z "$comp_svc" ] && continue

      # Engine gets offset port, UI gets the user-selected port
      if [ "$comp" = "engine" ]; then
        comp_port=$engine_port
      else
        comp_port=$req_port
      fi

      if [ "$comp_type" = "node" ] && [ -n "$comp_entry" ]; then
        comp_exec="/usr/bin/node ${install_dir}/${comp_entry}"
      else
        comp_exec="/usr/bin/npx serve ${comp_entry:-dist} -l ${comp_port} -s"
      fi

      local restart_policy="on-failure"
      [ "$comp_always_on" = "true" ] && restart_policy="always"

      local comp_svc_file="$HOME/.config/systemd/user/${comp_svc}.service"
      cat > "$comp_svc_file" <<UNIT
[Unit]
Description=${app} ${comp} service
After=network.target

[Service]
Type=simple
WorkingDirectory=${install_dir}
ExecStart=${comp_exec}
Environment=PORT=${comp_port}
Environment=ENGINE_PORT=${engine_port}
Environment=UI_PORT=${req_port}
CPUAffinity=${req_core}
AllowedCPUs=${req_core}
MemoryMax=128M
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${install_dir}
PrivateTmp=true
NoNewPrivileges=true
Restart=${restart_policy}
RestartSec=5

[Install]
WantedBy=default.target
UNIT

      user_systemctl daemon-reload
      user_systemctl enable "${comp_svc}.service"
      user_systemctl start "${comp_svc}.service"
    done
  else
    # Legacy single-service
    local svc_file="$HOME/.config/systemd/user/${svc}.service"
    local app_type entrypoint exec_start
    app_type=$(registry_get "$app" "type")
    entrypoint=$(registry_get "$app" "entrypoint")
    mkdir -p "$HOME/.config/systemd/user"

    if [ "$app_type" = "node" ] && [ -n "$entrypoint" ]; then
      exec_start="/usr/bin/node ${install_dir}/${entrypoint}"
    else
      exec_start="/usr/bin/npx serve dist -l ${req_port} -s"
    fi

    cat > "$svc_file" <<UNIT
[Unit]
Description=${app} service
After=network.target

[Service]
Type=simple
WorkingDirectory=${install_dir}
ExecStart=${exec_start}
Environment=PORT=${req_port}
CPUAffinity=${req_core}
AllowedCPUs=${req_core}
MemoryMax=128M
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${install_dir}
PrivateTmp=true
NoNewPrivileges=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT

    user_systemctl daemon-reload
    user_systemctl enable "${svc}.service"
    user_systemctl start "${svc}.service"
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
    if ! nice -n 15 ionice -c 3 bash "$install_dir/$script" --port "$req_port" --core "$req_core" >> "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi
  fi

  progress "$sf" "$app" "Sparar konfiguration..." "$start_time"

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
      rm -f "$HOME/.config/systemd/user/${comp_svc}.service" 2>/dev/null || true
    done
  else
    # Legacy single service
    sudo systemctl stop "${svc}.service" 2>/dev/null || user_systemctl stop "${svc}.service" 2>/dev/null || true
    sudo systemctl disable "${svc}.service" 2>/dev/null || user_systemctl disable "${svc}.service" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/${svc}.service" 2>/dev/null || true
  fi

  # Run uninstall script if it exists
  if [ -n "$uninstall_script" ] && [ -f "$install_dir/$uninstall_script" ]; then
    chmod +x "$install_dir/$uninstall_script"
    bash "$install_dir/$uninstall_script" 2>/dev/null || true
  fi

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
      req_port=$(echo "$body" | jq -r '.port // 3000' 2>/dev/null)
      req_core=$(echo "$body" | jq -r '.core // 1' 2>/dev/null)
      if [ -z "$(registry_get "$app" "repo")" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        # Clear stale status and log before starting new install
        echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Startar installation...\"}" > "$INSTALL_DIR/${app}.json"
        rm -f "$INSTALL_DIR/${app}.log"
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
      # Try new path first, fallback to old
      ddir="$HOME/pi-control-center"
      [ ! -d "$ddir" ] && ddir="$HOME/pi-dashboard"
      ndir="/var/www/pi-control-center"
      [ ! -d "$ndir" ] && ndir="/var/www/pi-dashboard"
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
        NODE_OPTIONS="--max-old-space-size=256" nice -n 15 ionice -c 3 npx vite build || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Build failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        sudo mkdir -p "$ndir"
        sudo cp -r dist/* "$ndir/" || { echo "{\"app\":\"dashboard\",\"status\":\"error\",\"message\":\"Deploy failed\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"; exit 1; }
        [ -f "$ddir/public/services.json" ] && sudo cp "$ddir/public/services.json" "$ndir/" || true
        if [ -f "$ddir/public/pi-scripts/pi-dashboard-api.sh" ]; then
          sudo install -m 755 "$ddir/public/pi-scripts/pi-dashboard-api.sh" /usr/local/bin/pi-dashboard-api.sh || true
        fi
        rm -rf node_modules
        npm cache clean --force >/dev/null 2>&1 || true
        echo "{\"app\":\"dashboard\",\"status\":\"success\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
        # Restart API (try new name first, fallback to old)
        sudo systemctl restart pi-control-center-api >/dev/null 2>&1 || sudo systemctl restart pi-dashboard-api >/dev/null 2>&1 || true
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
            if curl -sfL "$download_url" -o "/tmp/pi-dashboard/${app}-dist.tar.gz" 2>> "$update_log"; then
              echo "Packar upp..." >> "$update_log"
              rm -rf "$install_dir/dist"
              tar xzf "/tmp/pi-dashboard/${app}-dist.tar.gz" -C "$install_dir" 2>> "$update_log"
              rm -f "/tmp/pi-dashboard/${app}-dist.tar.gz"

              export XDG_RUNTIME_DIR="$USER_RUNTIME_DIR"
              export DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS"
              # Restart component-based or legacy services
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
        local ddir="$HOME/pi-control-center"
        [ ! -d "$ddir" ] && ddir="$HOME/pi-dashboard"
        if [ -d "$ddir/.git" ]; then
          v_local=$(git -C "$ddir" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
          v_local="${v_local,,}"
          v_local_hash=$(git -C "$ddir" rev-parse --short HEAD 2>/dev/null)
        fi
        v_remote_hash=$(git ls-remote --heads "$(git -C "$ddir" remote get-url origin 2>/dev/null)" main 2>/dev/null | cut -c1-7)
        v_has_update="false"
        [ -n "$v_local_hash" ] && [ -n "$v_remote_hash" ] && [ "$v_local_hash" != "$v_remote_hash" ] && v_has_update="true"
        response="{\"local\":\"${v_local}\",\"remote\":\"\",\"hasUpdate\":${v_has_update}}"
      else
        v_install_dir=$(eval echo "$(registry_get "$vapp" "installDir")" 2>/dev/null)
        v_repo=$(registry_get "$vapp" "repo" 2>/dev/null)
        if [ -z "$v_install_dir" ]; then
          status_line="HTTP/1.1 404 Not Found"
          response="{\"error\":\"unknown service: ${vapp}\"}"
        else
          v_local=""
          v_local_hash=""
          v_remote_hash=""
          if [ -d "$v_install_dir/.git" ]; then
            v_local=$(git -C "$v_install_dir" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
            v_local="${v_local,,}"
            v_local_hash=$(git -C "$v_install_dir" rev-parse --short HEAD 2>/dev/null)
          fi
          v_remote_hash=$(git ls-remote --heads "$v_repo" main 2>/dev/null | cut -c1-7)
          v_has_update="false"
          [ -n "$v_local_hash" ] && [ -n "$v_remote_hash" ] && [ "$v_local_hash" != "$v_remote_hash" ] && v_has_update="true"
          response="{\"local\":\"${v_local}\",\"remote\":\"\",\"hasUpdate\":${v_has_update}}"
        fi
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
      local ddir2="$HOME/pi-control-center"
      [ ! -d "$ddir2" ] && ddir2="$HOME/pi-dashboard"
      if [ -d "$ddir2/.git" ]; then
        d_local=$(git -C "$ddir2" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
        d_local="${d_local,,}"
        d_hash=$(git -C "$ddir2" rev-parse --short HEAD 2>/dev/null)
      fi
      d_remote_hash=$(git ls-remote --heads "$(git -C "$ddir2" remote get-url origin 2>/dev/null)" main 2>/dev/null | cut -c1-7)
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

# Start health polling in background
health_poll_loop &
HEALTH_PID=$!
trap "kill $HEALTH_PID 2>/dev/null; exit" EXIT INT TERM

while true; do
  socat TCP-LISTEN:${PORT},reuseaddr,fork EXEC:"${SCRIPT_PATH} --handle-request ${PORT}" 2>/dev/null || sleep 1
done
