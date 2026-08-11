#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : install-nagios-plugins.sh
# Purpose: Download, compile and install
#          Nagios Plugins 2.4.12
##################################################

set -e

LOG="/var/log/pinpoint-plugins.log"

PLUGIN_VERSION="2.4.12"
PLUGIN_ARCHIVE="nagios-plugins-${PLUGIN_VERSION}.tar.gz"
PLUGIN_FOLDER="nagios-plugins-${PLUGIN_VERSION}"
DOWNLOAD_URL="https://nagios-plugins.org/download/${PLUGIN_ARCHIVE}"

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
echo " PinPoint - Installing Nagios Plugins" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

########################################
# [1/7] Prepare Source Directory
########################################

echo
echo "[1/7] Preparing source directory..." | tee -a "$LOG"

cd /usr/local/src

########################################
# [2/7] Download Plugins
########################################

echo
echo "[2/7] Downloading Nagios Plugins..." | tee -a "$LOG"

if [ ! -f "$PLUGIN_ARCHIVE" ]; then
    wget "$DOWNLOAD_URL"
    echo "✓ Download completed." | tee -a "$LOG"
else
    echo "✓ Archive already exists." | tee -a "$LOG"
fi

########################################
# [3/7] Extract Source
########################################

echo
echo "[3/7] Extracting source..." | tee -a "$LOG"

rm -rf "$PLUGIN_FOLDER"

tar -xzf "$PLUGIN_ARCHIVE"

cd "$PLUGIN_FOLDER"

echo "✓ Source extracted." | tee -a "$LOG"

########################################
# [4/7] Configure Plugins
########################################

echo
echo "[4/7] Configuring plugins..." | tee -a "$LOG"

./configure \
    --with-nagios-user=nagios \
    --with-nagios-group=nagios

echo "✓ Configure completed." | tee -a "$LOG"

########################################
# [5/7] Compile Plugins
########################################

echo
echo "[5/7] Compiling plugins..." | tee -a "$LOG"

make

echo "✓ Compilation completed." | tee -a "$LOG"

########################################
# [6/7] Install Plugins
########################################

echo
echo "[6/7] Installing plugins..." | tee -a "$LOG"

make install

echo "✓ Plugins installed." | tee -a "$LOG"

########################################
# [7/7] Verify Installation
########################################

echo
echo "[7/7] Verifying installation..." | tee -a "$LOG"

if [ -f /usr/local/nagios/libexec/check_ping ]; then
    echo "✓ Nagios Plugins verified." | tee -a "$LOG"
else
    echo "✗ Nagios Plugins installation failed." | tee -a "$LOG"
    exit 1
fi

########################################
# Footer
########################################

echo
echo "======================================" | tee -a "$LOG"
echo " Nagios Plugins installation completed." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
