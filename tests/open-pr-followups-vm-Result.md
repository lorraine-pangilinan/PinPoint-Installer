# open-pr-followups-vm-Result

Result of testing the open pull requests #14, #10 and #8 against `main`, and the follow-up fixes on
branch `fix/upgrade-checks-and-log-limits`, on the test VM.

| Item | Value |
|---|---|
| Date (UTC) | 2026-11-15 16:00-16:35 |
| Host | `user-1` (Ubuntu 22.04.5 PinPoint appliance, snapshot taken) |
| Base | `main` at `ff54bd1` |
| App | Network-Diagnosis-System `e0c348b4` |

## The open PRs against main

| PR | Result | Verdict |
|---|---|---|
| #14 health check and the `restart nagios` rule | Main: 60 passed, 1 failed (the intended restart rule is reported as a fault). PR: 61 passed, 0 failed. Extra `stop`, `start`, `restart sshd` and `restart nagios *` rules are each reported; a missing restart rule is reported. Merges cleanly with main and with this branch. | Merge |
| #10 NCPA resource helper | Its appliance test passes with main's helper; 12 of its 14 unit tests pass on main. One failure is a string match (main calls the same installer through a variable). The other is a real gap: no early check that the helper files are in the setup folder. Conflicts with main in 7 files and would replace main's newer helper. | Close; gap fixed here |
| #8 log retention | Duplicates main's `configure-journald-logs.sh`. On an upgrade it calls main's own file "administrator-edited" and adds a second logrotate rule for `/var/log/pinpoint-*.log`, so logrotate reports `duplicate log entry` and skips it. On a fresh install its 100M / 7 day file makes main's script think an administrator edited the drop-in, so main's 200M / 30 day is never applied. | Close; useful parts done here |

## Fixes on this branch

| Change | Check on the VM | Result |
|---|---|---|
| `deploy-pinpoint-web.sh` stops at step 1 if `install-resource-helper.sh` or `pinpoint-apply-resources.py` is missing | Upgrade from a setup folder without `pinpoint-apply-resources.py` | **PASS**: stopped at [1/12] with "Nothing was changed"; app and service file unchanged |
| `deploy-pinpoint-web.sh` runs `configure-journald-logs.sh` (reported, not fatal) | Full web upgrade on a server with no log limits | **PASS**: exit 0 in 29 s, "Journal and installer log limits in place", 200M / 30day drop-in and one logrotate rule, logrotate config valid, web HTTP 200 |
| `configure-journald-logs.sh` leaves the limits to an administrator who set them in `journald.conf` or a drop-in under `/etc` or `/run` | `tests/journald-log-tests.sh` (new J10-J12) | **PASS 12, FAIL 0** |
| `pinpoint-healthcheck.sh` accepts the mode the app writes for `hosts.cfg` (640) | Modes 664, 640, 644 pass; 600 (group cannot read) and 666 (world-writable) fail | **PASS**; health check now 60 passed, 1 failed (the #14 item) |

## Problems in the test itself

- A copy made from the Windows working tree had CRLF in `pinpoint-apply-resources.py` (checked out
  before `*.py eol=lf`), so the installed helper's shebang became `python3 -I\r` and the first full
  upgrade failed at the helper step and restored the previous app. Not a product bug: the files in
  git are LF. Later copies were made with `git archive`, and the helper was reinstalled with LF.
- The first incomplete-folder run was not incomplete (`cp` stopped on the `manifests` folder before
  the file was removed). Corrected and rerun above.
- J1-J5 failed once because that broken run had removed the log files; rerun with them in place:
  12 of 12.

## VM state afterwards

Sudoers, journald and logrotate files as on `main`; `hosts.cfg` back to `pinpoint:nagios 640`;
Nagios and PinPoint web running. Test copies in `/root/prtest/` and `/root/pinpoint-fix/`.
