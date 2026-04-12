#!/bin/bash
# ============================================================
# Pi Control Center — SD Card Prep Script
# ============================================================
#
# Run this on your computer AFTER flashing Raspberry Pi OS.
# It copies the first-boot files to the SD card so everything
# installs automatically on first power-on.
#
# USAGE:
#   ./prep-sd-card.sh /path/to/sd-rootfs [REPO_URL]
#
# Example (macOS):
#   ./prep-sd-card.sh /Volumes/rootfs https://github.com/user/pi-control-center.git
#
# Example (Linux):
#   ./prep-sd-card.sh /mnt/rootfs https://github.com/user/pi-control-center.git
#
# After running this:
#   1. Eject SD card safely
#   2. Insert into Pi Zero 2 W
#   3. Power on
#   4. Wait ~10-15 minutes
#   5. Open http://<pi-ip> on your phone
#
# ============================================================

set -euo pipefail

ROOTFS="${1:?Usage: $0 /path/to/sd-rootfs [repo-url]}"
REPO_URL="${2:-https://github.com/raagerrd-ship-it/pi-control-center.git}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$ROOTFS/etc" ]; then
  echo "Error: $ROOTFS doesn't look like a rootfs partition (no /etc found)"
  exit 1
fi

echo "=== Pi Control Center — SD Card Prep ==="
echo ""
echo "Target:  $ROOTFS"
echo "Repo:    $REPO_URL"
echo ""

# Copy first-boot script
echo "[1/3] Copying first-boot script..."
sudo cp "$SCRIPT_DIR/first-boot-setup.sh" "$ROOTFS/opt/first-boot-setup.sh"
sudo chmod +x "$ROOTFS/opt/first-boot-setup.sh"

# Inject repo URL
if [ "$REPO_URL" != "https://github.com/raagerrd-ship-it/pi-control-center.git" ]; then
  sudo sed -i "s|PI_REPO:-https://github.com/raagerrd-ship-it/pi-control-center.git|PI_REPO:-${REPO_URL}|" "$ROOTFS/opt/first-boot-setup.sh"
fi

# Copy & enable systemd service
echo "[2/3] Installing systemd service..."
sudo cp "$SCRIPT_DIR/first-boot-setup.service" "$ROOTFS/etc/systemd/system/"
sudo mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/first-boot-setup.service \
     "$ROOTFS/etc/systemd/system/multi-user.target.wants/first-boot-setup.service"

# Verify
echo "[3/3] Verifying..."
[ -f "$ROOTFS/opt/first-boot-setup.sh" ] && echo "  ✓ first-boot-setup.sh" || echo "  ✗ first-boot-setup.sh MISSING"
[ -f "$ROOTFS/etc/systemd/system/first-boot-setup.service" ] && echo "  ✓ first-boot-setup.service" || echo "  ✗ first-boot-setup.service MISSING"
[ -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/first-boot-setup.service" ] && echo "  ✓ service enabled" || echo "  ✗ service NOT enabled"

echo ""
echo "=== Done! ==="
echo ""
echo "Nu kan du:"
echo "  1. Mata ut SD-kortet säkert"
echo "  2. Sätt i det i Pi Zero 2 W"
echo "  3. Slå på strömmen"
echo "  4. Vänta ~10-15 minuter"
echo "  5. Öppna http://<pi-ip> på mobilen"
echo ""
echo "Loggar vid problem: ssh pi@<ip> → cat /var/log/pi-control-center-setup.log"
