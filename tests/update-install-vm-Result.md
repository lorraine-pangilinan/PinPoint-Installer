# update-install-vm-Result

Result of testing plan Phases 4 and 5 (the update catalog and real Nagios updates) on a VM.
Branch `feat/update-catalog-install`, commit `1bca8ac`. Every case is marked PASS or FAIL. A case
is marked PASS only if it was run.

## Summary

| Part | Result |
|---|---|
| Portable tests on the VM | **PASS 148, FAIL 0** (catalog 25, controller 12, approvals 38, executor 29, resource helper 10, login hook 7, baseline downloads 14, first boot 13) |
| Install runner `tests/update-install-tests.sh` (one run, no rerun) | **PASS 36, FAIL 0** |
| Real update, start to finish | Nagios Core 4.5.11 to **4.5.14**: downloaded, checked against the manifest SHA-256, built as `pinpoint-updater`, installed, and passed the health suite |
| Rollback with a real build | Injected bad config, and a kill after install: both rolled back to 4.5.11, and Nagios and PinPoint web kept running |

## Environment

| Item | Value |
|---|---|
| Date (UTC) | 2026-11-14 |
| Host | `user-1`, disposable Proxmox VM over Tailscale; the user took a snapshot before the test |
| OS | Ubuntu 22.04.5 LTS, kernel 5.15.0-203-generic |
| Starting state | End of the follow-up test (`tests/update-fixes-vm-Result.md`), with Nagios Core 4.5.11 and the baseline set `pp-mon-baseline-1` |
| Code under test | `feat/update-catalog-install` at `1bca8ac`, copied to `/root/pinpoint-phase45/` in the `scripts/build.sh` layout; runner run with `PINPOINT_MODULE_DIR=/root/pinpoint-phase45` |
| Catalog used | `https://raw.githubusercontent.com/lorraine-pangilinan/PinPoint-Installer/feat/update-catalog-install/catalog/`, the pushed branch on GitHub (main has no `catalog/` until the merge) |
| Tester | Claude Code, over SSH. Every test ran on the VM; none ran on the laptop |

## 1. Install and catalog checks

```
I01|PASS|configure-monitoring-updates.sh succeeds (see /root/update-install-I01.txt)
I02|PASS|Build user pinpoint-updater exists and cannot log in
I03|PASS|Daily catalog timer and scheduled-window timer are enabled
I04|PASS|Ubuntu security updates are automatic
I05|PASS|updater.conf is root:root 644 and points to the main catalog
I06|PASS|No update set is offered before the catalog is checked
I07|PASS|discover finds pp-mon-2026.11-1 (Nagios Core 4.5.14) on the branch catalog
I08|PASS|pp-mon-2026.11-1 recorded with source catalog
I09|PASS|Login notice says an update is available
I10|PASS|Tampered manifest refused (exit 7), nothing written: CATALOG_UNAVAILABLE: The catalog could not be checked: pp-mon-2099.01-1 does not match the SHA-256 in the catalog index. Nothing was changed.
I11|PASS|Changed digest for a recorded manifest refused (exit 7)
I12|PASS|Catalog on another host refused before any download (exit 7)
I13|PASS|Status is UNKNOWN after a failed check, never up to date
I14|PASS|Catalog check works again on the branch catalog
```

I10 to I12 used the fixtures in `tests/catalog-fixtures/`. In each case discover failed, and no
manifest file or database row was written.

## 2. Rollback with a real build

```
F1|PASS|Nagios 4.5.14 built and installed, broken config detected, rolled back to 4.5.11 (txn-20261114153646-d7de7b)
F1a|PASS|Installed set is still pp-mon-baseline-1
F1b|PASS|Build was done by pinpoint-updater (build log written, build folder removed)
F1c|PASS|Approval used up; rolled_back notice queued
F1d|PASS|nagios and pinpoint-gunicorn running after the rollback
F2|PASS|Killed after installing 4.5.14; reconcile rolled back to 4.5.11 (txn-20261114154126-1b6d88)
F2a|PASS|nagios and pinpoint-gunicorn running after reconcile
F2b|PASS|Fault injection is refused without the staging marker
```

F1 used `run --inject config` and F2 used `run --crash-after-apply`. Both need the root-owned marker
`/etc/pinpoint/updates/allow-fault-injection`, which the runner created and then removed. F2b checks
that the flags are refused when the marker is missing.

## 3. Scheduled window

```
W1|PASS|Run timer does nothing before the window opens
W2|PASS|Login notice shows the scheduled update
W3|PASS|Starting it by hand before the window is refused (exit 4)
W4|PASS|Scheduled update cancelled
```

## 4. Real update through systemd

```
S1|PASS|approve --now ran in pinpoint-update-exec@txn-20261114154402-09a508.service: Nagios Core 4.5.14 installed
S2|PASS|Installed set is now pp-mon-2026.11-1
S3|PASS|Status says up to date; login notice removed
S4|PASS|Health suite passes on 4.5.14
S5|PASS|Nagios config kept: hosts.cfg unchanged by the update (make install-config never ran)
S6|PASS|Recovery point rp-20261114154434-4b6b4c of the update kept for a manual restore
S7|PASS|nagios and pinpoint-gunicorn running
S8|PASS|Audit chain intact
S9|PASS|A succeeded notice was queued
S10|PASS|Installing the same set again is refused (already installed)
```

## 5. Final state

Transactions (id | state | reason | downtime in seconds):

```
txn-20261114153646-d7de7b|rolled_back|HEALTH_FAILED|247
txn-20261114154126-1b6d88|rolled_back|INTERRUPTED|
txn-20261114154401-799325|cancelled|APPROVAL_REVOKED|
txn-20261114154402-09a508|succeeded||123
```

The five `cancelled` rows from 2026-11-09 are left over from the Phase 3 test.

Notices (kind | subject | state | send attempts):

```
available|pp-mon-2026.11-1|pending|0
rolled_back|txn-20261114153646-d7de7b|pending|0
rolled_back|txn-20261114154126-1b6d88|pending|0
succeeded|txn-20261114154402-09a508|pending|0
```

The notices are still `pending` because `/etc/msmtprc` on the VM is empty, so no mail relay is set
up. This is expected on the test VM. Each notice was queued exactly once. Sending will be tested
once the university gives us a relay (Phase 6).

After the test, `nagios` and `pinpoint-gunicorn` were active, and the VM was on Nagios Core 4.5.14
with installed set `pp-mon-2026.11-1`. `updater.conf` still points to the branch catalog. Change it
back to the main catalog after the merge.

## Problems found during the test and fixed before this run

| Problem | Fix |
|---|---|
| UT-CAT13 TypeError: `%` was applied to a `Path` | Added parentheses in the test |
| IndentationError in `tests/test_pinpoint_update_exec.py`: the new methods came after a module constant | Moved `DRILL_LINE` and `CANDIDATE_FILE` to the end of the file |

Both fixes are in `1bca8ac`. The run above is the first and only full run.

## Not tested here

- Mail delivery (no relay on the VM).
- `recover`, reminders, the daily digest and escalation. These are not built yet; see
  `docs/University-Maintenance-and-Updates-Plan.md` §8.4.
- Phase 6 (university pilot).
