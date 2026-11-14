#!/bin/bash

# Sourced from /etc/profile.d, so use "return" rather than
# "exit": exit would end the login shell itself.

MARKER="/var/lib/pinpoint/web-credentials-pending"
CREDENTIALS_SCRIPT="/usr/local/bin/pinpoint-web-credentials"
UPDATE_MENU_MARKER="/var/lib/pinpoint/update-menu-pending"
UPDATE_PROGRAM="/usr/local/sbin/pinpoint-update"
# Written by pinpoint-update: update available, scheduled,
# running or failed. World-readable; holds no secrets.
UPDATE_NOTICE="/var/lib/pinpoint/update-notice"

# Only run for interactive shells
case "$-" in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

# Show the generated web credentials once. Returns 1 while
# they are still pending, so the update menu waits for them.
pinpoint_login_credentials() {
    # Credentials already recorded and removed
    if [ ! -f "$MARKER" ]; then
        return 0
    fi

    # Credentials script is not available
    if [ ! -x "$CREDENTIALS_SCRIPT" ]; then
        echo
        echo "WARNING: PinPoint credentials viewer is unavailable."
        echo "Expected: $CREDENTIALS_SCRIPT"
        echo
        return 1
    fi

    echo
    echo "=========================================="
    echo " PinPoint Installation Complete"
    echo "=========================================="
    echo
    echo "The PinPoint web administrator account"
    echo "was generated during installation."

    sudo "$CREDENTIALS_SCRIPT"

    if [ ! -f "$MARKER" ]; then
        read -rp "Press Enter to continue to the shell..."
        echo
        return 0
    fi
    return 1
}

# After a fresh install, open the PinPoint Update Manager
# once, whether or not updates are available. The program
# removes the marker before showing the menu.
pinpoint_login_update_menu() {
    if [ -f "$UPDATE_MENU_MARKER" ] && [ -x "$UPDATE_PROGRAM" ]; then
        sudo "$UPDATE_PROGRAM" --first-login
    fi
}

# Every login: a few lines when an update needs attention.
pinpoint_login_update_notice() {
    if [ -s "$UPDATE_NOTICE" ] && [ ! -f "$UPDATE_MENU_MARKER" ]; then
        echo
        head -n 8 "$UPDATE_NOTICE"
        echo
    fi
}

if pinpoint_login_credentials; then
    pinpoint_login_update_notice
    pinpoint_login_update_menu
fi

unset -f pinpoint_login_credentials pinpoint_login_update_menu pinpoint_login_update_notice
