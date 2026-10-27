#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : configure-monitoring-updates.sh
# Purpose: Install the PinPoint Update Manager
#          (read-only in this version), its
#          recovery executor and health suite, and
#          the baseline manifest, then record the
#          installed Nagios versions.
#
# Installs:
#   /usr/local/sbin/pinpoint-update (root:root 755)
#   /usr/local/sbin/pinpoint-update-exec (root:root 755)
#   /usr/local/lib/pinpoint-update/ (health suite, root:root 755)
#   /etc/pinpoint/updates/manifests/ (root:root 755, files 644)
#   /var/lib/pinpoint/updates/ (root:root 700, SQLite state)
#   /usr/local/.pinpoint-rp/ (root:root 700, recovery points)
#   pinpoint-update-reconcile.service and
#   pinpoint-update-reconcile-finish.service, which
#   finish an interrupted change at boot, toward
#   the previous version
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
EXEC_SRC="$SCRIPT_DIR/pinpoint-update-exec.py"
EXEC="/usr/local/sbin/pinpoint-update-exec"
LIB_DIR="/usr/local/lib/pinpoint-update"
MANIFEST_SRC_DIR="$SCRIPT_DIR/manifests"
MANIFEST_DIR="/etc/pinpoint/updates/manifests"
STATE_DIR="/var/lib/pinpoint/updates"
RP_DIR="/usr/local/.pinpoint-rp"
UNIT_DIR="/etc/systemd/system"
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
# [1/6] Install the programs
##################################################

echo
echo "[1/6] Installing pinpoint-update and pinpoint-update-exec..." | tee -a "$LOG"

for SRC in "$PROGRAM_SRC" "$EXEC_SRC" "$SCRIPT_DIR/pinpoint-update-health.sh" "$SCRIPT_DIR/pinpoint-healthcheck.sh"; do
    [ -f "$SRC" ] || fail "Missing $SRC."
done

install -o root -g root -m 0755 "$PROGRAM_SRC" "$PROGRAM"
install -o root -g root -m 0755 "$EXEC_SRC" "$EXEC"

# The health suite runs the application health check
# from its own folder, so both are installed together.
install -d -o root -g root -m 0755 "$LIB_DIR"
install -o root -g root -m 0755 "$SCRIPT_DIR/pinpoint-update-health.sh" "$LIB_DIR/"
install -o root -g root -m 0755 "$SCRIPT_DIR/pinpoint-healthcheck.sh" "$LIB_DIR/"

echo "✓ $PROGRAM, $EXEC and the health suite installed." | tee -a "$LOG"

##################################################
# [2/6] Install the baseline manifest
##################################################

echo
echo "[2/6] Installing the baseline manifest..." | tee -a "$LOG"

ls "$MANIFEST_SRC_DIR"/*.json >/dev/null 2>&1 || fail "No manifest found in $MANIFEST_SRC_DIR."
install -d -o root -g root -m 0755 /etc/pinpoint/updates "$MANIFEST_DIR"
install -o root -g root -m 0644 "$MANIFEST_SRC_DIR"/*.json "$MANIFEST_DIR/"

echo "✓ Manifest installed in $MANIFEST_DIR." | tee -a "$LOG"

##################################################
# [3/6] Recovery point folder
##################################################

echo
echo "[3/6] Creating the recovery point folder..." | tee -a "$LOG"

# Same filesystem as /usr/local/nagios, so a restore is a rename.
install -d -o root -g root -m 0700 "$RP_DIR"

if [ "$(stat -c %d /usr/local/nagios)" = "$(stat -c %d "$RP_DIR")" ]; then
    echo "✓ $RP_DIR is on the same filesystem as /usr/local/nagios." | tee -a "$LOG"
else
    fail "$RP_DIR is not on the same filesystem as /usr/local/nagios."
fi

##################################################
# [4/6] Record the installed versions
##################################################

echo
echo "[4/6] Recording installed Nagios versions..." | tee -a "$LOG"

install -d -o root -g root -m 0755 /var/lib/pinpoint
install -d -o root -g root -m 0700 "$STATE_DIR"

"$PROGRAM" status 2>&1 | tee -a "$LOG" || fail "pinpoint-update could not read the installation."

echo "✓ Inventory recorded in $STATE_DIR/updates.db." | tee -a "$LOG"

##################################################
# [5/6] Reconcile at boot
##################################################

echo
echo "[5/6] Installing the boot-time reconcile services..." | tee -a "$LOG"

# Two units, because a unit ordered before nagios.service cannot
# start Nagios itself (it would wait for its own end). The first
# puts the files back before the services start; the second runs
# the health suite once they are up. Both exit at once when no
# change was interrupted.
cat > "$UNIT_DIR/pinpoint-update-reconcile.service" <<EOF
[Unit]
Description=PinPoint Update Manager: restore an interrupted Nagios change
Before=nagios.service apache2.service pinpoint-gunicorn.service

[Service]
Type=oneshot
ExecStart=$EXEC reconcile --boot
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

cat > "$UNIT_DIR/pinpoint-update-reconcile-finish.service" <<EOF
[Unit]
Description=PinPoint Update Manager: check Nagios after a boot-time restore
After=nagios.service apache2.service pinpoint-gunicorn.service nginx.service

[Service]
Type=oneshot
ExecStart=$EXEC reconcile --finish
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$UNIT_DIR/pinpoint-update-reconcile.service" "$UNIT_DIR/pinpoint-update-reconcile-finish.service"
systemctl daemon-reload
systemctl enable pinpoint-update-reconcile.service pinpoint-update-reconcile-finish.service >> "$LOG" 2>&1 \
    || fail "Could not enable the reconcile services."

echo "✓ Reconcile services enabled." | tee -a "$LOG"

##################################################
# [6/6] First console login (fresh install only)
##################################################

echo
echo "[6/6] Setting up the first-login menu..." | tee -a "$LOG"

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
