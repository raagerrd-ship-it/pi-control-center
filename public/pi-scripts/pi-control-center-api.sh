#!/bin/bash
# Pi Control Center API — lightweight HTTP server optimized for Pi Zero 2 W
# Uses /proc for stats (no heavy subprocesses), caches results
# Dynamic service registry from services.json + assignments.json
# Usage: ./pi-control-center-api.sh [port]

REQUEST_MODE="${1:-}"
INSTALL_APP=""
INSTALL_PORT=""
INSTALL_CORE=""
MIN_MEMORY_MB=80

sudo_run() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

# PCC-tjänsten kör som root (för att kunna styra systemd m.m.) men app-kataloger
# i /etc/pi-control-center/apps/ MÅSTE ägas av den oprivilegierade pi-användaren
# eftersom apparnas systemd-units kör som User=pi. Använd ALDRIG `whoami` här —
# det returnerar "root" när API:t körs som root och leder till att appen
# inte kan skriva till sin egen settings.json (Permission denied).
pcc_owner_user() {
  if id -u pi >/dev/null 2>&1; then
    echo "pi"
  else
    # Fallback: ägaren av repo-katalogen (där detta skript ligger).
    stat -c '%U' "${BASH_SOURCE[0]%/*}" 2>/dev/null || echo "pi"
  fi
}

pcc_owner_group() {
  local u
  u=$(pcc_owner_user)
  id -gn "$u" 2>/dev/null || echo "$u"
}

sudo_run_quiet() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@" 2>/dev/null
  else
    sudo -n "$@" 2>/dev/null
  fi
}

sudo_available() {
  [ "$(id -u)" -eq 0 ] || sudo -n true >/dev/null 2>&1 || sudo -n /usr/bin/systemctl daemon-reload >/dev/null 2>&1
}

bluetooth_is_up_running() {
  if command -v hciconfig >/dev/null 2>&1; then
    hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'
  elif command -v bluetoothctl >/dev/null 2>&1; then
    bluetoothctl show 2>/dev/null | grep -q 'Powered: yes'
  else
    return 0
  fi
}

repair_ble_permissions() {
  local user_name="$(whoami)" group_changed=0 reboot_file="${REBOOT_REQUIRED_FILE:-/tmp/pi-control-center/reboot-required.json}"
  mkdir -p "$(dirname "$reboot_file")" 2>/dev/null || true
  sudo_run_quiet loginctl enable-linger "$(whoami)" || true
  id -nG "$user_name" 2>/dev/null | grep -qw bluetooth || group_changed=1
  sudo_run_quiet usermod -aG bluetooth,netdev,audio "$(whoami)" || true
  sudo_run_quiet mkdir -p /etc/polkit-1/rules.d || true
  sudo_run tee /etc/polkit-1/rules.d/49-allow-pi-bluez.rules > /dev/null <<'EOF' || true
polkit.addRule(function(action, subject) {
  if (subject.user == "pi" && action.id.indexOf("org.bluez.") == 0) {
    return polkit.Result.YES;
  }
});
EOF
  if [ -f /etc/bluetooth/main.conf ]; then
    if sudo_run_quiet grep -q '^DisablePlugins=' /etc/bluetooth/main.conf; then
      sudo_run_quiet sed -i 's/^DisablePlugins=.*/DisablePlugins=pnat/' /etc/bluetooth/main.conf || true
    elif sudo_run_quiet grep -q '^\[General\]' /etc/bluetooth/main.conf; then
      sudo_run_quiet sed -i '/^\[General\]/a DisablePlugins=pnat' /etc/bluetooth/main.conf || true
    else
      printf '\n[General]\nDisablePlugins=pnat\n' | sudo_run tee -a /etc/bluetooth/main.conf > /dev/null || true
    fi
  else
    printf '[General]\nDisablePlugins=pnat\n' | sudo_run tee /etc/bluetooth/main.conf > /dev/null || true
  fi
  sudo_run_quiet rfkill unblock bluetooth || true
  sudo_run_quiet hciconfig hci0 up || true
  sudo_run_quiet systemctl enable --now bluetooth || true
  sudo_run_quiet systemctl restart bluetooth || true
  if [ "$group_changed" -eq 1 ] && ! bluetooth_is_up_running; then
    echo '{"required":true,"reason":"ble_group_changed","message":"BLE-rättigheter har lagats men kräver omstart för ny gruppsession.","timestamp":"'"$(date -Iseconds)"'"}' > "$reboot_file"
  elif bluetooth_is_up_running; then
    rm -f "$reboot_file"
  fi
}

ble_permissions_need_repair() {
  local user_name="$(whoami)" missing=0
  id -nG "$user_name" 2>/dev/null | grep -qw bluetooth || missing=1
  loginctl show-user "$user_name" -p Linger 2>/dev/null | grep -q '=yes$' || missing=1
  [ -f /etc/polkit-1/rules.d/49-allow-pi-bluez.rules ] || missing=1
  grep -q '^DisablePlugins=pnat' /etc/bluetooth/main.conf 2>/dev/null || missing=1
  systemctl is-active --quiet bluetooth 2>/dev/null || missing=1
  rfkill list bluetooth 2>/dev/null | grep -qi 'Soft blocked: yes' && missing=1
  bluetooth_is_up_running || missing=1
  [ "$missing" -eq 1 ]
}

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
  --background-only)
    # Run only the long-lived background loops (status cache, health, watchdog)
    # plus startup hooks. The Python HTTP server owns the listening socket.
    shift
    PORT="${1:-8585}"
    ;;
  --sync-heap-limits)
    # One-shot: sync --max-old-space-size in every installed unit file with the
    # registry's memoryProfile.defaultLevel. Used by update-control-center.sh
    # so heap changes propagate without manual Repair.
    SYNC_HEAP_ONLY=1
    PORT="8585"
    ;;
  *)
    PORT="${1:-8585}"
    ;;
esac
# Resolve script path robustly: BASH_SOURCE survives socat EXEC forks where $0 may differ.
# Fallback to a known canonical path if BASH_SOURCE is also unreliable.
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
# Sanity: if SCRIPT_PATH doesn't point to a real file, fall back to the canonical install path.
if [ ! -f "$SCRIPT_PATH" ]; then
  for candidate in \
    "/home/pi/pi-control-center/public/pi-scripts/pi-control-center-api.sh" \
    "/usr/local/bin/pi-control-center-api.sh"; do
    if [ -f "$candidate" ]; then SCRIPT_PATH="$candidate"; break; fi
  done
fi
# Ensure the canonical /usr/local/bin symlink always points to the active script,
# so systemd-run jobs and other consumers can rely on a stable path.
if [ -f "$SCRIPT_PATH" ] && [ "$SCRIPT_PATH" != "/usr/local/bin/pi-control-center-api.sh" ]; then
  if [ ! -L /usr/local/bin/pi-control-center-api.sh ] || \
     [ "$(readlink -f /usr/local/bin/pi-control-center-api.sh 2>/dev/null)" != "$SCRIPT_PATH" ]; then
    sudo_run_quiet ln -sf "$SCRIPT_PATH" /usr/local/bin/pi-control-center-api.sh || true
  fi
fi
PI_HOME="/home/pi"
STATUS_DIR="/tmp/pi-control-center"
INSTALL_DIR="/tmp/pi-control-center/install"
CACHE_FILE="$STATUS_DIR/status-cache.json"
CACHE_MAX_AGE=4  # seconds
REBOOT_REQUIRED_FILE="$STATUS_DIR/reboot-required.json"
USER_ID="$(id -u)"
USER_RUNTIME_DIR="/run/user/$USER_ID"
USER_BUS_ADDRESS="unix:path=$USER_RUNTIME_DIR/bus"

REGISTRY_FILE="/var/www/pi-control-center/services.json"
ASSIGNMENTS_FILE="/etc/pi-control-center/assignments.json"
APPS_CONFIG_DIR="/etc/pi-control-center/apps"
APPS_DATA_DIR="/var/lib/pi-control-center/apps"
APPS_LOG_DIR="/var/log/pi-control-center/apps"
OP_LOCK_FILE="/tmp/pi-control-center/operation.lock"

# Acquire OP_LOCK med timeout. Returnerar 0 om lock erhållet, 1 om timeout.
# Förhindrar att en hängande update blockerar alla framtida update-försök.
acquire_op_lock_or_timeout() {
  local fd=$1
  local timeout_seconds=${2:-600}
  local elapsed=0
  while ! flock -n "$fd"; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      return 1
    fi
  done
  return 0
}

HEALTH_DIR="$STATUS_DIR/health"
WATCHDOG_DIR="$STATUS_DIR/watchdog"
RELEASE_HEAL_DIR="$STATUS_DIR/release-heal"
RELEASE_HEAL_WINDOW_SECONDS=900

mkdir -p "$STATUS_DIR" "$INSTALL_DIR" "$HEALTH_DIR" "$WATCHDOG_DIR" "$RELEASE_HEAL_DIR" 2>/dev/null || true
# Defensive: if /tmp/pi-control-center was created by an earlier root-owned
# process (legacy socat/bash service), reclaim ownership for the current user
# so watchdog/status loops can write their .tmp files. /tmp is wiped on reboot
# but a service-user change does not trigger a reboot, so we self-heal here.
if [ -d "$STATUS_DIR" ] && [ ! -w "$STATUS_DIR" ] || [ -d "$WATCHDOG_DIR" ] && [ ! -w "$WATCHDOG_DIR" ]; then
  sudo_run_quiet chown -R "$(id -u):$(id -g)" "$STATUS_DIR" || true
fi
chmod -R u+rwX "$STATUS_DIR" 2>/dev/null || true
sudo_run_quiet mkdir -p /etc/pi-control-center || true
sudo_run_quiet mkdir -p "$APPS_CONFIG_DIR" || true
sudo_run_quiet mkdir -p "$APPS_DATA_DIR" || true
sudo_run_quiet mkdir -p "$APPS_LOG_DIR" || true
# CRITICAL: parent app-dirs must be owned by the unprivileged user, otherwise
# every per-app subdirectory created later inherits root and triggers the
# systemd directory-permissions warning. Self-heal on every API start so legacy
# installations get fixed without manual intervention or reinstall.
_pcc_owner="$(pcc_owner_user):$(pcc_owner_group)"
sudo_run_quiet chown "$_pcc_owner" /etc/pi-control-center "$APPS_CONFIG_DIR" "$APPS_DATA_DIR" "$APPS_LOG_DIR" || true
# Recursively fix any existing app subdirs that were created as root by a
# previous version of this script (covers all currently-installed apps).
sudo_run_quiet chown -R "$_pcc_owner" "$APPS_CONFIG_DIR" "$APPS_DATA_DIR" "$APPS_LOG_DIR" || true

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
[ -f "$ASSIGNMENTS_FILE" ] || echo '{}' | sudo_run tee "$ASSIGNMENTS_FILE" > /dev/null || true

# Fixed port mapping: UI = 3000 + core, Engine = 3050 + core
port_for_core() { echo $((3000 + ${1:-1})); }
engine_port_for_core() { echo $((3050 + ${1:-1})); }

user_systemctl() {
  XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" \
  DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS" \
  systemctl --user "$@"
}

get_node_bin() {
  command -v node 2>/dev/null || echo "/usr/bin/node"
}

get_node_version() {
  local node_bin
  node_bin=$(get_node_bin)
  [ -x "$node_bin" ] && "$node_bin" -v 2>/dev/null || echo "unavailable"
}

assert_node_runtime() {
  local version major
  version=$(get_node_version)
  major=${version#v}; major=${major%%.*}
  [ "$major" = "24" ]
}

node_runtime_json() {
  local node_bin version major status
  node_bin=$(get_node_bin | sed 's/"/\\"/g')
  version=$(get_node_version | sed 's/"/\\"/g')
  major=${version#v}; major=${major%%.*}
  status="ok"
  [ "$major" = "24" ] || status="warning"
  echo "{\"nodeVersion\":\"${version}\",\"nodePath\":\"${node_bin}\",\"status\":\"${status}\"}"
}

log() {
  echo "PCC API: $*" >&2
}

app_config_dir() { echo "$APPS_CONFIG_DIR/$(echo "$1" | tr -cd 'a-zA-Z0-9_-')"; }
app_data_dir() { echo "$APPS_DATA_DIR/$(echo "$1" | tr -cd 'a-zA-Z0-9_-')"; }
app_log_dir() { echo "$APPS_LOG_DIR/$(echo "$1" | tr -cd 'a-zA-Z0-9_-')"; }

ensure_app_managed_dirs() {
  local app=$1 cfg data_dir logdir home_dir xdg_share_dir wpath
  cfg=$(app_config_dir "$app")
  data_dir=$(app_data_dir "$app")
  logdir=$(app_log_dir "$app")
  home_dir="$data_dir/home"
  xdg_share_dir="$home_dir/.local/share"
  sudo_run_quiet mkdir -p "$cfg" "$data_dir" "$logdir" "$xdg_share_dir" || true
  sudo_run_quiet chown -R "$(pcc_owner_user):$(pcc_owner_group)" "$cfg" "$data_dir" "$logdir" || true
  sudo_run_quiet chmod 700 "$cfg" "$data_dir" "$home_dir" || true
  sudo_run_quiet chmod 755 "$xdg_share_dir" "$logdir" || true
  # App-specifika writable-mappar inom installDir (t.ex. lotus pi/data/storage.json).
  # Update-scripts som körs som root lämnar ofta dessa root-ägda → engine får EACCES.
  while IFS= read -r wpath; do
    [ -n "$wpath" ] || continue
    sudo_run_quiet mkdir -p "$wpath" || true
    sudo_run_quiet chown -R "$(pcc_owner_user):$(pcc_owner_group)" "$wpath" || true
    sudo_run_quiet chmod -R u+rwX,g+rX "$wpath" || true
  done < <(app_writable_dir_paths "$app")
  # Permissions may have changed; drop any cached "needs repair" verdict.
  invalidate_app_dirs_cache "$app"
}

# Result cache for app_dirs_need_repair to avoid 9 stat calls every poll cycle.
# Filbaserad så att invalidering från per-request-processer syns av
# status_cache_loop-bakgrundsprocessen (in-memory cache delas inte mellan processer).
_APP_DIR_REPAIR_TTL=60

_app_dirs_check() {
  local app=$1 expected_owner cfg data_dir logdir path mode owner want_mode wpath
  expected_owner="$(pcc_owner_user):$(pcc_owner_group)"
  cfg=$(app_config_dir "$app")
  data_dir=$(app_data_dir "$app")
  logdir=$(app_log_dir "$app")
  for path in "$cfg:700" "$data_dir:700" "$logdir:755"; do
    want_mode=${path##*:}
    path=${path%:*}
    [ -d "$path" ] || return 0
    owner=$(stat -c '%U:%G' "$path" 2>/dev/null || echo '')
    mode=$(stat -c '%a' "$path" 2>/dev/null || echo '')
    [ "$owner" = "$expected_owner" ] && [ "$mode" = "$want_mode" ] || return 0
  done
  # Kontrollera även app-specifika writable-mappar (registry: writableDirs).
  # Viktigt: kolla BÅDE mappen OCH alla filer/undermappar inuti — update-scripts
  # som kör `cp` som root lämnar ofta enskilda filer (t.ex. storage.json) root-ägda
  # även när själva mappen redan är pi-ägd från första install. Engine får då
  # EACCES på writeFileSync trots att mappägaren ser korrekt ut.
  local bad
  while IFS= read -r wpath; do
    [ -n "$wpath" ] || continue
    [ -d "$wpath" ] || continue
    owner=$(stat -c '%U:%G' "$wpath" 2>/dev/null || echo '')
    [ "$owner" = "$expected_owner" ] || return 0
    # Hitta första entry inuti som inte ägs av expected_owner (rekursivt).
    bad=$(find "$wpath" -mindepth 1 ! -user "$(pcc_owner_user)" -print -quit 2>/dev/null)
    [ -z "$bad" ] || return 0
  done < <(app_writable_dir_paths "$app")
  return 1
}

# Cached wrapper. Returns 0 if dirs need repair, 1 otherwise.
app_dirs_need_repair() {
  local app=$1 cache_file now age verdict
  cache_file="$STATUS_DIR/dir-repair-${app}.cache"
  now=$(date +%s)
  if [ -f "$cache_file" ]; then
    age=$(( now - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$_APP_DIR_REPAIR_TTL" ]; then
      verdict=$(cat "$cache_file" 2>/dev/null)
      [ "$verdict" = "1" ] && return 0 || return 1
    fi
  fi
  if _app_dirs_check "$app"; then
    echo 1 > "$cache_file"
    return 0
  else
    echo 0 > "$cache_file"
    return 1
  fi
}

# Force re-check on next call (used after a repair)
invalidate_app_dirs_cache() {
  rm -f "$STATUS_DIR/dir-repair-${1}.cache"
}

repair_app_managed_dirs() {
  local app=$1 reason=${2:-preflight} log_file="$STATUS_DIR/${app}.log"
  app_dirs_need_repair "$app" || return 1
  log "SYSTEMD WARNING: reparerar katalogrättigheter för $app ($reason)"
  printf '[%s] systemd warning: reparerar katalogrättigheter (%s)\n' "$(date -Iseconds)" "$reason" >> "$log_file"
  ensure_app_managed_dirs "$app"
  invalidate_app_dirs_cache "$app"
  rm -f "$CACHE_FILE"
  return 0
}

app_dirs_warning_json() {
  local app=$1 cfg data_dir logdir reason
  cfg=$(escape_json "$(app_config_dir "$app")")
  data_dir=$(escape_json "$(app_data_dir "$app")")
  logdir=$(escape_json "$(app_log_dir "$app")")
  if app_dirs_need_repair "$app"; then
    reason="Katalogrättigheter behöver repareras"
    echo "{\"status\":\"warning\",\"reason\":\"directory_permissions\",\"message\":\"${reason}\",\"configDir\":\"${cfg}\",\"dataDir\":\"${data_dir}\",\"logDir\":\"${logdir}\"}"
  else
    echo '{"status":"ok"}'
  fi
}

escape_json() {
  printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/  /g' | tr '\n' ' ' | cut -c1-240
}

# --- Dynamic registry helpers ---

# Get a field from services.json: registry_get <key> <field>
# Uses _REGISTRY_CACHE_JSON when set (one parse per build_status_json) to avoid
# forking jq many times per status refresh on the Pi Zero 2.
registry_get() {
  if [ -n "${_REGISTRY_CACHE_JSON:-}" ]; then
    printf '%s' "$_REGISTRY_CACHE_JSON" | jq -r --arg k "$1" --arg f "$2" '.[] | select(.key == $k) | .[$f] // empty' 2>/dev/null
  else
    jq -r --arg k "$1" --arg f "$2" '.[] | select(.key == $k) | .[$f] // empty' "$REGISTRY_FILE" 2>/dev/null
  fi
}

registry_release_asset() {
  local asset
  asset=$(registry_get "$1" "releaseAsset")
  [ -n "$asset" ] && echo "$asset" || echo "dist.tar.gz"
}

# App-specifika writable-mappar inom installDir (relativa paths).
# Definieras i services.json som "writableDirs": ["pi/data", ...].
# Används för att återställa ägarskap efter update-scripts som kör som root
# och annars lämnar dessa mappar root-ägda → engine får EACCES på writeFileSync.
registry_writable_dirs() {
  local app=$1
  if [ -n "${_REGISTRY_CACHE_JSON:-}" ]; then
    printf '%s' "$_REGISTRY_CACHE_JSON" | jq -r --arg k "$app" '.[] | select(.key == $k) | .writableDirs[]? // empty' 2>/dev/null
  else
    jq -r --arg k "$app" '.[] | select(.key == $k) | .writableDirs[]? // empty' "$REGISTRY_FILE" 2>/dev/null
  fi
}

# Resolva absolut path för en writable-katalog: <installDir>/<relPath>
app_writable_dir_paths() {
  local app=$1 install_dir rel
  install_dir=$(eval echo "$(registry_get "$app" "installDir")")
  [ -n "$install_dir" ] || return 0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # Strip leading slash så path alltid blir relativ
    rel="${rel#/}"
    printf '%s\n' "$install_dir/$rel"
  done < <(registry_writable_dirs "$app")
}

latest_release_json() {
  local app=$1 release_url cache_file cache_age now
  release_url=$(registry_get "$app" "releaseUrl")
  [ -n "$release_url" ] || return 1
  cache_file="$STATUS_DIR/${app}-latest-release.json"
  now=$(date +%s)
  if [ -s "$cache_file" ]; then
    cache_age=$((now - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
    [ "$cache_age" -lt 300 ] && { cat "$cache_file"; return 0; }
  fi
  curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' -H 'User-Agent: pi-control-center' "$release_url" 2>/dev/null | tee "$cache_file"
}

latest_release_tag() {
  latest_release_json "$1" | jq -r '.tag_name // .name // empty' 2>/dev/null
}

latest_release_asset_url() {
  local app=$1 asset
  asset=$(registry_release_asset "$app")
  latest_release_json "$app" | jq -r --arg a "$asset" '.assets[]? | select(.name == $a) | .browser_download_url' 2>/dev/null | head -1
}

installed_release_version() {
  local install_dir=$1 version
  if [ -f "$install_dir/VERSION.json" ]; then
    version=$(jq -r '.tag // .version // .name // empty' "$install_dir/VERSION.json" 2>/dev/null)
  fi
  [ -z "$version" ] && [ -f "$install_dir/package.json" ] && version=$(jq -r '.version // empty' "$install_dir/package.json" 2>/dev/null)
  [ -z "$version" ] && [ -f "$install_dir/engine/package.json" ] && version=$(jq -r '.version // empty' "$install_dir/engine/package.json" 2>/dev/null)
  echo "$version"
}

# Helper: run a jq filter against the cached registry JSON when available,
# otherwise read from disk. Args: <jq_flag> <filter> [jq args...]
_registry_jq() {
  local flag=$1 filter=$2; shift 2
  if [ -n "${_REGISTRY_CACHE_JSON:-}" ]; then
    printf '%s' "$_REGISTRY_CACHE_JSON" | jq "$flag" "$@" "$filter" 2>/dev/null
  else
    jq "$flag" "$@" "$filter" "$REGISTRY_FILE" 2>/dev/null
  fi
}

# Get a component field: registry_get_component <key> <component> <field>
registry_get_component() {
  _registry_jq -r '.[] | select(.key == $k) | .components[$c][$f] // empty' \
    --arg k "$1" --arg c "$2" --arg f "$3"
}

registry_memory_profile_json() {
  _registry_jq -c '.[] | select(.key == $k) | .memoryProfile // empty' --arg k "$1"
}

registry_memory_profile_default_level() {
  _registry_jq -r '.[] | select(.key == $k) | .memoryProfile.defaultLevel // "balanced"' --arg k "$1"
}

registry_memory_profile_mb() {
  local app=$1 level=${2:-}
  [ -z "$level" ] && level=$(registry_memory_profile_default_level "$app")
  local mb
  mb=$(_registry_jq -r '.[] | select(.key == $k) | .memoryProfile.levels[$l] // empty' --arg k "$app" --arg l "$level")
  [ -n "$mb" ] && [ "$mb" -lt "$MIN_MEMORY_MB" ] 2>/dev/null && mb="$MIN_MEMORY_MB"
  echo "$mb"
}

registry_permissions_json() {
  local raw
  raw=$(_registry_jq -c '.[] | select(.key == $k) | .permissions // []' --arg k "$1")
  [ -n "$raw" ] && echo "$raw" || echo "[]"
}

registry_permissions_env() {
  jq -r --arg k "$1" '.[] | select(.key == $k) | (.permissions // []) | join(",")' "$REGISTRY_FILE" 2>/dev/null
}

registry_needs_permission() {
  jq -e --arg k "$1" --arg p "$2" '.[] | select(.key == $k) | (.permissions // []) | index($p)' "$REGISTRY_FILE" >/dev/null 2>&1
}

memory_level_for_mb() {
  local app=$1 mb=$2
  local level
  level=$(jq -r --arg k "$app" --argjson mb "${mb:-0}" '.[] | select(.key == $k) | (.memoryProfile.levels // {}) | to_entries[]? | select(.value == $mb) | .key' "$REGISTRY_FILE" 2>/dev/null | head -1)
  [ -n "$level" ] && echo "$level" || echo "custom"
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
    echo '{}' | sudo_run tee "$ASSIGNMENTS_FILE" > /dev/null || true
  fi
  tmp=$(jq --arg k "$1" --argjson c "$2" '.[$k] = $c' "$ASSIGNMENTS_FILE" 2>/dev/null)
  if [ -n "$tmp" ] && echo "$tmp" | jq empty 2>/dev/null; then
    echo "$tmp" > "$tmpfile"
    sudo_run mv "$tmpfile" "$ASSIGNMENTS_FILE"
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
    echo '{}' | sudo_run tee "$ASSIGNMENTS_FILE" > /dev/null || true
  fi
  tmp=$(jq --arg k "$1" 'del(.[$k])' "$ASSIGNMENTS_FILE" 2>/dev/null)
  if [ -n "$tmp" ] && echo "$tmp" | jq empty 2>/dev/null; then
    echo "$tmp" > "$tmpfile"
    sudo_run mv "$tmpfile" "$ASSIGNMENTS_FILE"
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

release_heal_mark() {
  local app=$1 file="$RELEASE_HEAL_DIR/${app}.state"
  echo "timestamp=$(date +%s)" > "$file"
  echo "last_online=true" >> "$file"
  echo "attempts=0" >> "$file"
}

release_heal_get() {
  local app=$1 field=$2 file="$RELEASE_HEAL_DIR/${app}.state"
  [ -f "$file" ] && grep -E "^${field}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-
}

release_heal_set() {
  local app=$1 field=$2 value=$3 file="$RELEASE_HEAL_DIR/${app}.state" tmp="$RELEASE_HEAL_DIR/${app}.tmp.$$"
  [ -f "$file" ] || return
  if grep -qE "^${field}=" "$file" 2>/dev/null; then
    sed "s/^${field}=.*/${field}=${value}/" "$file" > "$tmp"
  else
    cat "$file" > "$tmp"
    echo "${field}=${value}" >> "$tmp"
  fi
  mv "$tmp" "$file"
}

release_update_heal_if_needed() {
  local app=$1 online=$2 file="$RELEASE_HEAL_DIR/${app}.state"
  [ -f "$file" ] || return

  local ts age last_online attempts
  ts=$(release_heal_get "$app" timestamp); ts=${ts:-0}
  age=$(( $(date +%s) - ts ))
  if [ "$age" -gt "$RELEASE_HEAL_WINDOW_SECONDS" ]; then
    rm -f "$file"
    return
  fi

  last_online=$(release_heal_get "$app" last_online)
  attempts=$(release_heal_get "$app" attempts); attempts=${attempts:-0}
  registry_needs_permission "$app" "bluetooth" || registry_needs_permission "$app" "rfkill" || return
  if [ "$online" = "true" ]; then
    release_heal_set "$app" last_online true
    if [ "$attempts" -lt 2 ] 2>/dev/null && ble_permissions_need_repair; then
      attempts=$((attempts + 1))
      release_heal_set "$app" attempts "$attempts"
      log "SELF-HEAL: $app är online efter release-update men BLE/Noble är inte redo — reparerar Bluetooth"
      repair_ble_permissions
      sleep 2
      _app_try_restart "$app"
      rm -f "$CACHE_FILE"
    fi
    return
  fi
  [ "$last_online" = "true" ] || return
  [ "$attempts" -ge 2 ] 2>/dev/null && return

  attempts=$((attempts + 1))
  release_heal_set "$app" attempts "$attempts"
  release_heal_set "$app" last_online false
  if ble_permissions_need_repair; then
    log "SELF-HEAL: $app gick offline efter release-update — BLE/Noble-rättigheter saknas, reparerar"
    repair_ble_permissions
    sleep 2
  else
    log "SELF-HEAL: $app gick offline efter release-update — BLE/Noble-rättigheter OK, hoppar över Bluetooth-omstart"
  fi
  _app_try_restart "$app"
  rm -f "$CACHE_FILE"
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
        [ "$engine_active" != "true" ] && { echo '{"status":"offline"}' > "$HEALTH_DIR/${app}.json"; release_update_heal_if_needed "$app" false; continue; }
        engine_port=$(engine_port_for_core "$core")
        poll_engine_health "$app" "$engine_port"

        local ui_svc
        ui_svc=$(registry_get_component "$app" "ui" "service")
        if [ -n "$ui_svc" ]; then
          try_heal_component "$app" "$ui_svc" "ui" "$port"
        fi

        try_heal_component "$app" "$engine_svc" "engine" "$engine_port"
        release_update_heal_if_needed "$app" true
      else
        local svc_active
        svc_active=$(service_is_active "$(registry_get "$app" "service")")
        [ "$svc_active" != "true" ] && { echo '{"status":"offline"}' > "$HEALTH_DIR/${app}.json"; release_update_heal_if_needed "$app" false; continue; }
        poll_engine_health "$app" "$port"
        release_update_heal_if_needed "$app" true
      fi
    done
    sleep 30
    cleanup_counter=$((cleanup_counter + 1))
    if [ $((cleanup_counter % 10)) -eq 0 ]; then
      find "$STATUS_DIR" -maxdepth 1 -name '*.json' ! -name 'status-cache.json' ! -name 'factory-reset.json' -mmin +10 -delete 2>/dev/null
      find "$INSTALL_DIR" -maxdepth 1 -name '*.json' -mmin +10 -delete 2>/dev/null
      find "$HEAL_FAIL_DIR" -maxdepth 1 -type f -exec sh -c 'for file do echo 0 > "$file"; done' sh {} + 2>/dev/null || true
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

# --- Watchdog ---
# Conservative guard for Pi Zero 2: restarts services that repeatedly exceed
# CPU/RAM thresholds or are active but unreachable, then protects against loops.
WATCHDOG_INTERVAL=30
WATCHDOG_CPU_LIMIT=85
WATCHDOG_MEM_WARN=85
WATCHDOG_MEM_RESTART=95
WATCHDOG_STRIKES=3
WATCHDOG_MAX_RESTARTS=3
MEMORY_AUTOSCALE_UP_PCT=85
MEMORY_AUTOSCALE_DOWN_PCT=45
MEMORY_AUTOSCALE_UP_STRIKES=2
MEMORY_AUTOSCALE_DOWN_STRIKES=6
MEMORY_AUTOSCALE_COOLDOWN_SECONDS=120

watchdog_key() { echo "${1}-${2}" | tr -cd 'a-zA-Z0-9_.-'; }

service_exists() {
  local svc=$1
  [ -z "$svc" ] && { echo "false"; return; }
  if user_systemctl cat "${svc}.service" >/dev/null 2>&1 || systemctl cat "${svc}.service" >/dev/null 2>&1; then
    echo "true"
  else
    echo "false"
  fi
}

get_memory_limit_mb() {
  local svc=$1 val
  val=$(user_systemctl show "${svc}.service" --property=MemoryMax 2>/dev/null | cut -d= -f2)
  if [ -z "$val" ] || [ "$val" = "infinity" ] || [ "$val" = "[not set]" ] || [ "$val" = "0" ]; then
    val=$(systemctl show "${svc}.service" --property=MemoryMax 2>/dev/null | cut -d= -f2)
  fi
  if [ -n "$val" ] && [ "$val" != "infinity" ] && [ "$val" != "[not set]" ] && [ "$val" != "0" ]; then
    echo $((val / 1048576))
  else
    echo 0
  fi
}

watchdog_get() {
  local app=$1 comp=$2 field=$3 file="$WATCHDOG_DIR/$(watchdog_key "$app" "$comp").state"
  [ -f "$file" ] && grep -E "^${field}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-
}

watchdog_write_state() {
  local app=$1 comp=$2 status=$3 reason=$4 cpu_fails=$5 mem_fails=$6 health_fails=$7 restarts=$8 last_action=$9
  local key file tmp
  key=$(watchdog_key "$app" "$comp")
  file="$WATCHDOG_DIR/${key}.state"
  tmp="$WATCHDOG_DIR/${key}.tmp.$$"
  {
    echo "status=${status:-ok}"
    echo "reason=${reason:-}"
    echo "cpu_fails=${cpu_fails:-0}"
    echo "mem_fails=${mem_fails:-0}"
    echo "health_fails=${health_fails:-0}"
    echo "restart_count=${restarts:-0}"
    echo "last_action=${last_action:-}"
    echo "timestamp=$(date -Iseconds)"
  } > "$tmp"
  mv "$tmp" "$file"
}

watchdog_json() {
  local app=$1 comp=$2 file="$WATCHDOG_DIR/$(watchdog_key "$app" "$comp").state"
  local status reason restarts last_action timestamp
  if [ ! -f "$file" ]; then
    echo '{"status":"ok","restartCount":0}'
    return
  fi
  status=$(grep -E '^status=' "$file" | tail -1 | cut -d= -f2-)
  reason=$(grep -E '^reason=' "$file" | tail -1 | cut -d= -f2- | sed 's/"/\\"/g')
  restarts=$(grep -E '^restart_count=' "$file" | tail -1 | cut -d= -f2-)
  last_action=$(grep -E '^last_action=' "$file" | tail -1 | cut -d= -f2- | sed 's/"/\\"/g')
  timestamp=$(grep -E '^timestamp=' "$file" | tail -1 | cut -d= -f2- | sed 's/"/\\"/g')
  echo "{\"status\":\"${status:-ok}\",\"reason\":\"${reason}\",\"restartCount\":${restarts:-0},\"lastAction\":\"${last_action}\",\"timestamp\":\"${timestamp}\"}"
}

watchdog_reset() {
  local app=$1 comp=${2:-service}
  rm -f "$WATCHDOG_DIR/$(watchdog_key "$app" "$comp").state"
}

memory_autoscale_get() {
  local app=$1 field=$2 file="$WATCHDOG_DIR/$(watchdog_key "$app" "memory-autoscale").state"
  [ -f "$file" ] && grep -E "^${field}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-
}

memory_autoscale_write() {
  local app=$1 up_fails=$2 down_fails=$3 last_change=$4 file tmp
  file="$WATCHDOG_DIR/$(watchdog_key "$app" "memory-autoscale").state"
  tmp="${file}.tmp.$$"
  {
    echo "up_fails=${up_fails:-0}"
    echo "down_fails=${down_fails:-0}"
    echo "last_change=${last_change:-0}"
    echo "timestamp=$(date -Iseconds)"
  } > "$tmp"
  mv "$tmp" "$file"
}

memory_profile_adjacent_level() {
  local app=$1 current_mb=$2 direction=$3 op
  [ "$direction" = "up" ] && op='select(.value > $mb)' || op='select(.value < $mb)'
  jq -r --arg k "$app" --argjson mb "${current_mb:-0}" --arg op "$direction" '
    .[] | select(.key == $k) | (.memoryProfile.levels // {}) | to_entries
    | map(select((if $op == "up" then .value > $mb else .value < $mb end)))
    | sort_by(.value)
    | (if $op == "up" then .[0] else .[-1] end)
    | if . then "\(.key):\(.value)" else empty end
  ' "$REGISTRY_FILE" 2>/dev/null
}

append_memory_change_log() {
  local app=$1 message=$2 log_file app_mem_log now
  now="$(date -Iseconds)"
  log_file="$STATUS_DIR/${app}.log"
  app_mem_log="$(app_log_dir "$app")/memory.log"
  mkdir -p "$(dirname "$app_mem_log")" 2>/dev/null || true
  printf "[%s] %s\n" "$now" "$message" >> "$log_file"
  printf "[%s] %s\n" "$now" "$message" >> "$app_mem_log" 2>/dev/null || true
  log "$message"
}

auto_adjust_memory_limit() {
  local app=$1 ram=$2 current_limit current_level pct up_fails down_fails last_change now adjacent next_level next_mb direction old_limit
  [ -n "$(assignment_get_core "$app")" ] || return
  current_limit=$(_app_current_limit "$app")
  [ -z "$current_limit" ] && current_limit=$(registry_memory_profile_mb "$app")
  [ -z "$current_limit" ] || [ "$current_limit" -le 0 ] 2>/dev/null && return
  [ -z "$ram" ] || [ "$ram" -le 0 ] 2>/dev/null && return

  current_level=$(memory_level_for_mb "$app" "$current_limit")
  [ "$current_level" = "custom" ] && return
  pct=$((ram * 100 / current_limit))
  up_fails=$(memory_autoscale_get "$app" up_fails); up_fails=${up_fails:-0}
  down_fails=$(memory_autoscale_get "$app" down_fails); down_fails=${down_fails:-0}
  last_change=$(memory_autoscale_get "$app" last_change); last_change=${last_change:-0}
  now=$(date +%s)

  direction=""
  if [ "$pct" -ge "$MEMORY_AUTOSCALE_UP_PCT" ] 2>/dev/null; then
    up_fails=$((up_fails + 1)); down_fails=0
    [ "$up_fails" -ge "$MEMORY_AUTOSCALE_UP_STRIKES" ] && direction="up"
  elif [ "$pct" -le "$MEMORY_AUTOSCALE_DOWN_PCT" ] 2>/dev/null; then
    down_fails=$((down_fails + 1)); up_fails=0
    [ "$down_fails" -ge "$MEMORY_AUTOSCALE_DOWN_STRIKES" ] && direction="down"
  else
    up_fails=0; down_fails=0
  fi

  if [ -z "$direction" ] || [ $((now - last_change)) -lt "$MEMORY_AUTOSCALE_COOLDOWN_SECONDS" ] 2>/dev/null; then
    memory_autoscale_write "$app" "$up_fails" "$down_fails" "$last_change"
    return
  fi

  adjacent=$(memory_profile_adjacent_level "$app" "$current_limit" "$direction")
  [ -z "$adjacent" ] && { memory_autoscale_write "$app" 0 0 "$last_change"; return; }
  next_level=${adjacent%%:*}
  next_mb=${adjacent##*:}
  [ -z "$next_mb" ] || [ "$next_mb" -lt "$MIN_MEMORY_MB" ] 2>/dev/null && return

  old_limit=$current_limit
  _app_set_limit "$app" "$next_mb"
  sudo_run_quiet systemctl daemon-reload || user_systemctl daemon-reload 2>/dev/null || true
  _app_try_restart "$app"
  rm -f "$CACHE_FILE"
  memory_autoscale_write "$app" 0 0 "$now"
  append_memory_change_log "$app" "MEMORY: ${app} MemoryMax ${old_limit}MB → ${next_mb}MB (${current_level} → ${next_level}) efter ${ram}MB/${old_limit}MB (${pct}%)"
}

watchdog_restart_or_protect() {
  local app=$1 comp=$2 svc=$3 reason=$4 cpu_fails=$5 mem_fails=$6 health_fails=$7 restarts=$8
  local last_action
  if [ "$restarts" -ge "$WATCHDOG_MAX_RESTARTS" ]; then
    user_systemctl stop "${svc}.service" 2>/dev/null || systemctl stop "${svc}.service" 2>/dev/null || true
    last_action="skyddsstopp $(date -Iseconds)"
    watchdog_write_state "$app" "$comp" "protected" "restart_loop" "$cpu_fails" "$mem_fails" "$health_fails" "$restarts" "$last_action"
    echo "WATCHDOG: protected $app/$comp after repeated $reason" >&2
    return
  fi

  restarts=$((restarts + 1))
  user_systemctl restart "${svc}.service" 2>/dev/null || systemctl restart "${svc}.service" 2>/dev/null || true
  last_action="restart $(date -Iseconds)"
  watchdog_write_state "$app" "$comp" "restarting" "$reason" 0 0 0 "$restarts" "$last_action"
  echo "WATCHDOG: restarted $app/$comp ($reason, $restarts/$WATCHDOG_MAX_RESTARTS)" >&2
}

watchdog_check_component() {
  local app=$1 comp=$2 svc=$3 port=$4
  [ -z "$svc" ] && return
  [ "$(service_exists "$svc")" = "true" ] || return

  local prev_status cpu_fails mem_fails health_fails restarts online cpu ram limit mem_pct port_up health_status reason status
  prev_status=$(watchdog_get "$app" "$comp" status)
  cpu_fails=$(watchdog_get "$app" "$comp" cpu_fails); cpu_fails=${cpu_fails:-0}
  mem_fails=$(watchdog_get "$app" "$comp" mem_fails); mem_fails=${mem_fails:-0}
  health_fails=$(watchdog_get "$app" "$comp" health_fails); health_fails=${health_fails:-0}
  restarts=$(watchdog_get "$app" "$comp" restart_count); restarts=${restarts:-0}
  [ "$prev_status" = "protected" ] && return

  online=$(service_is_active "$svc")
  [ "$online" != "true" ] && { watchdog_write_state "$app" "$comp" "ok" "" 0 0 0 "$restarts" ""; return; }

  cpu=0
  local pid
  pid=$(get_service_pid "$svc")
  [ -n "$pid" ] && [ "$pid" != "0" ] && cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' | cut -d. -f1 || echo 0)
  ram=$(get_service_ram "$svc")
  limit=$(get_memory_limit_mb "$svc")
  port_up="true"
  [ -n "$port" ] && [ "$port" -gt 0 ] 2>/dev/null && port_up=$(check_service "$port")
  health_status="ok"
  if [ "$comp" = "engine" ] || [ "$comp" = "service" ]; then
    health_status=$(get_health "$app" | jq -r '.status // "ok"' 2>/dev/null)
  fi

  if [ "${cpu:-0}" -ge "$WATCHDOG_CPU_LIMIT" ] 2>/dev/null; then cpu_fails=$((cpu_fails + 1)); else cpu_fails=0; fi
  if [ "$limit" -gt 0 ] 2>/dev/null && [ "$ram" -gt 0 ] 2>/dev/null; then
    mem_pct=$((ram * 100 / limit))
    [ "$mem_pct" -ge "$WATCHDOG_MEM_RESTART" ] && mem_fails=$((mem_fails + 1)) || mem_fails=0
  else
    mem_pct=0; mem_fails=0
  fi
  if [ "$port_up" != "true" ] || [ "$health_status" = "unreachable" ] || [ "$health_status" = "error" ]; then
    health_fails=$((health_fails + 1))
  else
    health_fails=0
  fi

  [ "$comp" = "engine" ] || [ "$comp" = "service" ] && auto_adjust_memory_limit "$app" "$ram"

  reason=""; status="ok"
  [ "$limit" -gt 0 ] 2>/dev/null && [ "${mem_pct:-0}" -ge "$WATCHDOG_MEM_WARN" ] && { status="warning"; reason="high_memory"; }
  [ "$cpu_fails" -ge "$WATCHDOG_STRIKES" ] && reason="high_cpu"
  [ "$mem_fails" -ge "$WATCHDOG_STRIKES" ] && reason="high_memory"
  [ "$health_fails" -ge "$WATCHDOG_STRIKES" ] && reason="health_timeout"

  if [ -n "$reason" ] && { [ "$cpu_fails" -ge "$WATCHDOG_STRIKES" ] || [ "$mem_fails" -ge "$WATCHDOG_STRIKES" ] || [ "$health_fails" -ge "$WATCHDOG_STRIKES" ]; }; then
    watchdog_restart_or_protect "$app" "$comp" "$svc" "$reason" "$cpu_fails" "$mem_fails" "$health_fails" "$restarts"
  else
    watchdog_write_state "$app" "$comp" "$status" "$reason" "$cpu_fails" "$mem_fails" "$health_fails" "$restarts" ""
  fi
}

watchdog_loop() {
  while true; do
    for app in $(registry_keys); do
      local core port has_comp managed svc engine_svc ui_svc engine_port
      core=$(assignment_get_core "$app")
      [ -z "$core" ] || [ "$core" -lt 1 ] 2>/dev/null && continue
      port=$(port_for_core "$core")
      engine_port=$(engine_port_for_core "$core")
      has_comp=$(registry_has_components "$app")
      managed=$(registry_is_managed "$app")
      if [ "$has_comp" = "true" ]; then
        engine_svc=$(registry_get_component "$app" "engine" "service")
        ui_svc=$(registry_get_component "$app" "ui" "service")
        [ "$managed" = "true" ] && watchdog_check_component "$app" "engine" "$engine_svc" "$engine_port"
        [ "$managed" = "true" ] && watchdog_check_component "$app" "ui" "$ui_svc" "$port"
      else
        svc=$(registry_get "$app" "service")
        [ "$managed" = "true" ] && watchdog_check_component "$app" "service" "$svc" "$port"
      fi
    done
    sleep "$WATCHDOG_INTERVAL"
  done
}

# Combined CPU sampler: reads /proc/stat once, sleeps once, reads again.
# Populates two globals to avoid double-sampling per status build:
#   _CPU_TOTAL_PCT  — aggregate cpu usage (0-100)
#   _CPU_PER_CORE   — JSON array string, e.g. "[12,3,7,0]"
sample_cpu_stats() {
  local agg_total1=0 agg_idle1=0 agg_total2=0 agg_idle2=0
  local cores_before=() cores_after=()

  local label u n s idle w x y _rest total
  while IFS=' ' read -r label u n s idle w x y _rest; do
    if [ "$label" = "cpu" ]; then
      agg_total1=$((u + n + s + idle + w + x + y))
      agg_idle1=$idle
    elif [[ "$label" =~ ^cpu[0-9]+$ ]]; then
      total=$((u + n + s + idle + w + x + y))
      cores_before+=("$total:$idle")
    fi
  done < /proc/stat

  sleep 0.2

  while IFS=' ' read -r label u n s idle w x y _rest; do
    if [ "$label" = "cpu" ]; then
      agg_total2=$((u + n + s + idle + w + x + y))
      agg_idle2=$idle
    elif [[ "$label" =~ ^cpu[0-9]+$ ]]; then
      total=$((u + n + s + idle + w + x + y))
      cores_after+=("$total:$idle")
    fi
  done < /proc/stat

  local td=$((agg_total2 - agg_total1)) id=$((agg_idle2 - agg_idle1))
  if [ "$td" -gt 0 ]; then
    _CPU_TOTAL_PCT=$(((td - id) * 100 / td))
  else
    _CPU_TOTAL_PCT=0
  fi

  local result="" j t1 i1 t2 i2 pct
  for j in $(seq 0 $((${#cores_before[@]} - 1))); do
    t1=${cores_before[$j]%%:*}; i1=${cores_before[$j]##*:}
    t2=${cores_after[$j]%%:*};  i2=${cores_after[$j]##*:}
    td=$((t2 - t1)); id=$((i2 - i1))
    pct=0
    [ "$td" -gt 0 ] && pct=$(((td - id) * 100 / td))
    [ -n "$result" ] && result="${result},"
    result="${result}${pct}"
  done
  _CPU_PER_CORE="[${result}]"
}

# Backwards-compatible wrappers (single sample each, kept for ad-hoc callers).
get_cpu()          { sample_cpu_stats; echo "$_CPU_TOTAL_PCT"; }
get_cpu_per_core() { sample_cpu_stats; echo "$_CPU_PER_CORE"; }

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
  if [ -n "$pid" ] && [ "$pid" != "0" ]; then
    echo "$pid"
    return
  fi
  pid=$(systemctl show "$svc.service" --property=MainPID 2>/dev/null | cut -d= -f2)
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

service_unit_file() {
  local svc=$1
  [ -z "$svc" ] && return
  if [ -f "/etc/systemd/system/${svc}.service" ]; then
    echo "/etc/systemd/system/${svc}.service"
  elif [ -f "$PI_HOME/.config/systemd/user/${svc}.service" ]; then
    echo "$PI_HOME/.config/systemd/user/${svc}.service"
  fi
}

_GET_VERSION_TTL=30

# Inner resolver — does the actual work (curl/git/file).
_get_version_resolve() {
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

# Cached wrapper. Versions don't change between status polls — caching for
# 30s eliminates the worst-case 1s curl/service per installed app per cycle.
get_version() {
  local install_dir="$1" port="$2"
  local key cache_file now age val
  key=$(printf '%s|%s' "$install_dir" "$port" | tr -c 'a-zA-Z0-9' '_' | cut -c1-120)
  cache_file="$STATUS_DIR/version-${key}.cache"
  now=$(date +%s)
  if [ -f "$cache_file" ]; then
    age=$(( now - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$_GET_VERSION_TTL" ]; then
      cat "$cache_file"
      return
    fi
  fi
  val=$(_get_version_resolve "$install_dir" "$port")
  printf '%s' "$val" > "$cache_file" 2>/dev/null
  printf '%s' "$val"
}

# Invalidera version-cachen för en specifik tjänst (anropa efter install/update).
# Om port utelämnas rensas alla version-cache-filer för det install_dir
# (täcker både UI-port och engine-port för component-baserade tjänster).
_invalidate_version_cache() {
  local install_dir="$1" port="${2:-}" key prefix
  if [ -n "$port" ]; then
    key=$(printf '%s|%s' "$install_dir" "$port" | tr -c 'a-zA-Z0-9' '_' | cut -c1-120)
    rm -f "$STATUS_DIR/version-${key}.cache"
  else
    prefix=$(printf '%s|' "$install_dir" | tr -c 'a-zA-Z0-9' '_')
    # Ta de första 120 tecknen för att matcha get_version's cut -c1-120
    prefix=$(printf '%s' "$prefix" | cut -c1-120)
    rm -f "$STATUS_DIR/version-${prefix}"*.cache 2>/dev/null || true
  fi
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
  local cpu temp ram disk uptime_str ram_used ram_total disk_used disk_total svc_json cpu_cores runtime_json
  # Single CPU sample populates both aggregate and per-core in one sleep
  sample_cpu_stats
  cpu="$_CPU_TOTAL_PCT"
  cpu_cores="$_CPU_PER_CORE"
  temp=$(get_temp)
  ram=$(get_ram)
  disk=$(get_disk)
  uptime_str=$(get_uptime)
  runtime_json=$(node_runtime_json)
  rebalance_memory_budget

  # Cache registry once for this build to avoid forking jq dozens of times
  _REGISTRY_CACHE_JSON=$(cat "$REGISTRY_FILE" 2>/dev/null)

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
      local engine_svc ui_svc engine_online ui_online engine_cpu engine_ram ui_cpu ui_ram engine_ver ui_ver engine_port engine_watchdog ui_watchdog
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

      # Check installed: need install_dir + at least one system/user service file
      installed="false"
      if [ -d "$install_dir" ]; then
        { [ -n "$engine_svc" ] && [ -n "$(service_unit_file "$engine_svc")" ]; } || \
        { [ -n "$ui_svc" ] && [ -n "$(service_unit_file "$ui_svc")" ]; } && installed="true"
      fi

      # Use engine port for version check (UI port serves static HTML, not API)
      ver=$(get_version "$install_dir" "$engine_port")
      engine_ver="$ver"; ui_ver="$ver"
      engine_watchdog=$(watchdog_json "$app" "engine")
      ui_watchdog=$(watchdog_json "$app" "ui")

      local total_cpu total_ram
      total_cpu=$(awk -v a="${engine_cpu:-0}" -v b="${ui_cpu:-0}" 'BEGIN{printf "%.1f", a+b}')
      total_ram=$((engine_ram + ui_ram))

      # Read cached health data for engine
      local health_json
      health_json=$(get_health "$app")
      local health_status health_uptime health_mem_rss
      health_status=$(echo "$health_json" | jq -r '.status // "unknown"' 2>/dev/null)
      health_uptime=$(echo "$health_json" | jq -r '.uptime // 0' 2>/dev/null)
      health_mem_rss=$(echo "$health_json" | jq -r '.memory.rss // 0' 2>/dev/null)

      local mem_limit mem_profile mem_level permissions_json cfg_dir data_dir log_dir systemd_warning
      mem_limit=$(_app_current_limit "$app"); [ -z "$mem_limit" ] && mem_limit=$(registry_memory_profile_mb "$app"); [ -z "$mem_limit" ] && mem_limit=128
      mem_profile=$(registry_memory_profile_json "$app"); [ -z "$mem_profile" ] && mem_profile="null"
      mem_level=$(memory_level_for_mb "$app" "$mem_limit")
      permissions_json=$(registry_permissions_json "$app")
      cfg_dir=$(escape_json "$(app_config_dir "$app")")
      data_dir=$(escape_json "$(app_data_dir "$app")")
      log_dir=$(escape_json "$(app_log_dir "$app")")
      systemd_warning=$(app_dirs_warning_json "$app")

      [ -n "$svc_json" ] && svc_json="${svc_json},"
      svc_json="${svc_json}\"${app}\":{\"online\":${online},\"installed\":${installed},\"version\":\"${ver}\",\"cpu\":${total_cpu:-0},\"ramMb\":${total_ram:-0},\"cpuCore\":${core},\"port\":${port},\"memoryMaxMb\":${mem_limit},\"memoryLevel\":\"${mem_level}\",\"memoryProfile\":${mem_profile},\"permissions\":${permissions_json},\"configDir\":\"${cfg_dir}\",\"dataDir\":\"${data_dir}\",\"logDir\":\"${log_dir}\",\"systemdWarning\":${systemd_warning},\"watchdog\":${engine_watchdog},\"health\":{\"status\":\"${health_status}\",\"uptime\":${health_uptime:-0},\"memoryRss\":${health_mem_rss:-0}},\"components\":{\"engine\":{\"online\":${engine_online},\"version\":\"${engine_ver}\",\"cpu\":${engine_cpu:-0},\"ramMb\":${engine_ram:-0},\"service\":\"${engine_svc}\",\"port\":${engine_port},\"cpuCore\":${core},\"watchdog\":${engine_watchdog}},\"ui\":{\"online\":${ui_online},\"version\":\"${ui_ver}\",\"cpu\":${ui_cpu:-0},\"ramMb\":${ui_ram:-0},\"service\":\"${ui_svc}\",\"port\":${port},\"cpuCore\":0,\"watchdog\":${ui_watchdog}}}}"
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
      local service_watchdog
      service_watchdog=$(watchdog_json "$app" "service")
      local mem_limit mem_profile mem_level permissions_json cfg_dir data_dir log_dir systemd_warning
      mem_limit=$(_app_current_limit "$app"); [ -z "$mem_limit" ] && mem_limit=$(registry_memory_profile_mb "$app"); [ -z "$mem_limit" ] && mem_limit=128
      mem_profile=$(registry_memory_profile_json "$app"); [ -z "$mem_profile" ] && mem_profile="null"
      mem_level=$(memory_level_for_mb "$app" "$mem_limit")
      permissions_json=$(registry_permissions_json "$app")
      cfg_dir=$(escape_json "$(app_config_dir "$app")")
      data_dir=$(escape_json "$(app_data_dir "$app")")
      log_dir=$(escape_json "$(app_log_dir "$app")")
      systemd_warning=$(app_dirs_warning_json "$app")
      svc_json="${svc_json}\"${app}\":{\"online\":${online},\"installed\":${installed},\"version\":\"${ver}\",\"cpu\":${s_cpu:-0},\"ramMb\":${s_ram:-0},\"cpuCore\":${s_core},\"port\":${port},\"memoryMaxMb\":${mem_limit},\"memoryLevel\":\"${mem_level}\",\"memoryProfile\":${mem_profile},\"permissions\":${permissions_json},\"configDir\":\"${cfg_dir}\",\"dataDir\":\"${data_dir}\",\"logDir\":\"${log_dir}\",\"systemdWarning\":${systemd_warning},\"watchdog\":${service_watchdog}}"
    fi
  done

  local dash_cpu dash_ram nginx_ram dash_pid
  dash_cpu=0
  dash_ram=$(get_service_ram "pi-control-center-api")
  nginx_ram=$(get_service_ram "nginx")
  dash_ram=$((dash_ram + nginx_ram))
  dash_pid=$(systemctl show "pi-control-center-api.service" --property=MainPID 2>/dev/null | cut -d= -f2)
  [ -n "$dash_pid" ] && [ "$dash_pid" != "0" ] && dash_cpu=$(ps -p "$dash_pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")

  local reboot_json
  reboot_json='{"required":false}'
  [ -f "$REBOOT_REQUIRED_FILE" ] && reboot_json=$(cat "$REBOOT_REQUIRED_FILE" 2>/dev/null || echo '{"required":false}')
  echo "{\"cpu\":${cpu:-0},\"cpuCores\":${cpu_cores:-[]},\"temp\":${temp:-0},\"ramUsed\":${ram_used:-0},\"ramTotal\":${ram_total:-0},\"diskUsed\":${disk_used:-0},\"diskTotal\":${disk_total:-0},\"uptime\":\"${uptime_str}\",\"dashboardCpu\":${dash_cpu:-0},\"dashboardRamMb\":${dash_ram:-0},\"commit\":\"${DASHBOARD_COMMIT_SHORT}\",\"branch\":\"${DASHBOARD_BRANCH}\",\"runtime\":${runtime_json},\"rebootRequired\":${reboot_json},\"services\":{${svc_json}}}"
  unset _REGISTRY_CACHE_JSON
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


# Total antal steg i en typisk installation (används för procentberäkning)
INSTALL_TOTAL_STEPS=10

# Mappa progress-meddelande till stegnummer (1..INSTALL_TOTAL_STEPS)
_progress_step_for_msg() {
  case "$1" in
    Startar*)                          echo 1 ;;
    Hämtar\ release-info*)             echo 2 ;;
    Förbereder\ katalog*)              echo 3 ;;
    Klonar*)                           echo 3 ;;
    Laddar\ ner*)                      echo 4 ;;
    Packar\ upp*)                      echo 5 ;;
    Verifierar*)                       echo 5 ;;
    Bygger*|npm\ rebuild*)             echo 6 ;;
    Kör\ installationsskript*)         echo 7 ;;
    Skapar\ systemd*)                  echo 8 ;;
    Aktiverar*|Startar\ tjänst*)       echo 9 ;;
    Hanteras\ externt*)                echo 9 ;;
    Klar*|Installation\ klar*)         echo 10 ;;
    *)                                 echo "" ;;
  esac
}

progress() {
  local sf=$1 app=$2 msg=$3 start=$4
  local elapsed=$(( $(date +%s) - start ))
  local min=$((elapsed / 60)) sec=$((elapsed % 60))
  local time_str
  if [ "$min" -gt 0 ]; then time_str="${min}m ${sec}s"; else time_str="${sec}s"; fi

  local step pct
  step=$(_progress_step_for_msg "$msg")
  if [ -n "$step" ]; then
    pct=$(( step * 100 / INSTALL_TOTAL_STEPS ))
  else
    # Okänt meddelande: behåll föregående steg/procent om filen finns
    if [ -f "$sf" ]; then
      step=$(grep -oP '"step":\K\d+' "$sf" 2>/dev/null)
      pct=$(grep -oP '"percent":\K\d+' "$sf" 2>/dev/null)
    fi
    [ -z "$step" ] && step=1
    [ -z "$pct" ] && pct=10
  fi

  echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"${msg}\",\"elapsed\":\"${time_str}\",\"step\":${step},\"totalSteps\":${INSTALL_TOTAL_STEPS},\"percent\":${pct}}" > "$sf"
}

queue_install() {
  local app=$1 req_port=$2 req_core=$3 unit_name run_err
  unit_name="pi-control-center-install-${app}-$(date +%s)"
  run_err="$INSTALL_DIR/${app}.queue.log"
  : > "$run_err"

  if XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS" \
    systemd-run --user --quiet --collect --no-block --unit "$unit_name" \
      --setenv=XDG_RUNTIME_DIR="$USER_RUNTIME_DIR" \
      --setenv=DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS" \
      "$SCRIPT_PATH" --run-install "$app" "$req_port" "$req_core" >> "$run_err" 2>&1; then
    return 0
  fi

  sudo_run systemd-run --quiet --collect --no-block --unit "$unit_name" \
    -p Type=exec \
    -p User="$(whoami)" \
    -p Group="$(id -gn)" \
    -p MemoryMax=256M \
    -p Environment="XDG_RUNTIME_DIR=$USER_RUNTIME_DIR" \
    -p Environment="DBUS_SESSION_BUS_ADDRESS=$USER_BUS_ADDRESS" \
    "$SCRIPT_PATH" --run-install "$app" "$req_port" "$req_core" >> "$run_err" 2>&1
}

do_install_release() {
  local app=$1 req_port=$2 req_core=$3 sf=$4 start_time=$5
  local release_url install_dir svc download_url

  release_url=$(registry_get "$app" "releaseUrl")
  install_dir=$(eval echo "$(registry_get "$app" "installDir")")
  svc=$(registry_get "$app" "service")

  if [ -z "$release_url" ]; then
    printf '[%s] release: ingen releaseUrl i services.json — hoppar över release-install\n' "$(date -Iseconds)" >> "$INSTALL_DIR/${app}.log"
    return 1
  fi

  progress "$sf" "$app" "Hämtar release-info från GitHub..." "$start_time"
  download_url=$(latest_release_asset_url "$app")

  if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
    printf '[%s] release: kunde inte hitta nedladdnings-URL för senaste release (asset=%s, url=%s)\n' \
      "$(date -Iseconds)" "$(registry_release_asset "$app")" "$release_url" >> "$INSTALL_DIR/${app}.log"
    echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Ingen release-asset hittad på GitHub (kontrollera att senaste release har $(registry_release_asset "$app"))\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
    return 1
  fi

  progress "$sf" "$app" "Förbereder katalog..." "$start_time"
  [ -d "$install_dir" ] && sudo_run rm -rf "$install_dir"
  sudo_run mkdir -p "$install_dir"
  sudo_run chown "$(pcc_owner_user):$(pcc_owner_group)" "$install_dir"

  progress "$sf" "$app" "Laddar ner förbyggd release..." "$start_time"
  if ! curl -sfL "$download_url" -o "/tmp/pi-control-center/${app}-dist.tar.gz" >> "$INSTALL_DIR/${app}.log" 2>&1; then
    printf '[%s] release: curl-nedladdning misslyckades från %s\n' "$(date -Iseconds)" "$download_url" >> "$INSTALL_DIR/${app}.log"
    echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Nedladdning av release-asset misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
    return 1
  fi

  progress "$sf" "$app" "Packar upp..." "$start_time"
  if ! tar xzf "/tmp/pi-control-center/${app}-dist.tar.gz" -C "$install_dir" >> "$INSTALL_DIR/${app}.log" 2>&1; then
    echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Uppackning misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
    rm -f "/tmp/pi-control-center/${app}-dist.tar.gz"
    return 1
  fi
  rm -f "/tmp/pi-control-center/${app}-dist.tar.gz"

  local latest_tag
  latest_tag=$(latest_release_tag "$app")
  if [ -n "$latest_tag" ]; then
    printf '{"tag":"%s","version":"%s","installedAt":"%s"}\n' "$(escape_json "$latest_tag")" "$(escape_json "$latest_tag")" "$(date -Iseconds)" > "$install_dir/VERSION.json"
  fi

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
        # Kör som app-usern (pi) — annars blir node_modules root-ägda och
        # engine får EACCES på första write. Native modules kräver INTE root.
        if ! sudo_run systemd-run --scope --quiet -p MemoryMax=256M -p User="$(pcc_owner_user)" -p Group="$(pcc_owner_group)" \
          bash -lc "cd '$pkg_dir' && NPM_CONFIG_CACHE='${install_dir}/.npm-cache' nice -n 15 ionice -c 3 npm rebuild --no-audit --no-fund" >> "$INSTALL_DIR/${app}.log" 2>&1; then
          progress "$sf" "$app" "npm rebuild misslyckades i ${pkg_dir##*/}, försöker npm install..." "$start_time"
          sudo_run systemd-run --scope --quiet -p MemoryMax=256M -p User="$(pcc_owner_user)" -p Group="$(pcc_owner_group)" \
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
      # Kör install-script som app-usern. Om scriptet behöver root för enstaka
      # operationer (systemd, apt) ska det själv göra `sudo` — så att alla
      # vanliga filskrivningar (storage.json, config) sker som pi.
        sudo_run systemd-run --scope --quiet -p MemoryMax=256M -p User="$(pcc_owner_user)" -p Group="$(pcc_owner_group)" \
          env PCC_MANAGED=1 nice -n 15 ionice -c 3 bash "$install_dir/$install_script" --port "$req_port" --core "$req_core" >> "$INSTALL_DIR/${app}.log" 2>&1 || true
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
        assert_node_runtime || log "WARNING: PCC expects Node.js v24, current runtime is $(get_node_version)"
        local comp_heap_mb
        comp_heap_mb=$(registry_memory_profile_mb "$app")
        [ -z "$comp_heap_mb" ] && comp_heap_mb=96
        comp_exec="$(get_node_bin) --max-old-space-size=${comp_heap_mb} ${install_dir}/${comp_entry}"
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

      local comp_security_lines="PrivateTmp=true"
      local comp_env_lines=""
      local comp_cfg_dir comp_data_dir comp_log_dir comp_home_dir comp_permissions comp_group_lines comp_cap_lines comp_device_lines
      comp_cfg_dir=$(app_config_dir "$app")
      comp_data_dir=$(app_data_dir "$app")
      comp_log_dir=$(app_log_dir "$app")
      comp_home_dir="${comp_data_dir}/home"
      comp_permissions=$(registry_permissions_env "$app")
      ensure_app_managed_dirs "$app"
      comp_group_lines=""
      comp_cap_lines=""
      comp_device_lines=""
      comp_env_lines="Environment=HOME=${comp_home_dir}
Environment=XDG_DATA_HOME=${comp_home_dir}/.local/share"
      if registry_needs_permission "$app" "bluetooth" || registry_needs_permission "$app" "rfkill" || registry_needs_permission "$app" "audio"; then
        comp_group_lines="SupplementaryGroups=netdev bluetooth audio"
      fi
      if [ "$comp" = "engine" ] && [ "$comp_type" = "node" ]; then
        comp_security_lines="PrivateTmp=true"
        comp_env_lines="${comp_env_lines}
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=${comp_heap_mb}
Environment=DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket"
        if registry_needs_permission "$app" "bluetooth" || registry_needs_permission "$app" "rfkill"; then
          comp_cap_lines="NoNewPrivileges=false
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_SYS_NICE
CapabilityBoundingSet=CAP_NET_RAW CAP_NET_ADMIN CAP_SYS_NICE"
          comp_device_lines="DeviceAllow=/dev/rfkill rw
DeviceAllow=char-rfkill rw"
        fi
        if registry_needs_permission "$app" "audio"; then
          comp_device_lines="${comp_device_lines}
DeviceAllow=char-alsa rw
DeviceAllow=/dev/snd rw
LimitRTPRIO=99
LimitNICE=-20"
        fi
      fi

      local comp_svc_file="/etc/systemd/system/${comp_svc}.service"
      user_systemctl stop "${comp_svc}.service" 2>/dev/null || true
      user_systemctl disable "${comp_svc}.service" 2>/dev/null || true
      rm -f "$PI_HOME/.config/systemd/user/${comp_svc}.service" 2>/dev/null || true
      sudo_run_quiet systemctl stop "${comp_svc}.service" || true
      sudo_run_quiet systemctl disable "${comp_svc}.service" || true
      if ! sudo_run tee "$comp_svc_file" > /dev/null <<UNIT
[Unit]
Description=${app} ${comp} service
After=network.target

[Service]
Type=simple
User=pi
Group=pi
WorkingDirectory=${comp_work_dir}
ExecStart=${comp_exec}
Environment=NPM_CONFIG_CACHE=${install_dir}/.npm-cache
Environment=PCC_APP_KEY=${app}
Environment=PCC_CONFIG_DIR=${comp_cfg_dir}
Environment=PCC_DATA_DIR=${comp_data_dir}
Environment=PCC_LOG_DIR=${comp_log_dir}
Environment=PCC_PERMISSIONS=${comp_permissions}
Environment=PORT=${comp_port}
Environment=ENGINE_PORT=${engine_port}
Environment=UI_PORT=${req_port}
${comp_env_lines}
${cpu_pin_lines}
${comp_cap_lines}
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${install_dir}
ReadWritePaths=${comp_cfg_dir}
ReadWritePaths=${comp_data_dir}
ReadWritePaths=${comp_log_dir}
${comp_security_lines}
${comp_group_lines}
${comp_device_lines}
StandardOutput=append:${comp_log_dir}/${comp}.log
StandardError=append:${comp_log_dir}/${comp}.log
Restart=${restart_policy}
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
      then
        return 1
      fi

      sudo_run systemctl daemon-reload || return 1
      sudo_run systemctl enable "${comp_svc}.service" || return 1
      sudo_run systemctl --no-block start "${comp_svc}.service" || return 1
    done
  else
    # Legacy single-service
    local svc_file="/etc/systemd/system/${svc}.service"
    local app_type entrypoint exec_start
    app_type=$(registry_get "$app" "type")
    entrypoint=$(registry_get "$app" "entrypoint")
    mkdir -p "${install_dir}/.npm-cache"

    # Determine working directory from entrypoint's package.json location
    local legacy_work_dir="${install_dir}"
    local legacy_security_lines="PrivateTmp=true
NoNewPrivileges=true"
    local legacy_env_lines=""
    local legacy_cfg_dir legacy_data_dir legacy_log_dir legacy_home_dir legacy_permissions legacy_group_lines
    legacy_cfg_dir=$(app_config_dir "$app")
    legacy_data_dir=$(app_data_dir "$app")
    legacy_log_dir=$(app_log_dir "$app")
    legacy_home_dir="${legacy_data_dir}/home"
    legacy_permissions=$(registry_permissions_env "$app")
    ensure_app_managed_dirs "$app"
    legacy_group_lines=""
    legacy_env_lines="Environment=HOME=${legacy_home_dir}
Environment=XDG_DATA_HOME=${legacy_home_dir}/.local/share"
    registry_needs_permission "$app" "bluetooth" && legacy_group_lines="SupplementaryGroups=bluetooth"
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
      assert_node_runtime || log "WARNING: PCC expects Node.js v24, current runtime is $(get_node_version)"
      local legacy_heap_mb
      legacy_heap_mb=$(registry_memory_profile_mb "$app")
      [ -z "$legacy_heap_mb" ] && legacy_heap_mb=96
      exec_start="$(get_node_bin) --max-old-space-size=${legacy_heap_mb} ${install_dir}/${entrypoint}"
      legacy_security_lines="PrivateTmp=true"
      legacy_env_lines="${legacy_env_lines}
Environment=NODE_ENV=production
Environment=NODE_OPTIONS=--max-old-space-size=${legacy_heap_mb}
Environment=DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket"
    else
      exec_start="/usr/bin/python3 ${PI_HOME}/pi-control-center/public/pi-scripts/static-spa-server.py --root ${install_dir}/dist --port ${req_port} --host 0.0.0.0"
    fi

    user_systemctl stop "${svc}.service" 2>/dev/null || true
    user_systemctl disable "${svc}.service" 2>/dev/null || true
    rm -f "$PI_HOME/.config/systemd/user/${svc}.service" 2>/dev/null || true
    sudo_run_quiet systemctl stop "${svc}.service" || true
    sudo_run_quiet systemctl disable "${svc}.service" || true
    sudo_run tee "$svc_file" > /dev/null <<UNIT
[Unit]
Description=${app} service
After=network.target

[Service]
Type=simple
User=pi
Group=pi
WorkingDirectory=${legacy_work_dir}
ExecStart=${exec_start}
Environment=NPM_CONFIG_CACHE=${install_dir}/.npm-cache
Environment=PCC_APP_KEY=${app}
Environment=PCC_CONFIG_DIR=${legacy_cfg_dir}
Environment=PCC_DATA_DIR=${legacy_data_dir}
Environment=PCC_LOG_DIR=${legacy_log_dir}
Environment=PCC_PERMISSIONS=${legacy_permissions}
Environment=PORT=${req_port}
${legacy_env_lines}
CPUAffinity=${req_core}
AllowedCPUs=${req_core}
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${install_dir}
ReadWritePaths=${legacy_cfg_dir}
ReadWritePaths=${legacy_data_dir}
ReadWritePaths=${legacy_log_dir}
${legacy_security_lines}
${legacy_group_lines}
StandardOutput=append:${legacy_log_dir}/service.log
StandardError=append:${legacy_log_dir}/service.log
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    sudo_run systemctl daemon-reload
    sudo_run systemctl enable "${svc}.service"
    sudo_run systemctl --no-block start "${svc}.service"
  fi

  return 0
}

# --- RAM-budget: hantera MemoryMax per installerad tjänst ---
# Alla installerade appar får minst sin profilnivå. Finns ledig budget kvar
# fördelas den jämnt mellan apparna så MemoryMax växer automatiskt.
# Vid överskridande av budget skalas alla limits ned proportionellt.
RAM_BUDGET_MB=330

memory_budget_mb() {
  local total available committed app_used budget
  read -r total available < <(awk '/^MemTotal:/{t=int($2/1024)} /^MemAvailable:/{a=int($2/1024)} END{print t, a}' /proc/meminfo 2>/dev/null)
  budget=$RAM_BUDGET_MB
  if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
    app_used=${1:-0}
    committed=$((app_used + available - 64))
    budget=$((total - 86))
    [ "$committed" -lt "$budget" ] && budget=$committed
    [ "$budget" -lt 240 ] && budget=240
    [ "$budget" -gt 480 ] && budget=480
  fi
  echo "$budget"
}

# Hämta primär service-fil för en app (engine om components, annars legacy service)
_app_primary_svc_file() {
  local app="$1"
  local s
  if [ "$(registry_has_components "$app")" = "true" ]; then
    s=$(registry_get_component "$app" "engine" "service")
    [ -z "$s" ] && s=$(registry_get_component "$app" "ui" "service")
  else
    s=$(registry_get "$app" "service")
  fi
  [ -n "$s" ] && service_unit_file "$s"
}

# Läs aktuell MemoryMax (MB) för en app, tom sträng om ej satt
_app_current_limit() {
  local f
  f=$(_app_primary_svc_file "$1")
  [ -f "$f" ] || { echo ""; return; }
  grep -oP '^MemoryMax=\K\d+' "$f" 2>/dev/null
}

# Sätt MemoryMax (MB) på alla service-filer som hör till en app
_app_set_limit() {
  local app="$1" limit_mb="$2"
  local s f
  if [ "$(registry_has_components "$app")" = "true" ]; then
    for comp in engine ui; do
      s=$(registry_get_component "$app" "$comp" "service")
      [ -n "$s" ] || continue
      f=$(service_unit_file "$s")
      [ -f "$f" ] || continue
      if grep -q '^MemoryMax=' "$f"; then
        sudo_run sed -i "s/^MemoryMax=.*/MemoryMax=${limit_mb}M/" "$f"
      else
        sudo_run sed -i "/^\[Service\]/a MemoryMax=${limit_mb}M" "$f"
      fi
      sudo_run_quiet systemctl set-property "${s}.service" "MemoryMax=${limit_mb}M" || user_systemctl set-property "${s}.service" "MemoryMax=${limit_mb}M" 2>/dev/null || true
    done
  else
    s=$(registry_get "$app" "service")
    [ -n "$s" ] || return
    f=$(service_unit_file "$s")
    [ -f "$f" ] || return
    if grep -q '^MemoryMax=' "$f"; then
      sudo_run sed -i "s/^MemoryMax=.*/MemoryMax=${limit_mb}M/" "$f"
    else
      sudo_run sed -i "/^\[Service\]/a MemoryMax=${limit_mb}M" "$f"
    fi
    sudo_run_quiet systemctl set-property "${s}.service" "MemoryMax=${limit_mb}M" || user_systemctl set-property "${s}.service" "MemoryMax=${limit_mb}M" 2>/dev/null || true
  fi
}

# Skriv om --max-old-space-size=N i ExecStart= och NODE_OPTIONS för en unit-fil
# om värdet skiljer sig från target_mb. Returnerar 0 om filen ändrades, 1 annars.
_sync_heap_in_unit_file() {
  local f="$1" target_mb="$2"
  [ -f "$f" ] || return 1
  [ -n "$target_mb" ] || return 1
  # Kolla om filen ens innehåller ett heap-värde
  grep -q -- '--max-old-space-size=' "$f" || return 1
  # Kolla om alla värden redan matchar
  if ! grep -oE -- '--max-old-space-size=[0-9]+' "$f" | grep -qv -- "--max-old-space-size=${target_mb}\$"; then
    return 1
  fi
  sudo_run sed -i -E "s/--max-old-space-size=[0-9]+/--max-old-space-size=${target_mb}/g" "$f"
  return 0
}

# Synka heap-limit i alla installerade tjänsters unit-filer mot registryns
# memoryProfile.defaultLevel. Daemon-reload + try-restart vid förändring.
sync_all_heap_limits() {
  local app changed=0 target_mb level s f
  for app in $(registry_keys); do
    target_mb=$(registry_memory_profile_mb "$app")
    [ -n "$target_mb" ] || continue
    level=$(registry_memory_profile_default_level "$app")
    if [ "$(registry_has_components "$app")" = "true" ]; then
      for comp in engine ui; do
        s=$(registry_get_component "$app" "$comp" "service")
        [ -n "$s" ] || continue
        f=$(service_unit_file "$s")
        [ -n "$f" ] || continue
        if _sync_heap_in_unit_file "$f" "$target_mb"; then
          changed=1
          log "HEAP-SYNC: ${s} → --max-old-space-size=${target_mb} (${app}/${level})"
          append_memory_change_log "$app" "HEAP: ${s} satt till ${target_mb}MB (${level}) via auto-sync"
          sudo_run_quiet systemctl try-restart "${s}.service" || user_systemctl try-restart "${s}.service" 2>/dev/null || true
        fi
      done
    else
      s=$(registry_get "$app" "service")
      [ -n "$s" ] || continue
      f=$(service_unit_file "$s")
      [ -n "$f" ] || continue
      if _sync_heap_in_unit_file "$f" "$target_mb"; then
        changed=1
        log "HEAP-SYNC: ${s} → --max-old-space-size=${target_mb} (${app}/${level})"
        append_memory_change_log "$app" "HEAP: ${s} satt till ${target_mb}MB (${level}) via auto-sync"
        sudo_run_quiet systemctl try-restart "${s}.service" || user_systemctl try-restart "${s}.service" 2>/dev/null || true
      fi
    fi
  done
  [ "$changed" -eq 1 ] && sudo_run systemctl daemon-reload || true
  return 0
}

# Starta om alla service-filer för en app
_app_try_restart() {
  local app="$1" s
  if [ "$(registry_has_components "$app")" = "true" ]; then
    for comp in engine ui; do
      s=$(registry_get_component "$app" "$comp" "service")
      [ -n "$s" ] && { sudo_run_quiet systemctl try-restart "${s}.service" || user_systemctl try-restart "${s}.service" 2>/dev/null || true; }
    done
  else
    s=$(registry_get "$app" "service")
    [ -n "$s" ] && { sudo_run_quiet systemctl try-restart "${s}.service" || user_systemctl try-restart "${s}.service" 2>/dev/null || true; }
  fi
}

_app_runtime_ram_mb() {
  local app="$1" total=0 s
  if [ "$(registry_has_components "$app")" = "true" ]; then
    for comp in engine ui; do
      s=$(registry_get_component "$app" "$comp" "service")
      [ -n "$s" ] || continue
      [ "$(service_is_active "$s")" = "true" ] && total=$((total + $(get_service_ram "$s")))
    done
  else
    s=$(registry_get "$app" "service")
    [ -n "$s" ] && [ "$(service_is_active "$s")" = "true" ] && total=$(get_service_ram "$s")
  fi
  echo "$total"
}

rebalance_memory_budget() {
  local installed_apps=()
  local app
  for app in $(registry_keys); do
    [ -n "$(assignment_get_core "$app")" ] && installed_apps+=("$app")
  done
  local count=${#installed_apps[@]}
  [ "$count" -eq 0 ] && return 0

  # Steg 1: räkna faktisk RAM-användning per app
  local total_used=0 changed_apps=()
  declare -A current_limits
  declare -A runtime_ram
  for app in "${installed_apps[@]}"; do
    local cur used
    cur=$(_app_current_limit "$app")
    [ -z "$cur" ] && cur=0
    used=$(_app_runtime_ram_mb "$app")
    [ -z "$used" ] && used=0
    current_limits[$app]=$cur
    runtime_ram[$app]=$used
    total_used=$((total_used + used))
  done

  local budget
  budget=$(memory_budget_mb "$total_used")

  # Steg 2: ny maxgräns = faktisk användning + lika del av ledigt app-RAM
  local free=$((budget - total_used)) share=0 extra=0 idx=0
  [ "$free" -gt 0 ] && share=$((free / count)) && extra=$((free % count))
  [ "$free" -lt 0 ] && log "RAM-användning ${total_used}MB > budget ${budget}MB — sätter gränser nära aktuell användning"
  for app in "${installed_apps[@]}"; do
    local old=${current_limits[$app]} add=$share new floor
    floor=$(registry_memory_profile_mb "$app")
    [ -z "$floor" ] && floor=$MIN_MEMORY_MB
    [ "$idx" -lt "$extra" ] && add=$((add + 1))
    idx=$((idx + 1))
    new=$((runtime_ram[$app] + add))
    [ "$new" -lt "$floor" ] && new=$floor
    [ "$new" -gt 480 ] && new=480
    if [ "$new" != "$old" ]; then
      current_limits[$app]=$new
      changed_apps+=("$app")
    fi
  done

  # Steg 3: skriv alla ändrade limits
  if [ ${#changed_apps[@]} -gt 0 ]; then
    local seen=" "
    for app in "${changed_apps[@]}"; do
      case "$seen" in *" $app "*) continue;; esac
      seen="$seen$app "
      _app_set_limit "$app" "${current_limits[$app]}"
    done
    sudo_run_quiet systemctl daemon-reload || user_systemctl daemon-reload 2>/dev/null || true
    rm -f "$CACHE_FILE"
    log "RAM-budget fördelad: ${budget}MB över ${count} tjänst(er)"
  fi
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
  exec 9>"$OP_LOCK_FILE"
  if ! flock -n 9; then
    progress "$sf" "$app" "Pi upptagen – väntar på installationskö..." "$start_time"
    flock 9
  fi
  if [ "$(registry_is_managed "$app")" != "false" ] && ! sudo_available; then
    echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"PCC saknar lösenordsfri sudo för systemtjänster\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
    return 1
  fi
  ensure_app_managed_dirs "$app"

  export XDG_RUNTIME_DIR="$USER_RUNTIME_DIR"
  export DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS"

  # Try release-based install first
  if do_install_release "$app" "$req_port" "$req_core" "$sf" "$start_time"; then
    install_message="Installation klar (release)"
  else
    # Om release-vägen redan skrev ett tydligt felmeddelande, behåll det
    # istället för att falla tillbaka till git clone (som annars döljer
    # det verkliga felet bakom "Git clone misslyckades").
    if [ -f "$sf" ] && grep -q '"status":"error"' "$sf" 2>/dev/null; then
      return 1
    fi
    # Fallback to legacy git clone + build
    install_message="Installation klar"

    progress "$sf" "$app" "Förbereder katalog..." "$start_time"
    [ -d "$install_dir" ] && sudo_run rm -rf "$install_dir"
    sudo_run mkdir -p "$(dirname "$install_dir")"

    progress "$sf" "$app" "Klonar repo..." "$start_time"
    if ! nice -n 15 sudo_run git clone --depth 1 "$repo" "$install_dir" > "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Git clone misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi
    sudo_run chown -R "$(pcc_owner_user):$(pcc_owner_group)" "$install_dir"

    # Fix CRLF line endings in all shell scripts
    find "$install_dir" -name '*.sh' -exec sed -i 's/\r$//' {} +

    progress "$sf" "$app" "Verifierar installationsskript..." "$start_time"
    if [ ! -f "$install_dir/$script" ]; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript saknas\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi

    chmod +x "$install_dir/$script"

    progress "$sf" "$app" "Kör installationsskript (kan ta flera minuter)..." "$start_time"
    if ! sudo_run systemd-run --scope --quiet -p MemoryMax=256M \
      nice -n 15 ionice -c 3 bash "$install_dir/$script" --port "$req_port" --core "$req_core" >> "$INSTALL_DIR/${app}.log" 2>&1; then
      echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Installationsskript misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
      return 1
    fi
  fi

  progress "$sf" "$app" "Sparar konfiguration..." "$start_time"
  repair_app_managed_dirs "$app" "config-save" || true

  # Save assignment
  assignment_set "$app" "$req_core"

  # Omfördela RAM-budgeten mellan alla installerade tjänster
  rebalance_memory_budget

  _invalidate_version_cache "$install_dir"
  rm -f "$CACHE_FILE"
  local total_elapsed=$(( $(date +%s) - start_time ))
  local t_min=$((total_elapsed / 60)) t_sec=$((total_elapsed % 60))
  local total_str
  if [ "$t_min" -gt 0 ]; then total_str="${t_min}m ${t_sec}s"; else total_str="${t_sec}s"; fi
  echo "{\"app\":\"${app}\",\"status\":\"success\",\"message\":\"${install_message} (${total_str})\",\"timestamp\":\"$(date -Iseconds)\"}" > "$sf"
}

do_uninstall() {
  # Returns 0 on success, 1 on failure. On failure, prints reason to stderr.
  local app install_dir svc uninstall_script has_comp
  app=$1
  install_dir=$(eval echo "$(registry_get "$app" "installDir")")
  svc=$(registry_get "$app" "service")
  uninstall_script=$(registry_get "$app" "uninstallScript")
  has_comp=$(registry_has_components "$app")

  local svc_list=()
  if [ "$has_comp" = "true" ]; then
    for comp in engine ui; do
      local comp_svc
      comp_svc=$(registry_get_component "$app" "$comp" "service")
      [ -z "$comp_svc" ] && continue
      svc_list+=("$comp_svc")
      sudo_run_quiet systemctl --no-block stop "${comp_svc}.service" || sudo_run_quiet systemctl stop "${comp_svc}.service" || user_systemctl stop "${comp_svc}.service" 2>/dev/null || true
      sudo_run_quiet systemctl disable "${comp_svc}.service" || user_systemctl disable "${comp_svc}.service" 2>/dev/null || true
      sudo_run_quiet rm -f "/etc/systemd/system/${comp_svc}.service" || true
      rm -f "$PI_HOME/.config/systemd/user/${comp_svc}.service" 2>/dev/null || true
    done
  else
    [ -n "$svc" ] && svc_list+=("$svc")
    sudo_run_quiet systemctl --no-block stop "${svc}.service" || sudo_run_quiet systemctl stop "${svc}.service" || user_systemctl stop "${svc}.service" 2>/dev/null || true
    sudo_run_quiet systemctl disable "${svc}.service" || user_systemctl disable "${svc}.service" 2>/dev/null || true
    sudo_run_quiet rm -f "/etc/systemd/system/${svc}.service" || true
    rm -f "$PI_HOME/.config/systemd/user/${svc}.service" 2>/dev/null || true
  fi
  sudo_run_quiet systemctl daemon-reload || true

  # Run uninstall script if it exists
  if [ -n "$uninstall_script" ] && [ -f "$install_dir/$uninstall_script" ]; then
    chmod +x "$install_dir/$uninstall_script" 2>/dev/null || true
    timeout 20 bash "$install_dir/$uninstall_script" 2>/dev/null || true
  fi

  sudo_run_quiet systemctl daemon-reload || true
  user_systemctl daemon-reload 2>/dev/null || true

  # Remove install directory (try sudo, then non-sudo as fallback)
  local rm_err=""
  if [ -n "$install_dir" ] && [ -d "$install_dir" ]; then
    rm_err=$(sudo_run rm -rf "$install_dir" 2>&1) || true
    if [ -d "$install_dir" ]; then
      rm_err=$(rm -rf "$install_dir" 2>&1) || true
    fi
  fi

  # Remove assignment
  assignment_remove "$app"

  # Omfördela RAM-budgeten — kvarvarande tjänster får mer
  rebalance_memory_budget

  rm -f "$CACHE_FILE"
  rm -f "$HEALTH_DIR/${app}.json"

  # Verify removal — collect leftovers
  local leftovers=()
  if [ -n "$install_dir" ] && [ -d "$install_dir" ]; then
    leftovers+=("install-dir kvar: $install_dir")
  fi
  for s in "${svc_list[@]}"; do
    if [ -f "/etc/systemd/system/${s}.service" ] || [ -f "$PI_HOME/.config/systemd/user/${s}.service" ]; then
      leftovers+=("service-fil kvar: ${s}.service")
    fi
  done

  if [ ${#leftovers[@]} -gt 0 ]; then
    local reason
    reason=$(IFS='; '; echo "${leftovers[*]}")
    [ -n "$rm_err" ] && reason="${reason}; rm-fel: ${rm_err}"
    echo "UNINSTALL_ERROR: ${reason}" >&2
    return 1
  fi
  return 0
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
        echo "{\"app\":\"${app}\",\"status\":\"installing\",\"progress\":\"Startar installation...\",\"elapsed\":\"0s\",\"step\":1,\"totalSteps\":${INSTALL_TOTAL_STEPS},\"percent\":10}" > "$INSTALL_DIR/${app}.json"
        rm -f "$INSTALL_DIR/${app}.log"
        if queue_install "$app" "$req_port" "$req_core"; then
          response=$(< "$INSTALL_DIR/${app}.json")
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
      local app uninst_err
      app=${path#/api/uninstall/}
      if [ -z "$(registry_get "$app" "repo")" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        local uninst_rc
        uninst_err=$(do_uninstall "$app" 2>&1 >/dev/null)
        uninst_rc=$?
        # Endast rader med UNINSTALL_ERROR-prefix räknas som fel; övrig stderr
        # (t.ex. "PCC API: RAM-budget fördelad...") är informationsloggar.
        local err_line
        err_line=$(printf '%s\n' "$uninst_err" | grep -m1 '^UNINSTALL_ERROR:' || true)
        if [ "$uninst_rc" -eq 0 ] && [ -z "$err_line" ]; then
          response="{\"app\":\"${app}\",\"status\":\"success\"}"
        else
          local msg="${err_line#UNINSTALL_ERROR: }"
          msg=${msg//\\/\\\\}
          msg=${msg//\"/\\\"}
          msg=${msg//$'\n'/ }
          [ -z "$msg" ] && msg="Avinstallation misslyckades (okänt fel)"
          status_line="HTTP/1.1 500 Internal Server Error"
          response="{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"${msg}\"}"
        fi
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

        # Clear persistent app config/data/logs
        sudo rm -rf "$APPS_CONFIG_DIR" "$APPS_DATA_DIR" "$APPS_LOG_DIR" >> "$reset_log" 2>&1 || true
        sudo mkdir -p "$APPS_CONFIG_DIR" "$APPS_DATA_DIR" "$APPS_LOG_DIR" >> "$reset_log" 2>&1 || true
        sudo chown -R pi:pi "$APPS_CONFIG_DIR" "$APPS_DATA_DIR" "$APPS_LOG_DIR" >> "$reset_log" 2>&1 || true

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
        sudo chown -R pi:pi "$ddir/node_modules" 2>/dev/null || true
        sudo systemd-run --scope --quiet -p MemoryMax=512M bash -lc "cd '$ddir' && NODE_OPTIONS='--max-old-space-size=384' npm install --omit=dev --no-audit --no-fund" >> "$reset_log" 2>&1 || true
        sudo chown -R pi:pi "$ddir/node_modules" 2>/dev/null || true

        echo '{"status":"resetting","phase":"Bygger dashboard..."}' > "$STATUS_DIR/factory-reset.json"
        echo "Bygger dashboard..." >> "$reset_log"
        sudo rm -rf "$ddir/dist"
        sudo systemd-run --scope --quiet -p MemoryMax=384M bash -lc "cd '$ddir' && NODE_OPTIONS='--max-old-space-size=320' npx vite build" >> "$reset_log" 2>&1 || true

        # Verifiera att vite faktiskt producerade en dist/index.html.
        # Vite kan misslyckas tyst på Pi Zero 2 W om swap är otillräckligt.
        if [ ! -f "$ddir/dist/index.html" ]; then
          echo '{"status":"error","message":"Dashboard-build misslyckades — index.html saknas"}' > "$STATUS_DIR/factory-reset.json"
          echo "❌ vite build producerade ingen dist/index.html" >> "$reset_log"
          tail -30 "$reset_log" >> "$reset_log.fail"
          exit 1
        fi

        echo '{"status":"resetting","phase":"Deployar..."}' > "$STATUS_DIR/factory-reset.json"
        sudo mkdir -p "$ndir"
        sudo cp -r dist/* "$ndir/" 2>> "$reset_log" || true
        sudo chown -R pi:pi "$ddir/dist" 2>/dev/null || true
        [ -f "$ddir/public/services.json" ] && sudo cp "$ddir/public/services.json" "$ndir/" || true
        if [ -f "$ddir/public/pi-scripts/pi-control-center-api.sh" ]; then
          src="$ddir/public/pi-scripts/pi-control-center-api.sh"
          dst="/usr/local/bin/pi-control-center-api.sh"
          if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
            : # symlänk pekar redan på källan — hoppa över
          else
            sudo install -m 755 "$src" "$dst" || true
          fi
          unset src dst
        fi

        # Återställ rättigheter via first-boot-setup --repair-permissions så
        # sudoers/polkit/bluetooth/units alltid matchar senaste PCC-version.
        echo '{"status":"resetting","phase":"Återställer rättigheter..."}' > "$STATUS_DIR/factory-reset.json"
        echo "Återställer sudoers, polkit, bluetooth..." >> "$reset_log"
        local fbs="$ddir/public/pi-scripts/first-boot-setup.sh"
        if [ -f "$fbs" ]; then
          chmod +x "$fbs" 2>/dev/null || true
          if sudo bash "$fbs" --repair-permissions >> "$reset_log" 2>&1; then
            echo "Rättigheter återställda" >> "$reset_log"
          else
            echo "VARNING: Permission repair returnerade icke-noll, fortsätter ändå" >> "$reset_log"
          fi
        else
          echo "VARNING: $fbs hittades inte — hoppar över permission repair" >> "$reset_log"
        fi

        echo '{"status":"success","timestamp":"'"$(date -Iseconds)"'"}' > "$STATUS_DIR/factory-reset.json"
        echo "Återställning klar. Startar om API..." >> "$reset_log"
        sudo systemctl restart pi-control-center-api >/dev/null 2>&1 || true
      ) >> "$reset_log" 2>&1 &
      ;;

    "POST /api/reboot")
      response='{"status":"rebooting"}'
      ( sleep 1; sudo_run_quiet systemctl reboot || sudo_run_quiet reboot || true ) &
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
        # Global timeout: hela update får max 15 min. Förhindrar att hängande
        # npm install / git fetch lämnar systemet i evig "updating"-state.
        UPDATE_TIMEOUT_SECONDS=900
        update_pid=$$
        ( sleep $UPDATE_TIMEOUT_SECONDS && kill -TERM $update_pid 2>/dev/null ) &
        timeout_killer_pid=$!

        exec 9>"$OP_LOCK_FILE"
        if ! flock -n 9; then
          echo '{"app":"dashboard","status":"updating","progress":"Pi upptagen – väntar på uppdateringskö..."}' > "$sf"
          if ! acquire_op_lock_or_timeout 9 600; then
            echo '{"app":"dashboard","status":"error","message":"Annan operation håller lock över 10 min — avbryter","timestamp":"'"$(date -Iseconds)"'"}' > "$sf"
            kill "$timeout_killer_pid" 2>/dev/null || true
            exit 1
          fi
        fi
        STOPPED_SERVICES=""

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

        # Collect service unit names for every installed app (apps with an assignment)
        collect_app_services() {
          local out="" app has_comp cs s assigned
          for app in $(registry_keys); do
            assigned=$(assignment_get_core "$app")
            [ -z "$assigned" ] && continue
            has_comp=$(registry_has_components "$app")
            if [ "$has_comp" = "true" ]; then
              for comp in engine ui; do
                cs=$(registry_get_component "$app" "$comp" "service")
                [ -n "$cs" ] && out="$out $cs"
              done
            else
              s=$(registry_get "$app" "service")
              [ -n "$s" ] && out="$out $s"
            fi
          done
          echo "$out"
        }

        stop_app_services() {
          STOPPED_SERVICES=$(collect_app_services)
          local svc
          for svc in $STOPPED_SERVICES; do
            sudo_run_quiet systemctl --no-block stop "${svc}.service" || sudo_run_quiet systemctl stop "${svc}.service" || user_systemctl stop "${svc}.service" 2>/dev/null || true
          done
        }

        restart_app_services() {
          local svc
          for svc in $STOPPED_SERVICES; do
            sudo systemctl start "${svc}.service" 2>/dev/null || user_systemctl start "${svc}.service" 2>/dev/null || true
          done
        }

        dashboard_git_fetch() {
          local fetch_err="$1" branch="" attempt=1
          branch=$(git remote show origin 2>>"$fetch_err" | awk '/HEAD branch/ {print $NF}' | head -1)
          [ -z "$branch" ] && branch="main"
          while [ "$attempt" -le 3 ]; do
            echo "Git fetch försök ${attempt}/3 (${branch})..." >> "$dashboard_log"
            if git -c http.version=HTTP/1.1 -c protocol.version=2 fetch origin "$branch" --depth=1 --prune --no-tags 2>>"$fetch_err"; then
              remote_ref="origin/$branch"
              return 0
            fi
            [ "$branch" = "main" ] && git -c http.version=HTTP/1.1 fetch origin master --depth=1 --prune --no-tags 2>>"$fetch_err" && { remote_ref="origin/master"; return 0; }
            sleep 2
            attempt=$((attempt + 1))
          done
          git -c http.version=HTTP/1.1 fetch origin --depth=1 --prune --no-tags 2>>"$fetch_err" || return 1
          if git show-ref --verify --quiet refs/remotes/origin/main; then remote_ref="origin/main"; return 0; fi
          if git show-ref --verify --quiet refs/remotes/origin/master; then remote_ref="origin/master"; return 0; fi
          return 1
        }

        # EXIT-trap: säkerställ att tjänster ALLTID startas om, oavsett hur vi avslutar.
        # Skriv "error"-status om vi avslutar med fel-kod och status fortfarande är "updating".
        cleanup_exit() {
          local code=$?
          if [ "$code" -ne 0 ] && grep -q "\"status\":\"updating\"" "$sf" 2>/dev/null; then
            dashboard_fail "Uppdateringen avbröts oväntat (exit code $code)"
          fi
          # Stoppa timeout-killer om vi når exit innan den fyrar
          [ -n "${timeout_killer_pid:-}" ] && kill "$timeout_killer_pid" 2>/dev/null || true
          # ALLTID restart tjänster — även vid fel ska de startas om
          restart_app_services
        }
        trap cleanup_exit EXIT

        cd "$ddir" 2>/dev/null || { dashboard_fail "Dashboard-katalog saknas"; exit 1; }

        dashboard_progress "Återställer lokala ändringar..."
        git checkout -- . 2>/dev/null || true
        git clean -fd -e node_modules >/dev/null 2>&1 || true

        dashboard_progress "Hämtar senaste kod..."
        fetch_err="$STATUS_DIR/dashboard-git-fetch.err"
        : > "$fetch_err"
        if ! nice -n 15 dashboard_git_fetch "$fetch_err"; then
          fetch_msg=$(tail -8 "$fetch_err" 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c1-260)
          dashboard_fail "Git fetch misslyckades${fetch_msg:+: ${fetch_msg}}"
          exit 1
        fi
        rm -f "$fetch_err"
        git reset --hard "$remote_ref" --quiet || git reset --hard origin/main --quiet 2>/dev/null || git reset --hard origin/master --quiet 2>/dev/null || { dashboard_fail "Git reset misslyckades"; exit 1; }
        # Verifiera att local HEAD nu matchar remote — annars har git reset tyst misslyckats
        local_head=$(git -C "$ddir" rev-parse --short=7 HEAD 2>/dev/null)
        remote_head=$(git -C "$ddir" rev-parse --short=7 "$remote_ref" 2>/dev/null)
        if [ -z "$local_head" ] || [ "$local_head" != "$remote_head" ]; then
          dashboard_fail "Git reset verifiering misslyckades: local=${local_head:-tom} remote=${remote_head:-tom}"
          exit 1
        fi
        echo "Git HEAD uppdaterad till ${local_head}" >> "$dashboard_log"
        git clean -fd -e node_modules >/dev/null 2>&1 || true
        sed -i 's/\r$//' "$ddir/public/pi-scripts/"*.sh
        chmod +x "$ddir/public/pi-scripts/"*.sh

        dashboard_progress "Stoppar tjänster..."
        stop_app_services

        dashboard_progress "Säkerställer swap..."
        if [ "$(swapon --show | wc -l)" -lt 2 ] && [ -f /etc/dphys-swapfile ]; then
          sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=768/' /etc/dphys-swapfile
          sudo dphys-swapfile setup || true
          sudo dphys-swapfile swapon || true
        fi

        dashboard_progress "Installerar dependencies..."
        # Behåll gammal node_modules som backup tills ny install bekräftats
        if [ -d node_modules ]; then
          mv node_modules node_modules.old 2>/dev/null || rm -rf node_modules
        fi
        if ! sudo systemd-run --scope --quiet -p MemoryMax=400M bash -lc "cd '$ddir' && NODE_OPTIONS='--max-old-space-size=352' npm install --no-audit --no-fund"; then
          # Restore backup om ny install failade
          if [ -d node_modules.old ]; then
            rm -rf node_modules
            mv node_modules.old node_modules
            echo "Återställde gammal node_modules efter misslyckad install" >> "$dashboard_log"
          fi
          dashboard_fail "npm install misslyckades eller dödades (troligen minnesbrist)"
          exit 1
        fi
        # Rensa backup när ny install lyckats
        rm -rf node_modules.old 2>/dev/null || true
        sudo chown -R pi:pi "$ddir/node_modules" 2>/dev/null || true

        dashboard_progress "Bygger dashboard..."
        # Bygg till temp-dir så att existerande dist/ finns kvar tills ny är OK
        sudo rm -rf "$ddir/dist.new"
        if ! sudo systemd-run --scope --quiet -p MemoryMax=384M bash -lc "cd '$ddir' && NODE_OPTIONS='--max-old-space-size=320' npx vite build --outDir dist.new"; then
          sudo rm -rf "$ddir/dist.new" 2>/dev/null || true
          dashboard_fail "Build misslyckades eller dödades (troligen minnesbrist)"
          exit 1
        fi
        # Verifiera ny build är komplett innan vi byter
        if [ ! -f "$ddir/dist.new/index.html" ]; then
          sudo rm -rf "$ddir/dist.new" 2>/dev/null || true
          dashboard_fail "Build verifierade inte — index.html saknas i dist.new"
          exit 1
        fi
        # Atomic swap: bara nu ersätter vi gamla dist
        sudo rm -rf "$ddir/dist.bak" 2>/dev/null || true
        [ -d "$ddir/dist" ] && sudo mv "$ddir/dist" "$ddir/dist.bak"
        sudo mv "$ddir/dist.new" "$ddir/dist"

        dashboard_progress "Deployar..."
        sudo mkdir -p "$ndir"
        # Backup nuvarande nginx-deploy så vi kan rulla tillbaka vid fel
        sudo rm -rf "${ndir}.bak" 2>/dev/null || true
        if [ -d "$ndir" ] && [ "$(ls -A "$ndir" 2>/dev/null)" ]; then
          sudo cp -r "$ndir" "${ndir}.bak" 2>/dev/null || true
        fi
        if ! sudo cp -r dist/* "$ndir/" 2>> "$dashboard_log"; then
          # Rulla tillbaka
          if [ -d "${ndir}.bak" ]; then
            sudo rm -rf "$ndir"
            sudo mv "${ndir}.bak" "$ndir"
            echo "Rullade tillbaka deploy efter cp-fel" >> "$dashboard_log"
          fi
          dashboard_fail "Deploy misslyckades"
          exit 1
        fi
        # Verifiera att något faktiskt kopierades
        if [ -z "$(find "$ndir" -maxdepth 2 -name "index.html" | head -1)" ]; then
          if [ -d "${ndir}.bak" ]; then
            sudo rm -rf "$ndir"
            sudo mv "${ndir}.bak" "$ndir"
            echo "Rullade tillbaka deploy efter index.html-saknad" >> "$dashboard_log"
          fi
          dashboard_fail "Deploy verifiering misslyckades — index.html saknas i $ndir"
          exit 1
        fi
        # Allt OK — rensa backup
        sudo rm -rf "${ndir}.bak" 2>/dev/null || true
        sudo chown -R pi:pi "$ddir/dist" 2>/dev/null || true
        [ -f "$ddir/public/services.json" ] && sudo cp "$ddir/public/services.json" "$ndir/" || true
        if [ -f "$ddir/public/pi-scripts/pi-control-center-api.sh" ]; then
          src="$ddir/public/pi-scripts/pi-control-center-api.sh"
          dst="/usr/local/bin/pi-control-center-api.sh"
          if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
            : # symlänk pekar redan på källan — hoppa över
          else
            sudo install -m 755 "$src" "$dst" || true
          fi
          unset src dst
        fi

        dashboard_progress "Återställer BLE-rättigheter..."
        repair_ble_permissions

        dashboard_progress "Startar om tjänster..."
        restart_app_services
        STOPPED_SERVICES=""  # förhindra dubbel-restart i EXIT-trap

        # Vänta tills nginx faktiskt serverar nya filer (förhindrar att UI ser
        # cachad gammal index.html under restart-fönstret)
        dashboard_progress "Verifierar deploy..."
        deploy_check_attempts=0
        while [ "$deploy_check_attempts" -lt 5 ]; do
          if curl -sf "http://127.0.0.1/" -o /dev/null 2>/dev/null; then
            echo "Deploy verifierad — nginx svarar" >> "$dashboard_log"
            break
          fi
          sleep 1
          deploy_check_attempts=$((deploy_check_attempts + 1))
        done

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
        # Sync så success-status garanterat hamnar på disk innan restart
        sync
        sleep 2
        # Stoppa timeout-killer innan vi triggar restart (annars kan kill -TERM
        # komma efter att API:t startat om och döda fel process)
        kill "$timeout_killer_pid" 2>/dev/null || true
        # Använd --no-block så vår process inte blir kapad mid-restart.
        # Service file har Restart=always så systemd startar om oss reliably.
        sudo systemctl --no-block restart pi-control-center-api 2>/dev/null || true
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
        exec 9>"$OP_LOCK_FILE"
        if ! flock -n 9; then
          echo "{\"app\":\"${app}\",\"status\":\"updating\",\"progress\":\"Pi upptagen – väntar på uppdateringskö...\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
          flock 9
        fi
        local release_url install_dir svc download_url latest_tag
        release_url=$(registry_get "$app" "releaseUrl")
        install_dir=$(eval echo "$(registry_get "$app" "installDir")")
        svc=$(registry_get "$app" "service")

        updated=false

        # Try release-based update first
        if [ -n "$release_url" ]; then
          latest_tag=$(latest_release_tag "$app")
          download_url=$(latest_release_asset_url "$app")
          if [ -n "$download_url" ] && [ "$download_url" != "null" ]; then
            echo "Laddar ner release ${latest_tag:-latest}..." >> "$update_log"
            if curl -sfL "$download_url" -o "/tmp/pi-control-center/${app}-dist.tar.gz" 2>> "$update_log"; then
              echo "Packar upp..." >> "$update_log"

              # Rensa install_dir genom att ta bort hela mappen och återskapa den.
              # sudoers-regeln /usr/bin/rm -rf /opt/* matchar en path-komponent under /opt
              # (t.ex. /opt/cast-away). Glob /opt/cast-away/* matchas INTE av samma regel,
              # vilket var orsaken till tyst fel tidigare.
              if ! sudo_run rm -rf "$install_dir" 2>> "$update_log"; then
                echo "Kunde inte rensa gamla filer" >> "$update_log"
                echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Kunde inte rensa gamla filer\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
                rm -f "/tmp/pi-control-center/${app}-dist.tar.gz"
                exit 0
              fi
              if ! sudo_run mkdir -p "$install_dir" 2>> "$update_log"; then
                echo "Kunde inte återskapa install-katalog" >> "$update_log"
                echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Kunde inte återskapa install-katalog\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
                rm -f "/tmp/pi-control-center/${app}-dist.tar.gz"
                exit 0
              fi
              sudo_run chown -R "$(pcc_owner_user):$(pcc_owner_group)" "$install_dir" 2>> "$update_log" || true

              # Extrahera med error check
              if ! tar xzf "/tmp/pi-control-center/${app}-dist.tar.gz" -C "$install_dir" 2>> "$update_log"; then
                echo "Uppackning misslyckades" >> "$update_log"
                echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Uppackning misslyckades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
                rm -f "/tmp/pi-control-center/${app}-dist.tar.gz"
                exit 0
              fi
              rm -f "/tmp/pi-control-center/${app}-dist.tar.gz"

              # Hantera tarballs som extraherar till en enda subdirektory
              # (vanligt för GitHub source-archives). Flytta upp innehållet till install_dir.
              local top_entries top_dir
              top_entries=$(find "$install_dir" -mindepth 1 -maxdepth 1 | wc -l)
              if [ "$top_entries" = "1" ]; then
                top_dir=$(find "$install_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
                if [ -n "$top_dir" ] && [ -d "$top_dir" ]; then
                  echo "Lyfter innehåll från $(basename "$top_dir")/..." >> "$update_log"
                  # Loopa filerna och mv var och en via sudo_run direkt — slipper
                  # sudo sh -c som inte är tillåten i sudoers.
                  local entry
                  shopt -s dotglob nullglob
                  for entry in "$top_dir"/*; do
                    [ -e "$entry" ] && sudo_run mv "$entry" "$install_dir/" 2>> "$update_log" || true
                  done
                  shopt -u dotglob nullglob
                  sudo_run rmdir "$top_dir" 2>> "$update_log" || true
                fi
              fi

              # Verifiera att extraktionen producerade filer
              if [ -z "$(find "$install_dir" -mindepth 1 -maxdepth 1 | head -1)" ]; then
                echo "Uppackning tom — inga filer extraherades" >> "$update_log"
                echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Uppackning tom — inga filer extraherades\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
                exit 0
              fi

              # Skriv VERSION.json via sudo tee — install_dir kan vara root-ägd
              # efter sudo_run mkdir ovan, så direkt > redirect skulle nekas.
              if [ -n "$latest_tag" ]; then
                local version_json
                version_json=$(printf '{"tag":"%s","version":"%s","updatedAt":"%s"}\n' \
                  "$(escape_json "$latest_tag")" "$(escape_json "$latest_tag")" "$(date -Iseconds)")
                if ! echo "$version_json" | sudo_run tee "$install_dir/VERSION.json" >/dev/null 2>> "$update_log"; then
                  echo "Kunde inte skriva VERSION.json" >> "$update_log"
                  echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"Kunde inte skriva VERSION.json\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
                  exit 0
                fi
                # Verifiera att VERSION.json är läsbar med förväntad tagg
                local written_tag
                written_tag=$(jq -r '.tag // empty' "$install_dir/VERSION.json" 2>/dev/null)
                if [ "$written_tag" != "$latest_tag" ]; then
                  echo "VERSION.json verifiering misslyckades: skrev '$latest_tag', läste '$written_tag'" >> "$update_log"
                  echo "{\"app\":\"${app}\",\"status\":\"error\",\"message\":\"VERSION.json kunde inte verifieras\",\"timestamp\":\"$(date -Iseconds)\"}" > "$update_json"
                  exit 0
                fi
              fi

              export XDG_RUNTIME_DIR="$USER_RUNTIME_DIR"
              export DBUS_SESSION_BUS_ADDRESS="$USER_BUS_ADDRESS"
              # Synkron rättighetsfix INNAN restart — tar/cp som root lämnar nya
              # filer root-ägda; engine får annars EACCES på första writeFileSync.
              # Vi kör detta proaktivt här istället för att vänta på poll-loopen.
              echo "Säkerställer ägarskap på app-mappar..." >> "$update_log"
              ensure_app_managed_dirs "$app" >> "$update_log" 2>&1 || true
              # Restart services (skip if managed: false)

              if [ "$(registry_is_managed "$app")" != "false" ]; then
                local has_comp_upd
                has_comp_upd=$(registry_has_components "$app")
                if [ "$has_comp_upd" = "true" ]; then
                  for comp_upd in engine ui; do
                    local comp_svc_upd
                    comp_svc_upd=$(registry_get_component "$app" "$comp_upd" "service")
                    [ -n "$comp_svc_upd" ] && { sudo_run systemctl restart "${comp_svc_upd}.service" 2>> "$update_log" || user_systemctl restart "${comp_svc_upd}.service" 2>> "$update_log" || true; }
                  done
                else
                  sudo_run systemctl restart "${svc}.service" 2>> "$update_log" || user_systemctl restart "${svc}.service" 2>> "$update_log" || true
                fi
              fi

              updated=true
              release_heal_mark "$app"
              _invalidate_version_cache "$install_dir"
              # Invalidera också GitHub release-cachen så nästa hasUpdate-check får färska data
              rm -f "$STATUS_DIR/${app}-latest-release.json"
              rm -f "$CACHE_FILE"
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
            # Skyddsnät: även om uscript kör som pi kan det internt köra
            # `sudo cp` etc. som lämnar enstaka filer root-ägda. Säkerställ
            # ägarskap INNAN eventuell restart så engine slipper EACCES.
            echo "Säkerställer ägarskap på app-mappar..." >> "$update_log"
            ensure_app_managed_dirs "$app" >> "$update_log" 2>&1 || true
            if [ "$exit_code" -eq 0 ]; then
              release_heal_mark "$app"
              _invalidate_version_cache "$install_dir"
              rm -f "$CACHE_FILE"
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
        if [ "$action" = "start" ] || [ "$action" = "restart" ]; then
          repair_app_managed_dirs "$app" "service-${action}" || true
        fi
        if sudo_run systemctl "$action" "${svc}.service" 2>/tmp/svc-err-$$; then
          svc_ok="true"
        elif user_systemctl "$action" "${svc}.service" 2>/tmp/svc-err-$$; then
          svc_ok="true"
        else
          svc_err=$(cat /tmp/svc-err-$$ 2>/dev/null | head -1 | sed 's/"/\\"/g')
        fi
        rm -f /tmp/svc-err-$$
        if [ "$svc_ok" = "true" ]; then
          if [ "$action" = "start" ] || [ "$action" = "restart" ]; then
            watchdog_reset "$app" "${component:-service}"
          fi
          rm -f "$CACHE_FILE"
          printf "[%s] service %s %s: success\n" "$now" "$svc" "$action" >> "$log_file"
          response="{\"app\":\"${app}\",\"action\":\"${action}\",\"status\":\"success\"}"
        else
          printf "[%s] service %s %s: %s\n" "$now" "$svc" "$action" "${svc_err:-systemctl ${action} failed}" >> "$log_file"
          response="{\"app\":\"${app}\",\"action\":\"${action}\",\"status\":\"error\",\"message\":\"${svc_err:-systemctl ${action} failed}\"}"
        fi
      fi
      ;;

    POST\ /api/repair-dirs/*)
      local app
      app=${path#/api/repair-dirs/}
      app="${app%%[?#]*}"
      app="${app//[^a-zA-Z0-9_-]/}"
      if [ -z "$(registry_get "$app" "repo")" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        repair_app_managed_dirs "$app" "manual" || ensure_app_managed_dirs "$app"
        response="{\"app\":\"${app}\",\"status\":\"success\"}"
      fi
      ;;

    "GET /api/memory-limit/"*)
      local ml_app ml_services ml_limit ml_svc_file ml_profile ml_level
      ml_app=${path#/api/memory-limit/}
      ml_app="${ml_app%%[?#]*}"
      ml_app="${ml_app//[^a-zA-Z0-9_-]/}"
      ml_limit=$(_app_current_limit "$ml_app")
      [ -z "$ml_limit" ] && ml_limit=$(registry_memory_profile_mb "$ml_app")
      [ -z "$ml_limit" ] && ml_limit="128"
      local ml_mb
      ml_mb=$(echo "$ml_limit" | grep -oP '^\d+')
      ml_profile=$(registry_memory_profile_json "$ml_app"); [ -z "$ml_profile" ] && ml_profile="null"
      ml_level=$(memory_level_for_mb "$ml_app" "${ml_mb:-128}")
      response="{\"app\":\"${ml_app}\",\"limitMb\":${ml_mb:-128},\"level\":\"${ml_level}\",\"profile\":${ml_profile},\"raw\":\"${ml_limit}M\"}"
      ;;

    "POST /api/memory-limit/"*)
      local ml_app ml_body ml_new_limit ml_level ml_mb
      ml_app=${path#/api/memory-limit/}
      ml_app="${ml_app%%[?#]*}"
      ml_app="${ml_app//[^a-zA-Z0-9_-]/}"
      ml_body="$body"
      ml_new_limit=$(echo "$ml_body" | grep -oP '"limitMb"\s*:\s*\K\d+')
      ml_level=$(echo "$ml_body" | grep -oP '"level"\s*:\s*"\K[^"]+' | tr -cd 'a-zA-Z0-9_-')
      if [ -z "$ml_new_limit" ] && [ -n "$ml_level" ]; then
        ml_new_limit=$(registry_memory_profile_mb "$ml_app" "$ml_level")
      fi
      if [ -z "$ml_new_limit" ] || [ "$ml_new_limit" -lt "$MIN_MEMORY_MB" ] 2>/dev/null || [ "$ml_new_limit" -gt 480 ] 2>/dev/null; then
        status_line="HTTP/1.1 400 Bad Request"
        response="{\"error\":\"limitMb måste vara ${MIN_MEMORY_MB}-480\"}"
      else
        _app_set_limit "$ml_app" "$ml_new_limit"
        if [ -n "$(_app_current_limit "$ml_app")" ]; then
          sudo systemctl daemon-reload 2>/dev/null || user_systemctl daemon-reload 2>/dev/null || true
          _app_try_restart "$ml_app"
          rm -f "$CACHE_FILE"
          [ -z "$ml_level" ] && ml_level=$(memory_level_for_mb "$ml_app" "$ml_new_limit")
          append_memory_change_log "$ml_app" "MEMORY: ${ml_app} MemoryMax satt till ${ml_new_limit}MB (${ml_level}) från UI"
          response="{\"app\":\"${ml_app}\",\"limitMb\":${ml_new_limit},\"level\":\"${ml_level}\",\"status\":\"success\"}"
        else
          status_line="HTTP/1.1 404 Not Found"
          response="{\"error\":\"Ingen tjänstfil hittad för ${ml_app}\"}"
        fi
      fi
      ;;

    GET\ /api/service-log/*)
      local app svc lc tmp_err app_logs has_comp_log
      app=${path#/api/service-log/}
      svc=$(registry_get "$app" "service")
      has_comp_log=$(registry_has_components "$app")
      app_logs="$(app_log_dir "$app")"
      if [ -z "$svc" ] && [ "$has_comp_log" != "true" ]; then
        status_line="HTTP/1.1 404 Not Found"
        response="{\"error\":\"Unknown app: ${app}\"}"
      else
        tmp_err="/tmp/service-log-$$.err"
        if [ "$has_comp_log" = "true" ]; then
          lc=$(for comp in engine ui; do
            local cs
            cs=$(registry_get_component "$app" "$comp" "service")
            [ -n "$cs" ] && timeout 2s journalctl --user -u "${cs}.service" -n 30 --no-pager 2>>"$tmp_err"
            [ -f "$app_logs/${comp}.log" ] && tail -30 "$app_logs/${comp}.log"
          done)
        else
          lc=$(
            timeout 3s sudo -n journalctl -u "${svc}.service" -n 60 --no-pager 2>"$tmp_err" ||
            timeout 3s journalctl -u "${svc}.service" -n 60 --no-pager 2>>"$tmp_err" ||
            timeout 3s systemctl status "${svc}.service" --no-pager -n 40 2>>"$tmp_err" ||
            cat "$tmp_err"
          )
        fi
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

          if [ -n "$v_release_url" ]; then
            # Release-based install: compare local VERSION/package version against latest GitHub release
            v_local_hash=$(installed_release_version "$v_install_dir")
            v_local="$v_local_hash"
            v_remote_hash=$(latest_release_tag "$vapp")
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

        if [ -n "$rel_url" ]; then
          # Release-based install
          local_hash=$(installed_release_version "$install_dir")
          local_v="$local_hash"
          remote_hash=$(latest_release_tag "$app")
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
        # rev-parse fungerar oavsett om refs är lösa eller packed (vilket cat inte gör)
        d_hash=$(git -C "$ddir2" rev-parse --short=7 HEAD 2>/dev/null)
        d_local=$(git -C "$ddir2" log -1 --format='%cd' --date=format:'%-d %b' 2>/dev/null)
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
  # Close stdout so the Python proxy's subprocess.run() returns immediately
  # even if we forked background jobs (install/update/factory-reset) that
  # would otherwise keep the inherited stdout pipe open until completion.
  exec 1>&- 2>&-
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

if [ "${SYNC_HEAP_ONLY:-0}" = "1" ]; then
  sync_all_heap_limits
  exit 0
fi

# --- Startup: remove legacy user-level app service files now that PCC owns system services ---
startup_cleanup_user_services() {
  local cleaned=0
  for app in $(registry_keys); do
    [ "$(registry_is_managed "$app")" = "false" ] && continue
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
      local user_file="$PI_HOME/.config/systemd/user/${svc_name}.service"
      if [ -f "$user_file" ]; then
        log "Startup cleanup: removing legacy user service ${user_file}"
        user_systemctl stop "${svc_name}.service" 2>/dev/null || true
        user_systemctl disable "${svc_name}.service" 2>/dev/null || true
        rm -f "$user_file"
        cleaned=1
      fi
    done
  done
  [ "$cleaned" -eq 1 ] && user_systemctl daemon-reload 2>/dev/null || true
}
startup_cleanup_user_services

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

startup_repair_app_dirs() {
  local app assigned
  for app in $(registry_keys); do
    assigned=$(assignment_get_core "$app")
    [ -n "$assigned" ] || continue
    repair_app_managed_dirs "$app" "api-startup" || true
  done
}
startup_repair_app_dirs

if [ "$REQUEST_MODE" = "--background-only" ]; then
  echo "Pi Control Center API background loops starting (HTTP served by Python on port $PORT)"
else
  echo "Pi Control Center API listening on port $PORT"
fi

# Start health polling in background
health_poll_loop &
HEALTH_PID=$!

# Start watchdog protection in background
watchdog_loop &
WATCHDOG_PID=$!

# Start status cache refresh in background
status_cache_loop &
CACHE_PID=$!

trap "kill $HEALTH_PID $WATCHDOG_PID $CACHE_PID 2>/dev/null; exit" EXIT INT TERM

if [ "$REQUEST_MODE" = "--background-only" ]; then
  # Wait on the background loops; the Python parent owns the HTTP socket.
  wait
  exit 0
fi

while true; do
  socat TCP-LISTEN:${PORT},reuseaddr,fork EXEC:"${SCRIPT_PATH} --handle-request ${PORT}" 2>/dev/null || sleep 1
done
