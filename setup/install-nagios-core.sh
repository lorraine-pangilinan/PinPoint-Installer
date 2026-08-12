#!/bin/bash

##################################################
# PinPoint Installer Module
# Module: install-nagios-core.sh
# Purpose: Download, compile, and install Nagios Core
##################################################

set -e

LOG="/var/log/pinpoint-nagios.log"

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
echo " PinPoint - Installing Nagios Core" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

########################################
# [1/10] Prepare Source Directory
########################################

echo
echo "[1/10] Preparing source directory..." | tee -a "$LOG"

cd /usr/local/src

########################################
# [2/10] Download Nagios Core
########################################

echo
echo "[2/10] Downloading Nagios Core..." | tee -a "$LOG"

if [ ! -f nagios-4.5.11.tar.gz ]; then
    wget https://assets.nagios.com/downloads/nagioscore/releases/nagios-4.5.11.tar.gz
else
    echo "✓ Nagios archive already exists." | tee -a "$LOG"
fi

########################################
# [3/10] Extract Nagios
########################################

echo
echo "[3/10] Extracting Nagios Core..." | tee -a "$LOG"

rm -rf nagios-4.5.11

tar -xzf nagios-4.5.11.tar.gz

cd nagios-4.5.11

echo "✓ Source extracted successfully." | tee -a "$LOG"

########################################
# [4/10] Configure Nagios
########################################

echo
echo "[4/10] Configuring Nagios..." | tee -a "$LOG"

./configure \
    --with-httpd-conf=/etc/apache2/sites-enabled

echo "✓ Configure completed." | tee -a "$LOG"

########################################
# [5/10] Compile Nagios
########################################

echo
echo "[5/10] Compiling Nagios..." | tee -a "$LOG"

make all

echo "✓ Compilation completed." | tee -a "$LOG"

########################################
# [6/10] Install Nagios
########################################

echo
echo "[6/10] Creating Nagios user and group..." | tee -a "$LOG"

make install-groups-users

usermod -a -G nagios www-data

echo "✓ Nagios users created." | tee -a "$LOG"

########################################
# [7/10] Install Nagios User & Groups
########################################

echo
echo "[7/10] Installing Nagios Core..." | tee -a "$LOG"

make install

echo "✓ Nagios installed successfully.." | tee -a "$LOG"

########################################
# [8/10] Install Service Files
########################################

echo
echo "[8/10] Installing Nagios service..." | tee -a "$LOG"

make install-daemoninit

make install-commandmode

echo "✓ Service installed." | tee -a "$LOG"

########################################
# [9/10] Install Configuration
########################################

echo
echo "[9/10] Installing Nagios configuration..." | tee -a "$LOG"

make install-config

make install-webconf

echo "✓ Configuration installed." | tee -a "$LOG"

########################################
# [10/10] Enable and Verify
########################################

echo
echo "[10/10] Enabling Nagios service..." | tee -a "$LOG"

a2enmod cgi

systemctl enable nagios

systemctl restart apache2

systemctl start nagios

echo
echo "Verifying Nagios..." | tee -a "$LOG"

systemctl is-active --quiet nagios

echo "✓ Nagios is running." | tee -a "$LOG"

echo
echo "======================================" | tee -a "$LOG"
echo "Nagios Core installation completed." | tee -a "$LOG"
echo "Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
