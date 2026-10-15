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

## Check interval

PinPoint lets an administrator choose how often Nagios checks devices (1, 2, 5, 10 or 15
minutes). The installer makes sure Nagios counts in minutes (`interval_length=60`), that
PinPoint may reload Nagios but not restart it, and that the database has the setting after an
upgrade. See [docs/Check-Interval.md](docs/Check-Interval.md) for what each interval means and
how to check a server.

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


## Log retention (issue 124)

Fresh installs and upgrades run `setup/configure-log-retention.sh` from the web
deployment step. It installs `/etc/systemd/journald.conf.d/pinpoint.conf` with
`SystemMaxUse=100M` (100 MiB) and `MaxRetentionSec=7day`, then restarts
`systemd-journald`. These are host-wide persistent journal limits, including
Gunicorn stdout/stderr. They are not per-service quotas. Journald rotates whole
journal files; the active journal can temporarily exceed the target. Existing
archives are not vacuumed destructively during installation. After sufficient
rotation, inspect `journalctl --disk-usage`; allow an active-file margin when
comparing usage with the target.

Administrator settings take precedence: any active `SystemMaxUse` or
`MaxRetentionSec` in the main journald configuration or another drop-in under
`/etc`, `/run`, `/usr/local/lib` or `/usr/lib` makes the installer skip its defaults.
If an administrator adds such a setting after installation, the next upgrade
removes only the byte-identical installer defaults and restarts journald. An
edited `pinpoint.conf` is always kept. An administrator policy can therefore
choose different limits. No settings in administrator files are overwritten.

The installer also installs `/etc/logrotate.d/pinpoint-installer` for
`/var/log/pinpoint-*.log`: weekly, four archives, compression (delayed one cycle),
missing/empty files skipped and `copytruncate` to support active installer file
descriptors. `copytruncate` can lose lines written during its small copy/truncate
window. Existing administrator-edited rotation rules are kept. Nagios continues
to rotate its own `nagios.log`; this module does not alter Nagios configuration.

The helper takes no command-line arguments and uses fixed system paths. It
refuses symlinks at managed destinations and writes new files without clobbering
concurrently created files. It never reads application secrets or accepts web
request data. The root prefix in the sourced function is for isolated tests;
the executable always uses system paths.

Run isolated regression checks with:

```sh
python3 -m unittest discover -s tests -p test_log_retention.py
bash -n setup/configure-log-retention.sh setup/deploy-pinpoint-web.sh
```

Release notes: upgrades add explicit appliance journal defaults and installer
log rotation while retaining administrator policies. No application database
migration, Nagios rotation change or additional application privilege is needed.
Fresh-appliance and upgrade disk-usage evidence must accompany release sign-off.
