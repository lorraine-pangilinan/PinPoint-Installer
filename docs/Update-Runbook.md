# PinPoint Nagios update runbook (draft)

**Status:** draft for the university IT team, 14 November 2026. Tested on the staging VM only
(`tests/update-install-vm-Result.md`). To be walked through with the receiving team before sign-off (plan §18).

This guide covers Nagios Core, the Nagios Plugins and `check_ncpa.py` on a PinPoint appliance.
Ubuntu packages (nginx, Apache, Python, OpenSSL and the rest) are updated by Ubuntu itself; see
section 6.

All commands are run on the appliance console or over SSH, as a member of `pinpoint-update-admins`.

---

## 1. See where things stand

```
sudo pinpoint-update
```

The screen shows the installed versions, the installed update set, the update status, and whether
Ubuntu installs its security updates automatically.

| Update status | Meaning | What to do |
|---|---|---|
| `Up to date (catalog checked ...)` | The catalog was checked recently and nothing newer can be installed | Nothing |
| `Update available: <ID>` | A newer update set can be installed here | Section 2 |
| `UNKNOWN (...)` | The catalog could not be checked, or not for 7 days | Choose **1** to reload; if it fails again, check the network (section 7) |

The appliance checks the catalog by itself once a day. An email is sent to the PinPoint users in
Nagios when a new update set appears.

## 2. Install an update

1. Plan a time. Nagios and PinPoint web stop for about 10 minutes (more if it rolls back). Optional
   but recommended: take a hypervisor snapshot of the appliance first.
2. Run `sudo pinpoint-update`, choose **2) Install updates**.
3. Read the screen: versions before and after, security fixes, limitations, expected downtime.
4. Choose **1) Install now**, type the update set ID, and type `ACCEPT` if it is conditional.
5. Watch the steps. Do not power off the appliance. Closing the window or SSH session does **not** stop
   the update; see it again with `sudo pinpoint-update status --follow`.

The result is one of:

| Result | Meaning | What to do |
|---|---|---|
| `SUCCEEDED` | The new version is installed and passed every critical health check | Check that alerts and the PinPoint dashboard look normal |
| `ROLLED_BACK` | The new version failed a health check; the previous version was put back and is healthy | Nothing urgent. Send `sudo pinpoint-update history` and the log (section 8) to the development team |
| `FAILED` / `BLOCKED` | Stopped before anything changed (download, build or preflight problem) | Read the reason in `sudo pinpoint-update history` |
| `RECOVERY_FAILED` | The update failed **and** the restore failed | Section 5, now |

Command-line equivalent:

```
sudo pinpoint-update list
sudo pinpoint-update show <ID>
sudo pinpoint-update approve <ID> --confirm <ID> --accept-limitations --now
```

## 3. Schedule an update for a maintenance window

Menu: **2) Install updates**, then **2) Schedule for later**, and enter the start time in the
appliance's local time, for example `2026-11-20 22:00`.

Command line:

```
sudo pinpoint-update approve <ID> --confirm <ID> --at 2026-11-20T22:00 --window-minutes 60
```

The run timer starts it within 5 minutes after the window opens. If the window passes without the
update starting (for example the appliance was off), it is marked `missed_window` and nothing changes;
approve it again. To cancel before it starts: `sudo pinpoint-update cancel <TXN_ID>`.

## 4. Do not update now

Menu **2**, then:

- **3) Not now**: nothing is recorded except that you looked; you will be reminded.
- **4) Defer**: give a reason and a review date; reminders stop until then.
- **5) Decline**: give a reason; this update set is not offered again by email.

Monitoring keeps running on the installed version in every case.

## 5. When recovery fails (`RECOVERY_FAILED`)

This is the only case that needs a person immediately. The appliance does nothing more by itself and
shows a CRITICAL line at every login.

1. Check what is running: `systemctl status nagios pinpoint-gunicorn`.
2. Read the reason: `sudo pinpoint-update history` (column *Recovery*) and the end of
   `/var/log/pinpoint-update.log`.
3. The previous version is kept in `/usr/local/.pinpoint-rp/<rp-id>/nagios` (the `rp-id` is in
   `sudo pinpoint-update history --json`). The failed version is in `/usr/local/.pinpoint-rp/<rp-id>/failed`.
4. If the recovery copy is intact, put it back by hand:

   ```
   sudo systemctl stop pinpoint-gunicorn nagios
   sudo mv /usr/local/nagios /usr/local/.pinpoint-rp/<rp-id>/failed-manual
   sudo mv /usr/local/.pinpoint-rp/<rp-id>/nagios /usr/local/nagios
   sudo /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg
   sudo systemctl start nagios pinpoint-gunicorn
   ```

5. If that does not work, restore the hypervisor snapshot taken before the window.
6. Tell the development team, with the transaction ID and `/var/lib/pinpoint/updates/txn/<TXN_ID>/`.

## 6. Ubuntu security updates

`configure-monitoring-updates.sh` turns on Ubuntu's daily security updates (`unattended-upgrades`).
The menu shows `Ubuntu security updates: installed automatically by Ubuntu` when it is on.
Ubuntu signs these packages and `apt` checks the signatures; nothing in the PinPoint catalog is involved.

Check by hand: `cat /etc/apt/apt.conf.d/20auto-upgrades` should show both values as `"1"`.
Ubuntu sometimes needs a reboot after a kernel update: `cat /var/run/reboot-required` exists when it does.

## 7. The catalog and the settings

- Address: `/etc/pinpoint/updates/updater.conf`, line `catalog_url`. Only
  `https://raw.githubusercontent.com/...` is accepted.
- Email recipients: the PinPoint users in Nagios (contact group `system_users`). To send update
  notices somewhere else, add `notify_to = it-team@university.edu` to `updater.conf`.
- Check by hand: `sudo pinpoint-update discover`. Exit code 7 means the catalog could not be read or
  was refused; nothing was changed.
- How update sets are published and why appliances trust them: `catalog/README.md` in the repository.

## 8. Where to look

| What | Where |
|---|---|
| Every approval, change and result (tamper-evident) | `sudo pinpoint-update audit --verify` |
| Past updates | `sudo pinpoint-update history` |
| Log | `/var/log/pinpoint-update.log`, `journalctl -t pinpoint-update` |
| One update's build and install output | `/var/lib/pinpoint/updates/txn/<TXN_ID>/` |
| The update unit | `journalctl -u pinpoint-update-exec@<TXN_ID>` |
| Timers | `systemctl list-timers 'pinpoint-update-*'` |
