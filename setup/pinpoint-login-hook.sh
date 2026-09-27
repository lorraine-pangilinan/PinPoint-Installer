#!/bin/bash

# Sourced from /etc/profile.d, so use "return" rather than
# "exit": exit would end the login shell itself.

MARKER="/var/lib/pinpoint/web-credentials-pending"
CREDENTIALS_SCRIPT="/usr/local/bin/pinpoint-web-credentials"

# Only run for interactive shells
case "$-" in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

# Credentials already recorded and removed
if [ ! -f "$MARKER" ]; then
    return 0 2>/dev/null || exit 0
fi

# Credentials script is not available
if [ ! -x "$CREDENTIALS_SCRIPT" ]; then
    echo
    echo "WARNING: PinPoint credentials viewer is unavailable."
    echo "Expected: $CREDENTIALS_SCRIPT"
    echo
    return 0 2>/dev/null || exit 0
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
fi
