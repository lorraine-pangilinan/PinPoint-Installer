# PinPoint Installer

A bootable Ubuntu Server ISO that turns a blank machine into a ready-to-use
**PinPoint network monitoring server**. The administrator answers a few
installation questions, and the installer does the rest: no manual Nagios,
SNMP, or web server setup.

## What it automates

- Ubuntu Server 22.04.5 LTS
- Nagios Core 4.5.11
- Official Nagios Plugins
- SNMP
- PinPoint Management System (Network-Diagnosis-System web interface, served by Nginx and Gunicorn)

The administrator only chooses the following during Ubuntu installation:

- Language
- Keyboard Layout
- Timezone
- Network (DHCP or static)
- Username
- Password
- Hostname

## Architecture

Boot ISO
↓
Interactive Ubuntu Installer
↓
Administrator specifies:

- Language
- Keyboard
- Timezone
- Network
- Username
- Password
- Hostname

↓
Ubuntu Installation

↓
PinPoint First Boot Setup

↓
Install Packages

↓
Install Nagios Core

↓
Install Nagios Plugins

↓
Configure SNMP

↓
Configure Nagios (Apache moved to 127.0.0.1:8081)

↓
Deploy PinPoint Web Interface (Nginx + Gunicorn)

↓
Configure PinPoint Privileges

↓
Ready for the network

```text
LAN browser
    |
    v
Nginx :80
    |-- /      -> built web client
    |-- /api/  -> Gunicorn 127.0.0.1:8000 -> Flask
                                               |
                                               +-> Nagios 127.0.0.1:8081
```

## Updating Network-Diagnosis-System

To update the PinPoint web interface on an installed server, run the deploy
script as root. It pulls the latest `main` of
[Network-Diagnosis-System](https://github.com/esfen14/Network-Diagnosis-System),
rebuilds the web client and restarts the service. Databases, configuration and
the built web interface are backed up first and restored if the update fails.

```bash
sudo bash /root/pinpoint/deploy-pinpoint-web.sh
```

Progress is logged to `/var/log/pinpoint-web.log`.

## Author

Lorraine G. Pangilinan

BSIT Capstone 2
