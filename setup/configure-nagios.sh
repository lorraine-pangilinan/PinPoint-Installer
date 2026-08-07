#!/bin/bash

set -e

LOG="/var/log/pinpoint-nagios.log"

echo "======================================" | tee -a "$LOG"
echo " Configuring Nagios Web Interface" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

cd /usr/local/src/nagios-4.5.11

echo "Installing init scripts..." | tee -a "$LOG"

make install-init

echo "Installing command mode..." | tee -a "$LOG"

make install-commandmode

echo "Installing sample configuration..." | tee -a "$LOG"

make install-config

echo "Installing Apache configuration..." | tee -a "$LOG"

make install-webconf

echo "Nagios configuration completed." | tee -a "$LOG"
