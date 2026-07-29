#!/bin/bash

set -e

LOG="/var/log/pinpoint-nagios.log"

echo "======================================" | tee -a "$LOG"
echo " PinPoint Phase 3 - Installing Nagios " | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

cd /usr/local/src

echo "Downloading Nagios Core..." | tee -a "$LOG"

wget https://assets.nagios.com/downloads/nagioscore/releases/nagios-4.5.11.tar.gz

echo "Extracting Nagios..." | tee -a "$LOG"

tar -xzf nagios-4.5.11.tar.gz

cd nagios-4.5.11

echo "Nagios source extracted successfully." | tee -a "$LOG"
