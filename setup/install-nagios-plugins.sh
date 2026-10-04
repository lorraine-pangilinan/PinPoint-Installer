#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : install-nagios-plugins.sh
# Purpose: Download, compile and install
#          Nagios Plugins 2.4.12 (incl. check_mysql)
#          and the NCPA check_ncpa.py plugin
##################################################

set -e

LOG="/var/log/pinpoint-plugins.log"

PLUGIN_VERSION="2.4.12"
PLUGIN_ARCHIVE="nagios-plugins-${PLUGIN_VERSION}.tar.gz"
PLUGIN_FOLDER="nagios-plugins-${PLUGIN_VERSION}"
DOWNLOAD_URL="https://nagios-plugins.org/download/${PLUGIN_ARCHIVE}"

LIBEXEC="/usr/local/nagios/libexec"
NCPA_ARCHIVE="check_ncpa.tar.gz"
NCPA_URL="https://assets.nagios.com/downloads/ncpa/${NCPA_ARCHIVE}"

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
# [1/8] Prepare Source Directory
########################################

echo
echo "[1/8] Preparing source directory..." | tee -a "$LOG"

cd /usr/local/src

########################################
# [2/8] Download Plugins
########################################

echo
echo "[2/8] Downloading Nagios Plugins..." | tee -a "$LOG"

if [ ! -f "$PLUGIN_ARCHIVE" ]; then
    wget "$DOWNLOAD_URL"
    echo "✓ Download completed." | tee -a "$LOG"
else
    echo "✓ Archive already exists." | tee -a "$LOG"
fi

########################################
# [3/8] Extract Source
########################################

echo
echo "[3/8] Extracting source..." | tee -a "$LOG"

rm -rf "$PLUGIN_FOLDER"

tar -xzf "$PLUGIN_ARCHIVE"

cd "$PLUGIN_FOLDER"

echo "✓ Source extracted." | tee -a "$LOG"

########################################
# [4/8] Configure Plugins
########################################

echo
echo "[4/8] Configuring plugins..." | tee -a "$LOG"

./configure \
    --with-nagios-user=nagios \
    --with-nagios-group=nagios

echo "✓ Configure completed." | tee -a "$LOG"

########################################
# [5/8] Compile Plugins
########################################

echo
echo "[5/8] Compiling plugins..." | tee -a "$LOG"

make

echo "✓ Compilation completed." | tee -a "$LOG"

########################################
# [6/8] Install Plugins
########################################

echo
echo "[6/8] Installing plugins..." | tee -a "$LOG"

make install

echo "✓ Plugins installed." | tee -a "$LOG"

########################################
# [7/8] Install NCPA Plugin (check_ncpa.py)
########################################

echo
echo "[7/8] Installing NCPA plugin..." | tee -a "$LOG"

cd /usr/local/src

# Always fetch the current release (not pinned)
rm -rf "$NCPA_ARCHIVE" check_ncpa
wget -O "$NCPA_ARCHIVE" "$NCPA_URL"

mkdir -p check_ncpa
tar -xzf "$NCPA_ARCHIVE" -C check_ncpa

NCPA_PLUGIN="$(find check_ncpa -type f -name 'check_ncpa.py' | head -n 1)"

if [ -z "$NCPA_PLUGIN" ]; then
    echo "✗ check_ncpa.py not found in $NCPA_ARCHIVE." | tee -a "$LOG"
    exit 1
fi

install -o nagios -g nagios -m 0755 "$NCPA_PLUGIN" "$LIBEXEC/check_ncpa.py"

echo "✓ check_ncpa.py installed." | tee -a "$LOG"

########################################
# [8/8] Verify Installation
########################################

echo
echo "[8/8] Verifying installation..." | tee -a "$LOG"

if [ -f "$LIBEXEC/check_ping" ]; then
    echo "✓ Nagios Plugins verified." | tee -a "$LOG"
else
    echo "✗ Nagios Plugins installation failed." | tee -a "$LOG"
    exit 1
fi

if [ -x "$LIBEXEC/check_mysql" ]; then
    echo "✓ check_mysql verified." | tee -a "$LOG"
else
    echo "✗ check_mysql was not built (MariaDB client headers missing?)." | tee -a "$LOG"
    echo "  Install libmariadb-dev and re-run." | tee -a "$LOG"
    exit 1
fi

if python3 "$LIBEXEC/check_ncpa.py" --help >/dev/null 2>&1; then
    echo "✓ check_ncpa.py verified." | tee -a "$LOG"
else
    echo "✗ check_ncpa.py failed to run." | tee -a "$LOG"
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
