#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : pinpoint-web-credentials.sh
# Purpose: Show the generated PinPoint web
#          administrator credentials once, then
#          remove them after the administrator
#          confirms they have been recorded.
##################################################

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run with administrator privileges."
    exit 1
fi

CREDENTIALS_FILE="/root/pinpoint-install-credentials.txt"
MARKER="/var/lib/pinpoint/web-credentials-pending"

if [ ! -f "$CREDENTIALS_FILE" ]; then
    echo
    echo "No PinPoint installation credentials are stored."
    echo "They were already removed after first login."
    echo
    rm -f "$MARKER"
    exit 0
fi

echo
echo "=========================================="
echo " PinPoint Web Administrator"
echo "=========================================="
echo

cat "$CREDENTIALS_FILE"

echo
echo "=========================================="
echo
echo "Record these credentials now."
echo "They will not be shown again once removed."
echo

read -rp "Have you recorded the credentials? Type YES to remove them: " CONFIRM

if [ "$CONFIRM" = "YES" ]; then

    shred -u "$CREDENTIALS_FILE" 2>/dev/null || rm -f "$CREDENTIALS_FILE"
    rm -f "$MARKER"

    echo
    echo "✓ Installation credentials removed."
    echo

else

    echo
    echo "Credentials kept. They will be shown again at the next login."
    echo "To view them manually, run: sudo pinpoint-web-credentials"
    echo

fi

exit 0
