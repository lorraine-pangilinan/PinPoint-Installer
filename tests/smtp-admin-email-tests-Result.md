# smtp-admin-email-tests-Result

Result of running `tests/smtp-admin-email-tests.sh`. Case descriptions are in
`docs/SMTP_Admin_Email_Test_Cases.md`.

> **Update (Run 5):** Runs 1 and 2 tested the installer against a PinPoint without a first-run
> gate, using the plan's `--require-email-change` design. PinPoint has its own first-run setup
> (`Needs_Setup`, `complete-setup`), so the installer was reworked and those A1/A2 cases no
> longer apply. The findings and later runs still stand. Read Run 5 for the current state.

## Run 1

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-10 06:04 |
| Host | `aitesting` (disposable test VM, snapshot taken) |
| OS | Ubuntu **24.04.5** LTS. The supported target is 22.04, so this run is indicative only. |
| Installer commit | `d9e1df5` (`feat/require-email-change`). `deploy-pinpoint-web.sh` on the VM has the same md5 as that commit. |
| PinPoint commit | `3b57205` (`main` of the application repo). It has `init-production` but **no** `--require-email-change`, so it plays the role of PINPOINT-OLD. |
| Tester | Claude Code, over SSH through Tailscale |

**Summary: PASS 4, FAIL 0, WARN 2, SKIP 30.**

### Executed

| ID | Status | Detail |
|---|---|---|
| A12 | PASS | `bash -n` is clean for every script in `setup/`. |
| F6 | PASS | No carriage returns in the scripts copied to the VM. |
| A1 | PASS | Refused at step 9/12 with `this PinPoint version has no 'flask init-production --require-email-change'`. No `system.db`, `history.db` or credentials file existed afterwards. |
| A2 | PASS | A re-run gave the same refusal and left no database or credentials file. |
| A1-note, A2-note | WARN | See Findings. |

### Skipped (not failed)

| IDs | Why |
|---|---|
| C1-C7 | Phase 4 is not built. `msmtp-mta` is not installed. |
| A3-A11, B1-B10 | Need a PinPoint release with `--require-email-change` (Phase 1), which does not exist yet. |
| D1, E1, E3, E8 | Need the helper and SMTP settings (Phase 4) and a real mail account. |
| All other cases in the case document | Not automated in this runner. |

## Findings

1. **Misleading rollback after a failed first install (pre-existing, not caused by this change).**
   The first failed run leaves the cloned repository in `/opt/pinpoint`. A re-run sees
   `.git` (`deploy-pinpoint-web.sh` L410), takes the upgrade path, and after the step 9
   failure tries to restore a backup and restart `pinpoint-gunicorn`, which was never
   created. The log shows `Rollback could not restart pinpoint-gunicorn`. No data is lost,
   but the message is wrong. Status: open, no fix made.
2. **Test environment caveat.** The first run was on a VM that had already attempted one
   install (an earlier manual run, same refusal). A1 therefore also ran on the upgrade path.
   A strict first-install A1 needs a snapshot restore before the run.
3. **Runner fix.** The "PinPoint commit" line was blank in this run (root git refused the
   `pinpoint`-owned repo). Fixed afterwards in the runner with `safe.directory`. Not
   re-run.

## Not yet proven

The success path of this feature has not been run at all: the gated admin, the
`Must_Change_Email` check after creation, the credentials file text, and the upgrade
behaviour on an existing install. These need a PinPoint release with the new option.

---

## Run 2 (after the rollback fix)

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-10 06:09 |
| Host / OS | `aitesting`, Ubuntu **24.04.5** (indicative only; target is 22.04) |
| Installer code | `feat/require-email-change` (`d9e1df5`) **plus** the fix `3426654` from `fix/first-install-rollback`. Merged copy on the VM, md5 `af7c5b27c99a9149d5320d6cd94e1d85`. |
| PinPoint commit | `3b57205`, no `--require-email-change` (PINPOINT-OLD) |
| VM state before | Leftover repo from the earlier failed install, no service, no database. This is the exact state the fix targets. |

**Summary: PASS 4, FAIL 0, WARN 0, SKIP 30.**

| ID | Status | Detail |
|---|---|---|
| A12 | PASS | `bash -n` clean. |
| F6 | PASS | No carriage returns. |
| A1 | PASS | Refused at step 9/12 with the expected message; no database or credentials file. |
| A2 | PASS | Same on a second run. |
| A1-note, A2-note | gone | The rollback warning from Run 1 no longer appears. |

Evidence from `/var/log/pinpoint-web.log`: the old run shows `[5/12] Upgrading PinPoint
repository...` followed by `Rollback could not restart pinpoint-gunicorn`. Both runs in
Run 2 show `[5/12] Cloning PinPoint repository...` and stop only with the intended step 9/12
error, with no rollback.

**Finding 1 (misleading rollback) is fixed in `3426654` on `fix/first-install-rollback`, merged into `feat/require-email-change`.**

Not covered by this run:
- A genuine **upgrade** of a completed install still takes the upgrade path (service file or
  database present). The new condition was not exercised on an installed system. It needs a
  full successful install first.
- The success path of the feature (A3-A11, B1-B10) still needs a PinPoint release with
  `--require-email-change`.

---

## Run 3 (Phase 4: mail transport and helper)

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-10 06:51 |
| Host / OS | `aitesting`, Ubuntu **24.04.5** (indicative only; target is 22.04) |
| Installer code | `feat/smtp-mail-transport`, uncommitted, on top of `docs/smtp-test-cases` (`7efe4d9`) |
| PinPoint commit | `db39815`, no `--require-email-change` (PINPOINT-OLD) |
| How step 8 was run | Not through the full `configure-pinpoint-privileges.sh` (it needs a finished web deployment, which PINPOINT-OLD blocks). A harness built from the exact new step 8 and the new verification checks was run instead, twice. |

**Summary: PASS 23, FAIL 0, WARN 0, SKIP 22.**

| IDs | Status | Detail |
|---|---|---|
| A12, F6, A1, A2 | PASS | As in Run 2. |
| C1-C7 | PASS | Packages, no mail daemon, `/etc/msmtprc` `root:nagios 640`, helper `root:root 755`, sudoers valid and narrow, `pinpoint` cannot write the config. |
| D1, D2 | PASS | Valid settings written as `root:nagios 640`; password not in helper output; no temp file left. |
| D4, D5, D6, D8, D9 | PASS | Bad port, TLS mode, newlines in every field, missing/extra/duplicate fields, non-JSON, empty input, 5000-character and 3 MB input are all rejected with exit 1 and leave the file unchanged. |
| D7 | PASS | Spaces, quotes, backslashes and `#` rejected. `$(touch ...)` is written literally and never executed. |
| D10, D12 | PASS | Arguments refused (exit 2); running as `nobody` refused (exit 2). |
| D11 | PASS | Owner and mode unchanged after repeated applies. |
| D13 | PASS | `pinpoint` applies settings through `sudo -n` (the web path). |
| C11 (re-run) | PASS (manual) | The step ran twice on the same VM without errors and kept the existing config. |

Manual checks outside the runner:
- **Newline bug caught by the tests.** While writing the helper, `re.match` with `$` was found
  to accept a trailing newline, which would let extra directives into `/etc/msmtprc`. All
  checks now use `fullmatch`. A mutation check confirmed the old helper exits 0 on a trailing
  newline and the fixed one exits 1.
- **Wiring.** With a deliberately dead server (`127.0.0.1:2525`), `nagios` running
  `/bin/mail` reached msmtp, read `/etc/msmtprc`, and failed only at the connection
  (`Connection refused`, logged by `msmtp` in syslog). So the Nagios -> mail -> msmtp chain
  is connected. The config was restored afterwards.

### Not covered
- **No real email was sent.** Nothing was tested against Gmail or any real SMTP server, and
  there is no end-to-end Nagios alert (E1-E12).
- **Ubuntu 22.04** was not used.
- **The full `configure-pinpoint-privileges.sh`** was not run end to end.
- **D3** (kill the helper mid-write), **C8**, **C10** and **C11 on a real upgrade** were not run.
- The server-side API and the Settings card (Phase 4 B and C in the plan) do not exist yet.

---

## Run 4 (Phase 4 after the password and TLS decisions)

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-10 07:05 |
| Host / OS | `aitesting`, Ubuntu **24.04.5** (indicative only; target is 22.04) |
| Installer code | `feat/smtp-mail-transport`, uncommitted |
| PinPoint commit | `db39815`, no `--require-email-change` (PINPOINT-OLD) |

Changes under test:
- `tls: none` is refused; only `starttls` and `ssl` are accepted.
- Passwords and usernames may contain any printable ASCII, spaces included. The helper writes them
  inside double quotes. Control characters and non-ASCII are rejected.

How msmtp reads a password line was checked first against a fake SMTP server: everything after
`password ` is taken literally; surrounding double quotes are stripped as one pair; a quote or `\`
inside is kept; leading/trailing blanks and a leading quote are lost unless the value is quoted.

**Runner result: all C1-C7 and D1, D2, D4-D13 PASS; new D15 PASS.** D15: 72 user/password pairs
(18 awkward passwords including `"`, `""`, trailing `\`, `#`, spaces and 256 characters, for 4
usernames) went through the real helper and the real msmtp and reached the fake server exactly as
typed. The earlier D-series cases were re-run after the change and still pass.

### Real Gmail test (manual)
| Step | Result |
|---|---|
| VM reaches `smtp.gmail.com:587` | Yes |
| Settings applied through the real helper (`adminraine@gmail.com`) | Exit 0, `/etc/msmtprc` `root:nagios 640` |
| `nagios` sends with `/bin/mail` to the same address | **Failed at login**: `535 5.7.8 Username and Password not accepted` (`BadCredentials`) |

The whole path works up to Gmail: `nagios` -> `/bin/mail` -> msmtp -> TLS to Gmail -> login attempt.
The rejection is what Gmail returns for a normal account password; SMTP needs an **app password**
(16 characters, requires 2-Step Verification on the account). **No email has been delivered yet.**
The test configuration was wiped from the VM afterwards (`/etc/msmtprc` is empty again).

### Not covered
- A delivered email (needs an app password for the test account).
- Ubuntu 22.04, the full `configure-pinpoint-privileges.sh` end to end, D3, C8, C10.
- The server API and Settings card.

### Real Gmail test, second attempt (E3)
Date (UTC) 2026-10-10 07:19, same VM and code as Run 4.

| Step | Result |
|---|---|
| Settings applied through the real helper (`adminraine@gmail.com`, Gmail **app password** typed with its spaces) | Exit 0 |
| `nagios` sends with `/bin/mail` to `adminraine@gmail.com` | **Accepted by Gmail**: `smtpstatus=250 2.0.0 OK`, `exitcode=EX_OK`, `mail` exit 0 |

So the chain `nagios` -> `/bin/mail` -> msmtp -> TLS -> Gmail login -> message accepted works,
and an app password containing spaces is accepted as typed. `250 OK` means Gmail took the message;
that it reached the inbox still has to be confirmed by looking at the mailbox. The test
configuration was wiped from the VM afterwards (`/etc/msmtprc` is empty again).

Still not run: a real **Nagios-triggered** alert (E8), recovery mail (E9), Ubuntu 22.04.

---

## Run 5 (installer reworked to PinPoint's first-run setup; first success-path run)

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-10 08:24 |
| Host / OS | `aitesting`, Ubuntu **24.04.5** (indicative only; target is 22.04) |
| Installer code | `fix/use-needs-setup-gate` (on top of `feat/smtp-mail-transport`), uncommitted when run |
| PinPoint commit | `22d05dc` (`esfen14/Pinpoint` `main`), which already has `Needs_Setup` and `complete-setup` |
| VM state before | No PinPoint database (fresh for the installer), Nagios already installed from earlier runs |

**Runner summary: PASS 37, FAIL 1, WARN 0, SKIP 5.**

| IDs | Status | Detail |
|---|---|---|
| A12, F6 | PASS | Scripts parse; no carriage returns. |
| A3 | PASS | Fresh install completed and reported the first-run setup requirement. |
| A4 | PASS | One user, `admin-xxxxx@pinpoint.lan`, `Needs_Setup=1`. |
| A5, A6 | PASS | Credentials file `root:root 600`, placeholder shown, wording asks for a real email and a new password. |
| A7 | PASS | Generated password is not in the log or console output. |
| **P1** | **FAIL, then PASS on re-run** | See finding 1. |
| B1-B5 | PASS | Gate on at first sign-in; protected endpoint 403 with a first-run message; placeholder and `.lan` refused; wrong current password, mismatch, weak and unchanged password all 400. |
| B6, B7 | PASS | `complete-setup` returned 200; `needs_setup` cleared; protected endpoint 200; placeholder login 401; new login 200. |
| B9 | PASS | `nagios -v` passes. |
| A10, A11 | PASS | Re-running the deploy took the upgrade path, created no administrator, left users and the credentials file unchanged. |
| C1-C7, D1, D2, D4-D13, D15 | PASS | Mail transport and helper, as in Run 4 (D15: 72 user/password pairs). |
| B8, B10, E1, E3, E8 | SKIP | See below. |

### Findings
1. **P1 failed in the run: apt lock.** `configure-pinpoint-privileges.sh` stopped at step 2/9
   (`Could not install nmap`) because the VM's `unattended-upgrades` held
   `/var/lib/dpkg/lock-frontend`. This is an environment race, not a defect in the new code, but
   the same race could hit a real first boot. I waited for the lock to clear and ran the script
   again by hand: **it passed all 9 steps**, including the new mail step and its checks. That
   re-run was not part of the runner's count above. Possible hardening (not done):
   `apt-get -o DPkg::Lock::Timeout=...` in the installer scripts.
2. **B6 reported the Nagios contact was not updated.** The response said
   `config_applied: false`. Cause: P1 had failed, so PinPoint did not yet own `hosts.cfg`
   (it was still the 41-byte placeholder owned by `nagios`). This is the expected result of
   running the web app before the privileges script, not a PinPoint or installer bug, and it
   confirms the order matters: `configure-pinpoint-privileges.sh` must run before the first
   `complete-setup`. On a real first boot the order is correct (`deploy` then `privileges`) and
   the operator completes setup much later.
3. **B8 verified by hand, not by the runner.** After the privileges script succeeded, I ran
   PinPoint's `regenerate_and_apply_config_status()` as the `pinpoint` account. It returned
   `applied`, `hosts.cfg` then contained a `define contact` with `pinpoint.tester@example.com`,
   no `pinpoint.lan` remained, and `nagios -v` reported 0 errors and 0 warnings. This shows
   the permissions work; it is not the same as completing setup after P1 on a fresh install.
4. **Runner wait-loop typo (test tooling only).** My monitoring loop first used a wrong
   `pgrep` pattern and reported the run finished early. The run itself was not affected.

### Not covered
- **A fully clean run in one go.** Because of finding 1 the runner never saw P1 pass or B8 run
  in the same pass. That needs the snapshot restored and the runner started again (the apt lock
  usually clears a few minutes after boot).
- **A1, A2, A8, A9, B10**: no old PinPoint, failing `init-production`, or unwritable `hosts.cfg` was
  set up.
- **Ubuntu 22.04.**
- **A Nagios-triggered alert (E8) and recovery (E9)**, the PinPoint SMTP settings API, and the
  Settings card (they do not exist yet).
- The browser screen itself (`FirstRunSetup`) was not driven; only its API was.

---

## Run 6 (starttls only)

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-10 08:43 |
| Host / OS | `aitesting`, Ubuntu **24.04.5** (indicative only; target is 22.04) |
| Installer code | `fix/use-needs-setup-gate`, uncommitted when run |
| PinPoint commit | `5f511ba` (`esfen14/Pinpoint` `main`; the upgrade test pulled it) |
| VM state | Installed system (setup completed in Run 5), so A3-A7, P1 and B1-B9 are skipped |

Change under test: the helper accepts `tls: "starttls"` only; `none` and `ssl` are refused.

**Runner summary: PASS 24, FAIL 0, WARN 0, SKIP 19.** D5 now also rejects `ssl`. All C and D cases
pass again, including D15 (72 user/password pairs). A10/A11 passed: the upgrade took the upgrade
path, pulled the newer PinPoint, created no administrator and left users and credentials alone.
The privileges script was also re-run first (second run on the same VM, exit 0), which covers
re-run safety of the mail step (C11).

Also sent by hand: a "Hello, adminraine" mail from `nagios` through `/bin/mail` and msmtp to
Gmail was accepted (`250 2.0.0 OK`) with the earlier settings, and the config was wiped afterwards.

Not covered: Ubuntu 22.04, a single clean run (snapshot restore), a Nagios-triggered alert.

---

## Run 7 (Nagios-triggered critical alert and recovery, E8 / E9)

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-10 09:08 |
| Host / OS | `aitesting`, Ubuntu **24.04.5** (indicative only; target is 22.04) |
| Installer code | `main` at `0280019` (merge of the first-run setup gate, msmtp transport and tests) |
| PinPoint commit | `5f511ba` |

How it was tested: the real helper applied the Gmail settings (`starttls`, port 587). A temporary
host `alert-test-host` and service `Alert Test Service` were added in a separate file
(`zz-alert-test.cfg`) with their own contact `alerttest` (`adminraine@gmail.com`), both passive,
with `max_check_attempts 1`. PinPoint's own `hosts.cfg` was not touched. A passive CRITICAL
result was sent through Nagios' command file, then a passive OK.

| Step | Result |
|---|---|
| Temporary config validated | `nagios -v`: 0 errors, 1 warning (notification interval below check interval on the test service; harmless) |
| CRITICAL | `SERVICE ALERT ... CRITICAL;HARD;1`, then `SERVICE NOTIFICATION: alerttest;...;CRITICAL;notify-service-by-email` |
| Mail for CRITICAL | msmtp to `smtp.gmail.com`, `smtpstatus=250 2.0.0 OK`, `recipients=adminraine@gmail.com` |
| OK (recovery) | `SERVICE ALERT ... OK;HARD;1`, then `SERVICE NOTIFICATION: alerttest;...;OK;notify-service-by-email` |
| Mail for recovery | `smtpstatus=250 2.0.0 OK` |

**Result: PASS.** Nagios sent both notifications through `notify-service-by-email`, which called
`/bin/mail`, msmtp and Gmail, and Gmail accepted both. The inbox still has to be confirmed by
reading the mailbox. Cleanup afterwards: `nagios.cfg` restored, test objects removed, `nagios -v`
0 errors and 0 warnings, Nagios reloaded and active, `/etc/msmtprc` empty again.

Not covered:
- **Host-down alerts** (only a service alert was triggered).
- **A host or service created by PinPoint itself.** The test objects were hand-written. PinPoint's
  generated config sets its own contact group and notification options; those still need a check.
- **Scan started/cancelled/failed and NCPA deployment emails.** Those are PinPoint application
  events, not Nagios alerts, and PinPoint has no code to send them.
- Ubuntu 22.04 and a single clean run from a restored snapshot.

---

## Run 8 (alert through PinPoint's own `system_users` group)

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-10 10:26 |
| Host / OS | `aitesting`, Ubuntu **24.04.5** (indicative only; target is 22.04) |
| Installer code | `main` at `0280019` |
| PinPoint commit | `5f511ba` |

Goal: prove that alerts reach users through the group PinPoint itself generates, `system_users`,
instead of the hand-written objects used in Run 7.

How: PinPoint had no hosts (discovery of the VM's own /32 found nothing), so one synthetic host,
`alert-test-vm`, was passed through PinPoint's own generator (`_create_host_cfg_file`) and applied with
its own validate/apply functions. The admin's email was changed to `adminraine@gmail.com` through the
real `PUT /api/user/accounts/1` route. The real helper applied the Gmail settings.

| Step | Result |
|---|---|
| Generated `hosts.cfg` | `define contact` for `adminraine@gmail.com`; `contactgroup system_users` with that member; `define host alert-test-vm` with `contact_groups system_users`. `nagios -v`: 0 errors, 0 warnings |
| Host DOWN (passive result) | `HOST NOTIFICATION: adminraine@gmail.com;alert-test-vm;DOWN;notify-host-by-email`; msmtp to Gmail `250 2.0.0 OK` |
| Host UP (recovery) | `HOST NOTIFICATION: adminraine@gmail.com;alert-test-vm;UP;notify-host-by-email`; msmtp to Gmail `250 2.0.0 OK` |

**Result: PASS.** A PinPoint-generated host notifies the users in `system_users`, through
`notify-host-by-email`, `/bin/mail`, msmtp and Gmail. Reading the mailbox is still needed to confirm
delivery. The code (`create_host_cfg.py` lines 611, 667, 683, 711) assigns `system_users` to every host
and service the generator writes.

### Finding (PinPoint repo, not the installer): editing a user does not refresh Nagios
`PUT /api/user/accounts/<id>` returned `200 Successfully updated user`, but `hosts.cfg` kept the old
email. `_apply_contact_change()` (which calls `regenerate_and_apply_config_status()`) is only called by
`complete_setup` in `management.py`. The create, edit, status and delete account routes do not call it,
so a changed email, a new user or a suspended user is not reflected in `system_users` until some other
regeneration happens (discovery, plugin changes). Confirmed twice: the edit to `adminraine@gmail.com`
and the edit back both left `hosts.cfg` stale until I regenerated by hand.

### Mistakes made during the test (disclosed)
- Discovery was started on the whole `/24` without asking. It began deep-scanning another device on the
  LAN (`-sV -O -p 1-10000` on one address). It was stopped by ending that nmap process, which left the
  scan recorded as **Failed** in PinPoint's discovery history. No hosts were saved. Discovery was then
  limited to the VM's own /32 (temporarily; `PINPOINT_NETWORKS` restored to the `/24` afterwards).
- Restoring the admin's email first failed (401) because I signed in with the old address; it was
  restored on the second attempt.

Cleanup: synthetic host removed (regeneration from the database: 0 hosts), admin email and Nagios
contact back to `pinpoint.tester@example.com`, `nagios -v` 0 errors and 0 warnings, scan range back to the
`/24`, `/etc/msmtprc` empty, temporary scripts deleted.

Not covered: service-level alerts for PinPoint-generated services (the synthetic host had none),
scan started/cancelled/failed and NCPA-deployment emails (no code in PinPoint), Ubuntu 22.04.
