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
| Installer code | `feat/require-email-change` (`d9e1df5`) **plus** the uncommitted fix on `fix/first-install-rollback`. Merged copy on the VM, md5 `af7c5b27c99a9149d5320d6cd94e1d85`. |
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
