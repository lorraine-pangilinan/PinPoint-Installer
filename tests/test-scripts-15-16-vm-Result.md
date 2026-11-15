# test-scripts-15-16-vm-Result

Fixes for issues #15 and #16 (false failures in the installer's own test scripts), tested on the
test VM `user-1` (Ubuntu 22.04.5 PinPoint appliance) on 2026-11-15, against `main` at `c8f0e01`.

**Result: PASS 24, FAIL 0.**

## #16: sudo allow-list in `check-interval-tests.sh` test 2.3

| ID | Check | Result |
|---|---|---|
| X16-1 | `main`'s test 2.3 on a correct install | FAIL, as reported in the issue (the bug) |
| X16-2 | Fixed test 2.3 on a correct install | PASS |
| X16-3 | Extra `systemctl restart sshd` rule | Reported (FAIL) |
| X16-4 | Wildcard `systemctl restart nagios *` rule | Reported (FAIL) |
| X16-5 | Resource helper allowed with any arguments | Reported (FAIL) |
| X16-6 | Test rules removed, `visudo -c` clean | PASS |
| X16-ci3 | Full `check-interval-tests.sh` run: 2.3 | PASS |

The allow-list now holds the four rules the installer creates, exactly as `sudo -l` prints them,
and compares whole lines. Before, a rule only had to contain one of three phrases, so
`restart nagios extra` would also have passed.

## #15: default setup folder

| ID | Check | Result |
|---|---|---|
| X15-*-a | `check-interval-tests.sh` and `smtp-admin-email-tests.sh` run from a checkout with no argument use the checkout's `setup/` | PASS |
| X15-*-b | An explicit folder argument still wins | PASS |
| X15-*-c | With no `setup/` next to `tests/` (ISO layout) the default is `/root/pinpoint` | PASS |
| X15-*-d | A folder with no scripts stops with "No installer scripts in ..." and exit 1, instead of "syntax errors in *.sh" | PASS |
| X15-j1, j2 | `journald-log-tests.sh`: same default; a wrong path gives a clear error; full run from the checkout 12/12 | PASS |
| X15-ci1, ci2 | Full `check-interval-tests.sh` (`SKIP_SCAN=1 SKIP_CADENCE=1`) from the checkout: used `setup/`, 1.12 passes; **PASS 27, FAIL 0, SKIP 12** | PASS |
| X15-s1-s3 | Full `smtp-admin-email-tests.sh` from the checkout: used `setup/`, A12 passes, A10 runs the real upgrade (no exit 127); **PASS 24, FAIL 0, SKIP 19** | PASS |

The SMTP runner rewrites `/etc/msmtprc`; it was saved before and put back after (X15-s4). Nagios and
PinPoint web were running at the end (Z1).
