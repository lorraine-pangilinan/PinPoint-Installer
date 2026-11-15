#!/bin/bash
# Appliance log policy. Only installer-owned defaults are added or removed;
# administrator files are retained byte for byte. No app input reaches this script.
set -euo pipefail

journal_defaults() {
    cat <<'EOF'
# PinPoint Installer default journal limits (issue 124).
# Administrator edits are preserved by subsequent installer runs.
[Journal]
SystemMaxUse=100M
MaxRetentionSec=7day
EOF
}

rotation_defaults() {
    cat <<'EOF'
# PinPoint Installer logs; the active installer may keep an open descriptor.
/var/log/pinpoint-*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su root root
}
EOF
}

configure_log_retention() {
    # A root prefix is used only by isolated tests which source this function.
    # The executable entry point below accepts no arguments and always uses /.
    local root="${1:-}" directory destination rotation config temp competing=0
    directory="$root/etc/systemd/journald.conf.d"
    destination="$directory/pinpoint.conf"
    rotation="$root/etc/logrotate.d/pinpoint-installer"
    for config in "$root/etc/systemd" "$directory" "$root/etc/logrotate.d" "$destination" "$rotation"; do
        if [ -L "$config" ]; then
            echo 'Log retention: refusing a symlinked managed destination.' >&2
            return 1
        fi
    done
    mkdir -p "$directory" "$root/etc/logrotate.d"
    for config in "$root/etc/systemd/journald.conf" \
        "$root"/{etc,run,usr/local/lib,usr/lib}/systemd/journald.conf.d/*.conf; do
        [ "$config" = "$destination" ] && continue
        if [ -f "$config" ] && grep -Eq '^[[:space:]]*(SystemMaxUse|MaxRetentionSec)[[:space:]]*=' "$config"; then
            competing=1
        fi
    done
    if [ -e "$destination" ] && ! cmp -s "$destination" <(journal_defaults); then
        echo 'Log retention: preserving administrator-edited pinpoint.conf.'
    elif [ "$competing" = 1 ]; then
        # Remove only our exact unedited defaults so they cannot override an
        # administrator's earlier-sorting drop-in or main configuration.
        if [ -f "$destination" ]; then
            rm -- "$destination"
            systemctl restart systemd-journald
        fi
        echo 'Log retention: administrator journal limits take precedence; defaults skipped.'
    else
        if [ ! -e "$destination" ]; then
            temp="$(mktemp "$directory/.pinpoint.XXXXXX")"
            journal_defaults > "$temp"
            chmod 644 "$temp"
            # Hard-link creation refuses to clobber a concurrent new file.
            ln -- "$temp" "$destination" || { rm -f -- "$temp"; return 1; }
            rm -- "$temp"
        fi
        # Reapply on a retry even if a previous restart failed. Configuration
        # bytes are unchanged on repeat runs.
        systemctl restart systemd-journald
    fi
    if [ ! -e "$rotation" ]; then
        temp="$(mktemp "$root/etc/logrotate.d/.pinpoint.XXXXXX")"
        rotation_defaults > "$temp"
        chmod 644 "$temp"
        ln -- "$temp" "$rotation" || { rm -f -- "$temp"; return 1; }
        rm -- "$temp"
    else
        echo 'Log retention: existing installer logrotate rule preserved.'
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "$EUID" -ne 0 ] || [ "$#" -ne 0 ]; then
        echo 'Run configure-log-retention.sh as root with no arguments.' >&2
        exit 1
    fi
    configure_log_retention
fi
