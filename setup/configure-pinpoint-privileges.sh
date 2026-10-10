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
#            - a send-only mail transport (msmtp) so
#              Nagios notifications can leave the
#              server, and a root-owned helper that
#              lets the web interface change its
#              settings without running as root
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

# Mail transport. Nagios runs "mail" as the nagios account;
# msmtp relays it to the SMTP server configured in MSMTP_CFG.
# Only SMTP_HELPER (root) writes that file; the web interface
# reaches it through the single sudoers rule in SMTP_SUDOERS_FILE.
MSMTP_CFG="/etc/msmtprc"
SMTP_HELPER="/usr/local/sbin/pinpoint-apply-smtp"
SMTP_SUDOERS_FILE="/etc/sudoers.d/pinpoint-apply-smtp"

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
# [1/9] Check Prerequisites
##################################################

echo
echo "[1/9] Checking prerequisites..." | tee -a "$LOG"

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
# [2/9] Install nmap
##################################################

echo
echo "[2/9] Installing nmap..." | tee -a "$LOG"

# libcap2-bin provides setcap and getcap; openssh-client
# provides ssh-keygen for the NCPA key.
apt-get install -y nmap libcap2-bin sudo openssh-client >> "$LOG" 2>&1 \
    || fail "Could not install nmap."

if [ ! -x "$NMAP_BIN" ]; then
    fail "$NMAP_BIN not found after installation."
fi

echo "✓ $("$NMAP_BIN" --version | head -n 1) installed." | tee -a "$LOG"

##################################################
# [3/9] Restrict nmap to the Service Account
##################################################

echo
echo "[3/9] Restricting nmap to $APP_USER..." | tee -a "$LOG"

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
# [4/9] Apply nmap Capabilities
##################################################

echo
echo "[4/9] Applying nmap capabilities..." | tee -a "$LOG"

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
# [5/9] Install nmap Wrapper
##################################################

echo
echo "[5/9] Installing $NMAP_WRAPPER..." | tee -a "$LOG"

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
# [6/9] Grant Nagios Configuration Access
##################################################

echo
echo "[6/9] Granting Nagios configuration access..." | tee -a "$LOG"

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
# [7/9] Create NCPA Deployment Key
##################################################

echo
echo "[7/9] Creating NCPA deployment key..." | tee -a "$LOG"

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
# [8/9] Install Mail Transport
##################################################

echo
echo "[8/9] Installing mail transport..." | tee -a "$LOG"

# Nagios' notify-*-by-email commands pipe each message to
# /bin/mail. bsd-mailx provides it and msmtp-mta delivers it
# (a send-only client: no daemon, nothing listens on port 25).
# mailutils is avoided on purpose: it can pull in Postfix.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    msmtp-mta bsd-mailx >> "$LOG" 2>&1 \
    || fail "Could not install msmtp-mta and bsd-mailx."

if [ ! -x /bin/mail ]; then
    fail "/bin/mail not found after installation (Nagios calls it)."
fi

echo "✓ msmtp-mta and bsd-mailx installed." | tee -a "$LOG"

# Nagios sends the mail, so it must be able to read the file;
# nobody else may, because it holds the SMTP password. Content
# written earlier by the web interface is kept on a re-run.
if [ ! -f "$MSMTP_CFG" ]; then
    : > "$MSMTP_CFG"
fi

chown root:"$NAGIOS_GROUP" "$MSMTP_CFG"
chmod 640 "$MSMTP_CFG"

echo "✓ $MSMTP_CFG is root:$NAGIOS_GROUP 640." | tee -a "$LOG"

# The web interface runs as an ordinary account and cannot
# write to /etc. This helper does that one job as root. It
# reads one JSON object on stdin (never arguments, which "ps"
# can show), validates every field, and replaces $MSMTP_CFG
# atomically. It never prints the password.
cat > "$SMTP_HELPER" <<'HELPER_EOF'
#!/usr/bin/python3 -I
# Managed by PinPoint Installer.
# Writes /etc/msmtprc from settings sent by the PinPoint web
# interface. Input: one JSON object on stdin:
#   {"host": str, "port": int, "tls": "starttls",
#    "username": str, "password": str, "sender": str}
# Exit 0 on success, 1 for rejected input, 2 for misuse.
# Messages go to stderr and never contain the password.

import grp
import json
import os
import re
import sys

CONFIG = "/etc/msmtprc"
OWNER_GROUP = "nagios"
MAX_INPUT = 4096

FIELDS = {"host", "port", "tls", "username", "password", "sender"}
# Encryption is mandatory: the login is always sent, so a plain
# connection would expose the password.
TLS_MODES = {"starttls"}

HOST_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
# Any printable ASCII character, spaces included, so the admin can
# choose a password freely. No control characters: a line break
# would end the config line and let a value start another one.
# The value is always written inside double quotes; msmtp removes
# exactly the outer pair and keeps everything inside as typed
# (checked for spaces, "#", quotes and backslashes).
PRINTABLE_RE = re.compile(r"[ -~]+")


def reject(message):
    print("pinpoint-apply-smtp: " + message, file=sys.stderr)
    sys.exit(1)


def pairs(items):
    keys = [key for key, _ in items]
    if len(keys) != len(set(keys)):
        reject("duplicate field in input.")
    return dict(items)


def text(data, name, limit):
    value = data[name]
    if not isinstance(value, str) or not value:
        reject("'%s' must be a non-empty string." % name)
    if len(value) > limit:
        reject("'%s' is too long." % name)
    return value


def main():
    if len(sys.argv) > 1:
        print("pinpoint-apply-smtp: takes no arguments; send JSON on stdin.",
              file=sys.stderr)
        sys.exit(2)

    if os.geteuid() != 0:
        print("pinpoint-apply-smtp: must run as root (use sudo).",
              file=sys.stderr)
        sys.exit(2)

    raw = sys.stdin.buffer.read(MAX_INPUT + 1)
    if len(raw) > MAX_INPUT:
        reject("input is too large.")

    try:
        data = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs)
    except (UnicodeDecodeError, ValueError):
        reject("input is not valid JSON.")

    if not isinstance(data, dict):
        reject("input must be a JSON object.")
    if set(data) != FIELDS:
        reject("fields must be exactly: " + ", ".join(sorted(FIELDS)) + ".")

    host = text(data, "host", 253)
    if not HOST_RE.fullmatch(host):
        reject("'host' is not a valid host name or address.")

    port = data["port"]
    if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
        reject("'port' must be a number from 1 to 65535.")

    tls = text(data, "tls", 16)
    if tls not in TLS_MODES:
        reject("'tls' must be starttls.")

    username = text(data, "username", 254)
    if not PRINTABLE_RE.fullmatch(username):
        reject("'username' may only contain printable characters.")

    password = text(data, "password", 256)
    if not PRINTABLE_RE.fullmatch(password):
        reject("'password' may only contain printable characters "
               "(no line breaks, tabs or other control characters).")

    sender = text(data, "sender", 254)
    if not EMAIL_RE.fullmatch(sender):
        reject("'sender' is not a valid email address.")

    lines = [
        "# Managed by PinPoint. Written by pinpoint-apply-smtp; edits are overwritten.",
        "defaults",
        "auth on",
        "tls_trust_file /etc/ssl/certs/ca-certificates.crt",
        "syslog on",
        "",
        "account pinpoint",
        "host " + host,
        "port %d" % port,
        "tls on",
        "tls_starttls on",
        "from " + sender,
        'user "' + username + '"',
        'password "' + password + '"',
        "",
        "account default : pinpoint",
        "",
    ]

    gid = grp.getgrnam(OWNER_GROUP).gr_gid
    temp = CONFIG + ".tmp"

    # Replace atomically: a crash leaves the old file or the new
    # one, never half of either. The temp file is created with the
    # final owner and mode, so the password is never exposed.
    try:
        os.unlink(temp)
    except FileNotFoundError:
        pass

    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
    try:
        os.fchown(fd, 0, gid)
        os.fchmod(fd, 0o640)
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            handle.write("\n".join(lines))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, CONFIG)
    except BaseException:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass
        raise


main()
HELPER_EOF

chown root:root "$SMTP_HELPER"
chmod 755 "$SMTP_HELPER"

echo "✓ $SMTP_HELPER installed." | tee -a "$LOG"

# Only this exact command. The empty string "" means it may
# be run with no arguments at all.
SMTP_SUDOERS_TMP="$(mktemp)"

cat > "$SMTP_SUDOERS_TMP" <<EOF
# Managed by PinPoint Installer.
# Lets the PinPoint web interface apply validated SMTP settings.
$APP_USER ALL=(root) NOPASSWD: $SMTP_HELPER ""
EOF

if ! visudo -cf "$SMTP_SUDOERS_TMP" >> "$LOG" 2>&1; then
    rm -f "$SMTP_SUDOERS_TMP"
    fail "Generated SMTP sudoers rule is invalid."
fi

install -m 440 -o root -g root "$SMTP_SUDOERS_TMP" "$SMTP_SUDOERS_FILE"
rm -f "$SMTP_SUDOERS_TMP"

echo "✓ $APP_USER may run $SMTP_HELPER only." | tee -a "$LOG"

##################################################
# [9/9] Verify Privileges
##################################################

echo
echo "[9/9] Verifying privileges..." | tee -a "$LOG"

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

# Mail transport: Nagios must find "mail", read the msmtp
# settings, and be the only account besides root that can.
if ! runuser -u nagios -- test -x /bin/mail; then
    fail "nagios cannot run /bin/mail."
fi

if ! runuser -u nagios -- test -r "$MSMTP_CFG"; then
    fail "nagios cannot read $MSMTP_CFG."
fi

if [ "$(stat -c '%U:%G %a' "$MSMTP_CFG")" != "root:$NAGIOS_GROUP 640" ]; then
    fail "$MSMTP_CFG must be root:$NAGIOS_GROUP 640."
fi

if runuser -u nobody -- test -r "$MSMTP_CFG"; then
    fail "$MSMTP_CFG can be read by accounts other than root and $NAGIOS_GROUP."
fi

if runuser -u "$APP_USER" -- test -w "$MSMTP_CFG"; then
    fail "$APP_USER can write $MSMTP_CFG directly."
fi

if dpkg -s postfix > /dev/null 2>&1 || dpkg -s mailutils > /dev/null 2>&1; then
    fail "postfix or mailutils is installed; only a send-only msmtp transport is expected."
fi

if ss -ltn | grep -q ':25 '; then
    fail "A service is listening on port 25; no mail server should run."
fi

if [ "$(stat -c '%U:%G %a' "$SMTP_HELPER")" != "root:root 755" ]; then
    fail "$SMTP_HELPER must be root:root 755."
fi

if ! runuser -u "$APP_USER" -- sudo -n -l "$SMTP_HELPER" > /dev/null 2>&1; then
    fail "$APP_USER cannot run $SMTP_HELPER through sudo."
fi

if runuser -u "$APP_USER" -- sudo -n -l /bin/cat > /dev/null 2>&1; then
    fail "$APP_USER has more sudo rights than the SMTP helper and Nagios reload."
fi

echo "✓ Mail transport ready; $APP_USER can run $SMTP_HELPER and nothing else new." | tee -a "$LOG"

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
