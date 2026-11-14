# PinPoint Update System: Test Report

**Date:** 15 November 2026
**Where it was tested:** the test VM (Ubuntu 22.04). We took a snapshot before each test so we could undo everything.

Five of the seven phases are built and tested on the test VM: Phases 1, 2, 3, 4 and 5. The other two,
Phases 0 and 6, need people from the university.

## Summary

| Phase | What it does | Built? | Tested? | Result | On main? |
|---|---|---|---|---|---|
| 0. Discovery | Name the owners and list every PinPoint appliance | Not our part | No | Waiting on the university | — |
| 1. Version management | Downloads only files whose fingerprint matches | ✅ | ✅ | All passed | ✅ Yes |
| 2. Recovery | Saves a copy before a change and puts it back if something breaks | ✅ | ✅ | All passed (after 2 fixes) | ✅ Yes |
| 3. Approval | Nothing installs without an admin's approval, and every action is logged | ✅ | ✅ | All passed | ✅ Yes |
| Small fixes | Three leftover problems from Phases 2 and 3 | ✅ | ✅ | All passed | ✅ Yes |
| 4. Finding updates | Checks our trusted update list and shows the menu and login notice | ✅ | ✅ | All passed | ❌ Branch `feat/update-catalog-install` |
| 5. Installing updates | Installs the update for real, rolls back on failure, sends notices | ✅ | ✅ | All passed | ❌ Branch `feat/update-catalog-install` |
| 6. Trial and handover | Try it on one real appliance, train staff, get sign-off | ❌ | ❌ | Needs the university | — |

## Phase by phase

### Phase 1: Version management

**In short:** PinPoint only installs software whose fingerprint matches the one we wrote down. A fake
or damaged download is refused.

**Tests:** 33 automated checks and 14 hands-on checks. **All 47 passed.**

**Examples:** a download with the wrong fingerprint was refused, and reinstalling worked.

**Report:** `tests/update-phase1-vm-Result.md`

### Phase 2: Recovery

**In short:** before every change, PinPoint saves a copy. If the change breaks Nagios, it puts the
copy back by itself, even after a crash or a reboot.

**Tests:** 55 code tests, 25 main checks and 7 reboot checks. **All passed in the end.**

**Problems found and fixed:**

- On the first run, a few checks failed because of the test script, not PinPoint. We fixed the
  script and ran them again.
- The first-time setup ran again after a reboot. That was an installer bug, and we fixed it.

**Report:** `tests/update-phase2-vm-Result.md`

### Phase 3: Approval and audit

**In short:** only an admin can approve an update. A viewer can't. Every action goes into a log that
can't be quietly edited.

**Tests:** 107 code tests and 33 VM checks. **All passed.** On the first run, 5 checks failed
because of the test script; after fixing it, all 33 passed.

**Report:** `tests/update-phase3-vm-Result.md`

### Small fixes

**In short:** three leftover problems were fixed:

- a service wrongly showed "failed" after a successful rollback
- a test held a lock it shouldn't have
- a test file had a typing error

**Tests:** 83 code tests, 25 main checks and 7 reboot checks. **All passed.**

**Report:** `tests/update-fixes-vm-Result.md`

### Phases 4 and 5: Finding and installing updates

**In short:** once a day, PinPoint checks our update list on GitHub. If there's an update, the admin
sees it at login and can approve it. PinPoint then installs it, checks that Nagios still works, and
rolls back if it doesn't.

**Tests:** 148 code tests and 36 VM checks. **All passed on the first full run.**

| What we checked | Result |
|---|---|
| Finds the real update (Nagios 4.5.11 → 4.5.14, security fixes) | ✅ |
| Refuses a tampered update list | ✅ |
| Refuses an update list from a different website | ✅ |
| Says "UNKNOWN", not "up to date", when the check fails | ✅ |
| Rolls back to 4.5.11 when we broke the Nagios settings on purpose | ✅ |
| Rolls back to 4.5.11 when we stopped the update midway | ✅ |
| Waits for the scheduled time and won't start early | ✅ |
| Installs 4.5.14 for real; Nagios and PinPoint web keep running | ✅ |
| Leaves your Nagios settings unchanged | ✅ |
| Won't install the same update twice | ✅ |
| Audit log still intact | ✅ |
| Ubuntu security updates turned on automatically | ✅ |

**Report:** `tests/update-install-vm-Result.md` on branch `feat/update-catalog-install`. It moves to
main when the branch is merged.

## Grand total

| | Passed | Failed |
|---|---|---|
| All the final test runs, Phases 1 to 5 | **All passed** | **0** |

Every failure we hit along the way was either a test-script problem or a real bug. Each was fixed and
tested again.

## Not tested yet

1. **Email notices.** PinPoint creates the emails, but the test VM has no mail server, so none were
   sent. This needs the university's mail server.
2. **Not built yet:** the `recover` command, reminder emails, the daily summary email, and
   escalation to the service owner when updates are put off too long.
3. **Phase 0 and Phase 6** need university staff: owners, the list of appliances, a trial on one real
   appliance, training and sign-off.

## Next steps

1. Decide whether to merge Phases 4 and 5 into main.
2. Take a snapshot of the test VM. It's now on Nagios 4.5.14.
3. Ask the university for a mail server to send from, the owners' names and a list of their PinPoint
   appliances. That unlocks email and Phase 6.
