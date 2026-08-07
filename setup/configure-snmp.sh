#!/bin/bash

set -e

LOG="/var/log/pinpoint-snmp.log"

echo "======================================" | tee -a "$LOG"
echo " Configuring SNMP" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

apt install -y snmp snmpd

cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.backup

cat <<EOF >/etc/snmp/snmpd.conf

agentAddress udp:161

rocommunity public

sysLocation PinPoint Monitoring Server
sysContact Admin

EOF

systemctl enable snmpd
systemctl restart snmpd

echo "SNMP configured successfully." | tee -a "$LOG"
