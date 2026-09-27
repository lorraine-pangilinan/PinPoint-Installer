#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : setup-web-auth.sh
# Purpose: Create initial Nagios web credentials
##################################################

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run with administrator privileges."
    exit 1
fi

HTPASSWD="/usr/local/nagios/etc/htpasswd.users"
MARKER="/var/lib/pinpoint/web-auth-pending"

echo
echo "=========================================="
echo " PinPoint Initial Web Authentication"
echo "=========================================="
echo

echo "Create the temporary credentials for the"
echo "Nagios Web Interface."
echo

while true; do

    read -rp "Username: " WEB_USERNAME

    if [ -z "$WEB_USERNAME" ]; then
        echo "ERROR: Username cannot be empty."
        continue
    fi

    read -rsp "Password: " WEB_PASSWORD
    echo

    if [ -z "$WEB_PASSWORD" ]; then
        echo "ERROR: Password cannot be empty."
        continue
    fi

    read -rsp "Confirm password: " WEB_PASSWORD_CONFIRM
    echo

    if [ "$WEB_PASSWORD" != "$WEB_PASSWORD_CONFIRM" ]; then
        echo "ERROR: Passwords do not match."
        echo
        continue
    fi

    break
done

echo
echo "Creating Nagios web authentication..."

# Only create a new file if none exists, so the
# pinpoint-api account is kept.
if [ -f "$HTPASSWD" ]; then
    HTPASSWD_CREATE=""
else
    HTPASSWD_CREATE="-c"
fi

printf '%s\n' "$WEB_PASSWORD" | htpasswd $HTPASSWD_CREATE -i "$HTPASSWD" "$WEB_USERNAME"

chown root:www-data "$HTPASSWD"
chmod 640 "$HTPASSWD"

rm -f "$MARKER"

echo
echo "=========================================="
echo " Web Authentication Configured"
echo "=========================================="
echo
echo "Username: $WEB_USERNAME"
echo
echo "Nagios Web Interface:"
echo "http://$(hostname -I | awk '{print $1}')/nagios/"
echo
echo "=========================================="
echo

unset WEB_PASSWORD
unset WEB_PASSWORD_CONFIRM

exit 0
