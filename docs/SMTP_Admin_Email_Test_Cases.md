# Test Cases: Admin Email Gate and SMTP Notifications

Covers the installer side of `SMTP_Admin_Email_Plan.md` (Phases 3 and 4) and the end-to-end
checks that need the PinPoint server and client. Server and client unit tests are listed in
plan section 7 and are not repeated here.

Status of every case: **not run** unless a result is written in the Result column.

## Conventions

- **VM**: disposable Ubuntu 22.04 (the supported target), snapshot taken before each run.
  A 24.04 run is indicative only.
- **PINPOINT-OLD**: a PinPoint release without `--require-email-change`.
- **PINPOINT-NEW**: a release with Phase 1 (flag, `Must_Change_Email`, email route).
- Commands run on the VM as root unless stated. Never paste real passwords into this file.
- "Log" means `/var/log/pinpoint-web.log` for `deploy-pinpoint-web.sh` and
  `/var/log/pinpoint-privileges.log` for `configure-pinpoint-privileges.sh`.

---

## A. Phase 3: email gate requested by the installer

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| A1 | Old PinPoint is refused before the database exists | Fresh VM, install with PINPOINT-OLD | Install stops at step 9/12 with `this PinPoint version has no 'flask init-production --require-email-change'`. `system.db` and `history.db` do not exist. | |
| A2 | Re-run after A1 still has no half-installed state | Run `deploy-pinpoint-web.sh` again on the VM from A1 | Same error, same stop. It is not treated as an existing install and does not skip admin creation. | |
| A3 | New PinPoint creates a gated admin | Fresh VM, install with PINPOINT-NEW | Log shows `Administrator account created.` and `Administrator must set a real email at first sign-in.` | |
| A4 | Admin row has the flag | After A3: query `User.Must_Change_Email` for the admin through the app environment | `True`. Exactly one user exists. | |
| A5 | Placeholder format | Read the credentials file | Username matches `admin-[0-9a-f]{5}@pinpoint.lan`. Label says temporary placeholder. | |
| A6 | Credentials file wording | `sudo pinpoint-web-credentials` | Text explains the first-login email step and that the placeholder stops working afterwards. | |
| A7 | Password never leaks | `grep` the log and `ps` during install for the generated password | Not found in the log, not in any process argument. | |
| A8 | Flag check failure of the command itself | Make `init-production` fail (for example run with the database file read-only) | Install stops with `flask init-production --require-email-change' failed. The administrator was not created.` | |
| A9 | Flag-set check fails loudly | Simulate an admin created without the flag | Install stops with `created without the first-login email requirement`. | |
| A10 | Existing install is not gated | Run `deploy-pinpoint-web.sh` on a VM that already has a database | Upgrade completes. No new admin, no credentials file, no error about the flag. | |
| A11 | Upgrade keeps the database | After A10 | Existing users unchanged and `Must_Change_Email` false for all. | |
| A12 | Script syntax | `bash -n` on every file in `setup/` | No errors. | |

## B. First sign-in and Nagios contact (needs PINPOINT-NEW, server and client)

| ID | Case | Steps | Expected | Result |
|---|---|---|---|---|
| B1 | Gate appears | Sign in with the placeholder | "Set your email" screen. Other pages are blocked. | |
| B2 | Other API blocked | With the session, call any normal API | 403 with the email-change message, not the password one. | |
| B3 | Placeholder rejected | Submit an address ending in `@pinpoint.lan` | Rejected. Flag stays set. | |
| B4 | Wrong current password | Submit a real address with a wrong password | Rejected, nothing saved. | |
| B5 | Duplicate address | Submit an address another user holds | 409, nothing saved. | |
| B6 | Success | Submit a valid new address and the correct password | App opens. Flag cleared. | |
| B7 | Sign-in name changed | Sign out, sign in with the placeholder, then with the new address | Placeholder fails. New address works. | |
| B8 | Nagios contact updated | `grep -A6 'define contact' /usr/local/nagios/etc/objects/hosts.cfg` | Contact `email` is the new address. No `pinpoint.lan`. | |
| B9 | Nagios still valid | `/usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg` | Passes with no errors. | |
| B10 | Regeneration failure | Make `hosts.cfg` unwritable, then submit the change | Email is still saved, response carries a warning, error is logged. Admin is not stuck. | |

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
| D5 | Bad TLS mode | `none` (never allowed: the login is always sent), or any value outside starttls / ssl | Non-zero exit, file unchanged. | |
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
`{"host": str, "port": int 1-65535, "tls": "starttls"|"ssl", "username": str, "password": str, "sender": email}`.
`username` and `password` may contain any printable ASCII character, spaces included. Control characters (line breaks, tabs) and non-ASCII are rejected.

## E. Phase 4: end to end (needs PINPOINT-NEW with SMTP settings)

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
