#!/bin/bash

set -e

LOG="/var/log/pinpoint-nagios.log"

echo "======================================" | tee -a "$LOG"
echo " Installing Nagios Plugins" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

cd /usr/local/src

echo "Downloading Nagios Plugins..." | tee -a "$LOG"

wget https://nagios-plugins.org/download/nagios-plugins-2.4.12.tar.gz

echo "Extracting plugins..." | tee -a "$LOG"

tar -xzf nagios-plugins-2.4.12.tar.gz

cd nagios-plugins-2.4.12

echo "Configuring..." | tee -a "$LOG"

./configure \
--with-nagios-user=nagios \
--with-nagios-group=nagios

echo "Compiling..." | tee -a "$LOG"

make

echo "Installing..." | tee -a "$LOG"

make install

echo "Nagios Plugins installation completed." | tee -a "$LOG"
