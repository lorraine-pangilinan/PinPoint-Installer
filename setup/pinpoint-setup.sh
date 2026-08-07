#!/bin/bash

# Ensure the wizard is running as root
if [ "$EUID" -ne 0 ]; then
    echo
    echo "This installer must be run as root."
    echo
    echo "Please run:"
    echo "sudo ./pinpoint-setup.sh"
    echo
    exit 1
fi

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

case $OPTION in
    1)
        echo
        echo "Starting PinPoint installation..."
        echo

        bash "$(dirname "$0")/install-packages.sh"

        ;;

    2)
        echo
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo
        echo "Invalid option."
        ;;
esac
