#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : configure-monitoring-updates.sh
# Purpose: Install the PinPoint Update Manager, its
#          update executor and health suite, its
#          admin and viewer groups, the baseline
#          manifest, the catalog check and run
#          timers, then record the installed Nagios
#          versions and make sure Ubuntu installs its
#          own security updates.
#
# Installs:
#   /usr/local/sbin/pinpoint-update (root:root 755)
#   /usr/local/sbin/pinpoint-update-exec (root:root 755)
#   /usr/local/lib/pinpoint-update/ (health suite, root:root 755)
#   groups pinpoint-update-admins and pinpoint-update-viewers
#   /etc/sudoers.d/pinpoint-update (root:root 440)
#   /etc/pinpoint/updates/manifests/ (root:root 755, files 644)
#   /var/lib/pinpoint/updates/ (root:root 700, SQLite state)
#   /usr/local/.pinpoint-rp/ (root:root 700, recovery points)
#   pinpoint-update-reconcile.service and
#   pinpoint-update-reconcile-finish.service, which
#   finish an interrupted change at boot, toward
#   the previous version
#   pinpoint-update-exec@.service (one update each)
#   pinpoint-update-discover.timer (daily catalog check)
#   pinpoint-update-run.timer (scheduled windows)
#   user pinpoint-updater and /var/lib/pinpoint/update-build/
#   /etc/pinpoint/updates/updater.conf (catalog address)
#   unattended-upgrades, on (Ubuntu security updates)
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
SUDOERS_FILE="/etc/sudoers.d/pinpoint-update"
ADMINS="pinpoint-update-admins"
VIEWERS="pinpoint-update-viewers"
CREDENTIALS_MARKER="/var/lib/pinpoint/web-credentials-pending"
MENU_PENDING="/var/lib/pinpoint/update-menu-pending"
BUILDER="pinpoint-updater"
BUILD_ROOT="/var/lib/pinpoint/update-build"
UPDATER_CONF="/etc/pinpoint/updates/updater.conf"
CATALOG_URL="https://raw.githubusercontent.com/lorraine-pangilinan/PinPoint-Installer/main/catalog/"
AUTO_UPGRADES="/etc/apt/apt.conf.d/20auto-upgrades"

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
# [1/7] Install the programs
##################################################

echo
echo "[1/7] Installing pinpoint-update and pinpoint-update-exec..." | tee -a "$LOG"

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
# [2/7] Admin and viewer groups
##################################################

echo
echo "[2/7] Setting up the update admin and viewer groups..." | tee -a "$LOG"

# Sudo only lets these groups start the program; the program
# itself decides what each role may do (approve, defer,
# decline and cancel are for admins only).
getent group "$VIEWERS" > /dev/null || groupadd --system "$VIEWERS" || fail "Could not create $VIEWERS."

# The members of "sudo" become the first admins, only when the
# group is created, so a later run never re-adds someone that
# university IT removed (gpasswd -d USER pinpoint-update-admins).
if ! getent group "$ADMINS" > /dev/null; then
    groupadd --system "$ADMINS" || fail "Could not create $ADMINS."
    for MEMBER in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
        usermod -aG "$ADMINS" "$MEMBER" && echo "  $MEMBER added to $ADMINS." | tee -a "$LOG"
    done
fi

SUDOERS_TMP="$(mktemp)"

cat > "$SUDOERS_TMP" <<EOF
# Managed by PinPoint Installer.
# Lets update admins and viewers start the PinPoint Update Manager.
# The program checks each caller's group before it changes anything.
%$ADMINS ALL=(root) NOPASSWD: $PROGRAM, $PROGRAM *
%$VIEWERS ALL=(root) NOPASSWD: $PROGRAM, $PROGRAM *
EOF

if ! visudo -cf "$SUDOERS_TMP" >> "$LOG" 2>&1; then
    rm -f "$SUDOERS_TMP"
    fail "Generated sudoers rule is invalid."
fi

install -m 440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
rm -f "$SUDOERS_TMP"

echo "✓ Update admins: $(getent group "$ADMINS" | cut -d: -f4 | tr ',' ' ')" | tee -a "$LOG"

##################################################
# [3/7] Install the baseline manifest
##################################################

echo
echo "[3/7] Installing the baseline manifest..." | tee -a "$LOG"

ls "$MANIFEST_SRC_DIR"/*.json >/dev/null 2>&1 || fail "No manifest found in $MANIFEST_SRC_DIR."
install -d -o root -g root -m 0755 /etc/pinpoint/updates "$MANIFEST_DIR"
install -o root -g root -m 0644 "$MANIFEST_SRC_DIR"/*.json "$MANIFEST_DIR/"

echo "✓ Manifest installed in $MANIFEST_DIR." | tee -a "$LOG"

##################################################
# [4/7] Recovery point folder
##################################################

echo
echo "[4/7] Creating the recovery point folder..." | tee -a "$LOG"

# Same filesystem as /usr/local/nagios, so a restore is a rename.
install -d -o root -g root -m 0700 "$RP_DIR"

if [ "$(stat -c %d /usr/local/nagios)" = "$(stat -c %d "$RP_DIR")" ]; then
    echo "✓ $RP_DIR is on the same filesystem as /usr/local/nagios." | tee -a "$LOG"
else
    fail "$RP_DIR is not on the same filesystem as /usr/local/nagios."
fi

##################################################
# [5/7] Record the installed versions
##################################################

echo
echo "[5/7] Recording installed Nagios versions..." | tee -a "$LOG"

install -d -o root -g root -m 0755 /var/lib/pinpoint
install -d -o root -g root -m 0700 "$STATE_DIR"

"$PROGRAM" status 2>&1 | tee -a "$LOG" || fail "pinpoint-update could not read the installation."

echo "✓ Inventory recorded in $STATE_DIR/updates.db." | tee -a "$LOG"

##################################################
# [6/7] Reconcile at boot
##################################################

echo
echo "[6/7] Installing the boot-time reconcile services..." | tee -a "$LOG"

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
# Exit 10 means the boot-time restore worked and Nagios is back on
# the previous version, which is a success for this unit.
SuccessExitStatus=10
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
# Build user, update runner and timers
##################################################

echo
echo "Installing the update runner, the build user and the timers..." | tee -a "$LOG"

# Downloads are unpacked and compiled by this user, never by
# root (plan 12.1). It cannot log in and owns nothing else.
if ! id "$BUILDER" > /dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$BUILDER" \
        || fail "Could not create the build user $BUILDER."
fi
install -d -o root -g root -m 0755 "$BUILD_ROOT"

# Catalog address: the university's GitHub repository (decision
# of 14 November 2026). Kept if it exists, so a site can point
# to its own fork; only raw.githubusercontent.com is accepted.
if [ ! -f "$UPDATER_CONF" ]; then
    cat > "$UPDATER_CONF" <<EOF
# PinPoint Update Manager settings. Root only.
# Where the list of approved update sets is downloaded from.
catalog_url = $CATALOG_URL
# Optional: send update notices to these addresses instead of
# the PinPoint users in Nagios (comma-separated).
# notify_to = admin@university.edu
EOF
fi
chown root:root "$UPDATER_CONF"
chmod 0644 "$UPDATER_CONF"

# One unit per update, so closing the SSH session never stops
# an update that is running (plan 8.1).
cat > "$UNIT_DIR/pinpoint-update-exec@.service" <<EOF
[Unit]
Description=PinPoint Update Manager: install update %i
Wants=network-online.target
After=network-online.target nagios.service

[Service]
Type=oneshot
ExecStart=$EXEC run %i
TimeoutStartSec=10800
EOF

# Daily catalog check. It only downloads the list and sends
# notices; it never installs anything.
cat > "$UNIT_DIR/pinpoint-update-discover.service" <<EOF
[Unit]
Description=PinPoint Update Manager: check the update catalog
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$PROGRAM discover --quiet
EOF

cat > "$UNIT_DIR/pinpoint-update-discover.timer" <<EOF
[Unit]
Description=PinPoint Update Manager: daily catalog check

[Timer]
OnBootSec=15min
OnCalendar=daily
RandomizedDelaySec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Starts an update only when an admin approved it with a
# maintenance window and that window has opened.
cat > "$UNIT_DIR/pinpoint-update-run.service" <<EOF
[Unit]
Description=PinPoint Update Manager: run scheduled updates
Wants=network-online.target
After=network-online.target nagios.service

[Service]
Type=oneshot
ExecStart=$EXEC run-due
TimeoutStartSec=10800
EOF

cat > "$UNIT_DIR/pinpoint-update-run.timer" <<EOF
[Unit]
Description=PinPoint Update Manager: check every 5 minutes for an opened window

[Timer]
OnBootSec=10min
OnCalendar=*:0/5

[Install]
WantedBy=timers.target
EOF

chmod 644 "$UNIT_DIR"/pinpoint-update-exec@.service "$UNIT_DIR"/pinpoint-update-discover.* "$UNIT_DIR"/pinpoint-update-run.*
systemctl daemon-reload
systemctl enable --now pinpoint-update-discover.timer pinpoint-update-run.timer >> "$LOG" 2>&1 \
    || fail "Could not enable the update timers."

echo "✓ Build user $BUILDER, catalog $(grep '^catalog_url' "$UPDATER_CONF" | cut -d= -f2- | xargs)" | tee -a "$LOG"
echo "✓ Timers enabled: daily catalog check, scheduled-window runner." | tee -a "$LOG"

##################################################
# Ubuntu security updates
##################################################

echo
echo "Checking that Ubuntu installs its security updates..." | tee -a "$LOG"

# nginx, Apache, Python, OpenSSL and the other Ubuntu packages
# are updated and signature-checked by Ubuntu itself (plan
# section 3). Make sure the daily security updates are on.
if ! dpkg -s unattended-upgrades > /dev/null 2>&1; then
    apt-get install -y unattended-upgrades >> "$LOG" 2>&1 \
        || echo "  WARNING: unattended-upgrades could not be installed (offline?)." | tee -a "$LOG"
fi

if dpkg -s unattended-upgrades > /dev/null 2>&1; then
    if ! grep -q 'Unattended-Upgrade "1"' "$AUTO_UPGRADES" 2> /dev/null \
        || ! grep -q 'Update-Package-Lists "1"' "$AUTO_UPGRADES" 2> /dev/null; then
        cat > "$AUTO_UPGRADES" <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
        echo "  Daily Ubuntu security updates turned on." | tee -a "$LOG"
    fi
    echo "✓ Ubuntu security updates: automatic." | tee -a "$LOG"
else
    echo "  WARNING: Ubuntu security updates are NOT automatic on this appliance." | tee -a "$LOG"
fi

##################################################
# [7/7] First console login (fresh install only)
##################################################

echo
echo "[7/7] Setting up the first-login menu..." | tee -a "$LOG"

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
