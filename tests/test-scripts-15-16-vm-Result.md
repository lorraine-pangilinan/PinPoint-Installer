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

## Monitored-host cases (5.3-5.9, 5.12)

These were skipped above because the VM monitored no device. Getting them to run found two more
faults in `check-interval-tests.sh`, both fixed on this branch:

| Fault | Effect | Fix |
|---|---|---|
| The runner started discovery with an empty request; the app wants a JSON body (`{}` or `{"target": ...}`) and answered 400 | The scan never started, and the runner then waited out `SCAN_TIMEOUT` (default 6000 s). This is the "hang" in the comment on #15. | Send `{}`, add `SCAN_TARGET=IP` to scan one device, stop waiting when the start is refused |
| 5.5 counted backup files | The app names hosts.cfg backups by the minute (`host-DD-MM-YYYY-HH-MM.cfg`), so an interval change in the same minute as a scan rewrites that file instead of adding one; 5.5 failed although the backup was made | Pass when a backup is written or rewritten after the change |

Final run (`SKIP_SCAN=1`, devices `gateway` 192.168.130.1 and `dev-2f8e99` 192.168.130.3 added
through PinPoint's own discovery with `SCAN_TARGET`): **PASS 36, FAIL 0, SKIP 4.** 5.3-5.9 and 5.12 all
pass; 5.7 measured host checks 120 s apart at a 2-minute interval. The 4 skips need a pre-60 snapshot
(1.11, 3.8, 5.2) or have no installer check (5.13).

On the first try 5.7 watched `gateway`, which does not answer ping and is DOWN, so its checks
followed a different schedule (90 s). The runner prefers an UP host; once one existed it was chosen.

Notes for the app (not changed here): two configuration changes in the same minute keep only one
hosts.cfg backup, because the backup name has no seconds.

VM state: the two devices stay monitored in PinPoint; the check interval is back to 5 minutes.
