

## Problem

The "Återställ Pi" build fails with `EACCES, Permission denied` on `/home/pi/pi-control-center/dist/assets`.

**Root cause**: The `vite build` command runs inside `sudo systemd-run`, which means the `dist/` directory gets created as **root**. On the next build attempt, Vite tries to `rmSync` the existing `dist/` folder but can't because the current user (pi) doesn't own it.

The same issue exists in the factory-reset path (line ~1236).

## Fix

Add `rm -rf dist/` (as the user who owns it, or via sudo) **before** running `vite build` in both the pi-reset and factory-reset code paths. Also fix ownership after `sudo cp` deployment so future builds don't break.

### Changes in `public/pi-scripts/pi-control-center-api.sh`:

1. **Before vite build in pi-reset** (~line 1321): Add `sudo rm -rf "$ddir/dist"` before the build command.

2. **Before vite build in factory-reset** (~line 1236): Add the same `sudo rm -rf "$ddir/dist"` line.

3. **After deployment** (both paths): Add `sudo chown -R pi:pi "$ddir/dist"` after `sudo cp -r dist/*` to prevent future permission issues if the build runs without the cleanup step.

This is a 3-line addition across 2 code paths — minimal and targeted.

