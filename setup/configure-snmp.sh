#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : configure-snmp.sh
# Purpose: Configure SNMP daemon
##################################################

set -e

LOG="/var/log/pinpoint-snmp.log"

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
echo " PinPoint - Configuring SNMP" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

########################################
# [1/6] Installing SNMP
########################################

echo
echo "[1/6] Installing SNMP packages..." | tee -a "$LOG"

apt install -y snmp snmpd

echo "✓ SNMP packages installed." | tee -a "$LOG"

########################################
# [2/6] Backing Up Configuration
########################################

echo
echo "[2/6] Backing up current configuration..." | tee -a "$LOG"

if [ ! -f /etc/snmp/snmpd.conf.backup ]; then
    cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.backup
fi

echo "✓ Backup completed." | tee -a "$LOG"

########################################
# [3/6] Writing Configuration
########################################

echo
echo "[3/6] Writing PinPoint SNMP configuration..." | tee -a "$LOG"

cat <<EOF >/etc/snmp/snmpd.conf
agentAddress udp:161

rocommunity public

sysLocation PinPoint Monitoring Server
sysContact PinPoint Administrator
EOF

echo "✓ Configuration written." | tee -a "$LOG"

########################################
# [4/6] Enabling SNMP
########################################

echo
echo "[4/6] Enabling SNMP service..." | tee -a "$LOG"

systemctl enable snmpd

echo "✓ Service enabled." | tee -a "$LOG"

########################################
# [5/6] Restarting SNMP
########################################

echo
echo "[5/6] Restarting SNMP..." | tee -a "$LOG"

systemctl restart snmpd

echo "✓ SNMP restarted." | tee -a "$LOG"

########################################
# [6/6] Verification
########################################

echo
echo "[6/6] Verifying SNMP..." | tee -a "$LOG"

if systemctl is-active --quiet snmpd; then
    echo "✓ SNMP service is running." | tee -a "$LOG"
else
    echo "✗ SNMP failed to start." | tee -a "$LOG"
    exit 1
fi

########################################
# Footer
########################################

echo
echo "======================================" | tee -a "$LOG"
echo " SNMP configuration completed." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
