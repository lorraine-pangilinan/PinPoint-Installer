#!/bin/bash

##################################################
# PinPoint Installer Module
# Module: install-nagios-core.sh
# Purpose: Download, compile, and install Nagios Core
##################################################

set -e

LOG="/var/log/pinpoint-nagios.log"

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
echo " PinPoint - Installing Nagios Core" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

##################################################
# [1/8] Prepare Source Directory
##################################################

echo
echo "[1/8] Preparing source directory..." | tee -a "$LOG"

mkdir -p /usr/local/src
cd /usr/local/src

##################################################
# [2/8] Download Nagios Core
##################################################

echo
echo "[2/8] Downloading Nagios Core..." | tee -a "$LOG"

if [ ! -f nagios-4.5.11.tar.gz ]; then
    wget https://assets.nagios.com/downloads/nagioscore/releases/nagios-4.5.11.tar.gz
else
    echo "✓ Nagios archive already exists." | tee -a "$LOG"
fi

##################################################
# [3/8] Extract Nagios Core
##################################################

echo
echo "[3/8] Extracting Nagios Core..." | tee -a "$LOG"

rm -rf nagios-4.5.11
tar -xzf nagios-4.5.11.tar.gz

cd nagios-4.5.11

echo "✓ Source extracted successfully." | tee -a "$LOG"

##################################################
# [4/8] Configure Nagios
##################################################

echo
echo "[4/8] Configuring Nagios..." | tee -a "$LOG"

./configure \
    --with-httpd-conf=/etc/apache2/sites-enabled

echo "✓ Configure completed." | tee -a "$LOG"

##################################################
# [5/8] Compile Nagios
##################################################

echo
echo "[5/8] Compiling Nagios..." | tee -a "$LOG"

make all

echo "✓ Compilation completed." | tee -a "$LOG"

##################################################
# [6/8] Create Nagios User and Groups
##################################################

echo
echo "[6/8] Creating Nagios user and group..." | tee -a "$LOG"

make install-groups-users

usermod -a -G nagios www-data

echo "✓ Nagios user and group created." | tee -a "$LOG"
echo "✓ www-data added to nagios group." | tee -a "$LOG"

##################################################
# [7/8] Install Nagios Core and Service
##################################################

echo
echo "[7/8] Installing Nagios Core and service..." | tee -a "$LOG"

make install
make install-daemoninit
make install-commandmode

echo "✓ Nagios Core installed." | tee -a "$LOG"
echo "✓ Nagios service installed." | tee -a "$LOG"
echo "✓ Nagios command mode installed." | tee -a "$LOG"

##################################################
# [8/8] Verify Nagios Core
##################################################

echo
echo "[8/8] Verifying Nagios Core..." | tee -a "$LOG"

if [ ! -x /usr/local/nagios/bin/nagios ]; then
    echo "ERROR: Nagios binary was not installed." | tee -a "$LOG"
    exit 1
fi

/usr/local/nagios/bin/nagios -V | tee -a "$LOG"

echo "✓ Nagios Core verified." | tee -a "$LOG"

##################################################
# Footer
##################################################

echo
echo "======================================" | tee -a "$LOG"
echo " Nagios Core installation completed." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
