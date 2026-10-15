# VM test result: restart rule, event handler, log limits, check interval

First real-VM run of the changes merged on 2026-10-15 (installer `main` at `f48d90d`). Every case is
PASS, FAIL or SKIP with the reason; nothing is marked as passed unless it was run.

## Summary

| Part | Result |
|---|---|
| First boot from the ISO | **FAIL at step 8**, `configure-event-handler.sh`: "Permission denied" (bug 1). Steps 1 to 7 completed |
| `restart-sudoers-tests.sh` | **PASS 8, FAIL 0** |
| `event-handler-tests.sh` | **PASS 13, FAIL 0, SKIP 0** (after fixing the E12 test, bug 3) |
| `journald-log-tests.sh` | **PASS 9, FAIL 0** (after fixing the logrotate rule, bug 2) |
| `check-interval-tests.sh` (clean run) | **PASS 36, FAIL 0, WARN 0, SKIP 4** |
| `smtp-admin-email-tests.sh` | **Not run** in this round |

Steps 8 and 9 were run by hand after the first boot stopped (see "How the VM was patched"), so this run
shows the modules work, not that a fresh ISO installs cleanly. That needs a rebuilt ISO and a new install.

## Environment

| Item | Value |
|---|---|
| Date (UTC) | 2026-10-15 to 2026-10-16 |
| VM | Proxmox VM 102, installed from the ISO built from `main` at `f48d90d`, reached over Tailscale |
| OS | Ubuntu 22.04.5 LTS |
| PinPoint (deployed app) | `edb5036`, includes `server/scripts/pinpoint_event_handler.py` |
| Tester | Claude Code, over SSH, as a user with sudo |

## Bugs found

| # | Bug | Effect | Fix branch |
|---|---|---|---|
| 1 | The new scripts `configure-event-handler.sh` and `configure-journald-logs.sh` were committed `100644` (not executable). First boot runs modules by path | `pinpoint-firstboot.service` failed at step 8: `Permission denied`, exit 126. Steps 8 and 9 never ran | `fix/new-scripts-exec-bit` |
| 2 | The logrotate rule had no `su root root`. `/var/log` is group-writable on Ubuntu | `logrotate -d` rejected the rule ("parent directory has insecure permissions"); the module stopped with "Generated logrotate rule is invalid". Without the check, logrotate would have skipped every installer log | `fix/logrotate-su-directive` |
| 3 | Test E12 treated the stock `illegal_macro_output_chars` value as an override | False FAIL. The install was correct: the line is Nagios's default `` `~$&|'"<> `` | `fix/event-handler-test-e12` |

## How the VM was patched

The first boot stopped at step 8, so the rest was done by hand to keep testing:
`bash /root/pinpoint/configure-event-handler.sh`, then `configure-journald-logs.sh` (this failed on
bug 2 until the fixed script from `fix/logrotate-su-directive` was copied to `/root/pinpoint/`), then
the runners were copied to `/root/` and run as root.

## Restart rule (`restart-sudoers-tests.sh`)

| Case | Check | Result |
|---|---|---|
| R1 | `sudo -n /usr/bin/systemctl restart nagios` works as `pinpoint`, nagios stays active | PASS |
| R2 | `restart sshd` is refused | PASS |
| R3 | `restart nagios extra` is refused | PASS |
| R4 | `stop` and `start` are refused | PASS |
| R5 | `sudo -n -l` shows no wildcard or shell | PASS |
| R6 | `/etc/sudoers.d/pinpoint-restart` is `root:root 440` | PASS |
| R7 | `visudo -c` parses every sudoers file | PASS |
| R8 | Reload and SMTP helper rules unchanged | PASS |

## Event spool and handler (`event-handler-tests.sh`)

| Case | Check | Result |
|---|---|---|
| E1 | Spool is `nagios:pinpoint 2770` | PASS |
| E2 | Spool parent is `root:root 755` | PASS |
| E3 | `pinpoint` is in group `pinpoint` | PASS |
| E4 | `nagios` can write to the spool | PASS |
| E5 | New entries get group `pinpoint` (setgid) | PASS |
| E6 | `pinpoint` can read and delete entries | PASS |
| E7 | Other accounts cannot list the spool | PASS |
| E8 | Handler is `root:root 755` | PASS |
| E9 | `pinpoint` cannot modify the handler | PASS |
| E10 | `nagios` can run the handler | PASS |
| E11 | `enable_event_handlers` is not 0 (it is 1) | PASS |
| E12 | `illegal_macro_output_chars` left at the default | PASS (after the test fix; first run FAIL, bug 3) |
| E13 | Second run keeps owners and modes | PASS |

Not proved here: a real Nagios problem event actually firing the handler and PinPoint acting on it.
That depends on the application side.

## Journald limit and log rotation (`journald-log-tests.sh`)

| Case | Check | Result |
|---|---|---|
| J1 | Drop-in has `SystemMaxUse=200M`, `MaxRetentionSec=30day` | PASS |
| J2 | Drop-in is `root:root 644` | PASS |
| J3 | journald active, `journalctl --disk-usage` works (32.0M) | PASS |
| J4 | `/etc/logrotate.d/pinpoint` passes `logrotate -d` | PASS (after bug 2 fix) |
| J5 | Rule covers `/var/log/pinpoint-*.log` and has `su root root` | PASS |
| J6 | Second run succeeds | PASS |
| J7 | Edited journald drop-in is kept | PASS |
| J8 | Edited logrotate rule is kept | PASS |
| J9 | Forced rotation works, log file stays in place | PASS |

## Check interval (`check-interval-tests.sh`)

The clean run was PASS 36, FAIL 0, WARN 0, SKIP 4. Skipped (need the pre-60 snapshot): 1.11, 3.8, 5.2,
and 5.13 (no installer check by design). Case 2.2 now expects `stop` and `start` refused, and 2.3 allows
the new `restart nagios` rule alongside reload and the SMTP helper; both PASS.

An earlier run reported 4 failures (5.3, 5.5, 5.6, 5.7). Cause: two copies of the runner ran at the same
time (the first kept running on the VM after the SSH connection dropped), and both changed the check
interval. With one copy running, all four pass. That was a test-procedure error, not a product bug.

## Not tested

- A fresh install from a rebuilt ISO with the three fixes (bug 1 especially: step 8 and 9 under first boot).
- An upgrade of an existing appliance (re-running `pinpoint-setup.sh`), including a pre-existing custom
  journald or logrotate file.
- Failure path of the restart rule on a real VM (a deliberately invalid generated rule keeps the old file).
- `smtp-admin-email-tests.sh`.
- Cases needing the pre-60 snapshot: 1.11, 3.8, 5.2.
- A real Nagios event running the handler end to end.
