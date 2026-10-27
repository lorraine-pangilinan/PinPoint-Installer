"""PinPoint Update Manager milestone 1 contract; temporary files, no Nagios, sudo or network required."""
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / 'setup/pinpoint-update.py'
BASELINE = REPO / 'setup/manifests/pp-mon-baseline-1.json'

CORE_V = 'Nagios Core 4.5.11\nCopyright (c) 2009-present Nagios Core Development Team\n'
PING_V = 'check_ping v2.4.12 (nagios-plugins 2.4.12)\n'
NCPA_V = 'check_ncpa.py, Version 1.2.4\n'


class UpdateManagerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        spec = importlib.util.spec_from_file_location('pinpoint_update', SOURCE)
        self.pu = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.pu)
        self.pu.NAGIOS = root / 'nagios'
        self.pu.STATE_DIR = root / 'state'
        self.pu.APP_DIR = root / 'app'
        self.pu.OS_RELEASE = root / 'os-release'
        self.pu.OS_RELEASE.write_text('ID=ubuntu\nVERSION_ID="22.04"\n')
        self.manifest = self.pu.load_manifest(BASELINE)
        self.outputs = {'nagios': CORE_V, 'check_ping': PING_V, 'check_ncpa.py': NCPA_V}
        run = patch.object(self.pu, 'run', side_effect=lambda args: self.outputs[Path(args[0]).name])
        run.start(); self.addCleanup(run.stop)
        self.store = self.pu.Store()
        self.addCleanup(self.store.close)

    def install(self, *names):
        for name in names:
            path = self.pu.NAGIOS / ('bin' if name == 'nagios' else 'libexec') / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('#!/bin/sh\n')

    def statuses(self):
        return {r['component']: r['status'] for r in self.pu.compare(self.pu.scan(), self.manifest)}

    def test_parsers_read_real_version_output(self):
        self.assertEqual(self.pu.parse_core_version(CORE_V), '4.5.11')
        self.assertEqual(self.pu.parse_plugins_version(PING_V), '2.4.12')
        self.assertEqual(self.pu.parse_ncpa_version(NCPA_V), '1.2.4')
        self.assertIsNone(self.pu.parse_core_version('garbage'))

    def test_baseline_install_is_recorded_once_with_audit(self):
        self.install('nagios', 'check_ping', 'check_ncpa.py')
        self.assertEqual(set(self.statuses().values()), {'baseline'})
        self.pu.inventory(self.store, self.manifest)
        self.pu.inventory(self.store, self.manifest)
        self.assertEqual(self.store.installed_manifest(), 'pp-mon-baseline-1')
        events = [e for (e,) in self.store.db.execute('SELECT event FROM audit ORDER BY seq')]
        self.assertEqual(events, ['installed_state.recorded', 'inventory.scanned', 'inventory.scanned'])
        self.assertIsNone(self.store.verify_audit())

    def test_differing_or_missing_components_are_reported_and_not_recorded(self):
        self.install('nagios', 'check_ping')
        self.outputs['nagios'] = 'Nagios Core 4.5.12\n'
        self.assertEqual(self.statuses(), {'nagios-core': 'DIFFERS', 'nagios-plugins': 'baseline',
                                           'check-ncpa': 'NOT INSTALLED'})
        self.pu.inventory(self.store, self.manifest)
        self.assertIsNone(self.store.installed_manifest())

    def test_unreadable_version_is_unknown_not_baseline(self):
        self.install('nagios', 'check_ping', 'check_ncpa.py')
        self.outputs['check_ping'] = ''
        self.assertEqual(self.statuses()['nagios-plugins'], 'UNKNOWN')

    def test_audit_chain_detects_tampering(self):
        self.install('nagios', 'check_ping', 'check_ncpa.py')
        self.pu.inventory(self.store, self.manifest)
        with self.store.db:
            self.store.db.execute("UPDATE audit SET actor = 'someone-else' WHERE seq = 1")
        self.assertEqual(self.store.verify_audit(), 1)

    def test_menu_options_change_nothing_and_never_claim_up_to_date(self):
        self.install('nagios', 'check_ping', 'check_ncpa.py')
        answers, out = iter(['2', '3', '9', '1', '4']), io.StringIO()
        nagios_before = sorted(p.name for p in self.pu.NAGIOS.rglob('*'))
        code = self.pu.menu(self.store, self.manifest, read=lambda prompt: next(answers),
                            write=lambda text='': out.write(text + '\n'))
        text = out.getvalue()
        self.assertEqual(code, 0)
        self.assertEqual(text.count('Installing updates is not available'), 2)
        self.assertIn('Please enter 1, 2, 3 or 4.', text)
        self.assertIn('Update status: UNKNOWN', text)
        self.assertNotIn('up to date', text.lower())
        for option in ('1) Reload (check for updates)', '2) Install updates', '3) Choose what to update', '4) Exit'):
            self.assertIn(option, text)
        self.assertEqual(sorted(p.name for p in self.pu.NAGIOS.rglob('*')), nagios_before)
        events = [e for (e,) in self.store.db.execute('SELECT event FROM audit')]
        self.assertIn('catalog.unavailable', events)

    def test_menu_exits_cleanly_on_end_of_input(self):
        def eof(prompt):
            raise EOFError
        self.assertEqual(self.pu.menu(self.store, self.manifest, read=eof, write=lambda text='': None), 0)

    def test_non_root_is_refused(self):
        with patch.object(self.pu.os, 'geteuid', return_value=1000, create=True):
            self.assertEqual(self.pu.main(['status']), 3)

    def test_status_json_contract(self):
        self.install('nagios', 'check_ping', 'check_ncpa.py')
        self.pu.MANIFEST = BASELINE
        out = io.StringIO()
        with patch.object(self.pu.os, 'geteuid', return_value=0, create=True), patch('sys.stdout', out):
            self.assertEqual(self.pu.main(['status', '--json']), 0)
        data = json.loads(out.getvalue())
        self.assertEqual(data['schema'], 'pinpoint-update/v1')
        self.assertEqual(data['installed_manifest'], 'pp-mon-baseline-1')
        self.assertTrue(data['update_status'].startswith('UNKNOWN'))
        self.assertEqual(data['os']['version'], '22.04')

    def test_first_login_menu_opens_once(self):
        self.install('nagios', 'check_ping', 'check_ncpa.py')
        self.pu.MANIFEST = BASELINE
        self.pu.MENU_PENDING = Path(self.temp.name) / 'update-menu-pending'
        self.pu.MENU_PENDING.write_text('')
        shown = []
        with patch.object(self.pu.os, 'geteuid', return_value=0, create=True),                 patch.object(self.pu, 'menu', side_effect=lambda store, manifest: shown.append(1) or 0):
            self.assertEqual(self.pu.main(['--first-login']), 0)
            self.assertEqual(self.pu.main(['--first-login']), 0)
        self.assertEqual(shown, [1])
        self.assertFalse(self.pu.MENU_PENDING.exists())

    def test_app_commit_reads_branch_ref_without_git(self):
        git = self.pu.APP_DIR / '.git'
        (git / 'refs/heads').mkdir(parents=True)
        (git / 'HEAD').write_text('ref: refs/heads/main\n')
        (git / 'refs/heads/main').write_text('a' * 40 + '\n')
        self.assertEqual(self.pu.app_commit(), 'a' * 40)

    def test_invalid_manifest_is_rejected(self):
        bad = Path(self.temp.name) / 'bad.json'
        bad.write_text(json.dumps({'schema_version': 2, 'manifest_id': 'x'}))
        with self.assertRaises(ValueError):
            self.pu.load_manifest(bad)


if __name__ == '__main__':
    unittest.main()
