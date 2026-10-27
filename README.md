# PinPoint Installer

A bootable Ubuntu Server ISO that turns a blank machine into a ready-to-use
**PinPoint network monitoring server**. The administrator answers a few
installation questions, and the installer does the rest: no manual Nagios,
SNMP, or web server setup.

## What it automates

- Ubuntu Server 22.04.5 LTS
- Nagios Core 4.5.11
- Official Nagios Plugins 2.4.12 and the NCPA `check_ncpa.py` plugin
  (versions and SHA-256 fixed in `setup/manifests/pp-mon-baseline-1.json`; a download that does not
  match is refused)
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

## Check interval

PinPoint lets an administrator choose how often Nagios checks devices (1, 2, 5, 10 or 15
minutes). The installer makes sure Nagios counts in minutes (`interval_length=60`), that
PinPoint may reload Nagios but not restart it, and that the database has the setting after an
upgrade. See [docs/Check-Interval.md](docs/Check-Interval.md) for what each interval means and
how to check a server.

## Nagios versions and the Update Manager

`sudo pinpoint-update` opens the PinPoint Update Manager, a numbered console menu:

```text
   1) Reload (check for updates)
   2) Install updates
   3) Choose what to update
   4) Exit
```

This version is read-only. It shows the installed Nagios Core, Nagios Plugins and
`check_ncpa.py` next to the baseline manifest and records them in
`/var/lib/pinpoint/updates/updates.db`. There is no update catalog yet, so Reload shows
the update status as UNKNOWN, and options 2 and 3 install nothing. After a fresh install
the menu opens once at the first console login, after the web credentials. On an existing
appliance, install it with `sudo bash /root/pinpoint/configure-monitoring-updates.sh`; no
menu opens by itself there. Other commands: `sudo pinpoint-update status [--json]` and
`sudo pinpoint-update audit --verify`. The full design is in
`docs/University-Maintenance-and-Updates-Plan.md`.

## Updating Network-Diagnosis-System

The restricted [resource secret writer](docs/Resource-Secrets.md) preserves
Nagios ownership during managed block updates. Its application integration and
installed update/rollback acceptance are still pending on the issue #129 branch.

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
