#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : configure-journald-logs.sh
# Purpose: Keep log growth from filling the disk:
#            - a size and age limit for the systemd
#              journal (drop-in file)
#            - weekly rotation of the installer logs
#              /var/log/pinpoint-*.log
#
# Safe to run again. A file that was edited by an
# administrator (it no longer starts with the
# "Managed by PinPoint Installer" line) is never
# overwritten; the script says so and leaves it.
##################################################

set -e

LOG="/var/log/pinpoint-logs-setup.log"

MANAGED_MARK="# Managed by PinPoint Installer."

JOURNALD_DROPIN_DIR="/etc/systemd/journald.conf.d"
JOURNALD_DROPIN="$JOURNALD_DROPIN_DIR/pinpoint.conf"
JOURNAL_MAX_USE="200M"
JOURNAL_MAX_RETENTION="30day"

LOGROTATE_FILE="/etc/logrotate.d/pinpoint"

##################################################
# Helpers
##################################################

fail() {
    echo "ERROR: $1" | tee -a "$LOG"
    echo "Check $LOG for details." | tee -a "$LOG"
    exit 1
}

# install_managed TEMP DEST MODE
# Returns 0 when DEST was written or already current,
# 2 when DEST belongs to an administrator and was kept.
install_managed() {
    local tmp="$1" dest="$2" mode="$3"

    if [ -e "$dest" ] && ! head -n 1 "$dest" | grep -qxF "$MANAGED_MARK"; then
        return 2
    fi

    if [ -e "$dest" ] && cmp -s "$tmp" "$dest"; then
        return 0
    fi

    install -m "$mode" -o root -g root "$tmp" "$dest"
    CHANGED=1
    return 0
}

# Prints the administrator files (journald.conf and drop-ins under /etc and
# /run, not PinPoint's own) that set SystemMaxUse or MaxRetentionSec.
# Vendor files under /usr/lib are not an administrator's choice.
admin_journal_limits() {
    local file found=""
    for file in /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf /run/systemd/journald.conf.d/*.conf; do
        [ "$file" = "$JOURNALD_DROPIN" ] && continue
        [ -f "$file" ] || continue
        if grep -Eq '^[[:space:]]*(SystemMaxUse|MaxRetentionSec)[[:space:]]*=' "$file"; then
            found="${found:+$found, }$file"
        fi
    done
    echo "$found"
}

##################################################
# Root Check
##################################################

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "======================================" | tee -a "$LOG"
echo " PinPoint - Configuring Log Limits" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

##################################################
# [1/3] Journal Size Limit
##################################################

echo
echo "[1/3] Limiting the systemd journal..." | tee -a "$LOG"

mkdir -p "$JOURNALD_DROPIN_DIR"

JOURNALD_TMP="$(mktemp)"

cat > "$JOURNALD_TMP" <<EOT
$MANAGED_MARK
# Caps journal disk use. Edit this file and remove the line above to keep
# your own values across installer runs.
[Journal]
SystemMaxUse=$JOURNAL_MAX_USE
MaxRetentionSec=$JOURNAL_MAX_RETENTION
EOT

CHANGED=0
RC=0
ADMIN_LIMITS="$(admin_journal_limits)"

if [ -n "$ADMIN_LIMITS" ]; then
    # An administrator set the limits elsewhere. Our drop-in would override
    # journald.conf, so step aside: remove it if it is still ours.
    rm -f "$JOURNALD_TMP"
    if [ -e "$JOURNALD_DROPIN" ] && head -n 1 "$JOURNALD_DROPIN" | grep -qxF "$MANAGED_MARK"; then
        rm -f "$JOURNALD_DROPIN"
        systemctl restart systemd-journald >> "$LOG" 2>&1 \
            || fail "Could not restart systemd-journald."
    fi
    RC=3
else
    install_managed "$JOURNALD_TMP" "$JOURNALD_DROPIN" 644 || RC=$?
    rm -f "$JOURNALD_TMP"
fi

if [ "$RC" -eq 3 ]; then
    echo "✓ Journal limits set by an administrator in $ADMIN_LIMITS; PinPoint's defaults not applied." | tee -a "$LOG"
elif [ "$RC" -eq 2 ]; then
    echo "✓ $JOURNALD_DROPIN was edited by an administrator; left unchanged." | tee -a "$LOG"
else
    if [ "$CHANGED" = "1" ]; then
        systemctl restart systemd-journald >> "$LOG" 2>&1 \
            || fail "Could not restart systemd-journald."
    fi

    echo "✓ Journal limited to $JOURNAL_MAX_USE and $JOURNAL_MAX_RETENTION." | tee -a "$LOG"
fi

##################################################
# [2/3] Rotate the Installer Logs
##################################################

echo
echo "[2/3] Rotating /var/log/pinpoint-*.log..." | tee -a "$LOG"

if ! command -v logrotate > /dev/null 2>&1; then
    apt-get install -y logrotate >> "$LOG" 2>&1 || fail "Could not install logrotate."
fi

mkdir -p "$(dirname "$LOGROTATE_FILE")"

LOGROTATE_TMP="$(mktemp)"

# su root root: /var/log is group-writable on Ubuntu, and logrotate
# skips the files without it. copytruncate: the installer scripts append to these files with
# "tee -a" and never reopen them.
cat > "$LOGROTATE_TMP" <<EOT
$MANAGED_MARK
/var/log/pinpoint-*.log {
    su root root
    weekly
    rotate 8
    maxsize 20M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOT

if ! logrotate -d "$LOGROTATE_TMP" >> "$LOG" 2>&1; then
    rm -f "$LOGROTATE_TMP"
    fail "Generated logrotate rule is invalid."
fi

RC=0
install_managed "$LOGROTATE_TMP" "$LOGROTATE_FILE" 644 || RC=$?
rm -f "$LOGROTATE_TMP"

if [ "$RC" -eq 2 ]; then
    echo "✓ $LOGROTATE_FILE was edited by an administrator; left unchanged." | tee -a "$LOG"
else
    echo "✓ Installer logs rotate weekly, 8 kept, compressed." | tee -a "$LOG"
fi

##################################################
# [3/3] Verify
##################################################

echo
echo "[3/3] Verifying..." | tee -a "$LOG"

if { [ -f "$JOURNALD_DROPIN" ] || [ -n "$ADMIN_LIMITS" ]; } && [ -f "$LOGROTATE_FILE" ]; then
    echo "✓ Journal usage: $(journalctl --disk-usage 2> /dev/null | sed 's/^Archived and active journals take up //')" | tee -a "$LOG"
else
    fail "A log limit file is missing."
fi

echo
echo "======================================" | tee -a "$LOG"
echo " Log limits setup completed."
echo "======================================" | tee -a "$LOG"
