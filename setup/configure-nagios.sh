#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : configure-nagios.sh
# Purpose: Configure Nagios Core and Apache
##################################################

set -e

LOG="/var/log/pinpoint-configure.log"

########################################
# Root Check
########################################

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

########################################
# Header
########################################

echo "======================================" | tee -a "$LOG"
echo " PinPoint - Configuring Nagios" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

########################################
# [1/7] Verify Source
########################################

echo
echo "[1/7] Checking Nagios source..." | tee -a "$LOG"

if [ ! -d /usr/local/src/nagios-4.5.11 ]; then
    echo "ERROR: Nagios source not found." | tee -a "$LOG"
    exit 1
fi

cd /usr/local/src/nagios-4.5.11

########################################
# [2/7] Install Init Scripts
########################################

echo
echo "[2/7] Installing init scripts..." | tee -a "$LOG"

make install-init

echo "✓ Init scripts installed." | tee -a "$LOG"

########################################
# [3/7] Install Command Mode
########################################

echo
echo "[3/7] Installing command mode..." | tee -a "$LOG"

make install-commandmode

echo "✓ Command mode installed." | tee -a "$LOG"

########################################
# [4/7] Install Configuration
########################################

echo
echo "[4/7] Installing sample configuration..." | tee -a "$LOG"

make install-config

echo "✓ Configuration installed." | tee -a "$LOG"

########################################
# [5/7] Install Apache Configuration
########################################

echo
echo "[5/7] Installing Apache configuration..." | tee -a "$LOG"

make install-webconf

a2enmod cgi

echo "✓ Apache configured." | tee -a "$LOG"

########################################
# [6/7] Restart Services
########################################

echo
echo "[6/7] Restarting services..." | tee -a "$LOG"

systemctl restart apache2
systemctl restart nagios

echo "✓ Services restarted." | tee -a "$LOG"

########################################
# [7/7] Verify Installation
########################################

echo
echo "[7/7] Verifying Nagios..." | tee -a "$LOG"

if /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg; then
    echo "✓ Nagios configuration is valid." | tee -a "$LOG"
else
    echo "✗ Nagios configuration check failed." | tee -a "$LOG"
    exit 1
fi

########################################
# Footer
########################################

echo
echo "======================================" | tee -a "$LOG"
echo " Nagios configuration completed." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
