#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : configure-monitoring-updates.sh
# Purpose: Install the PinPoint Update Manager
#          (read-only in this version) and the
#          baseline manifest, then record the
#          installed Nagios versions.
#
# Installs:
#   /usr/local/sbin/pinpoint-update (root:root 755)
#   /etc/pinpoint/updates/manifests/ (root:root 755, files 644)
#   /var/lib/pinpoint/updates/ (root:root 700, SQLite state)
#
# Safe to run again on an existing appliance. Only on a
# fresh install (install credentials not yet shown) is the
# menu set to open once at the first console login.
##################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOG="/var/log/pinpoint-updates.log"

PROGRAM_SRC="$SCRIPT_DIR/pinpoint-update.py"
PROGRAM="/usr/local/sbin/pinpoint-update"
MANIFEST_SRC_DIR="$SCRIPT_DIR/manifests"
MANIFEST_DIR="/etc/pinpoint/updates/manifests"
STATE_DIR="/var/lib/pinpoint/updates"
CREDENTIALS_MARKER="/var/lib/pinpoint/web-credentials-pending"
MENU_PENDING="/var/lib/pinpoint/update-menu-pending"

fail() {
    echo "✗ $1" | tee -a "$LOG"
    exit 1
}

##################################################
# Root Check
##################################################

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "======================================" | tee -a "$LOG"
echo " PinPoint - Configuring Update Manager" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

##################################################
# [1/4] Install the program
##################################################

echo
echo "[1/4] Installing pinpoint-update..." | tee -a "$LOG"

[ -f "$PROGRAM_SRC" ] || fail "Missing $PROGRAM_SRC."
install -o root -g root -m 0755 "$PROGRAM_SRC" "$PROGRAM"

echo "✓ $PROGRAM installed." | tee -a "$LOG"

##################################################
# [2/4] Install the baseline manifest
##################################################

echo
echo "[2/4] Installing the baseline manifest..." | tee -a "$LOG"

ls "$MANIFEST_SRC_DIR"/*.json >/dev/null 2>&1 || fail "No manifest found in $MANIFEST_SRC_DIR."
install -d -o root -g root -m 0755 /etc/pinpoint/updates "$MANIFEST_DIR"
install -o root -g root -m 0644 "$MANIFEST_SRC_DIR"/*.json "$MANIFEST_DIR/"

echo "✓ Manifest installed in $MANIFEST_DIR." | tee -a "$LOG"

##################################################
# [3/4] Record the installed versions
##################################################

echo
echo "[3/4] Recording installed Nagios versions..." | tee -a "$LOG"

install -d -o root -g root -m 0755 /var/lib/pinpoint
install -d -o root -g root -m 0700 "$STATE_DIR"

"$PROGRAM" status 2>&1 | tee -a "$LOG" || fail "pinpoint-update could not read the installation."

echo "✓ Inventory recorded in $STATE_DIR/updates.db." | tee -a "$LOG"

##################################################
# [4/4] First console login (fresh install only)
##################################################

echo
echo "[4/4] Setting up the first-login menu..." | tee -a "$LOG"

if [ -f "$CREDENTIALS_MARKER" ]; then
    touch "$MENU_PENDING"
    chmod 644 "$MENU_PENDING"
    echo "✓ Fresh install: the Update Manager opens once at the first console login." | tee -a "$LOG"
else
    echo "✓ Existing appliance: no automatic menu. Run: sudo pinpoint-update" | tee -a "$LOG"
fi

echo
echo "======================================" | tee -a "$LOG"
echo " Update Manager configured." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
