#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : configure-pinpoint-privileges.sh
# Purpose: Grant the pinpoint service account the
#          privileges the web application needs:
#            - nmap raw-socket scans (Discovery)
#
# nmap is given file capabilities (raw sockets only)
# instead of running through sudo, so scans and NSE
# version scripts never run as root:
#
#   Flask -> /usr/local/bin/nmap-sudo
#         -> /usr/bin/nmap --privileged
#            (cap_net_raw, cap_net_admin,
#             cap_net_bind_service)
#
# /usr/bin/nmap is restricted to the pinpoint group,
# so no other local account gains these rights.
#
# Upgrading the nmap package drops the capabilities.
# They are re-applied after every dpkg run and each
# time pinpoint-gunicorn starts.
#
# Must run after deploy-pinpoint-web.sh, which creates
# the pinpoint account and pinpoint-gunicorn service.
##################################################

set -e

LOG="/var/log/pinpoint-privileges.log"

# Set explicitly: SUDO_USER/USER resolve to root at first boot.
APP_USER="pinpoint"

GUNICORN_SERVICE="pinpoint-gunicorn"
GUNICORN_DROPIN_DIR="/etc/systemd/system/$GUNICORN_SERVICE.service.d"
GUNICORN_DROPIN="$GUNICORN_DROPIN_DIR/nmap-capabilities.conf"

NMAP_BIN="/usr/bin/nmap"
NMAP_CAPS="cap_net_raw,cap_net_admin,cap_net_bind_service=eip"

# Path used by the application (network_discovery.py).
NMAP_WRAPPER="/usr/local/bin/nmap-sudo"
NMAP_CAPS_HELPER="/usr/local/sbin/pinpoint-nmap-caps"
APT_HOOK="/etc/apt/apt.conf.d/80pinpoint-nmap-caps"

##################################################
# Helpers
##################################################

fail() {
    echo "ERROR: $1" | tee -a "$LOG"
    echo "Check $LOG for details." | tee -a "$LOG"
    exit 1
}

##################################################
# Root Check
##################################################

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

##################################################
# Header
##################################################

echo "======================================" | tee -a "$LOG"
echo " PinPoint - Configuring Privileges" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

##################################################
# [1/6] Check Prerequisites
##################################################

echo
echo "[1/6] Checking prerequisites..." | tee -a "$LOG"

if ! id "$APP_USER" > /dev/null 2>&1; then
    fail "Account $APP_USER not found. Run deploy-pinpoint-web.sh first."
fi

if [ ! -f "/etc/systemd/system/$GUNICORN_SERVICE.service" ]; then
    fail "$GUNICORN_SERVICE.service not found. Run deploy-pinpoint-web.sh first."
fi

echo "✓ Account $APP_USER and $GUNICORN_SERVICE found." | tee -a "$LOG"

##################################################
# [2/6] Install nmap
##################################################

echo
echo "[2/6] Installing nmap..." | tee -a "$LOG"

# libcap2-bin provides setcap and getcap.
apt-get install -y nmap libcap2-bin >> "$LOG" 2>&1 \
    || fail "Could not install nmap."

if [ ! -x "$NMAP_BIN" ]; then
    fail "$NMAP_BIN not found after installation."
fi

echo "✓ $("$NMAP_BIN" --version | head -n 1) installed." | tee -a "$LOG"

##################################################
# [3/6] Restrict nmap to the Service Account
##################################################

echo
echo "[3/6] Restricting nmap to $APP_USER..." | tee -a "$LOG"

# A dpkg override keeps the owner and mode across nmap
# upgrades. Changing the owner clears file capabilities,
# so this must happen before they are applied.
if dpkg-statoverride --list "$NMAP_BIN" > /dev/null; then
    dpkg-statoverride --remove "$NMAP_BIN"
fi

dpkg-statoverride --update --add root "$APP_USER" 0750 "$NMAP_BIN" \
    || fail "Could not restrict $NMAP_BIN."

echo "✓ $NMAP_BIN is root:$APP_USER 750." | tee -a "$LOG"

##################################################
# [4/6] Apply nmap Capabilities
##################################################

echo
echo "[4/6] Applying nmap capabilities..." | tee -a "$LOG"

cat > "$NMAP_CAPS_HELPER" <<EOF
#!/bin/sh
# Managed by PinPoint Installer.
# Gives nmap raw-socket rights without root. Upgrading
# the nmap package drops them, so this runs after every
# dpkg run and before $GUNICORN_SERVICE starts.
[ -x $NMAP_BIN ] || exit 0
exec /usr/sbin/setcap $NMAP_CAPS $NMAP_BIN
EOF

chown root:root "$NMAP_CAPS_HELPER"
chmod 755 "$NMAP_CAPS_HELPER"

# Never let a failure here break apt.
cat > "$APT_HOOK" <<EOF
// Managed by PinPoint Installer.
// Re-apply nmap capabilities after package upgrades.
DPkg::Post-Invoke { "$NMAP_CAPS_HELPER || true"; };
EOF

chmod 644 "$APT_HOOK"

# "+" runs the helper as root despite User=pinpoint.
# "-" lets the web interface start even if it fails;
# only Discovery scans would be affected.
mkdir -p "$GUNICORN_DROPIN_DIR"

cat > "$GUNICORN_DROPIN" <<EOF
# Managed by PinPoint Installer.
# Re-apply nmap capabilities in case nmap was upgraded.
[Service]
ExecStartPre=-+$NMAP_CAPS_HELPER
EOF

chmod 644 "$GUNICORN_DROPIN"

"$NMAP_CAPS_HELPER" >> "$LOG" 2>&1 \
    || fail "Could not apply capabilities to $NMAP_BIN."

echo "✓ $(getcap "$NMAP_BIN")" | tee -a "$LOG"

systemctl daemon-reload
systemctl restart "$GUNICORN_SERVICE"

echo "✓ $GUNICORN_SERVICE re-applies capabilities on start." | tee -a "$LOG"

##################################################
# [5/6] Install nmap Wrapper
##################################################

echo
echo "[5/6] Installing $NMAP_WRAPPER..." | tee -a "$LOG"

# The name is kept for the application; sudo is not used.
# --privileged tells nmap to use its raw-socket rights
# instead of assuming a non-root user has none.
cat > "$NMAP_WRAPPER" <<EOF
#!/bin/sh
# Managed by PinPoint Installer.
# nmap for the PinPoint web application. Runs with file
# capabilities (raw sockets), not root.
exec $NMAP_BIN --privileged "\$@"
EOF

chown root:root "$NMAP_WRAPPER"
chmod 755 "$NMAP_WRAPPER"

echo "✓ $NMAP_WRAPPER installed." | tee -a "$LOG"

##################################################
# [6/6] Verify nmap Privileges
##################################################

echo
echo "[6/6] Verifying nmap privileges..." | tee -a "$LOG"

if ! getcap "$NMAP_BIN" | grep -q 'cap_net_raw'; then
    fail "$NMAP_BIN has no raw-socket capability."
fi

if ! systemctl is-active --quiet "$GUNICORN_SERVICE"; then
    journalctl -u "$GUNICORN_SERVICE" -n 50 --no-pager >> "$LOG" 2>&1 || true
    fail "$GUNICORN_SERVICE did not restart."
fi

# Same privileged scan types Discovery uses: SYN scan
# and OS detection, run as the service account.
SCAN_OUTPUT="$(runuser -u "$APP_USER" -- \
    timeout 120 "$NMAP_WRAPPER" -sS -O -Pn -p 22 127.0.0.1 2>&1)" \
    || { echo "$SCAN_OUTPUT" >> "$LOG"; fail "nmap scan as $APP_USER failed."; }

echo "$SCAN_OUTPUT" >> "$LOG"

if printf '%s' "$SCAN_OUTPUT" | grep -Eqi 'QUITTING|requires root|Operation not permitted'; then
    fail "nmap scan as $APP_USER was refused."
fi

echo "✓ $APP_USER can run SYN and OS detection scans." | tee -a "$LOG"

# Other accounts must not inherit the capabilities.
if runuser -u nobody -- "$NMAP_BIN" --version > /dev/null 2>&1; then
    fail "$NMAP_BIN can be run by accounts other than $APP_USER."
fi

echo "✓ Other accounts cannot run $NMAP_BIN." | tee -a "$LOG"

##################################################
# Footer
##################################################

echo
echo "======================================" | tee -a "$LOG"
echo " PinPoint privileges configured." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
