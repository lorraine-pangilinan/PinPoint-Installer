# Release notes

## Unreleased

- Nagios downloads are now checked. Nagios Core, the Nagios Plugins and `check_ncpa.py` are read
  from the baseline manifest `setup/manifests/pp-mon-baseline-1.json` (version, HTTPS URL, SHA-256),
  through the new `setup/baseline-artifacts.sh`. A cached archive is reused only if its SHA-256
  matches; a download that does not match is deleted and the install stops before building.
  `check_ncpa.py` is no longer fetched unpinned: if upstream replaces the archive, the install stops
  until the manifest is updated. `configure-nagios.sh` takes the Nagios source folder from the
  manifest instead of a hard-coded path. `scripts/build.sh` copies the manifest onto the ISO.
  Tests: `tests/baseline-artifacts-tests.sh` (runs on any machine).

- PinPoint can now restart `nagios` automatically (proactive resolution, `restart_local_service`).
  The installer adds `/etc/sudoers.d/pinpoint-restart` (`root:root`, `0440`) with one rule:
  `pinpoint ALL=(root) NOPASSWD: /usr/bin/systemctl restart nagios`. No other unit, no wildcards, no
  shell. The existing reload and SMTP helper rules are unchanged. The rule is validated with
  `visudo -cf` before it is moved into place; if validation fails, the previous rule is kept and the
  install stops with an error. The unit list (`RESTARTABLE_UNITS`) must match
  `server/app/remediation_actions.py`.

- New installer module `configure-event-handler.sh`: creates the event spool folder
  `/usr/local/nagios/var/spool/pinpoint-events` (`nagios:pinpoint`, `2770`) and installs the event
  handler as `/usr/local/sbin/pinpoint-event-handler` (`root:root`, `755`) from the deployed
  PinPoint (`server/scripts/pinpoint_event_handler.py`). Safe to run again on an existing
  appliance. If the deployed PinPoint has no handler, only the spool is created and a warning is logged.

- New installer module `configure-journald-logs.sh`: limits the systemd journal to 200M and 30 days
  (`/etc/systemd/journald.conf.d/pinpoint.conf`) and rotates `/var/log/pinpoint-*.log` weekly, 8 kept
  (`/etc/logrotate.d/pinpoint`). A file an administrator edited (its first line no longer reads
  "Managed by PinPoint Installer.") is never overwritten.
