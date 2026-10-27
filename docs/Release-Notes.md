# Release notes

## Unreleased

- Recovery foundation for Nagios updates (plan Phase 2). Nothing is updated yet, but a change to
  Nagios can now be undone. `configure-monitoring-updates.sh` also installs
  `/usr/local/sbin/pinpoint-update-exec` (`root:root`, `755`), the health suite in
  `/usr/local/lib/pinpoint-update/` (`pinpoint-update-health.sh`, checks HC-01 to HC-13, with a copy
  of `pinpoint-healthcheck.sh`), the recovery point folder `/usr/local/.pinpoint-rp/` (`root:root`,
  `700`, same filesystem as `/usr/local/nagios`) and two boot units,
  `pinpoint-update-reconcile.service` (restores the files of an interrupted change before Nagios
  starts) and `pinpoint-update-reconcile-finish.service` (runs the health suite once the services are
  up). A recovery point is a copy of `/usr/local/nagios`, `nagios.service` and the Apache Nagios site
  with a SHA-256, owner and mode list, verified before it is trusted; restoring is a rename swap,
  each step recorded so it can be repeated after a crash. `sudo pinpoint-update-exec drill --yes`
  runs the whole recovery path on a staging appliance and reports the time it took;
  `--inject config|service|plugin|corrupt` and `--crash-after-apply` add the failure cases FI-06 to
  FI-11. The drill stops Nagios and PinPoint web for a few minutes. `deploy-pinpoint-web.sh` now
  takes the update lock `/run/lock/pinpoint-update.lock` and refuses to run while a drill or update
  holds it. The update database gains the `txn` and `recovery_point` tables. Tests:
  `tests/test_pinpoint_update_exec.py` (any machine), `tests/update-recovery-tests.sh` (VM).

- New installer module `configure-monitoring-updates.sh` (first boot step 10/10) installs the
  read-only PinPoint Update Manager as `/usr/local/sbin/pinpoint-update` (`root:root`, `755`), the
  baseline manifest in `/etc/pinpoint/updates/manifests/`, and its state in
  `/var/lib/pinpoint/updates/updates.db` (`root:root`, `600`; folder `700`) with a hash-chained audit
  log. `sudo pinpoint-update` shows the numbered menu (1 Reload, 2 Install updates, 3 Choose what to
  update, 4 Exit); nothing is installed or downloaded yet, and Reload reports the update status as
  UNKNOWN because no catalog exists. On a fresh install only (install credentials still pending),
  `/var/lib/pinpoint/update-menu-pending` makes `pinpoint-login-hook.sh` open the menu once at the
  first console login, after the credentials. Safe to run again on an existing appliance, where no
  menu opens by itself. Tests: `tests/test_pinpoint_update.py`, `tests/login-hook-tests.sh`.

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
