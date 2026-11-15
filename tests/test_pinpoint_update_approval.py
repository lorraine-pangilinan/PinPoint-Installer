"""PinPoint Update Manager, Phase 3 contract: compatibility gate, approvals, roles, audit chain and CLI.

Runs on any machine: manifests live in a temporary folder, the installed versions
come from a stub scan, and sudo groups are a stub. Test IDs follow plan section 13.2
(UT-GATE, UT-APR, UT-APR-INV) and the security layer (UT-SEC).
"""
import contextlib
import copy
import datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / 'setup/pinpoint-update.py'
BASELINE = REPO / 'setup/manifests/pp-mon-baseline-1.json'
CANDIDATE = 'pp-mon-2026.11-1'


class ApprovalTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        spec = importlib.util.spec_from_file_location('pinpoint_update', SOURCE)
        self.pu = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.pu)
        pu = self.pu
        pu.STATE_DIR = root / 'state'
        pu.MANIFEST_DIR = root / 'manifests'
        pu.MANIFEST_DIR.mkdir()
        pu.MANIFEST = pu.MANIFEST_DIR / BASELINE.name
        pu.MANIFEST.write_bytes(BASELINE.read_bytes())
        pu.OS_RELEASE = root / 'os-release'
        pu.OS_RELEASE.write_text('ID=ubuntu\nVERSION_ID="22.04"\n')
        pu.LOG = root / 'pinpoint-update.log'
        pu.JOURNAL = None
        pu.APP_DIR = root / 'app'
        pu.LOGIN_NOTICE = root / 'update-notice'
        pu.UPDATER_CONF = root / 'updater.conf'
        pu.OBJECTS_CACHE = root / 'objects.cache'
        pu.AUTO_UPGRADES = root / '20auto-upgrades'
        self.host = 'test-host'
        pu.host_id = lambda: self.host
        self.untrusted = set()
        pu.trusted_file = lambda path: Path(path).name not in self.untrusted
        self.versions = {'nagios-core': '4.5.11', 'nagios-plugins': '2.4.12', 'check-ncpa': '1.2.4'}
        pu.scan = lambda: {k: {'version': v, 'sha256': None} for k, v in self.versions.items()}
        self.groups = {}
        pu.user_groups = lambda user: self.groups.get(user, set())
        for p in (patch.object(pu.platform, 'machine', return_value='x86_64'),
                  patch.object(pu.os, 'geteuid', return_value=0, create=True)):
            p.start()
            self.addCleanup(p.stop)
        env = patch.dict(os.environ, {'SUDO_USER': 'alice'})
        env.start()
        self.addCleanup(env.stop)
        self.groups['alice'] = {pu.ADMINS}
        self.groups['victor'] = {pu.VIEWERS}
        self.baseline = json.loads(BASELINE.read_text())
        self.add_manifest(CANDIDATE)
        self.assertEqual(self.cli('status')[0], 0)  # records the baseline as installed

    # Helpers --------------------------------------------------------------

    def add_manifest(self, manifest_id, **changes):
        body = copy.deepcopy(self.baseline)
        body.update({'manifest_id': manifest_id, 'upgrade_from': ['pp-mon-baseline-1'], 'migration_class': 'binary-only',
                     'expected_downtime_minutes': 10,
                     'compatibility': {'state': 'verified', 'evidence_ids': ['ev-1'], 'known_limitations': []}})
        body['components']['nagios-core']['version'] = '4.5.12'
        body['components']['nagios-core']['artifact']['sha256'] = 'c' * 64
        for key, value in changes.items():
            if key == 'compat':
                body['compatibility']['state'] = value
            elif key == 'limitations':
                body['compatibility']['known_limitations'] = value
            else:
                body[key] = value
        (self.pu.MANIFEST_DIR / (manifest_id + '.json')).write_text(json.dumps(body, indent=2))
        return body

    def cli(self, *argv, user='alice'):
        out, err = io.StringIO(), io.StringIO()
        env = {'SUDO_USER': user} if user else {}
        with patch.dict(os.environ, env, clear=False), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            if user is None:
                os.environ.pop('SUDO_USER', None)
            code = self.pu.main(list(argv))
        return code, out.getvalue() + err.getvalue()

    def usage_error(self, *argv):
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
            self.pu.main(list(argv))
        return raised.exception.code

    def approve(self, manifest_id=CANDIDATE, *extra, user='alice'):
        return self.cli('approve', manifest_id, '--confirm', manifest_id, *extra, user=user)

    def store(self):
        store = self.pu.Store()
        self.addCleanup(store.close)
        return store

    def approvals(self):
        return self.store().rows('SELECT * FROM approval ORDER BY created_at, rowid')

    def txns(self):
        return self.store().rows('SELECT * FROM txn ORDER BY created_at, rowid')

    def events(self):
        return [e for (e,) in self.store().db.execute('SELECT event FROM audit ORDER BY seq')]

    def sql(self, statement, args=()):
        store = self.store()
        with store.db:
            store.db.execute(statement, args)

    # Compatibility gate ---------------------------------------------------

    def test_gate_verified_upgrade_is_installable(self):
        code, out = self.cli('validate', CANDIDATE)
        self.assertEqual(code, 0, out)
        self.assertIn('manifest.validated', self.events())

    def test_gate_refuses_untested_incompatible_and_deprecated(self):
        for state in ('untested', 'incompatible', 'deprecated'):
            self.add_manifest('pp-mon-' + state, compat=state)
            self.assertEqual(self.cli('validate', 'pp-mon-' + state)[0], 4, state)
            code, out = self.approve('pp-mon-' + state)
            self.assertEqual(code, 4, state)
            self.assertIn('Compatibility is ' + state, out)
        self.assertEqual(self.approvals(), [])

    def test_gate_refuses_wrong_platform_major_and_unknown_source(self):
        self.add_manifest('pp-mon-arm', platform={'os': 'ubuntu', 'version': '22.04', 'arch': 'aarch64'})
        self.add_manifest('pp-mon-major', migration_class='major')
        self.add_manifest('pp-mon-other-path', upgrade_from=['pp-mon-something-else'])
        self.assertIn('this host is ubuntu 22.04 x86_64', self.approve('pp-mon-arm')[1])
        self.assertIn('major change', self.approve('pp-mon-major')[1])
        self.assertIn('cannot be installed over pp-mon-baseline-1', self.approve('pp-mon-other-path')[1])
        self.assertIn('already installed', self.approve('pp-mon-baseline-1')[1])
        self.assertEqual(self.approvals(), [])

    def test_gate_refuses_drift(self):
        self.versions['nagios-core'] = '4.5.11-hand-built'
        code, out = self.approve()
        self.assertEqual(code, 4)
        self.assertIn('changed outside the Update Manager', out)

    def test_gate_refuses_without_recorded_installed_state(self):
        self.sql('DELETE FROM installed_state')
        self.versions['nagios-plugins'] = '2.4.11'  # so it is not recorded again
        code, out = self.approve()
        self.assertEqual(code, 4)
        self.assertIn('installed state is not recorded', out)

    # Approvals ------------------------------------------------------------

    def test_approve_binds_digest_host_and_source_and_creates_txn(self):
        code, out = self.approve()
        self.assertEqual(code, 0, out)
        [approval] = self.approvals()
        [txn] = self.txns()
        digest = self.store().manifest(CANDIDATE)['sha256']
        self.assertEqual((approval['manifest_sha256'], approval['host_id'], approval['source_manifest_id'],
                          approval['approver'], approval['status']),
                         (digest, 'test-host', 'pp-mon-baseline-1', 'alice', 'active'))
        self.assertEqual((txn['state'], txn['kind'], txn['approval_id'], txn['target_manifest_id']),
                         ('approved', 'update', approval['approval_id'], CANDIDATE))
        self.assertIn('approval.created', self.events())

    def test_approve_twice_returns_the_existing_approval(self):
        self.approve()
        code, out = self.approve()
        self.assertEqual(code, 0)
        self.assertIn('Already approved', out)
        self.assertEqual(len(self.approvals()), 1)
        self.assertEqual(len(self.txns()), 1)

    def test_confirmation_must_match(self):
        code, out = self.cli('approve', CANDIDATE, '--confirm', 'pp-mon-2026.11-2')
        self.assertEqual(code, 2)
        self.assertIn('does not match', out)
        self.assertEqual(self.approvals(), [])

    def test_conditional_needs_explicit_acceptance(self):
        self.add_manifest('pp-mon-cond', compat='conditional', limitations=['SNMP traps untested.'])
        code, out = self.approve('pp-mon-cond')
        self.assertEqual(code, 2)
        self.assertIn('SNMP traps untested.', out)
        self.assertEqual(self.approve('pp-mon-cond', '--accept-limitations')[0], 0)

    def test_schedule_window_is_checked_and_stored_in_utc(self):
        past = (datetime.datetime.now() - datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M')
        self.assertEqual(self.approve(CANDIDATE, '--at', past)[0], 2)
        soon = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)).replace(microsecond=0)
        self.assertEqual(self.approve(CANDIDATE, '--at', soon.isoformat(), '--window-minutes', '30')[0], 0)
        self.sql('DELETE FROM txn')
        self.sql('DELETE FROM approval')
        too_late = soon + datetime.timedelta(days=30)
        self.assertEqual(self.approve(CANDIDATE, '--at', too_late.isoformat())[0], 2)
        self.add_manifest('pp-mon-slow', expected_downtime_minutes=30)
        code, out = self.approve('pp-mon-slow', '--at', soon.isoformat(), '--window-minutes', '45')
        self.assertEqual(code, 2)
        self.assertIn('at least 60 minutes', out)
        local = soon.astimezone(datetime.timezone(datetime.timedelta(hours=8)))
        self.assertEqual(self.approve(CANDIDATE, '--at', local.isoformat())[0], 0)
        [approval] = self.approvals()
        self.assertEqual(approval['window_start'], soon.isoformat())
        self.assertEqual(self.usage_error('approve', CANDIDATE, '--confirm', CANDIDATE, '--at', 'tomorrow'), 2)
        self.assertEqual(self.approve(CANDIDATE, '--window-minutes', '60')[0], 0)  # already approved: idempotent

    def test_new_approval_supersedes_the_previous_one(self):
        self.add_manifest('pp-mon-2026.11-2')
        self.approve()
        self.assertEqual(self.approve('pp-mon-2026.11-2')[0], 0)
        first, second = self.approvals()
        self.assertEqual((first['status'], second['status']), ('superseded', 'active'))
        self.assertEqual([t['state'] for t in self.txns()], ['cancelled', 'approved'])

    def test_running_transaction_makes_approve_busy_and_changes_nothing(self):  # FI-13
        self.approve()
        self.sql("UPDATE txn SET state = 'preparing'")  # the executor has started it
        self.add_manifest('pp-mon-2026.11-2')
        code, _ = self.approve('pp-mon-2026.11-2')
        self.assertEqual(code, 5)
        self.assertEqual([a['status'] for a in self.approvals()], ['active'])
        self.sql("UPDATE txn SET state = 'cancelled'")
        self.sql("INSERT INTO txn (txn_id, kind, host_id, source_manifest_id, target_manifest_id, state, created_at) "
                 "VALUES ('txn-x', 'drill', 'test-host', 'a', 'a', 'applying', 'now')")
        self.sql("UPDATE approval SET status = 'used'")
        self.assertEqual(self.approve('pp-mon-2026.11-2')[0], 5)

    def test_cancel_approved_transaction(self):
        self.approve()
        [txn] = self.txns()
        self.assertEqual(self.cli('cancel', txn['txn_id'])[0], 0)
        self.assertEqual(self.txns()[0]['state'], 'cancelled')
        self.assertEqual(self.approvals()[0]['status'], 'revoked')
        code, out = self.cli('cancel', txn['txn_id'])
        self.assertEqual(code, 0)
        self.assertIn('already cancelled', out)

    def test_cancel_after_applying_is_an_invalid_transition(self):
        self.approve()
        [txn] = self.txns()
        self.sql("UPDATE txn SET state = 'applying'")
        self.assertEqual(self.cli('cancel', txn['txn_id'])[0], 6)
        self.assertEqual(self.cli('cancel', 'txn-20260101000000-abcdef')[0], 2)

    def test_defer_and_decline_are_recorded_with_reason(self):
        review = (datetime.date.today() + datetime.timedelta(days=30)).isoformat()
        self.assertEqual(self.cli('defer', CANDIDATE, '--reason', 'Exam week', '--review-date', review)[0], 0)
        self.assertEqual(self.cli('defer', CANDIDATE, '--reason', 'Exam week', '--review-date', review)[0], 0)
        self.assertEqual(len(self.approvals()), 1)
        self.assertEqual(self.cli('decline', CANDIDATE, '--reason', 'Waiting for 4.5.13')[0], 0)
        deferral, decline = self.approvals()
        self.assertEqual((deferral['status'], decline['decision'], decline['reason']),
                         ('superseded', 'decline', 'Waiting for 4.5.13'))
        self.assertIn('declined', self.cli('list')[1])
        self.assertEqual(self.txns(), [])
        self.assertIn('approval.declined', self.events())

    def test_defer_is_refused_while_approved(self):
        self.approve()
        code = self.cli('defer', CANDIDATE, '--reason', 'x', '--review-date', '2099-01-01')[0]
        self.assertEqual(code, 6)

    # Approval invalidation ------------------------------------------------

    def test_expired_approval_is_voided_and_its_txn_cancelled(self):
        self.approve()
        self.sql("UPDATE approval SET expires_at = '2000-01-01T00:00:00+00:00'")
        self.cli('status')
        self.assertEqual(self.approvals()[0]['status'], 'expired')
        self.assertEqual(self.txns()[0]['state'], 'cancelled')

    def test_missed_window(self):
        self.approve()
        self.sql("UPDATE approval SET window_start = '2000-01-01T00:00:00+00:00', "
                 "window_end = '2000-01-01T01:00:00+00:00'")
        self.cli('status')
        self.assertEqual(self.txns()[0]['state'], 'missed_window')

    def test_changed_installed_state_or_host_voids_the_approval(self):
        self.approve()
        self.sql("UPDATE installed_state SET manifest_id = 'pp-mon-other'")
        self.cli('status')
        self.assertEqual(self.approvals()[0]['status'], 'expired')
        self.sql("UPDATE installed_state SET manifest_id = 'pp-mon-baseline-1'")
        self.approve()
        self.host = 'another-host'
        self.cli('status')
        self.host = 'test-host'
        self.assertEqual([a['status'] for a in self.approvals()], ['expired', 'expired'])

    def test_drift_after_approval_revokes_it(self):
        self.approve()
        self.versions['nagios-core'] = '9.9.9'
        self.cli('status')
        self.assertEqual(self.approvals()[0]['status'], 'revoked')

    def test_revoked_manifest_voids_pending_approval(self):  # FI-03
        self.approve()
        (self.pu.MANIFEST_DIR / 'revoked.json').write_text(json.dumps({'schema_version': 1,
                                                                       'manifest_ids': [CANDIDATE]}))
        self.cli('status')
        self.assertEqual(self.approvals()[0]['status'], 'revoked')
        self.assertEqual(self.txns()[0]['state'], 'cancelled')
        self.assertEqual(self.store().manifest(CANDIDATE)['compat_state'], 'deprecated')
        self.assertIn('was revoked', self.approve()[1])
        self.assertEqual(self.events().count('manifest.revoked'), 1)

    def test_review_date_reached_ends_the_deferral(self):
        self.cli('defer', CANDIDATE, '--reason', 'later', '--review-date', '2099-01-01')
        self.sql("UPDATE approval SET review_date = '2000-01-01'")
        self.cli('status')
        self.assertEqual(self.approvals()[0]['status'], 'expired')
        self.assertIn('approval.review_due', self.events())

    # Roles ----------------------------------------------------------------

    def test_viewer_may_read_but_not_decide(self):
        self.assertEqual(self.cli('list', user='victor')[0], 0)
        self.assertEqual(self.cli('validate', CANDIDATE, user='victor')[0], 0)
        for argv in (('approve', CANDIDATE, '--confirm', CANDIDATE), ('decline', CANDIDATE, '--reason', 'no'),
                     ('cancel', 'txn-20260101000000-abcdef')):
            code, out = self.cli(*argv, user='victor')
            self.assertEqual(code, 3, argv)
            self.assertIn('pinpoint-update-admins', out)
        self.assertEqual(self.events().count('auth.refused'), 3)
        self.assertEqual(self.approvals(), [])

    def test_user_in_neither_group_is_refused(self):
        self.assertEqual(self.cli('status', user='mallory')[0], 3)
        refused = self.store().rows("SELECT actor, detail_json FROM audit WHERE event = 'auth.refused'")
        self.assertEqual(refused[0]['actor'], 'mallory')

    def test_direct_root_login_is_allowed_with_a_warning(self):
        self.assertEqual(self.approve(user=None)[0], 0)
        [row] = self.store().rows("SELECT actor, detail_json FROM audit WHERE event = 'approval.created'")
        self.assertEqual(row['actor'], 'root')
        self.assertIn('direct root login', row['detail_json'])

    # Security: manifests and input ----------------------------------------

    def test_edited_manifest_is_refused_and_audited_once(self):
        self.approve()
        body = json.loads((self.pu.MANIFEST_DIR / (CANDIDATE + '.json')).read_text())
        body['components']['nagios-core']['artifact']['sha256'] = 'd' * 64
        (self.pu.MANIFEST_DIR / (CANDIDATE + '.json')).write_text(json.dumps(body))
        code, out = self.cli('list')
        self.cli('list')
        self.assertIn('REFUSED %s.json: changed after it was recorded' % CANDIDATE, out)
        self.assertEqual(self.events().count('manifest.changed'), 1)
        self.assertEqual(self.store().manifest(CANDIDATE)['body']['components']['nagios-core']['artifact']['sha256'],
                         'c' * 64)

    def test_untrusted_or_malformed_manifests_are_refused(self):
        self.add_manifest('pp-mon-writable')
        self.untrusted.add('pp-mon-writable.json')
        self.add_manifest('pp-mon-http')
        path = self.pu.MANIFEST_DIR / 'pp-mon-http.json'
        path.write_text(path.read_text().replace('https://assets', 'http://assets'))
        bad_profile = self.add_manifest('pp-mon-profile')
        bad_profile['components']['nagios-core']['build_profile'] = 'rm -rf /'
        (self.pu.MANIFEST_DIR / 'pp-mon-profile.json').write_text(json.dumps(bad_profile))
        self.add_manifest('pp-mon-name')
        (self.pu.MANIFEST_DIR / 'pp-mon-name.json').rename(self.pu.MANIFEST_DIR / 'pp-mon-renamed.json')
        (self.pu.MANIFEST_DIR / 'pp-mon-junk.json').write_text('{not json')
        out = self.cli('list')[1]
        for name, problem in (('pp-mon-writable', 'writable by others'), ('pp-mon-http', 'artifact url'),
                              ('pp-mon-profile', 'build_profile must be core-source-v1'),
                              ('pp-mon-renamed', 'does not match manifest_id'), ('pp-mon-junk', 'REFUSED')):
            self.assertIn('REFUSED %s.json' % name, out)
            self.assertIn(problem, out)
            self.assertIsNone(self.store().manifest(name))

    def test_untrusted_folder_trusts_nothing(self):
        self.untrusted.add(self.pu.MANIFEST_DIR.name)
        self.add_manifest('pp-mon-new')
        self.assertIn('not root-only', self.cli('list')[1])
        self.assertIsNone(self.store().manifest('pp-mon-new'))

    def test_ids_paths_and_reasons_are_validated(self):
        for bad in ('../../etc/passwd', 'PP-MON', 'a' * 65, 'x;reboot', ''):
            self.assertEqual(self.usage_error('show', bad), 2, bad)
        self.assertEqual(self.usage_error('cancel', '../txn'), 2)
        for reason in ('line one\nline two', 'bell\x07', 'x' * 501, '   '):
            self.assertEqual(self.usage_error('decline', CANDIDATE, '--reason', reason), 2, repr(reason))
        self.assertEqual(self.usage_error('defer', CANDIDATE, '--reason', 'ok', '--review-date', '2026-02-30'), 2)
        self.assertEqual(self.usage_error('history', '--limit', '0'), 2)

    # Audit chain ----------------------------------------------------------

    def test_audit_chain_verifies_and_detects_edits_and_deletions(self):
        self.approve()
        self.cli('decline', 'pp-mon-baseline-1', '--reason', 'test')
        self.assertEqual(self.cli('audit', '--verify')[0], 0)
        self.sql("UPDATE audit SET detail_json = '{}' WHERE event = 'approval.created'")
        code, out = self.cli('audit', '--verify')
        self.assertEqual(code, 1)
        self.assertIn('BROKEN', out)

    def test_audit_deletion_is_detected(self):
        self.approve()
        self.sql("DELETE FROM audit WHERE seq = 2")
        self.assertEqual(self.cli('audit', '--verify')[0], 1)

    def test_removing_the_newest_rows_is_detected_once_another_is_written(self):
        self.approve()
        self.sql("DELETE FROM audit WHERE event = 'approval.created'")
        self.cli('status')
        self.assertEqual(self.cli('audit', '--verify')[0], 1)

    def test_audit_chain_cannot_fork(self):
        store = self.store()
        last = store.db.execute('SELECT prev_hash FROM audit ORDER BY seq DESC LIMIT 1').fetchone()[0]
        with self.assertRaises(sqlite3.IntegrityError), store.db:
            store.db.execute("INSERT INTO audit (at, actor, event, detail_json, prev_hash, hash) "
                             "VALUES ('t', 'x', 'forged', '{}', ?, 'h')", (last,))

    def test_audit_rows_are_copied_to_the_log(self):
        self.approve()
        log = self.pu.LOG.read_text()
        self.assertIn('alice approval.created', log)
        last = self.store().db.execute('SELECT hash FROM audit ORDER BY seq DESC LIMIT 1').fetchone()[0]
        self.assertIn('hash=' + last, log)

    def test_audit_since_filters_rows(self):
        out = self.cli('audit', '--since', '2999-01-01', '--json')[1]
        self.assertEqual(json.loads(out)['rows'], [])

    # CLI contract ---------------------------------------------------------

    def test_json_contract_for_success_and_refusal(self):
        data = json.loads(self.cli('list', '--json')[1])
        self.assertEqual((data['schema'], data['result'], data['installed_manifest']),
                         ('pinpoint-update/v1', 'OK', 'pp-mon-baseline-1'))
        candidate = [m for m in data['manifests'] if m['manifest_id'] == CANDIDATE][0]
        self.assertTrue(candidate['installable'])
        self.add_manifest('pp-mon-untested', compat='untested')
        code, out = self.approve('pp-mon-untested', '--json')
        self.assertEqual(code, 4)
        self.assertEqual(json.loads(out)['result'], 'BLOCKED')
        data = json.loads(self.cli('status', '--json')[1])
        self.assertEqual(data['approvals'], [])

    def test_show_lists_evidence_limitations_and_gate(self):
        self.add_manifest('pp-mon-cond', compat='conditional', limitations=['Needs PinPoint 2.1.'])
        out = self.cli('show', 'pp-mon-cond')[1]
        self.assertIn('CONDITIONAL (evidence: ev-1)', out)
        self.assertIn('Limitation: Needs PinPoint 2.1.', out)
        self.assertIn('can be installed', out)
        self.assertEqual(self.cli('show', 'pp-mon-missing')[0], 2)

    def test_history_shows_source_target_approver_and_result(self):
        self.approve()
        txn = self.txns()[0]['txn_id']
        self.cli('cancel', txn)
        data = json.loads(self.cli('history', '--json')[1])
        [row] = data['transactions']
        self.assertEqual((row['source_manifest_id'], row['target_manifest_id'], row['approver'], row['state']),
                         ('pp-mon-baseline-1', CANDIDATE, 'alice', 'cancelled'))


if __name__ == '__main__':
    unittest.main()
