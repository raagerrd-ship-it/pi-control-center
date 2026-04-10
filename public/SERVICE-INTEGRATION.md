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

## services.json Registration

Add an entry to `public/services.json`:

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

| Field | Description |
|-------|-------------|
| `key` | Unique identifier (used in API calls) |
| `name` | Display name in dashboard UI |
| `type` | `"node"` or `"static"` (default: `"static"`). Determines how the service is started |
| `entrypoint` | Path to main JS file, relative to `installDir` (only used when `type` is `"node"`) |
| `repo` | Git clone URL (used as fallback if no release exists) |
| `releaseUrl` | GitHub Releases API URL for pre-built downloads (optional) |
| `installDir` | Where the app is installed (`$HOME` is expanded) |
| `installScript` | Path relative to repo root, run during fallback install |
| `updateScript` | Absolute path to update script (fallback, exists after install) |
| `uninstallScript` | Path relative to repo root, run during uninstall |
| `service` | systemd service name (without `.service`) |

### Service Types

**`"static"`** (default) — Pure frontend apps. The dashboard runs:
```
npx serve dist -l {port} -s
```

**`"node"`** — Node.js servers (APIs, bridges, apps with built-in UI). The dashboard runs:
```
node {installDir}/{entrypoint}
```
The `PORT` environment variable is set automatically. Your app should listen on `process.env.PORT`.

#### Examples

A static frontend:
```json
{ "type": "static" }
```
→ `ExecStart=/usr/bin/npx serve dist -l 3001 -s`

A Node.js bridge server:
```json
{ "type": "node", "entrypoint": "bridge-pi/index.js" }
```
→ `ExecStart=/usr/bin/node /home/pi/.local/share/cast-away/bridge-pi/index.js`

A Node.js app that serves its own UI:
```json
{ "type": "node", "entrypoint": "pi/dist/index.js" }
```
→ `ExecStart=/usr/bin/node /opt/lotus-light/pi/dist/index.js`

## Release-Based Installation (Recommended)

The fastest way to deploy services on Pi Zero 2 W. No build step on the Pi.

### How it works

1. Your CI builds the project and publishes `dist.tar.gz` as a GitHub Release asset
2. The dashboard downloads and unpacks it to `installDir`
3. A systemd service is created automatically — using `npx serve` for static apps or `node {entrypoint}` for Node.js apps

Installation takes **~30 seconds** instead of 10-15 minutes.

### GitHub Actions Workflow — Static App

For pure frontends (`type: "static"`):

```yaml
name: Build and Release

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
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

For Node.js servers (`type: "node"`), include `node_modules` in the tarball so the Pi doesn't need to run `npm install`:

```yaml
name: Build and Release

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - run: npm ci
      - run: npm run build
      - run: npm ci --omit=dev
      - run: tar czf dist.tar.gz bridge-pi/ node_modules/
      # Adjust the paths above to match your project structure:
      #   tar czf dist.tar.gz pi/dist/ node_modules/
      #   tar czf dist.tar.gz server/ node_modules/
      - uses: softprops/action-gh-release@v2
        with:
          tag_name: latest
          files: dist.tar.gz
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

> **Tip**: Run `npm ci --omit=dev` before packaging to exclude dev dependencies and reduce tarball size.

### Release-based updates

Updates also use releases when available:

1. Dashboard fetches latest release from `releaseUrl`
2. Downloads `dist.tar.gz`, replaces files in `installDir`
3. Restarts the service

Update takes **~10 seconds**.

### What your repo needs

- A GitHub Actions workflow that publishes `dist.tar.gz` as a release asset
- For `"node"` apps: include `node_modules/` in the tarball
- That's it. No install script needed for release-based installs.

## Legacy Installation (Fallback)

If no `releaseUrl` is set, or no release with `dist.tar.gz` exists, the dashboard falls back to the traditional flow: clone repo → run install script.

### Installation Script

Your install script receives two arguments:

```
--port PORT    The port your service should listen on
--core CORE    The CPU core (0-3) your service should be pinned to
```

Example invocation by the dashboard:
```bash
bash scripts/install.sh --port 3001 --core 1
```

#### Parsing arguments

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

#### What your install script should do

1. Install any system dependencies (`apt-get install ...`)
2. Install app dependencies (`npm install`, `pip install`, etc.)
3. Build if needed (`npm run build`, etc.)
4. Create a systemd service unit (system or user)
5. Enable and start the service

### Update Script

The dashboard calls your update script directly (no arguments). It should:

1. `git fetch` + `git reset --hard` to latest
2. Rebuild if needed
3. Restart the service

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

systemctl --user stop "$SERVICE" 2>/dev/null || true
systemctl --user disable "$SERVICE" 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/${SERVICE}.service"
systemctl --user daemon-reload

rm -rf "$HOME/.local/share/my-service"
```

## Resource Limits

On Pi Zero 2 W (512MB RAM), use conservative resource settings for legacy installs:

```bash
export NODE_OPTIONS="--max-old-space-size=256"
nice -n 15 ionice -c 3 npm install
```

Core 0 is reserved for the dashboard + nginx. Available cores: **1, 2, 3**.

## Permissions

**Sudoers is configured automatically** by the dashboard installer. Your install script can use `sudo` for `systemctl` commands. No need to configure sudoers in your own scripts.

## Logging

The dashboard handles all user-facing logging centrally:

- **Install progress**: Shown in the UI with elapsed time
- **Script output**: stdout/stderr is captured to `/tmp/pi-dashboard/install/<key>.log`
- **Service logs**: Retrieved via `journalctl` through the dashboard UI

Your scripts should write output to stdout/stderr as usual — no special logging integration is needed.

## Checklist

Before registering your service:

- [ ] GitHub Actions workflow publishes `dist.tar.gz` (recommended), OR install script handles `--port` and `--core`
- [ ] Uninstall script cleans up service files and optionally data
- [ ] All scripts are executable (`chmod +x`)
- [ ] Scripts use LF line endings (not CRLF)
- [ ] Resource-heavy steps use `nice`/`ionice` and memory limits (legacy only)
