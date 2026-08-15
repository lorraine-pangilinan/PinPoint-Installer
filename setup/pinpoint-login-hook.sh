#!/bin/bash

MARKER="/var/lib/pinpoint/web-auth-pending"
AUTH_SCRIPT="/usr/local/bin/pinpoint-web-auth"

# Only run for interactive shells
case "$-" in
    *i*) ;;
    *) exit 0 ;;
esac

# Initial web authentication already completed
if [ ! -f "$MARKER" ]; then
    return 0 2>/dev/null || exit 0
fi

# Authentication script is not available
if [ ! -x "$AUTH_SCRIPT" ]; then
    echo
    echo "WARNING: PinPoint web authentication setup is unavailable."
    echo "Expected: $AUTH_SCRIPT"
    echo
    return 0 2>/dev/null || exit 0
fi

echo
echo "=========================================="
echo " PinPoint Initial Web Authentication"
echo "=========================================="
echo
echo "PinPoint installation is complete."
echo "Please create the temporary credentials"
echo "for the Nagios Web Interface."
echo

sudo "$AUTH_SCRIPT"

RESULT=$?

if [ "$RESULT" -eq 0 ] && [ ! -f "$MARKER" ]; then
    echo
    echo "=========================================="
    echo " Initial Web Setup Complete"
    echo "=========================================="
    echo
    echo "Nagios Web Interface:"
    echo "http://$(hostname -I | awk '{print $1}')/nagios/"
    echo
    read -rp "Press Enter to continue to the shell..."
    echo
else
    echo
    echo "Web authentication setup was not completed."
    echo "It will be offered again at the next login."
    echo
fi
