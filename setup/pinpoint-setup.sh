#!/bin/bash

##################################################
# PinPoint Setup Wizard
##################################################

set -e

########################################
# Root Check
########################################

if [ "$EUID" -ne 0 ]; then
    echo
    echo "This installer must be run as root."
    echo
    echo "Please run:"
    echo "sudo ./pinpoint-setup.sh"
    echo
    exit 1
fi

BASE_DIR="$(dirname "$0")"

########################################
# Main Menu
########################################

clear

echo "=========================================="
echo "      PinPoint Setup Wizard v1.0"
echo "=========================================="
echo

echo "Welcome to PinPoint Network Monitoring."
echo
echo "This wizard will install:"
echo "  - Apache"
echo "  - PHP"
echo "  - Nagios Core"
echo "  - Nagios Plugins"
echo "  - SNMP"
echo "  - PinPoint Web Interface"
echo

echo "------------------------------------------"
echo
echo "1) Install PinPoint"
echo "2) Exit"
echo

read -p "Select an option: " OPTION

case "$OPTION" in

1)

    echo
    echo "Starting PinPoint installation..."
    echo

    ##################################################
    # Installer Modules
    ##################################################

    MODULES=(
        "install-packages.sh"
        "install-nagios-core.sh"
        "install-nagios-plugins.sh"
        "configure-snmp.sh"
        "configure-nagios.sh"
    )

    TOTAL=${#MODULES[@]}

    for ((i=0; i<TOTAL; i++)); do

        MODULE="${MODULES[$i]}"

        echo
        echo "=========================================="
        echo " Module $((i+1))/$TOTAL"
        echo " Running: $MODULE"
        echo "=========================================="

        bash "$BASE_DIR/$MODULE"

        echo
        echo "✓ $MODULE completed successfully."

    done

    echo
    echo "=========================================="
    echo " PinPoint installation completed!"
    echo "=========================================="
    ;;

2)

    echo
    echo "Exiting..."
    exit 0
    ;;

*)

    echo
    echo "Invalid option."
    exit 1
    ;;

esac
