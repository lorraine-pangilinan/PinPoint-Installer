# update-fixes-vm-Result

Result of testing the three small follow-ups left open after plan Phases 1 to 3 on a VM.
Branch `fix/update-small-items`, commit `7142459`. Every case is marked PASS or FAIL; nothing is
marked as passed unless it was run.

## Summary

| Part | Result |
|---|---|
| Portable tests on the VM | **PASS 83, FAIL 0** (`test_resource_helper.py` 10, `test_pinpoint_update.py` 12, `test_pinpoint_update_exec.py` 23, `test_pinpoint_update_approval.py` 38) |
| Recovery runner, main cases (one run, no rerun) | **PASS 25, FAIL 0** (R01 to R31) |
| FI-10 interrupted change and reboot | **PASS 7, FAIL 0** (R20 to R26) |
| Reconcile-finish unit after the boot-time rollback | **`Result=success`, `ExecMainStatus=10`**, `systemctl --failed` empty |

## Environment

| Item | Value |
|---|---|
| Date (UTC) | 2026-11-12 |
| Host | `user-1`, disposable Proxmox VM over Tailscale; snapshot taken by the user before the test |
| OS | Ubuntu 22.04.5 LTS |
| Starting state | End of the Phase 3 test (`tests/update-phase3-vm-Result.md`) |
| Code under test | `fix/update-small-items` at `7142459`, copied to `/root/pinpoint-fixes/` in the `scripts/build.sh` layout (full repo in `/root/pinpoint-fixes/repo/` for the Python tests); runner run with `PINPOINT_MODULE_DIR=/root/pinpoint-fixes` |
| Tester | Claude Code, over SSH |

## The three fixes and how each was checked

| # | Problem | Fix | Check | Result |
|---|---|---|---|---|
| 1 | `pinpoint-update-reconcile-finish.service` showed "failed" after a successful boot-time rollback (exit 10) | `SuccessExitStatus=10` in the unit written by `setup/configure-monitoring-updates.sh` | FI-10 reboot, then `systemctl show` and `systemctl --failed` | **PASS**: `Result=success`, `ExecMainStatus=10`, no failed units |
| 2 | FI-13 in `tests/update-recovery-tests.sh`: killing `flock` left its `sleep` child holding the lock, so R18 got BUSY (exit 5) | Also `pkill -P` the holder, then wait up to 30 s for the lock (`R17a` FAIL if it is still held) | Full runner, single run | **PASS**: R18, R18a, R19, R19a pass first time; R17a not raised |
| 3 | `tests/test_resource_helper.py` SyntaxError: three test strings split across lines | Restored the `\n` escapes | `python3 -m unittest tests.test_resource_helper` on the VM | **PASS**: 10 of 10 |

## 1. Recovery runner, main cases

`sudo PINPOINT_MODULE_DIR=/root/pinpoint-fixes ./update-recovery-tests.sh`

```
R01|PASS|configure-monitoring-updates.sh installed the executor and health suite
R02|PASS|pinpoint-update-exec is root:root 755
R03|PASS|Recovery point folder is root:root 700 on the Nagios filesystem
R04|PASS|Both reconcile services are enabled
R05|PASS|Reconcile with nothing to do exits 0
R06|PASS|Running the install module again succeeds
R07|PASS|Health suite passes on the installed appliance (SUITE|1|0|0)
R08|PASS|Health suite output never contains the pinpoint-api password
R10|PASS|Restore drill, no fault (Recovery point: 0.6s   Restore and health checks: 121.8s   Downtime: 244s)
R11|PASS|FI-06 invalid Nagios config is rolled back (Recovery point: 0.6s   Restore and health checks: 122.8s   Downtime: 245s)
R12|PASS|FI-07 nagios.service fails to start, rolled back (Recovery point: 0.6s   Restore and health checks: 122.8s   Downtime: 245s)
R13|PASS|FI-08 plugin regression is rolled back (Recovery point: 0.6s   Restore and health checks: 122.8s   Downtime: 245s)
R11a|PASS|Health suite reported: failed: HC-02, HC-03, HC-04, HC-05, HC-06, HC-11
R12a|PASS|Health suite reported: failed: HC-01, HC-02, HC-03, HC-04, HC-05, HC-06, HC-11
R13a|PASS|Health suite reported: failed: HC-07
R14|PASS|FI-09 killed in applying; reconcile rolled back (exit 10)
R15|PASS|FI-13 drill refused while the lock is held (exit 5)
R16|PASS|FI-13 deploy-pinpoint-web.sh refused while the lock is held
R17|PASS|PinPoint web still running after the refused deploy
R18|PASS|FI-11 damaged recovery copy gives RecoveryFailed (exit 11) (Recovery point: 0.6s   Restore and health checks: 0.1s   Downtime: 122s)
R18a|PASS|Evidence kept in /usr/local/.pinpoint-rp/rp-20261112043406-fdb27e; CRITICAL message shown
R19|PASS|pinpoint-update-exec verify reports the damaged recovery point
R19a|PASS|Appliance healthy again after the manual repair
R30|PASS|Audit chain intact
R31|PASS|Every completed drill recorded its downtime
PASS 25, FAIL 0
```

In the Phase 2 test R18, R18a and R19 failed on the first run and passed only on a rerun with the
lock free. Here they passed on the first run.

## 2. FI-10: interrupted change and reboot

`reboot-prepare`, `systemctl reboot`, then `reboot-check` once the reconcile-finish unit was inactive.
No first-boot workaround was used (`setup/fix-firstboot-run-once.sh` was already applied).

```
R20|PASS|Change interrupted in applying with a broken nagios.cfg (txn-20261112051508-cfa6f8). Reboot now.
R21|PASS|Boot-time reconcile rolled back: txn-20261112051508-cfa6f8|rolled_back|INTERRUPTED|
R22|PASS|Files were restored before nagios.service started.
R23|PASS|nagios.cfg no longer has the injected line
R24|PASS|Nagios files equal those before the interrupted change
R25|PASS|nagios and pinpoint-gunicorn running
R26|PASS|Audit chain intact
reboot-check: PASS 6, FAIL 0
```

Unit state after the boot:

```
pinpoint-update-reconcile-finish.service  Result=success  ExecMainStatus=10  ActiveState=inactive
pinpoint-update-reconcile.service         Result=success  ExecMainStatus=0   ActiveState=inactive
systemctl --failed: (none)
journal: "Rolled back: the previous version is restored and passes the critical health checks."
         "pinpoint-update-reconcile-finish.service: Deactivated successfully."
```

## Notes

- The SSH session from the laptop dropped twice during the long runner (connection reset, then a
  timeout). The runner kept running on the VM and its output file was read afterwards; the results
  above are from that file.
- VM state after this test: the code from `/root/pinpoint-fixes/` is installed; FI-11 left a
  deliberately damaged recovery point in `/usr/local/.pinpoint-rp/` as in earlier runs.
