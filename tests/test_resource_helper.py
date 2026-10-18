"""Restricted resource writer contract; isolated files, no sudo or Nagios required."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / 'setup/pinpoint-apply-resources.py'


class ResourceHelperTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / 'resource.cfg'
        self.outside = '$USER1$=/plugins\n# External bytes stay unchanged\n'
        self.config.write_text(self.outside)
        self.config.chmod(0o660)
        spec = importlib.util.spec_from_file_location('resource_helper', SOURCE)
        self.helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.helper)
        self.helper.CONFIG = str(self.config)
        self.owner = patch.object(self.helper.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=os.getuid()))
        self.group = patch.object(self.helper.grp, 'getgrnam', return_value=SimpleNamespace(gr_gid=os.getgid()))
        self.owner.start(); self.group.start()
        self.addCleanup(self.owner.stop); self.addCleanup(self.group.stop)
        self.block = '# BEGIN PINPOINT\n# PINPOINT KEY "ncpa_token:1" $USER2$\n$USER2$=synthetic\n# END PINPOINT\n'

    def payload(self, block=None):
        before, _, after = self.helper.split_resource(self.config.read_text())
        return {'resource_path': str(self.config), 'outside_digest': self.helper.outside_digest(before, after),
                'block': self.block if block is None else block}

    def test_atomic_update_preserves_external_bytes_and_metadata_and_supports_rollback(self):
        original = self.config.stat()
        self.helper.apply(self.payload())
        self.assertEqual(self.config.read_text(), self.outside + self.block)
        current = self.config.stat()
        self.assertEqual((current.st_uid, current.st_gid, stat.S_IMODE(current.st_mode)),
                         (original.st_uid, original.st_gid, 0o660))
        restore = self.payload(); restore['block'] = None
        self.helper.apply(restore)
        self.assertEqual(self.config.read_text(), self.outside)
        self.assertEqual(list(self.config.parent.iterdir()), [self.config])

    def test_wrong_path_and_external_change_are_rejected(self):
        for key, value in [('resource_path', '/etc/sudoers'), ('outside_digest', '0' * 64)]:
            request = self.payload(); request[key] = value
            with self.assertRaises(self.helper.Rejected): self.helper.apply(request)
            self.assertEqual(self.config.read_text(), self.outside)

    def test_block_cannot_write_nonresource_directives_external_slots_or_inject_config(self):
        for body in ['cfg_file=/etc/evil', '$USER1$=evil', '$USER2$=safe\n$USER2$=duplicate',
                     '$USER2$=bad;value', '$USER257$=out-of-range', '# unrelated attacker comment']:
            request = self.payload('# BEGIN PINPOINT\n' + body + '\n# END PINPOINT\n')
            with self.assertRaises(self.helper.Rejected): self.helper.apply(request)
            self.assertEqual(self.config.read_text(), self.outside)

    def test_external_slot_collision_and_unsafe_permissions_are_rejected(self):
        self.config.write_text(self.outside + '$USER2$=external\n')
        with self.assertRaises(self.helper.Rejected): self.helper.apply(self.payload())
        self.config.chmod(0o664)
        with self.assertRaises(self.helper.Rejected): self.helper.apply(self.payload())

    def test_external_slot_with_whitespace_around_assignment_is_reserved(self):
        self.config.write_text(self.outside + '$USER2$ = external\n')
        with self.assertRaises(self.helper.Rejected): self.helper.apply(self.payload())

    def test_block_without_final_newline_cannot_join_external_footer(self):
        self.config.write_text(self.outside + self.block + '# footer\n')
        with self.assertRaises(self.helper.Rejected):
            self.helper.apply(self.payload(self.block.rstrip('\n')))

    def test_symlink_destination_is_refused_without_changing_target(self):
        target = self.config.with_name('target.cfg')
        target.write_text(self.outside)
        target.chmod(0o660)
        self.config.unlink()
        self.config.symlink_to(target)
        with self.assertRaises(OSError):
            self.helper.apply(self.payload())
        self.assertEqual(target.read_text(), self.outside)

    def test_wrong_owner_and_duplicate_markers_are_refused(self):
        with patch.object(self.helper.pwd, 'getpwnam',
                          return_value=SimpleNamespace(pw_uid=os.getuid() + 1)):
            with self.assertRaises(self.helper.Rejected):
                self.helper.apply(self.payload())
        self.config.write_text(self.outside + self.block + self.block)
        with self.assertRaises(self.helper.Rejected):
            self.helper.apply({'resource_path': str(self.config),
                               'outside_digest': '0' * 64, 'block': None})

    def test_unknown_request_fields_are_refused(self):
        request = self.payload()
        request['owner'] = 'root'
        with self.assertRaises(self.helper.Rejected):
            self.helper.apply(request)
        self.assertEqual(self.config.read_text(), self.outside)

    def test_replace_failure_keeps_original_and_removes_private_stage(self):
        with patch.object(self.helper.os, 'replace', side_effect=OSError('synthetic failure')):
            with self.assertRaises(OSError): self.helper.apply(self.payload())
        self.assertEqual(self.config.read_text(), self.outside)
        self.assertEqual(list(self.config.parent.iterdir()), [self.config])


if __name__ == '__main__':
    unittest.main()
