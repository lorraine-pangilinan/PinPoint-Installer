"""Isolated installer tests: production paths rooted in temp dirs, systemctl mocked."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'setup/configure-log-retention.sh'


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'bin').mkdir()
        command = self.root / 'bin/systemctl'
        command.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$RETENTION_CALLS"\n')
        command.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.root / 'bin') + ':' + os.environ['PATH'],
                    'RETENTION_CALLS': str(self.root / 'calls')}
        self.journal = self.root / 'etc/systemd/journald.conf.d/pinpoint.conf'
        self.rotation = self.root / 'etc/logrotate.d/pinpoint-installer'

    def run_config(self):
        return subprocess.run(['bash', '-c', 'source "$1"; configure_log_retention "$2"',
                               'test', str(SCRIPT), str(self.root)], env=self.env, text=True, capture_output=True)

    def test_fresh_and_repeat(self):
        result = self.run_config()
        self.assertEqual(result.returncode, 0, result.stderr)
        journal = self.journal.read_bytes()
        self.assertIn(b'SystemMaxUse=100M', journal)
        self.assertIn(b'MaxRetentionSec=7day', journal)
        rotate = self.rotation.read_bytes()
        for setting in (b'weekly', b'rotate 4', b'compress', b'copytruncate', b'/var/log/pinpoint-*.log'):
            self.assertIn(setting, rotate)
        result = self.run_config()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.journal.read_bytes(), journal)
        self.assertEqual(self.rotation.read_bytes(), rotate)
        self.assertEqual(self.journal.stat().st_mode & 0o777, 0o644)
        self.assertIn('restart systemd-journald', (self.root / 'calls').read_text())

    def test_upgrade_keeps_admin_settings_and_rotation(self):
        self.journal.parent.mkdir(parents=True)
        custom = self.journal.parent / '20-admin.conf'
        custom.write_text('[Journal]\nSystemMaxUse=25M\n')
        self.rotation.parent.mkdir(parents=True)
        self.rotation.write_text('# administrator rotation\n')
        result = self.run_config()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.journal.exists())
        self.assertEqual(custom.read_text(), '[Journal]\nSystemMaxUse=25M\n')
        self.assertEqual(self.rotation.read_text(), '# administrator rotation\n')
        self.assertFalse((self.root / 'calls').exists())

    def test_admin_added_after_install_and_edited_managed_file(self):
        self.assertEqual(self.run_config().returncode, 0)
        (self.journal.parent / '90-admin.conf').write_text('[Journal]\nMaxRetentionSec=3day\n')
        self.assertEqual(self.run_config().returncode, 0)
        self.assertFalse(self.journal.exists())
        self.journal.write_text('[Journal]\nSystemMaxUse=30M\n')
        before = self.journal.read_bytes()
        self.assertEqual(self.run_config().returncode, 0)
        self.assertEqual(self.journal.read_bytes(), before)

    def test_symlink_destination_never_written(self):
        self.journal.parent.mkdir(parents=True)
        victim = self.root / 'victim'
        victim.write_text('keep')
        self.journal.symlink_to(victim)
        self.assertNotEqual(self.run_config().returncode, 0)
        self.assertEqual(victim.read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
