# smtp-admin-email-tests-Result

Result of running `tests/smtp-admin-email-tests.sh`. Case descriptions are in
`docs/SMTP_Admin_Email_Test_Cases.md`.

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
