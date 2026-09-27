#!/bin/bash

##################################################
# PinPoint Installer Module
# Module: configure-nagios.sh
# Purpose: Configure Nagios Core and Apache
#
# Apache (Nagios web/CGI) listens on localhost only.
# Port 80 is left free for Nginx, which serves the
# PinPoint web interface. PinPoint reads Nagios data
# through the JSON CGIs using the pinpoint-api account.
##################################################

set -e

LOG="/var/log/pinpoint-configure.log"

NAGIOS_BIND="127.0.0.1:8081"
NAGIOS_URL="http://$NAGIOS_BIND/nagios"

HTPASSWD="/usr/local/nagios/etc/htpasswd.users"
CGI_CFG="/usr/local/nagios/etc/cgi.cfg"

API_USER="pinpoint-api"
PINPOINT_ETC="/etc/pinpoint"
API_CREDENTIALS="$PINPOINT_ETC/nagios-api.env"

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
echo " PinPoint - Configuring Nagios" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

##################################################
# [1/8] Verify Nagios Installation
##################################################

echo
echo "[1/8] Verifying Nagios installation..." | tee -a "$LOG"

if [ ! -x /usr/local/nagios/bin/nagios ]; then
    echo "ERROR: Nagios Core is not installed." | tee -a "$LOG"
    exit 1
fi

echo "✓ Nagios Core found." | tee -a "$LOG"

##################################################
# [2/8] Install Nagios Configuration
##################################################

echo
echo "[2/8] Installing Nagios configuration..." | tee -a "$LOG"

cd /usr/local/src/nagios-4.5.11

make install-config

echo "✓ Nagios configuration installed." | tee -a "$LOG"

##################################################
# [3/8] Install Apache Configuration
##################################################

echo
echo "[3/8] Installing Apache configuration..." | tee -a "$LOG"

make install-webconf

a2enmod cgi

# Move Apache off port 80 and bind it to localhost only.
if [ -f /etc/apache2/ports.conf ] && \
   [ ! -f /etc/apache2/ports.conf.backup ]; then

    cp /etc/apache2/ports.conf \
       /etc/apache2/ports.conf.backup

fi

cat > /etc/apache2/ports.conf <<EOF
# Managed by PinPoint Installer.
# Apache serves the Nagios CGIs to localhost only.
# Port 80 belongs to Nginx (PinPoint web interface).
Listen $NAGIOS_BIND
EOF

a2dissite 000-default

# Silence the AH00558 "could not determine ServerName" warning.
echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf
a2enconf servername

echo "✓ Apache configuration installed." | tee -a "$LOG"
echo "✓ Apache bound to $NAGIOS_BIND." | tee -a "$LOG"

##################################################
# [4/8] Create PinPoint API Account
##################################################

echo
echo "[4/8] Creating PinPoint Nagios API account..." | tee -a "$LOG"

mkdir -p "$PINPOINT_ETC"
chmod 755 "$PINPOINT_ETC"

# Reuse an existing password so re-running this module
# does not break a deployed PinPoint application.
if [ -f "$API_CREDENTIALS" ]; then

    API_PASSWORD="$(sed -n 's/^NAGIOS_PASSWORD=//p' "$API_CREDENTIALS")"

fi

if [ -z "$API_PASSWORD" ]; then

    API_PASSWORD="$(openssl rand -hex 24)"

fi

cat > "$API_CREDENTIALS" <<EOF
NAGIOS_USERNAME=$API_USER
NAGIOS_PASSWORD=$API_PASSWORD
EOF

chown root:root "$API_CREDENTIALS"
chmod 600 "$API_CREDENTIALS"

# Only create a new htpasswd file if none exists,
# so other accounts in the file are kept.
if [ -f "$HTPASSWD" ]; then
    HTPASSWD_CREATE=""
else
    HTPASSWD_CREATE="-c"
fi

printf '%s\n' "$API_PASSWORD" | htpasswd $HTPASSWD_CREATE -i "$HTPASSWD" "$API_USER"

chown root:www-data "$HTPASSWD"
chmod 640 "$HTPASSWD"

echo "✓ Account $API_USER created." | tee -a "$LOG"
echo "✓ Credentials saved to $API_CREDENTIALS." | tee -a "$LOG"

##################################################
# [5/8] Authorize PinPoint API Account
##################################################

echo
echo "[5/8] Authorizing $API_USER in cgi.cfg..." | tee -a "$LOG"

# Read-only access needed by statusjson, objectjson
# and archivejson. No command permissions are granted.
for KEY in \
    authorized_for_system_information \
    authorized_for_configuration_information \
    authorized_for_all_hosts \
    authorized_for_all_services; do

    if grep -q "^$KEY=.*\b$API_USER\b" "$CGI_CFG"; then
        continue
    fi

    if grep -q "^$KEY=" "$CGI_CFG"; then
        sed -i "s/^$KEY=.*/&,$API_USER/" "$CGI_CFG"
    else
        echo "$KEY=$API_USER" >> "$CGI_CFG"
    fi

done

echo "✓ $API_USER authorized for read-only access." | tee -a "$LOG"

##################################################
# [6/8] Validate Nagios Configuration
##################################################

echo
echo "[6/8] Validating Nagios configuration..." | tee -a "$LOG"

if /usr/local/nagios/bin/nagios \
    -v /usr/local/nagios/etc/nagios.cfg \
    >> "$LOG" 2>&1; then

    echo "✓ Nagios configuration is valid." | tee -a "$LOG"

else

    echo "ERROR: Nagios configuration validation failed." | tee -a "$LOG"
    echo "Check $LOG for details." | tee -a "$LOG"
    exit 1

fi

if apache2ctl configtest >> "$LOG" 2>&1; then

    echo "✓ Apache configuration is valid." | tee -a "$LOG"

else

    echo "ERROR: Apache configuration validation failed." | tee -a "$LOG"
    echo "Check $LOG for details." | tee -a "$LOG"
    exit 1

fi

##################################################
# [7/8] Enable and Restart Services
##################################################

echo
echo "[7/8] Enabling and restarting services..." | tee -a "$LOG"

systemctl enable apache2
systemctl enable nagios

systemctl restart apache2
echo "✓ Apache restarted." | tee -a "$LOG"

systemctl restart nagios
echo "✓ Nagios restarted." | tee -a "$LOG"

##################################################
# [8/8] Verify Services and Web Interface
##################################################

echo
echo "[8/8] Verifying services and web interface..." | tee -a "$LOG"

if systemctl is-active --quiet apache2; then
    echo "✓ Apache is running." | tee -a "$LOG"
else
    echo "ERROR: Apache is not running." | tee -a "$LOG"
    exit 1
fi

if systemctl is-active --quiet nagios; then
    echo "✓ Nagios is running." | tee -a "$LOG"
else
    echo "ERROR: Nagios is not running." | tee -a "$LOG"
    exit 1
fi

# Nginx may already own port 80 when this module is re-run;
# only Apache holding it is an error.
if ss -ltnpH 'sport = :80' | grep -q '"apache2"'; then
    echo "ERROR: Apache is still using port 80. It must be free for Nginx." | tee -a "$LOG"
    ss -ltnp 'sport = :80' >> "$LOG" 2>&1 || true
    exit 1
fi

echo "✓ Apache is not using port 80." | tee -a "$LOG"

HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" "$NAGIOS_URL/" || true)"

if [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "200" ]; then
    echo "✓ Nagios web interface is responding on $NAGIOS_BIND." | tee -a "$LOG"
else
    echo "ERROR: Nagios web interface returned HTTP $HTTP_STATUS." | tee -a "$LOG"
    exit 1
fi

# Credentials are passed on stdin so the password
# never appears in the process list or the log.
# Nagios needs a few seconds after restart to write
# status.dat, so retry before failing.
API_OK=0

for ATTEMPT in 1 2 3 4 5 6; do

    API_RESPONSE="$(printf 'user = "%s:%s"\n' "$API_USER" "$API_PASSWORD" \
        | curl -s -K - "$NAGIOS_URL/cgi-bin/statusjson.cgi?query=programstatus" || true)"

    if printf '%s' "$API_RESPONSE" | grep -Eq '"type_code":[[:space:]]*0'; then
        API_OK=1
        break
    fi

    sleep 5

done

if [ "$API_OK" = "1" ]; then
    echo "✓ $API_USER can read the Nagios status API." | tee -a "$LOG"
else
    echo "ERROR: $API_USER could not read the Nagios status API." | tee -a "$LOG"
    exit 1
fi

unset API_PASSWORD
unset API_RESPONSE

##################################################
# Footer
##################################################

echo
echo "======================================" | tee -a "$LOG"
echo " Nagios configuration completed." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
