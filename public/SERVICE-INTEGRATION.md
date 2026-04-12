# Service Integration Guide — Pi Dashboard

This document describes how to make a service installable, updatable, and removable via the Pi Dashboard.

## Overview

The dashboard uses a **generic installation flow** for all services — no service-specific logic exists in the dashboard codebase. Each service provides its own scripts for install, update, and uninstall.

### How it works

1. You register your service in `services.json` (see below)
2. The user picks your service in the dashboard UI, chooses a port and CPU core
3. **If your repo has a GitHub Release** with `dist.tar.gz`: the dashboard downloads and unpacks it (~30s)
4. **Otherwise**: the dashboard clones your repo and runs your `installScript` with `--port` and `--core`
5. The dashboard saves the port/core assignment and starts polling your service

## Service Isolation & Sandboxing

All services run in **sandboxed systemd units** with strict resource and filesystem limits. This ensures services cannot affect the host system.

### CPU Isolation (cgroups v2)

Each service is pinned to a single CPU core using **hard cgroup limits**:

```ini
CPUAffinity=2          # scheduling hint
AllowedCPUs=2          # hard cgroup limit — cannot escape
MemoryMax=128M         # memory ceiling per service
```

`AllowedCPUs` is a hard boundary — the process physically cannot run on other cores. Core 0 is reserved for the dashboard + nginx. Available cores: **1, 2, 3**.

### Filesystem Sandboxing

Services are **prevented from modifying system files** at runtime:

```ini
ProtectSystem=strict          # /usr, /boot, /etc are read-only
ProtectHome=read-only         # $HOME is read-only (except WorkingDirectory)
ReadWritePaths={installDir}   # only its own directory is writable
PrivateTmp=true               # isolated /tmp per service
NoNewPrivileges=true          # cannot escalate privileges
```

> **Important**: Install scripts still run with full privileges during installation. But the **running service** cannot change hostname, `/etc/hosts`, or other system files.

### What services MUST NOT do

- ❌ Modify `/etc/hosts` or `/etc/hostname`
- ❌ Change system-wide settings (locale, timezone, etc.)
- ❌ Write outside their own `installDir`
- ❌ Spawn processes on other CPU cores
- ❌ Use more than 128MB RAM

Use **environment variables** for service-internal configuration instead of modifying system files.

## services.json Registration

### Legacy format (single process)

```json
{
  "key": "my-service",
  "name": "My Service",
  "type": "node",
  "entrypoint": "server/index.js",
  "repo": "https://github.com/user/my-service.git",
  "releaseUrl": "https://api.github.com/repos/user/my-service/releases/latest",
  "installDir": "$HOME/.local/share/my-service",
  "installScript": "scripts/install.sh",
  "updateScript": "$HOME/.local/share/my-service/scripts/update.sh",
  "uninstallScript": "scripts/uninstall.sh",
  "service": "my-service"
}
```

### Component format (engine + UI separation)

For services with separate backend and frontend:

```json
{
  "key": "my-service",
  "name": "My Service",
  "repo": "https://github.com/user/my-service.git",
  "releaseUrl": "https://api.github.com/repos/user/my-service/releases/latest",
  "installDir": "$HOME/.local/share/my-service",
  "installScript": "scripts/install.sh",
  "updateScript": "$HOME/.local/share/my-service/scripts/update.sh",
  "uninstallScript": "scripts/uninstall.sh",
  "components": {
    "engine": {
      "type": "node",
      "entrypoint": "server/index.js",
      "service": "my-service-engine",
      "alwaysOn": true
    },
    "ui": {
      "type": "static",
      "entrypoint": "dist/",
      "service": "my-service-ui",
      "alwaysOn": false
    }
  }
}
```

**Benefits of component separation:**
- **Engine** runs independently — stays up even when UI is updated/restarted
- **UI** can be stopped/started/updated without interrupting backend logic
- Each component gets its own systemd service with independent status
- `alwaysOn: true` sets `Restart=always` (auto-restart on any exit)

**Backwards compatible**: services without `components` work exactly as before.

| Field | Description |
|-------|-------------|
| `key` | Unique identifier (used in API calls) |
| `name` | Display name in dashboard UI |
| `type` | `"node"` or `"static"` (legacy single-service only) |
| `entrypoint` | Path to main JS file, relative to `installDir` (legacy only) |
| `components` | Object with `engine` and/or `ui` component definitions |
| `repo` | Git clone URL (used as fallback if no release exists) |
| `releaseUrl` | GitHub Releases API URL for pre-built downloads (optional) |
| `installDir` | Where the app is installed (`$HOME` is expanded) |
| `installScript` | Path relative to repo root, run during fallback install |
| `updateScript` | Absolute path to update script (fallback, exists after install) |
| `uninstallScript` | Path relative to repo root, run during uninstall |
| `service` | systemd service name — legacy only (without `.service`) |

### Component Fields

| Field | Description |
|-------|-------------|
| `type` | `"node"` or `"static"` |
| `entrypoint` | Path relative to `installDir` |
| `service` | systemd service name for this component |
| `alwaysOn` | `true` = `Restart=always`, `false` = `Restart=on-failure` |

### Service Types

**`"static"`** — Pure frontend apps:
```
npx serve dist -l {port} -s
```

**`"node"`** — Node.js servers:
```
node {installDir}/{entrypoint}
```

The `PORT` environment variable is set automatically.

## Release-Based Installation (Recommended)

The fastest way to deploy services on Pi Zero 2 W. No build step on the Pi.

### How it works

1. Your CI builds the project and publishes `dist.tar.gz` as a GitHub Release asset
2. The dashboard downloads and unpacks it to `installDir`
3. Sandboxed systemd services are created automatically
4. Installation takes **~30 seconds**

### GitHub Actions Workflow — Static App

```yaml
name: Build and Release
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npm run build
      - run: tar czf dist.tar.gz dist/
      - uses: softprops/action-gh-release@v2
        with:
          tag_name: latest
          files: dist.tar.gz
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### GitHub Actions Workflow — Node.js App

Include `node_modules` so the Pi doesn't need to run `npm install`:

```yaml
name: Build and Release
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    env:
      FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npm run build
      - run: npm install --omit=dev --package-lock=false
      - run: tar czf dist.tar.gz bridge-pi/ node_modules/
      - uses: softprops/action-gh-release@v2
        with:
          tag_name: latest
          files: dist.tar.gz
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Legacy Installation (Fallback)

If no `releaseUrl` is set, the dashboard clones your repo and runs the install script.

Your install script receives:
```
--port PORT    The port your service should listen on
--core CORE    The CPU core (0-3) to pin to
```

## Uninstall Script

Provide a script that stops/disables the service and cleans up:

```bash
#!/bin/bash
SERVICE="my-service"
systemctl --user stop "$SERVICE" 2>/dev/null || true
systemctl --user disable "$SERVICE" 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/${SERVICE}.service"
systemctl --user daemon-reload
rm -rf "$HOME/.local/share/my-service"
```

For component-based services, clean up both services:

```bash
#!/bin/bash
for SVC in my-service-engine my-service-ui; do
  systemctl --user stop "$SVC" 2>/dev/null || true
  systemctl --user disable "$SVC" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/${SVC}.service"
done
systemctl --user daemon-reload
rm -rf "$HOME/.local/share/my-service"
```

## Checklist

- [ ] GitHub Actions workflow publishes `dist.tar.gz` (recommended), OR install script handles `--port` and `--core`
- [ ] Uninstall script cleans up service files
- [ ] Scripts are executable (`chmod +x`) with LF line endings
- [ ] Service does NOT modify system files (`/etc/hosts`, hostname, etc.)
- [ ] If using components: engine and UI have separate service names
