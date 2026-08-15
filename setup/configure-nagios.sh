#!/bin/bash

##################################################
# PinPoint Installer Module
# Module: configure-nagios.sh
# Purpose: Configure Nagios Core and Apache
##################################################

set -e

LOG="/var/log/pinpoint-configure.log"

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
# [1/7] Verify Nagios Installation
##################################################

echo
echo "[1/7] Verifying Nagios installation..." | tee -a "$LOG"

if [ ! -x /usr/local/nagios/bin/nagios ]; then
    echo "ERROR: Nagios Core is not installed." | tee -a "$LOG"
    exit 1
fi

echo "✓ Nagios Core found." | tee -a "$LOG"

##################################################
# [2/7] Install Nagios Configuration
##################################################

echo
echo "[2/7] Installing Nagios configuration..." | tee -a "$LOG"

cd /usr/local/src/nagios-4.5.11

make install-config

echo "✓ Nagios configuration installed." | tee -a "$LOG"

##################################################
# [3/7] Install Apache Configuration
##################################################

echo
echo "[3/7] Installing Apache configuration..." | tee -a "$LOG"

make install-webconf

a2enmod cgi

echo "✓ Apache configuration installed." | tee -a "$LOG"

##################################################
# [4/7] Validate Nagios Configuration
##################################################

echo
echo "[4/7] Validating Nagios configuration..." | tee -a "$LOG"

if /usr/local/nagios/bin/nagios \
    -v /usr/local/nagios/etc/nagios.cfg \
    >> "$LOG" 2>&1; then

    echo "✓ Nagios configuration is valid." | tee -a "$LOG"

else

    echo "ERROR: Nagios configuration validation failed." | tee -a "$LOG"
    echo "Check $LOG for details." | tee -a "$LOG"
    exit 1

fi

##################################################
# [5/7] Enable and Restart Services
##################################################

echo
echo "[5/7] Enabling and restarting services..." | tee -a "$LOG"

systemctl enable apache2
systemctl enable nagios

systemctl restart apache2
echo "✓ Apache restarted." | tee -a "$LOG"

systemctl restart nagios
echo "✓ Nagios restarted." | tee -a "$LOG"

##################################################
# [6/7] Verify Services and Web Interface
##################################################

echo
echo "[6/7] Verifying services and web interface..." | tee -a "$LOG"

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

HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/nagios/ || true)"

if [ "$HTTP_STATUS" = "401" ]; then
    echo "✓ Nagios web interface is responding." | tee -a "$LOG"
elif [ "$HTTP_STATUS" = "200" ]; then
    echo "✓ Nagios web interface is responding." | tee -a "$LOG"
else
    echo "WARNING: Nagios web interface returned HTTP $HTTP_STATUS." | tee -a "$LOG"
fi

##################################################
# Footer
##################################################

echo
echo "======================================" | tee -a "$LOG"
echo " Nagios configuration completed." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
