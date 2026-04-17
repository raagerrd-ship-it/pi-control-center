#!/bin/bash
# ============================================================
# Pi Control Center — sudo health repair
# ============================================================
# Verifies and repairs ownership/permissions for sudo-related
# files. PCC owns sudo-health on the Pi; other apps (Lotus,
# Cast Away, Brew Monitor) rely on this script via thin wrappers.
#
# Exit codes:
#   0 = OK or successfully repaired
#   1 = problems remain
# ============================================================

set -u

LOG_PREFIX="[fix-sudo]"
log() { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX WARN: $*" >&2; }
err() { echo "$LOG_PREFIX ERROR: $*" >&2; }

# Desired state: path|owner|mode|type(file|dir|optional-file)
EXPECTED=(
  "/etc/sudo.conf|root:root|644|optional-file"
  "/usr/bin/sudo|root:root|4755|file"
  "/etc/sudoers|root:root|440|file"
  "/etc/sudoers.d|root:root|750|dir"
)

# Build the repair command as a single shell snippet so it can be
# run via root, pkexec, or su -c fallback.
build_repair_cmd() {
  cat <<'REPAIR'
set -e
chown root:root /etc/sudo.conf 2>/dev/null && chmod 644 /etc/sudo.conf 2>/dev/null || true
[ -e /usr/bin/sudo ] && chown root:root /usr/bin/sudo && chmod 4755 /usr/bin/sudo
[ -e /etc/sudoers ] && chown root:root /etc/sudoers && chmod 440 /etc/sudoers
if [ -d /etc/sudoers.d ]; then
  chown root:root /etc/sudoers.d
  chmod 750 /etc/sudoers.d
  find /etc/sudoers.d -mindepth 1 -maxdepth 1 -type f -exec chown root:root {} \; -exec chmod 440 {} \;
fi
REPAIR
}

check_one() {
  local path="$1" owner="$2" mode="$3" type="$4"
  if [ ! -e "$path" ]; then
    [ "$type" = "optional-file" ] && return 0
    warn "missing: $path"
    return 1
  fi
  local actual_owner actual_mode
  actual_owner="$(stat -c '%U:%G' "$path" 2>/dev/null || echo '?')"
  actual_mode="$(stat -c '%a' "$path" 2>/dev/null || echo '?')"
  if [ "$actual_owner" != "$owner" ] || [ "$actual_mode" != "$mode" ]; then
    warn "$path: owner=$actual_owner mode=$actual_mode (expected $owner $mode)"
    return 1
  fi
  return 0
}

check_all() {
  local ok=0
  for entry in "${EXPECTED[@]}"; do
    IFS='|' read -r p o m t <<<"$entry"
    check_one "$p" "$o" "$m" "$t" || ok=1
  done
  # sudoers.d files
  if [ -d /etc/sudoers.d ]; then
    while IFS= read -r f; do
      local ao am
      ao="$(stat -c '%U:%G' "$f" 2>/dev/null || echo '?')"
      am="$(stat -c '%a' "$f" 2>/dev/null || echo '?')"
      if [ "$ao" != "root:root" ] || [ "$am" != "440" ]; then
        warn "$f: owner=$ao mode=$am (expected root:root 440)"
        ok=1
      fi
    done < <(find /etc/sudoers.d -mindepth 1 -maxdepth 1 -type f 2>/dev/null)
  fi
  return $ok
}

log "checking sudo health..."
if check_all; then
  log "sudo health OK"
  exit 0
fi

log "attempting repair..."
REPAIR_CMD="$(build_repair_cmd)"

REPAIRED=0
if [ "$(id -u)" = "0" ]; then
  log "running as root"
  if bash -c "$REPAIR_CMD"; then REPAIRED=1; fi
elif command -v pkexec >/dev/null 2>&1; then
  log "trying pkexec"
  if pkexec bash -c "$REPAIR_CMD"; then REPAIRED=1; fi
fi

if [ "$REPAIRED" -ne 1 ]; then
  log "falling back to su -c (will prompt for root password)"
  if su -c "$REPAIR_CMD"; then REPAIRED=1; fi
fi

if [ "$REPAIRED" -ne 1 ]; then
  err "could not execute repair (no root, no pkexec, su failed)"
  err "manual fallback — run as root:"
  err "  su -c '$(echo "$REPAIR_CMD" | tr '\n' ';' )'"
  exit 1
fi

log "re-checking after repair..."
if check_all; then
  log "sudo health repaired"
  exit 0
fi

err "problems remain after repair"
exit 1
