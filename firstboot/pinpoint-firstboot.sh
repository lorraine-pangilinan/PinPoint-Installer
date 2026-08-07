#!/bin/bash

LOG="/var/log/pinpoint-firstboot.log"

echo "==================================" | tee -a "$LOG"
echo " PinPoint First Boot Setup"
echo "==================================" | tee -a "$LOG"

echo "Starting PinPoint installation..." | tee -a "$LOG"

echo "[1/5] Installing required packages..." | tee -a "$LOG"
/root/install-packages.sh

echo "[2/5] Installing Nagios Core..." | tee -a "$LOG"
/root/install-nagios-core.sh

echo "[3/5] Installing Nagios Plugins..." | tee -a "$LOG"
/root/install-nagios-plugins.sh

echo "[4/5] Configuring SNMP..." | tee -a "$LOG"
/root/configure-snmp.sh

echo "[5/5] Configuring Nagios..." | tee -a "$LOG"
/root/configure-nagios.sh

echo "PinPoint installation completed successfully." | tee -a "$LOG"

echo "Disabling PinPoint First Boot service..." | tee -a "$LOG"
systemctl disable pinpoint-firstboot.service

echo "Done." | tee -a "$LOG"
