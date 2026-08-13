#!/bin/bash

##################################################
# PinPoint Installer Module
# Module: configure-snmp.sh
# Purpose: Install and configure SNMP daemon
##################################################

set -e

LOG="/var/log/pinpoint-snmp.log"

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
echo " PinPoint - Configuring SNMP" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

##################################################
# [1/6] Install SNMP Packages
##################################################

echo
echo "[1/6] Installing SNMP packages..." | tee -a "$LOG"

apt install -y snmp snmpd

echo "✓ SNMP packages installed." | tee -a "$LOG"

##################################################
# [2/6] Backup Configuration
##################################################

echo
echo "[2/6] Backing up current configuration..." | tee -a "$LOG"

if [ -f /etc/snmp/snmpd.conf ] && \
   [ ! -f /etc/snmp/snmpd.conf.backup ]; then

    cp /etc/snmp/snmpd.conf \
       /etc/snmp/snmpd.conf.backup

    echo "✓ Existing configuration backed up." | tee -a "$LOG"

else

    echo "✓ No new backup required." | tee -a "$LOG"

fi

##################################################
# [3/6] Write PinPoint Configuration
##################################################

echo
echo "[3/6] Writing PinPoint SNMP configuration..." | tee -a "$LOG"

cat > /etc/snmp/snmpd.conf <<'EOF'
agentAddress udp:161

rocommunity public

sysLocation PinPoint Monitoring Server
sysContact PinPoint Administrator
EOF

echo "✓ SNMP configuration written." | tee -a "$LOG"

##################################################
# [4/6] Enable SNMP
##################################################

echo
echo "[4/6] Enabling SNMP service..." | tee -a "$LOG"

systemctl enable snmpd

echo "✓ SNMP service enabled." | tee -a "$LOG"

##################################################
# [5/6] Restart SNMP
##################################################

echo
echo "[5/6] Restarting SNMP service..." | tee -a "$LOG"

systemctl restart snmpd

echo "✓ SNMP service restarted." | tee -a "$LOG"

##################################################
# [6/6] Verify SNMP
##################################################

echo
echo "[6/6] Verifying SNMP..." | tee -a "$LOG"

if systemctl is-active --quiet snmpd; then
    echo "✓ SNMP service is running." | tee -a "$LOG"
else
    echo "ERROR: SNMP service failed to start." | tee -a "$LOG"

    echo
    echo "SNMP service status:" | tee -a "$LOG"

    systemctl status snmpd --no-pager \
        >> "$LOG" 2>&1 || true

    echo "Recent SNMP journal:" | tee -a "$LOG"

    journalctl -u snmpd -n 30 --no-pager \
        >> "$LOG" 2>&1 || true

    exit 1
fi

##################################################
# Test SNMP Query
##################################################

echo
echo "Testing SNMP query..." | tee -a "$LOG"

if snmpget -v2c -c public localhost \
    1.3.6.1.2.1.1.1.0 \
    >> "$LOG" 2>&1; then

    echo "✓ SNMP query successful." | tee -a "$LOG"

else

    echo "ERROR: SNMP query failed." | tee -a "$LOG"
    echo "Check $LOG for details." | tee -a "$LOG"
    exit 1

fi

##################################################
# Footer
##################################################

echo
echo "======================================" | tee -a "$LOG"
echo " SNMP configuration completed." | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
