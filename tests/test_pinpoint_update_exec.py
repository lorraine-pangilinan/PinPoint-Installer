"""PinPoint update executor, Phase 2 contract: recovery points, restore, reconcile and drills.

Runs on any machine: Nagios is a folder in a temporary directory, systemctl and the
health suite are replaced by stubs, and the tree is copied with shutil instead of cp.
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
CONTROLLER = REPO / 'setup/pinpoint-update.py'
EXECUTOR = REPO / 'setup/pinpoint-update-exec.py'
BASELINE = REPO / 'setup/manifests/pp-mon-baseline-1.json'


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(module)
    return module


class ExecutorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.pu = load('pinpoint_update', CONTROLLER)
        self.ex = load('pinpoint_update_exec', EXECUTOR)
        self.ex.pu = self.pu
        self.pu.STATE_DIR = root / 'state'
        self.pu.MANIFEST = BASELINE
        self.pu.host_id = lambda: 'test-host'
        self.ex.NAGIOS = root / 'usr-local/nagios'
        self.ex.RP_ROOT = root / 'usr-local/.pinpoint-rp'
        self.ex.LOG = root / 'pinpoint-update.log'
        self.ex.HEALTH_TIMEOUT = 5
        self.ex.SPACE_MARGIN = 0

        self.nagios = self.ex.NAGIOS
        for rel, text in {'bin/nagios': 'binary 4.5.11\n', 'etc/nagios.cfg': 'log_file=x\n',
                          'etc/cgi.cfg': 'cgi\n', 'libexec/check_ping': '#!/bin/sh\nexit 0\n',
                          'var/retention.dat': 'state\n', 'var/rw/nagios.cmd': '',
                          'var/spool/pinpoint-events/e1.json': '{}\n'}.items():
            path = self.nagios / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.unit = root / 'nagios.service'
        self.unit.write_text('[Service]\nExecStart=/usr/local/nagios/bin/nagios\n')
        self.site = root / 'nagios.conf'
        self.site.write_text('ScriptAlias /nagios/cgi-bin\n')
        self.original = self.ex.file_list(self.nagios)

        self.systemctl_calls = []
        self.health_calls = []
        self.healthy = lambda mode: True
        stubs = {
            'systemctl': lambda *args: self.systemctl_calls.append(args),
            'copy_tree': lambda source, target: shutil.copytree(str(source), str(target), symlinks=True),
            'extra_files': lambda: [self.unit, self.site],
            'run_health': self.fake_health,
            'take_lock': lambda: 99,
            'ignore_interrupts': lambda: None,
            'say': lambda text: None,
        }
        for name, stub in stubs.items():
            p = patch.object(self.ex, name, side_effect=stub)
            p.start()
            self.addCleanup(p.stop)
        chown = patch.object(self.ex.os, 'chown', create=True)
        chown.start()
        self.addCleanup(chown.stop)
        self.pu.scan = lambda: {'nagios-core': {'version': '4.5.11', 'sha256': 'a' * 64},
                                'nagios-plugins': {'version': '2.4.12', 'sha256': None},
                                'check-ncpa': {'version': '1.2.4', 'sha256': 'b' * 64}}
        self.store = self.pu.Store()
        self.addCleanup(self.store.close)

    def fake_health(self, txn_id, mode, context, since=0):
        self.health_calls.append(mode)
        broken = (DRILL_LINE in (self.nagios / 'etc/nagios.cfg').read_text()
                  or 'exit 3' in (self.nagios / 'libexec/check_ping').read_text())
        if broken or not self.healthy(mode):
            return 1, ['HC-02|critical|FAIL|nagios -v: 1 errors.', 'SUITE|1|1|0']
        return 0, ['HC-02|critical|PASS|nagios -v: 0 errors.', 'SUITE|1|0|0']

    def txn(self, state='applying'):
        txn_id = self.ex.new_txn(self.store, 'drill', 'pp-mon-baseline-1', 'pp-mon-baseline-1')
        self.ex.save_context(txn_id, {'version': '4.5.11', 'ncpa_sha256': 'b' * 64})
        path = {'preparing': [], 'staging': ['staging'], 'applying': ['staging', 'applying']}[state]
        for to in path:
            self.ex.transition(self.store, txn_id, to)
        return txn_id

    def row(self, txn_id):
        return self.store.db.execute('SELECT state, step, failure_code, recovery_point_id FROM txn '
                                     'WHERE txn_id = ?', (txn_id,)).fetchone()

    def events(self):
        return [e for (e,) in self.store.db.execute('SELECT event FROM audit ORDER BY seq')]

    def break_live(self):
        with open(self.nagios / 'etc/nagios.cfg', 'a') as f:
            f.write(DRILL_LINE)
        self.unit.write_text('[Service]\nExecStart=/broken\n')

    # Recovery points ------------------------------------------------------

    def test_file_list_skips_runtime_files_and_sees_content_changes(self):
        self.assertIn('etc/nagios.cfg', self.original)
        self.assertIn('var/spool/pinpoint-events/e1.json', self.original)
        self.assertNotIn('var/rw', self.original)
        self.assertNotIn('var/rw/nagios.cmd', self.original)
        (self.nagios / 'var/rw/nagios.cmd').write_text('changed at runtime')
        self.assertEqual(self.ex.file_list(self.nagios), self.original)
        (self.nagios / 'etc/cgi.cfg').write_text('edited')
        self.assertNotEqual(self.ex.file_list(self.nagios), self.original)

    def test_recovery_point_is_recorded_verified_and_restores_tree_and_extra_files(self):
        txn_id = self.txn()
        rp_id = self.ex.create_recovery_point(self.store, txn_id)
        self.assertTrue(self.ex.verify_recovery_point(self.store, rp_id))
        kind, location = self.store.db.execute('SELECT kind, location FROM recovery_point WHERE rp_id = ?',
                                               (rp_id,)).fetchone()
        self.assertEqual((kind, location), ('tree-copy-v1', str(self.ex.RP_ROOT / rp_id)))
        unit_before = self.unit.read_text()
        self.break_live()
        self.ex.restore(self.store, txn_id, rp_id)
        self.assertEqual(self.ex.file_list(self.nagios), self.original)
        self.assertEqual(self.unit.read_text(), unit_before)
        self.assertTrue((self.ex.RP_ROOT / rp_id / 'failed/etc/nagios.cfg').exists())
        self.assertIn(('daemon-reload',), self.systemctl_calls)
        self.assertEqual(self.systemctl_calls[0], ('stop', 'pinpoint-gunicorn'))
        self.assertEqual(self.systemctl_calls[-3:], [('start', 'nagios'), ('start', 'pinpoint-gunicorn'),
                                                     ('reload', 'apache2')])
        self.assertEqual(self.row(txn_id)[1], 'restore.started')

    def test_damaged_copy_or_file_list_does_not_verify(self):
        txn_id = self.txn()
        rp_id = self.ex.create_recovery_point(self.store, txn_id)
        with open(self.ex.RP_ROOT / rp_id / 'nagios/etc/cgi.cfg', 'a') as f:
            f.write('# damaged\n')
        self.assertFalse(self.ex.verify_recovery_point(self.store, rp_id))
        rp2 = self.ex.create_recovery_point(self.store, txn_id)
        listing = self.ex.RP_ROOT / rp2 / 'filelist.json'
        listing.write_text(listing.read_text().replace('etc/cgi.cfg', 'etc/cgx.cfg'))
        self.assertFalse(self.ex.verify_recovery_point(self.store, rp2))

    def test_restore_finishes_after_a_crash_between_the_two_renames(self):
        txn_id = self.txn()
        rp_id = self.ex.create_recovery_point(self.store, txn_id)
        self.break_live()
        os.rename(str(self.nagios), str(self.ex.RP_ROOT / rp_id / 'failed'))
        self.ex.restore(self.store, txn_id, rp_id)
        self.assertEqual(self.ex.file_list(self.nagios), self.original)
        self.ex.restore(self.store, txn_id, rp_id)  # running it again changes nothing
        self.assertEqual(self.ex.file_list(self.nagios), self.original)

    # State machine ------------------------------------------------------

    def test_invalid_transition_is_refused_and_changes_nothing(self):
        txn_id = self.txn()
        with self.assertRaises(self.ex.InvalidTransition):
            self.ex.transition(self.store, txn_id, 'succeeded')
        self.assertEqual(self.row(txn_id)[0], 'applying')
        self.assertIsNone(self.store.verify_audit())

    def test_only_one_active_transaction_per_host(self):
        self.txn()
        with self.assertRaises(sqlite3.IntegrityError):
            self.ex.new_txn(self.store, 'drill', 'pp-mon-baseline-1', 'pp-mon-baseline-1')

    def test_unknown_fields_are_refused(self):
        txn_id = self.txn()
        with self.assertRaises(ValueError):
            self.ex.update_txn(self.store, txn_id, state='succeeded')

    # Reconcile ----------------------------------------------------------

    def test_reconcile_now_rolls_back_an_interrupted_change(self):
        txn_id = self.txn()
        rp_id = self.ex.create_recovery_point(self.store, txn_id)
        self.ex.update_txn(self.store, txn_id, recovery_point_id=rp_id, step='apply.change')
        self.break_live()
        self.assertEqual(self.ex.reconcile(self.store, 'now'), self.ex.ROLLED_BACK)
        self.assertEqual(self.row(txn_id)[0], 'rolled_back')
        self.assertEqual(self.row(txn_id)[2], 'INTERRUPTED')
        self.assertEqual(self.ex.file_list(self.nagios), self.original)

    def test_reconcile_at_boot_restores_files_without_touching_services_then_finishes(self):
        txn_id = self.txn()
        rp_id = self.ex.create_recovery_point(self.store, txn_id)
        self.ex.update_txn(self.store, txn_id, recovery_point_id=rp_id, step='apply.change')
        self.break_live()
        self.assertEqual(self.ex.reconcile(self.store, 'boot'), self.ex.OK)
        self.assertEqual(self.row(txn_id)[:2], ('rolling_back', 'restore.files-restored'))
        self.assertEqual([c for c in self.systemctl_calls if c[0] in ('start', 'stop')], [])
        self.assertEqual(self.ex.file_list(self.nagios), self.original)
        self.assertEqual(self.ex.reconcile(self.store, 'finish'), self.ex.ROLLED_BACK)
        self.assertEqual(self.row(txn_id)[0], 'rolled_back')
        self.assertEqual(self.ex.reconcile(self.store, 'finish'), self.ex.OK)

    def test_reconcile_before_the_recovery_point_changes_nothing_and_restarts(self):
        txn_id = self.txn()
        self.assertEqual(self.ex.reconcile(self.store, 'now'), self.ex.ROLLED_BACK)
        self.assertEqual(self.row(txn_id)[0], 'rolled_back')
        self.assertEqual(self.ex.file_list(self.nagios), self.original)
        self.assertIn(('start', 'nagios'), self.systemctl_calls)

    def test_reconcile_of_a_transaction_that_never_started_marks_it_failed(self):
        txn_id = self.txn('preparing')
        self.assertEqual(self.ex.reconcile(self.store, 'boot'), self.ex.OK)
        self.assertEqual(self.row(txn_id)[:3], ('failed', None, 'INTERRUPTED'))

    def test_reconcile_with_nothing_to_do(self):
        self.assertEqual(self.ex.reconcile(self.store, 'boot'), self.ex.OK)
        self.assertEqual(self.systemctl_calls, [])

    def test_unhealthy_after_restore_is_recovery_failed(self):
        txn_id = self.txn()
        rp_id = self.ex.create_recovery_point(self.store, txn_id)
        self.ex.update_txn(self.store, txn_id, recovery_point_id=rp_id)
        self.healthy = lambda mode: False
        self.assertEqual(self.ex.reconcile(self.store, 'now'), self.ex.RECOVERY_FAILED)
        self.assertEqual(self.row(txn_id)[:3:2], ('recovery_failed', 'HEALTH_AFTER_RESTORE'))

    # Drills (plan 13.4) -------------------------------------------------

    def drill(self, fault=None, crash=False):
        return self.ex.drill(self.store, fault, crash)

    def last_txn(self):
        return self.store.db.execute('SELECT txn_id FROM txn ORDER BY created_at DESC, rowid DESC').fetchone()[0]

    def test_drill_without_fault_copies_restores_and_passes(self):
        self.assertEqual(self.drill(), self.ex.OK)
        txn_id = self.last_txn()
        state, _, code, rp_id = self.row(txn_id)
        self.assertEqual((state, code), ('rolled_back', None))
        self.assertEqual(self.ex.file_list(self.nagios), self.original)
        self.assertEqual(self.health_calls, ['save', 'compare', 'compare'])
        tested = self.store.db.execute('SELECT restore_tested FROM recovery_point WHERE rp_id = ?',
                                       (rp_id,)).fetchone()[0]
        self.assertIsNotNone(tested)
        self.assertIn('drill.finished', self.events())
        self.assertIsNone(self.store.verify_audit())

    def test_drill_faults_are_detected_and_rolled_back(self):
        for fault in ('config', 'plugin'):
            with self.subTest(fault=fault):
                self.assertEqual(self.drill(fault), self.ex.OK)
                state, _, code, _ = self.row(self.last_txn())
                self.assertEqual((state, code), ('rolled_back', 'HEALTH_FAILED'))
                self.assertEqual(self.ex.file_list(self.nagios), self.original)

    def test_drill_fault_that_health_suite_misses_is_reported(self):
        self.healthy = lambda mode: True
        with patch.object(self.ex, 'inject', side_effect=lambda fault, rp_id: None):
            self.assertEqual(self.drill('config'), self.ex.DRILL_FAULT_MISSED)

    def test_drill_with_damaged_recovery_copy_is_recovery_failed_and_keeps_evidence(self):
        self.assertEqual(self.drill('corrupt'), self.ex.RECOVERY_FAILED)
        state, _, code, rp_id = self.row(self.last_txn())
        self.assertEqual((state, code), ('recovery_failed', 'RESTORE_FAILED'))
        self.assertTrue((self.ex.RP_ROOT / rp_id / 'nagios').is_dir())
        self.assertIn(DRILL_LINE, (self.nagios / 'etc/nagios.cfg').read_text())

    def test_drill_crash_after_apply_leaves_work_for_reconcile(self):
        with patch.object(self.ex.os, '_exit', side_effect=SystemExit):
            with self.assertRaises(SystemExit):
                self.drill('config', crash=True)
        txn_id = self.last_txn()
        self.assertEqual(self.row(txn_id)[:2], ('applying', 'apply.change'))
        self.assertEqual(self.ex.reconcile(self.store, 'now'), self.ex.ROLLED_BACK)
        self.assertEqual(self.ex.file_list(self.nagios), self.original)

    def test_unhealthy_system_blocks_the_drill_before_anything_changes(self):
        self.healthy = lambda mode: mode != 'save'
        self.assertEqual(self.drill('config'), self.ex.PREFLIGHT_FAILED)
        self.assertEqual(self.row(self.last_txn())[:3:2], ('blocked', 'PREFLIGHT_FAILED'))
        self.assertEqual(self.ex.file_list(self.nagios), self.original)
        self.assertEqual(self.systemctl_calls, [])

    def test_busy_lock_refuses_the_drill(self):
        self.ex.take_lock.side_effect = lambda: None
        self.assertEqual(self.drill(), self.ex.BUSY)
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM txn').fetchone()[0], 0)

    def test_drill_requires_confirmation_and_root(self):
        with patch.object(self.ex.os, 'geteuid', return_value=0, create=True):
            self.assertEqual(self.ex.main(['drill']), self.ex.PREFLIGHT_FAILED)
        with patch.object(self.ex.os, 'geteuid', return_value=1000, create=True):
            self.assertEqual(self.ex.main(['drill', '--yes']), self.ex.NOT_AUTHORISED)

    def test_context_is_kept_for_reconcile(self):
        txn_id = self.txn()
        self.assertEqual(self.ex.load_context(txn_id)['version'], '4.5.11')
        context = json.loads((self.pu.STATE_DIR / 'txn' / txn_id / 'context.json').read_text())
        self.assertEqual(context['ncpa_sha256'], 'b' * 64)


DRILL_LINE = 'pinpoint_drill_invalid_directive=1\n'


if __name__ == '__main__':
    unittest.main()
