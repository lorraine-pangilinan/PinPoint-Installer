#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : configure-pinpoint-privileges.sh
# Purpose: Grant the pinpoint service account the
#          privileges the web application needs:
#            - nmap raw-socket scans (Discovery)
#            - write access to the Nagios host and
#              plugin service configs it generates
#            - "systemctl reload nagios" via sudo,
#              and nothing else
#            - an SSH key for NCPA agent deployment
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

# Nagios files the application validates and replaces
# (NAGIOS_HOST_CFG and PLUGIN_SERVICE_CFG in config.py).
NAGIOS_GROUP="nagios"
NAGIOS_BIN="/usr/local/nagios/bin/nagios"
NAGIOS_CFG="/usr/local/nagios/etc/nagios.cfg"
NAGIOS_CFG_BACKUP="$NAGIOS_CFG.before-pinpoint"
NAGIOS_HOST_CFG="/usr/local/nagios/etc/objects/hosts.cfg"
PLUGIN_SERVICE_CFG="/usr/local/nagios/etc/objects/plugin-services.cfg"
SUDOERS_FILE="/etc/sudoers.d/pinpoint-nagios-reload"

# Key the application reads from ~/.ssh to deploy NCPA
# (ncpa_deployment.py).
NCPA_KEY_NAME="pinpoint_ncpa_deploy"

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
# [1/8] Check Prerequisites
##################################################

echo
echo "[1/8] Checking prerequisites..." | tee -a "$LOG"

if ! id "$APP_USER" > /dev/null 2>&1; then
    fail "Account $APP_USER not found. Run deploy-pinpoint-web.sh first."
fi

if [ ! -f "/etc/systemd/system/$GUNICORN_SERVICE.service" ]; then
    fail "$GUNICORN_SERVICE.service not found. Run deploy-pinpoint-web.sh first."
fi

if ! getent group "$NAGIOS_GROUP" > /dev/null || [ ! -f "$NAGIOS_CFG" ]; then
    fail "Nagios group or $NAGIOS_CFG not found. Run install-nagios-core.sh first."
fi

echo "✓ Account $APP_USER, $GUNICORN_SERVICE and Nagios found." | tee -a "$LOG"

##################################################
# [2/8] Install nmap
##################################################

echo
echo "[2/8] Installing nmap..." | tee -a "$LOG"

# libcap2-bin provides setcap and getcap; openssh-client
# provides ssh-keygen for the NCPA key.
apt-get install -y nmap libcap2-bin sudo openssh-client >> "$LOG" 2>&1 \
    || fail "Could not install nmap."

if [ ! -x "$NMAP_BIN" ]; then
    fail "$NMAP_BIN not found after installation."
fi

echo "✓ $("$NMAP_BIN" --version | head -n 1) installed." | tee -a "$LOG"

##################################################
# [3/8] Restrict nmap to the Service Account
##################################################

echo
echo "[3/8] Restricting nmap to $APP_USER..." | tee -a "$LOG"

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
# [4/8] Apply nmap Capabilities
##################################################

echo
echo "[4/8] Applying nmap capabilities..." | tee -a "$LOG"

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

echo "✓ $GUNICORN_SERVICE re-applies capabilities on start." | tee -a "$LOG"

##################################################
# [5/8] Install nmap Wrapper
##################################################

echo
echo "[5/8] Installing $NMAP_WRAPPER..." | tee -a "$LOG"

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
# [6/8] Grant Nagios Configuration Access
##################################################

echo
echo "[6/8] Granting Nagios configuration access..." | tee -a "$LOG"

# The nagios group lets the app read every file that
# "nagios -v" loads (resource.cfg is not world-readable).
usermod -aG "$NAGIOS_GROUP" "$APP_USER"

echo "✓ $APP_USER added to the $NAGIOS_GROUP group." | tee -a "$LOG"

# The app replaces these files with shutil.copy2, which
# also sets their timestamps, so it must own them.
# Nagios reads them through the group.
CFG_ADDED=0

for CFG in "$NAGIOS_HOST_CFG" "$PLUGIN_SERVICE_CFG"; do

    if [ ! -f "$CFG" ]; then
        echo "# Managed by the PinPoint web interface." > "$CFG"
    fi

    chown "$APP_USER:$NAGIOS_GROUP" "$CFG"
    chmod 664 "$CFG"

    # The app refuses to validate hosts.cfg unless nagios.cfg
    # loads it, and would otherwise edit nagios.cfg itself to
    # add plugin-services.cfg. configure-nagios.sh already adds
    # hosts.cfg; this covers servers installed before it did.
    if ! grep -qx "cfg_file=$CFG" "$NAGIOS_CFG"; then

        if [ ! -f "$NAGIOS_CFG_BACKUP" ]; then
            cp -p "$NAGIOS_CFG" "$NAGIOS_CFG_BACKUP"
        fi

        echo "cfg_file=$CFG" >> "$NAGIOS_CFG"
        CFG_ADDED=1

    fi

    echo "✓ $CFG owned by $APP_USER:$NAGIOS_GROUP (664)." | tee -a "$LOG"

done

if ! "$NAGIOS_BIN" -v "$NAGIOS_CFG" >> "$LOG" 2>&1; then
    if [ "$CFG_ADDED" = "1" ]; then
        cp -p "$NAGIOS_CFG_BACKUP" "$NAGIOS_CFG"
    fi
    fail "Nagios configuration is invalid after adding PinPoint config files."
fi

if [ "$CFG_ADDED" = "1" ]; then
    systemctl reload nagios
    echo "✓ nagios.cfg now loads the PinPoint config files." | tee -a "$LOG"
fi

# Only this exact command; the app calls it after it has
# validated a new config with "nagios -v".
SUDOERS_TMP="$(mktemp)"

cat > "$SUDOERS_TMP" <<EOF
# Managed by PinPoint Installer.
# Lets the PinPoint web interface apply validated Nagios configs.
$APP_USER ALL=(root) NOPASSWD: /usr/bin/systemctl reload nagios, /bin/systemctl reload nagios
EOF

if ! visudo -cf "$SUDOERS_TMP" >> "$LOG" 2>&1; then
    rm -f "$SUDOERS_TMP"
    fail "Generated sudoers rule is invalid."
fi

install -m 440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
rm -f "$SUDOERS_TMP"

echo "✓ $APP_USER may run 'systemctl reload nagios' only." | tee -a "$LOG"

##################################################
# [7/8] Create NCPA Deployment Key
##################################################

echo
echo "[7/8] Creating NCPA deployment key..." | tee -a "$LOG"

APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
SSH_DIR="$APP_HOME/.ssh"
NCPA_KEY="$SSH_DIR/$NCPA_KEY_NAME"

install -d -m 700 -o "$APP_USER" -g "$APP_USER" "$SSH_DIR"

if [ -f "$NCPA_KEY" ]; then
    echo "✓ Existing key $NCPA_KEY kept." | tee -a "$LOG"
else
    runuser -u "$APP_USER" -- ssh-keygen -q -t ed25519 -N '' \
        -C "pinpoint-ncpa-deploy@$(hostname)" -f "$NCPA_KEY" >> "$LOG" 2>&1 \
        || fail "Could not create $NCPA_KEY."
    echo "✓ $NCPA_KEY created." | tee -a "$LOG"
fi

##################################################
# [8/8] Verify Privileges
##################################################

echo
echo "[8/8] Verifying privileges..." | tee -a "$LOG"

# Restart so the service picks up the nagios group and
# re-applies nmap capabilities.
systemctl restart "$GUNICORN_SERVICE"

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

NAGIOS_GID="$(getent group "$NAGIOS_GROUP" | cut -d: -f3)"
GUNICORN_PID="$(systemctl show -p MainPID --value "$GUNICORN_SERVICE")"

if ! grep '^Groups:' "/proc/$GUNICORN_PID/status" 2> /dev/null | grep -qw "$NAGIOS_GID"; then
    fail "$GUNICORN_SERVICE is not running with the $NAGIOS_GROUP group."
fi

for CFG in "$NAGIOS_HOST_CFG" "$PLUGIN_SERVICE_CFG"; do
    if ! runuser -u "$APP_USER" -- test -w "$CFG"; then
        fail "$APP_USER cannot write $CFG."
    fi
done

if ! runuser -u "$APP_USER" -- "$NAGIOS_BIN" -v "$NAGIOS_CFG" >> "$LOG" 2>&1; then
    fail "$APP_USER cannot validate the Nagios configuration."
fi

echo "✓ $APP_USER can validate and replace Nagios host and plugin configs." | tee -a "$LOG"

# -l only checks the rule; Nagios is not reloaded.
if ! runuser -u "$APP_USER" -- sudo -n -l /usr/bin/systemctl reload nagios > /dev/null 2>&1; then
    fail "$APP_USER cannot run 'sudo systemctl reload nagios'."
fi

if runuser -u "$APP_USER" -- sudo -n -l /usr/bin/systemctl restart nagios > /dev/null 2>&1; then
    fail "$APP_USER has more sudo rights than 'systemctl reload nagios'."
fi

echo "✓ $APP_USER can reload Nagios and nothing else through sudo." | tee -a "$LOG"

if ! runuser -u "$APP_USER" -- test -r "$NCPA_KEY"; then
    fail "$APP_USER cannot read $NCPA_KEY."
fi

echo "✓ NCPA deployment key ready." | tee -a "$LOG"

##################################################
# Footer
##################################################

echo
echo "======================================" | tee -a "$LOG"
echo " PinPoint privileges configured." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
