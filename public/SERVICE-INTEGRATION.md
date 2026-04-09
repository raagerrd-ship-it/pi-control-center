# Service Integration Guide — Pi Dashboard

## Installation Script Requirements

Your install script will receive two arguments:

```
--port PORT    The port your service should listen on
--core CORE    The CPU core (0-3) your service should be pinned to
```

Example invocation:
```bash
bash install-linux.sh --port 3001 --core 1
```

### Parsing arguments

Add this to the top of your install script:

```bash
PORT=3000
CORE=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --port) PORT="$2"; shift 2 ;;
    --core) CORE="$2"; shift 2 ;;
    *) shift ;;
  esac
done
```

### Using PORT

Set it in your systemd unit's `Environment=` line or in a config file:

```ini
Environment=PORT=${PORT}
```

Or write it to a `.env` file that your app reads.

### Using CORE

Pin your service to a specific CPU core via the systemd unit:

```ini
AllowedCPUs=${CORE}
```

Core 0 is reserved for the dashboard + nginx. Available cores: **1, 2, 3** (on Pi Zero 2 W with 4 cores).

## Update Script

The dashboard calls your update script directly. It should:

1. `git fetch` + `git reset --hard` to latest
2. Rebuild if needed (npm install, npm run build, etc.)
3. Restart the service (`systemctl restart <service>`)

The script receives no arguments — it should know its own install directory.

## Uninstall Script

Provide an uninstall script that:

1. Stops and disables the systemd service
2. Removes the service file from `/etc/systemd/system/` or `~/.config/systemd/user/`
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
rm -rf /opt/my-service
```

## Logging

The dashboard handles all user-facing logging centrally.
Your scripts should write output to stdout/stderr as usual —
the dashboard captures it automatically.
No special logging integration is needed from your side.
