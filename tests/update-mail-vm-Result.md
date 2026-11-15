# update-mail-vm-Result

Result of running `tests/update-mail-tests.sh` on the test VM: update-notice email from plan
Phases 4 and 5 (plan 10.1 and 14). This closes the open item "Mail untested (no relay on VM)" in
`tests/update-install-vm-Result.md`.

| Item | Value |
|---|---|
| Date (UTC) | 2026-11-15 15:07 |
| Host | `user-1` (Ubuntu 22.04.5, test VM, snapshot taken before) |
| Code | branch `feat/update-catalog-install` plus the notice fix below |
| Relay | Local test mail server on `127.0.0.1:2587` (`python3-aiosmtpd`). It requires STARTTLS and then a login, like a real relay. Its certificate was trusted only while the test ran. |
| Relay settings | Written by the real `pinpoint-apply-smtp` helper (the same path the web interface uses) |
| Transport | `/bin/mail` (bsd-mailx) and `msmtp`, the same path the Nagios alerts use |
| Runner | **PASS 39, FAIL 0** (third run, see "Runs") |
| Portable tests on the VM | **PASS 116, FAIL 0** (114 before, plus 2 new notice tests) |

## Cases

| ID | Status | What it shows |
|---|---|---|
| M00a-c | PASS | Test mail server installed, its certificate trusted, listening |
| M01a-b | PASS | The helper accepts the relay settings; `/etc/msmtprc` is `root:nagios 640` |
| M02a-b | PASS | The `nagios` user can send through `/bin/mail` (the alert path), over STARTTLS with a login |
| M03a-b | PASS | No `notify_to` and no `system_users` group: nothing sent, notices stay pending, no attempt counted |
| M04 | PASS | Only placeholder addresses (`example.com`, `localhost`): nothing sent |
| M05a-c | PASS | With `notify_to` set, all 6 notices queued by the Phase 5 run were sent, one `notice.sent` audit row each |
| M06 | PASS | Each mail has one recipient, the relay's sender address as From, and a `[PinPoint user-1]` subject |
| M07 | PASS | The "installed" notice carries the transaction, versions, result and downtime |
| M08 | PASS | Running discover and run-due again sends nothing twice |
| M09a-c | PASS | Relay down: the notice stays pending after one attempt, the msmtp error is recorded, `notice.failed` is audited |
| M10a-b | PASS | Relay back: `run-due` (the 5-minute timer) retries and sends it once |
| M11a-e | PASS | Wrong password: not delivered, the error says authentication failed, no password in the notice table, audit log, journal or mail log; right password again: sent |
| M12a-c | PASS | After 10 failed attempts a notice is not tried again |
| M13 | PASS | Two `notify_to` addresses: one mail to both |
| M14a-c | PASS | Without `notify_to`, recipients come from the Nagios `system_users` group; the `example.com` member is skipped; Nagios is back without the test contacts |
| M15a-c | PASS | While another process holds the notices lock, a run leaves the notices to it; the next run sends them; every notice was delivered exactly once |
| Z1-Z3 | PASS | Test certificate no longer trusted, `/etc/msmtprc` and `updater.conf` restored, audit chain intact |

Sample mail, as the relay received it:

```
From: pinpoint-alerts@mailtest.lan
To: adminraine@gmail.com
Subject: [PinPoint user-1] Nagios update installed: pp-mon-2026.11-1

Transaction: txn-20261114154402-09a508
From:        pp-mon-baseline-1
To:          pp-mon-2026.11-1
Result:      succeeded
Reason:      -
Detail:      installed and healthy
Downtime:    123 s

Details: sudo pinpoint-update history
```

## Bug found and fixed: a notice could be mailed twice

In the first run, the 5-minute run timer (`pinpoint-update-run.service`) started at 15:00:08 while
the test's own `discover` was waiting on the relay. Both sent the same pending notice. One marked
it sent; then the other's failure wrote `sent_at = NULL` back over it, so the notice became pending
again and was mailed a second time at 15:00:20 (msmtp log and audit rows 772-781).

Cause: `send_notices` had no lock, and its update after a failed send did not check whether the
notice had been sent in the meantime. Three things send notices: the discover timer, the run timer
and the executor after an update.

Fix in `setup/pinpoint-update.py`:

- `send_notices` takes a non-blocking lock (`/var/lib/pinpoint/updates/notices.lock`). If another
  process is sending, this one leaves the notices to it; the next timer run picks up anything left.
  The descriptor is not inherited by `mail`/`msmtp` (Python opens it close-on-exec), so it cannot
  outlive the sender as in FI-13.
- The update after a send only changes a notice that is still unsent (`AND sent_at IS NULL`), so a
  sent notice is never reopened.

New unit tests: `test_ntc06_second_sender_leaves_notices_to_the_first`,
`test_ntc07_a_notice_sent_elsewhere_is_never_reopened`. Case M15 checks the lock on the VM.

## Runs

| Run | Result | Notes |
|---|---|---|
| 1 | 31 / 36 | Found the double-send bug above (M11, M12c). The rest were test faults: the test server kept silent on a wrong password (`AuthResult.handled` defaults to true in aiosmtpd; a real relay answers 535 at once, as Gmail did in `smtp-admin-email-tests-Result.md`), and the M14 contacts went to a `cfg_dir` this appliance does not have. |
| 2 | 36 / 39 | Product fix in. Three test faults: M09c counted audit rows from run 1, the test server's password was on its command line (logged by systemd), and M15c treated two rolled-back notices for the same update set (same subject, different transaction) as a duplicate. |
| 3 | **39 / 39** | |

## Real relay (Gmail)

After the runner, the relay was set to `smtp.gmail.com:587` (STARTTLS, `adminraine@gmail.com`,
Gmail app password) through `pinpoint-apply-smtp`, and one test notice was sent by
`pinpoint-update discover` with `notify_to = adminraine@gmail.com`.

| Step | Result |
|---|---|
| First app password (one letter mistyped) | Rejected: `535 5.7.8 Username and Password not accepted`. Notice stayed pending (attempt 1), error recorded, no password in the logs. |
| Correct app password | `smtpstatus=250 2.0.0 OK`, notice marked sent on attempt 2. Subject `[PinPoint user-1] Real relay test: update notices reach this inbox`. |

A wrong password is reported and retried, and once it is fixed the waiting notice goes out without
anyone queueing it again.

## Notes

- Two rolled-back attempts of one update set produce two mails with the same subject. The body
  names the transaction, so they can be told apart. A subject with the transaction id would make
  this clearer in an inbox; not changed here.
- A relay that accepts the connection and then stalls holds a send for up to 60 s per notice (the
  `mail` timeout). Seen only with the test server; with the lock in place it no longer causes a
  second send.
- The 6 notices from the Phase 5 run are now marked sent on the VM; they went to the local test
  server, not to a real inbox.
- Delivery through a real outside relay is not part of this runner. The earlier SMTP tests did it
  through Gmail with an app password (`smtp-admin-email-tests-Result.md`, run 8).
