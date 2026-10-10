# Test Cases: Admin Email Gate and SMTP Notifications

Covers the installer side of `SMTP_Admin_Email_Plan.md` and the end-to-end checks that need
the PinPoint server. PinPoint already ships its own first-run setup (`User.Needs_Setup`,
`POST /api/user/complete-setup`, the `FirstRunSetup` screen), which replaces the plan's
`--require-email-change` / `Must_Change_Email` design. The installer relies on that, so the
cases below test the installer against it. Server and client unit tests are PinPoint's own.

Status of every case: **not run** unless a result is written in the Result column.

## Conventions

- **VM**: disposable Ubuntu 22.04 (the supported target), snapshot taken before each run.
  A 24.04 run is indicative only.
- **Fresh run**: needs a VM restored from a snapshot with no PinPoint database. Cases A3-A7, P1
  and B1-B9 are skipped on an installed system; A10-A11 then test the upgrade.
- Commands run on the VM as root unless stated. Never paste real passwords into this file.
- "Log" means `/var/log/pinpoint-web.log` for `deploy-pinpoint-web.sh` and
  `/var/log/pinpoint-privileges.log` for `configure-pinpoint-privileges.sh`.

---

## A. Installer: fresh install and upgrade

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| A1 | Old PinPoint is refused before the database exists | Install with a PinPoint whose `User` model has no `Needs_Setup` | Install stops at step 9/12 with `this PinPoint version has no first-run setup`. No database exists afterwards. | not run (no such PinPoint available) |
| A2 | Re-run after A1 | Run `deploy-pinpoint-web.sh` again | Same error. Treated as a fresh install, not an upgrade (no rollback message). | not run (see A1) |
| A3 | Fresh install succeeds | Fresh run of `deploy-pinpoint-web.sh` | Exit 0 and `Administrator must complete first-run setup (real email and new password).` | |
| A4 | Admin row | Read `USER` in `system.db` | Exactly one user, `admin-xxxxx@pinpoint.lan`, `Needs_Setup=1`. | |
| A5 | Credentials file | `stat` and read it | `root:root 600`, shows the placeholder username. | |
| A6 | Credentials file wording | Read it | Says temporary placeholder, asks for a real email and a new password, no longer says "change the password after first login". | |
| A7 | Password never leaks | `grep` the deploy log and console output for the generated password | Not found. | |
| A8 | `init-production` fails | Make the command fail (read-only database) | Install stops with `'flask init-production' failed. The administrator was not created.` | not run |
| A9 | Gate flag missing after creation | Simulate an admin created without `Needs_Setup` | Install stops with `created without first-run setup`. | not run |
| A10 | Installed system is upgraded | Run `deploy-pinpoint-web.sh` on an installed system | Takes the upgrade path, creates no administrator. | |
| A11 | Upgrade keeps data | After A10 | Users and credentials file unchanged. | |
| A12 | Script syntax | `bash -n` on every file in `setup/` | No errors. | |
| P1 | Privileges script end to end | Run `configure-pinpoint-privileges.sh` after the deploy | Exit 0 with all 9 steps and its own checks passing. If `unattended-upgrades` holds the apt lock the nmap step fails; wait for the lock and re-run. | |

## B. First sign-in against PinPoint's first-run setup

Run against the real API through Nginx (`/api/user/login`, `/api/user/me`,
`/api/user/complete-setup`).

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| B1 | Gate is on | Sign in with the placeholder and the generated password, then `GET /api/user/me` | Login 200 and `needs_setup` is true. | |
| B2 | Everything else is blocked | `GET /api/system/discovery-settings` with that session | 403 mentioning first-run setup. | |
| B3 | Placeholder and reserved domains rejected | `complete-setup` with `@pinpoint.lan`, then `@company.lan` | Both 400. `needs_setup` stays true. | |
| B4 | Wrong current password | `complete-setup` with a wrong current password | 400, nothing saved. | |
| B5 | Password rules | Mismatching confirmation, a weak password, the same password as before | All 400. | |
| B6 | Success | Valid email, strong new password | 200. | |
| B7 | Result of success | `/me`, the protected endpoint, old and new logins | `needs_setup` false, protected endpoint 200, placeholder login 401, new login 200. | |
| B8 | Nagios contact | `grep -A6 'define contact' /usr/local/nagios/etc/objects/hosts.cfg` | Contact `email` is the new address. No `pinpoint.lan`. Requires P1 first, because the privileges script lets PinPoint write the file. | |
| B9 | Nagios still valid | `/usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg` | 0 errors. | |
| B10 | Regeneration failure | Make `hosts.cfg` unwritable, then run `complete-setup` | Email saved, response says the Nagios contact could not be updated. Admin is not stuck. | not run (the first run showed this behaviour by accident, see the result file) |

## C. Phase 4: mail transport on the appliance

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| C1 | Packages installed | `dpkg -l msmtp-mta bsd-mailx` | Both installed. `mailutils` and `postfix` are not installed. | |
| C2 | No mail daemon listening | `ss -ltn \| grep ':25 '` | Nothing listens on port 25. | |
| C3 | Config file exists | `stat -c '%U:%G %a' /etc/msmtprc` | `root:nagios 640`. | |
| C4 | Helper installed | `stat -c '%U:%G %a' /usr/local/sbin/pinpoint-apply-smtp` | `root:root 755`. | |
| C5 | Sudoers valid | `visudo -c` and `cat /etc/sudoers.d/pinpoint-apply-smtp` | Valid. One rule: `pinpoint` may run only that helper, `NOPASSWD`. | |
| C6 | Rights are narrow | As `pinpoint`: `sudo -n -l /usr/local/sbin/pinpoint-apply-smtp`, then `sudo -n -l /bin/cat` | First is allowed. Second is refused. | |
| C7 | Flask cannot write `/etc` | As `pinpoint`: `touch /etc/msmtprc` | Permission denied. | |
| C8 | Nagios reload rule intact | `sudo -n -l /usr/bin/systemctl reload nagios` as `pinpoint`, and `restart nagios` | Reload allowed, restart refused (existing behaviour). | |
| C9 | Mail command resolves | `grep -n 'by-email' /usr/local/nagios/etc/objects/commands.cfg` shows the commands call `/bin/mail`. Then, as `nagios`: `test -x /bin/mail`. | `/bin/mail` exists and `nagios` can run it. No change to `commands.cfg` is needed. | |
| C10 | msmtp is the transport | `readlink -f $(command -v sendmail)` | Points to msmtp. | |
| C11 | Script is idempotent | Run `configure-pinpoint-privileges.sh` twice | Second run succeeds. No duplicate sudoers lines, `/etc/msmtprc` content is not wiped. | |

## D. Phase 4: `pinpoint-apply-smtp` helper

Feed it on stdin. Run as `pinpoint` through sudo.

| ID | Case | Input | Expected | Result |
|---|---|---|---|---|
| D1 | Valid Gmail settings | `smtp.gmail.com`, 587, STARTTLS, user, 16-char password, sender | Exit 0. `/etc/msmtprc` rewritten, mode `640`, owner `root:nagios`. | |
| D2 | Password stays secret | Run D1, then check `ps`, the log, helper stdout and stderr | Password appears nowhere except `/etc/msmtprc`. | |
| D3 | Atomic write | Kill the helper mid-write | `/etc/msmtprc` is the old complete file or the new one, never partial. | |
| D4 | Bad port | Port `0`, `70000`, `abc` | Non-zero exit, short message, file unchanged. | |
| D5 | Bad TLS mode | `none` (never allowed: the login is always sent), `ssl`, or any value other than `starttls` | Non-zero exit, file unchanged. | |
| D6 | Newline injection | Host or user containing `\n` followed by extra msmtp directives | Rejected, file unchanged, no extra directive written. | |
| D7 | Control characters and shell syntax | Tab, ``, ``, DEL and non-ASCII in `username`/`password`; `$(...)` in the password | Control and non-ASCII rejected. `$(...)` is written literally inside quotes. Nothing executes. | |
| D8 | Missing field | Empty host or empty password | Non-zero exit, file unchanged. | |
| D9 | Oversized input | Several MB on stdin | Rejected quickly. | |
| D10 | No arguments accepted | Pass the settings as arguments | Ignored or refused. Never read from the command line. | |
| D11 | Ownership kept | Run D1 repeatedly | Owner and mode stay `root:nagios 640` every time. | |
| D12 | Non-root direct run | Run the helper as `pinpoint` without sudo | Fails with a clear message. | |
| D13 | Real web path | As `pinpoint`: `sudo -n /usr/local/sbin/pinpoint-apply-smtp` with valid JSON on stdin | Exit 0 and `/etc/msmtprc` updated. | |
| D15 | Password round trip | Apply 18 awkward passwords (spaces, leading/trailing blanks, `#`, `"`, `\`, `$`, 256 characters) for 4 usernames, then send with the real msmtp to a fake local SMTP server | The server receives exactly the username and password that were typed. | |
| D14 | Trailing newline | Valid JSON where `username`, `password`, `host` or `sender` ends in `\n` | Exit 1, file unchanged. Guards against Python's `$` matching before a final newline (the helper uses `fullmatch`). | |

Input contract for the helper (stdin, one JSON object, exactly these fields):
`{"host": str, "port": int 1-65535, "tls": "starttls", "username": str, "password": str, "sender": email}`.
`username` and `password` may contain any printable ASCII character, spaces included. Control characters (line breaks, tabs) and non-ASCII are rejected.

## E. Phase 4: end to end (needs the PinPoint SMTP settings API, which does not exist yet)

Use a throwaway Gmail account with an app password.

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| E1 | Save settings | Fill the Settings card, save | Database row saved, helper runs, `/etc/msmtprc` updated. | |
| E2 | Password write-only | `GET` the SMTP settings | Password never in the response. | |
| E3 | Test email arrives | "Send test email" | Message reaches the admin's real inbox. | |
| E4 | Verification | Answer Yes to "Did it arrive?" | `Email_Verified_At` set, notifications may be enabled. | |
| E5 | Verification No | Answer No | Admin is sent to "Change email". Notifications stay off. | |
| E6 | Wrong app password | Save a wrong password, send test | Plain error text from the transport, not just "failed". | |
| E7 | Blocked port | Block outbound 587 (`ufw`/`iptables`), send test | Error says the connection failed on `smtp.gmail.com:587`. | |
| E8 | Nagios notification | Force a notification: `printf "[%lu] SCHEDULE_FORCED_HOST_CHECK;<host>;%lu\n" ...` or stop a monitored service | Email arrives at the admin's real address. | |
| E9 | Recovery mail | Bring the service back | Recovery mail arrives (or is documented as not sent, per plan Q3). | |
| E10 | Notifications off by default | Fresh install before SMTP is saved | Notifications disabled. No mail queued. | |
| E11 | Key change | Change `PINPOINT_SECRETS_KEY`, reopen the card | Password shows as needing re-entry. Nothing crashes. | |
| E12 | Upgrade keeps settings | Re-run `deploy-pinpoint-web.sh` after E1 | Settings and `/etc/msmtprc` unchanged, mail still sends. | |

## F. Security and regression

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| F1 | Other users cannot read the secret | As an unrelated local user: `cat /etc/msmtprc` | Permission denied. | |
| F2 | `nagios` can read it | As `nagios`: `cat /etc/msmtprc` | Allowed (needed to send). Documented limit. | |
| F3 | Credentials file removal | Confirm with `YES` in `pinpoint-web-credentials` | File shredded, marker removed. | |
| F4 | Existing privileges unchanged | Re-run the existing verification of `configure-pinpoint-privileges.sh` | nmap capabilities, Nagios reload and NCPA key checks still pass. | |
| F5 | Full first boot | Run the whole `pinpoint-firstboot.sh` chain on a clean VM | All steps complete, service disables, no new warnings in the logs. | |
| F6 | CRLF safety | Check scripts in the built ISO for `\r` | None. The repository stores LF. | |

---

## Recording results

Write `pass`, `fail` with a one-line reason, or `skipped` with why, and note the Ubuntu
version, PinPoint commit and installer commit used. Do not close the feature until every A,
B and C case passes on 22.04.
