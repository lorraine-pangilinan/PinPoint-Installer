#!/bin/bash

set -e

LOG="/var/log/pinpoint-firstboot.log"

echo "==================================" | tee -a "$LOG"
echo " PinPoint First Boot Setup"
echo "==================================" | tee -a "$LOG"

echo "Starting PinPoint installation..." | tee -a "$LOG"

echo "[1/7] Installing required packages..." | tee -a "$LOG"
/root/pinpoint/install-packages.sh

echo "[2/7] Installing Nagios Core..." | tee -a "$LOG"
/root/pinpoint/install-nagios-core.sh

echo "[3/7] Installing Nagios Plugins..." | tee -a "$LOG"
/root/pinpoint/install-nagios-plugins.sh

echo "[4/7] Configuring SNMP..." | tee -a "$LOG"
/root/pinpoint/configure-snmp.sh

echo "[5/7] Configuring Nagios..." | tee -a "$LOG"
/root/pinpoint/configure-nagios.sh

echo "[6/7] Deploying PinPoint web interface..." | tee -a "$LOG"
/root/pinpoint/deploy-pinpoint-web.sh

echo "[7/7] Configuring PinPoint privileges..." | tee -a "$LOG"
/root/pinpoint/configure-pinpoint-privileges.sh

echo "PinPoint installation completed successfully." | tee -a "$LOG"
echo "Web administrator credentials will be shown at the next login." | tee -a "$LOG"
echo "Disabling PinPoint First Boot service..." | tee -a "$LOG"
systemctl disable pinpoint-firstboot.service

echo "Done." | tee -a "$LOG"
