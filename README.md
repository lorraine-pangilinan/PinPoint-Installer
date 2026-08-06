# PinPoint Installer

A customized Ubuntu Server deployment appliance for automated installation of:

- Ubuntu Server 22.04.5 LTS
- Nagios Core 4.5.11
- Official Nagios Plugins
- PinPoint Management System

Author:
Lorraine G. Pangilinan

Project:
BSIT Capstone 2

## Architecture Revisions (August 2026)

Initially, PinPoint relied on Ubuntu Server Autoinstall using `late-commands`
which installed Nagios, SNMP and PinPoint during operating system installation.

Later, based on client feedback, a new installer was developed which provided the
ability for the administrator to configure the following during Ubuntu
installation:

- Language
- Keyboard Layout
- Timezone
- Username
- Password
- Hostname

Deployment of PinPoint is done separately by means of the PinPoint Setup Wizard.
