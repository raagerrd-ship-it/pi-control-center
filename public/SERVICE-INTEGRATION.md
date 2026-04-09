# Service Integration Guide — Pi Dashboard

This document describes how to make a service installable, updatable, and removable via the Pi Dashboard.

## Overview

The dashboard uses a **generic installation flow** for all services — no service-specific logic exists in the dashboard codebase. Each service provides its own scripts for install, update, and uninstall.

### How it works

1. You register your service in `services.json` (see below)
2. The user picks your service in the dashboard UI, chooses a port and CPU core
3. The dashboard clones your repo and runs your `installScript` with `--port` and `--core`
4. Your script sets up everything: dependencies, systemd unit, config
5. The dashboard saves the port/core assignment and starts polling your service

## services.json Registration

Add an entry to `public/services.json`:

```json
{
  "key": "my-service",
  "name": "My Service",
  "repo": "https://github.com/user/my-service.git",
  "installDir": "$HOME/.local/share/my-service",
  "installScript": "scripts/install.sh",
  "updateScript": "$HOME/.local/share/my-service/scripts/update.sh",
  "uninstallScript": "scripts/uninstall.sh",
  "service": "my-service"
}
```

| Field | Description |
|-------|-------------|
| `key` | Unique identifier (used in API calls) |
| `name` | Display name in dashboard UI |
| `repo` | Git clone URL |
| `installDir` | Where the repo is cloned to (`$HOME` is expanded) |
| `installScript` | Path relative to repo root, run during install |
| `updateScript` | Absolute path to update script (exists after install) |
| `uninstallScript` | Path relative to repo root, run during uninstall |
| `service` | systemd service name (without `.service`) |

## Installation Script

Your install script receives two arguments:

```
--port PORT    The port your service should listen on
--core CORE    The CPU core (0-3) your service should be pinned to
```

Example invocation by the dashboard:
```bash
bash scripts/install.sh --port 3001 --core 1
```

### Parsing arguments

```bash
#!/bin/bash
set -e

PORT=3000
CORE=1

while [[ $# -gt 0 ]]; do
  case $1 in
    --port) PORT="$2"; shift 2 ;;
    --core) CORE="$2"; shift 2 ;;
    *) shift ;;
  esac
done
```

### What your install script should do

1. Install any system dependencies (`apt-get install ...`)
2. Install app dependencies (`npm install`, `pip install`, etc.)
3. Build if needed (`npm run build`, etc.)
4. Create a systemd service unit (system or user)
5. Enable and start the service

### Using PORT

Set it in your systemd unit's `Environment=` line or in a config file:

```ini
Environment=PORT=${PORT}
```

### Using CORE

Pin your service to a specific CPU core via the systemd unit:

```ini
AllowedCPUs=${CORE}
```

Core 0 is reserved for the dashboard + nginx. Available cores: **1, 2, 3** (on Pi Zero 2 W with 4 cores).

### Permissions

**Sudoers is configured automatically** by the dashboard installer. Your install script can use `sudo` for:

- `systemctl start/stop/restart/enable/disable`
- `systemctl daemon-reload`

No need to configure sudoers in your own scripts.

### Progress feedback

The dashboard polls your install status and shows progress to the user. Your script's stdout/stderr is captured to a log file automatically. Write descriptive `echo` statements so the user can follow along if they check the detailed log:

```bash
echo "Installing system packages..."
sudo apt-get install -y -qq libfoo-dev

echo "Installing npm dependencies (this may take a few minutes)..."
npm install --no-audit --no-fund

echo "Building..."
npm run build
```

### Resource limits

On Pi Zero 2 W (512MB RAM), use conservative resource settings:

```bash
export NODE_OPTIONS="--max-old-space-size=256"
nice -n 15 ionice -c 3 npm install
```

## Update Script

The dashboard calls your update script directly (no arguments). It should:

1. `git fetch` + `git reset --hard` to latest
2. Rebuild if needed (`npm install`, `npm run build`, etc.)
3. Restart the service (`systemctl restart <service>`)

Example:

```bash
#!/bin/bash
set -e

APP_DIR="$HOME/.local/share/my-service"
SERVICE="my-service"

cd "$APP_DIR"
git fetch origin main --quiet
git reset --hard origin/main --quiet

npm install --no-audit --no-fund
npm run build

systemctl --user restart "$SERVICE"
```

## Uninstall Script

Provide an uninstall script that:

1. Stops and disables the systemd service
2. Removes the service file
3. Runs `systemctl daemon-reload`
4. Optionally removes installed files

Example:

```bash
#!/bin/bash
SERVICE="my-service"

# System service
sudo systemctl stop "$SERVICE" 2>/dev/null || true
sudo systemctl disable "$SERVICE" 2>/dev/null || true
sudo rm -f "/etc/systemd/system/${SERVICE}.service"
sudo systemctl daemon-reload

# Or user service
systemctl --user stop "$SERVICE" 2>/dev/null || true
systemctl --user disable "$SERVICE" 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/${SERVICE}.service"
systemctl --user daemon-reload

# Cleanup files
rm -rf "$HOME/.local/share/my-service"
```

## Logging

The dashboard handles all user-facing logging centrally:

- **Install progress**: Shown in the UI with elapsed time (e.g. "Kör installationsskript... ⏱ 2m 14s")
- **Script output**: stdout/stderr is captured to `/tmp/pi-dashboard/install/<key>.log`
- **Service logs**: Retrieved via `journalctl` through the dashboard UI

Your scripts should write output to stdout/stderr as usual — no special logging integration is needed.

## Checklist

Before registering your service:

- [ ] Install script handles `--port` and `--core` flags
- [ ] Install script creates and enables a systemd service
- [ ] Service uses the provided port and CPU core
- [ ] Update script exists at the path specified in `updateScript`
- [ ] Uninstall script cleans up service files and optionally data
- [ ] All scripts are executable (`chmod +x`)
- [ ] Scripts use LF line endings (not CRLF)
- [ ] Resource-heavy steps use `nice`/`ionice` and memory limits
