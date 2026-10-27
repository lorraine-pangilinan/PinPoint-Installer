#!/bin/bash

set -e

LOG="/var/log/pinpoint-firstboot.log"

echo "==================================" | tee -a "$LOG"
echo " PinPoint First Boot Setup"
echo "==================================" | tee -a "$LOG"

echo "Starting PinPoint installation..." | tee -a "$LOG"

echo "[1/10] Installing required packages..." | tee -a "$LOG"
/root/pinpoint/install-packages.sh

echo "[2/10] Installing Nagios Core..." | tee -a "$LOG"
/root/pinpoint/install-nagios-core.sh

echo "[3/10] Installing Nagios Plugins..." | tee -a "$LOG"
/root/pinpoint/install-nagios-plugins.sh

echo "[4/10] Configuring SNMP..." | tee -a "$LOG"
/root/pinpoint/configure-snmp.sh

echo "[5/10] Configuring Nagios..." | tee -a "$LOG"
/root/pinpoint/configure-nagios.sh

echo "[6/10] Deploying PinPoint web interface..." | tee -a "$LOG"
/root/pinpoint/deploy-pinpoint-web.sh

echo "[7/10] Configuring PinPoint privileges..." | tee -a "$LOG"
/root/pinpoint/configure-pinpoint-privileges.sh

echo "[8/10] Configuring the event handler..." | tee -a "$LOG"
/root/pinpoint/configure-event-handler.sh

echo "[9/10] Configuring log limits..." | tee -a "$LOG"
/root/pinpoint/configure-journald-logs.sh

echo "[10/10] Configuring the Update Manager..." | tee -a "$LOG"
/root/pinpoint/configure-monitoring-updates.sh

echo "PinPoint installation completed successfully." | tee -a "$LOG"
echo "Web administrator credentials will be shown at the next login." | tee -a "$LOG"
echo "Disabling PinPoint First Boot service..." | tee -a "$LOG"
systemctl disable pinpoint-firstboot.service

echo "Done." | tee -a "$LOG"
