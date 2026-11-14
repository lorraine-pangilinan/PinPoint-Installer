"""PinPoint Update Manager, Phase 4 contract: update catalog, status line, notices and login notice.

Temporary folders only: the catalog is a dictionary served by a fake download
function, so no network, Nagios, mail or sudo is needed. IDs: UT-CAT (catalog
trust), UT-NTC (notices), UT-BAN (login notice), UT-MENU (decision screen).
"""
import copy
import datetime
import hashlib
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
REAL_CANDIDATE = REPO / 'catalog/manifests/pp-mon-2026.11-1.json'
BASE = 'https://raw.githubusercontent.com/lorraine-pangilinan/PinPoint-Installer/main/catalog/'
CANDIDATE = 'pp-mon-2026.11-1'


class CatalogTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = self.root = Path(self.temp.name)
        spec = importlib.util.spec_from_file_location('pinpoint_update', SOURCE)
        pu = self.pu = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(pu)
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
        pu.host_id = lambda: 'test-host'
        pu.trusted_file = lambda path: True
        self.versions = {'nagios-core': '4.5.11', 'nagios-plugins': '2.4.12', 'check-ncpa': '1.2.4'}
        pu.scan = lambda: {k: {'version': v, 'sha256': None} for k, v in self.versions.items()}
        for p in (patch.object(pu.platform, 'machine', return_value='x86_64'),
                  patch.object(pu.os, 'geteuid', return_value=0, create=True),
                  patch.dict(os.environ, {'SUDO_USER': 'alice'})):
            p.start()
            self.addCleanup(p.stop)
        pu.user_groups = lambda user: {pu.ADMINS}
        self.store = pu.Store()
        self.addCleanup(self.store.close)
        self.manifest = pu.load_manifest()
        pu.refresh(self.store, self.manifest)  # records the baseline as installed
        self.files = {}
        self.publish(CANDIDATE, REAL_CANDIDATE.read_bytes())
        self.requests = []

    # Helpers --------------------------------------------------------------

    def publish(self, mid, raw, digest=None, revoked=None):
        self.files[BASE + 'manifests/%s.json' % mid] = raw
        index = json.loads(self.files.get(BASE + 'index.json', b'{"schema_version": 1, "manifests": []}'))
        index['manifests'] = [e for e in index['manifests'] if e['manifest_id'] != mid]
        index['manifests'].append({'manifest_id': mid, 'sha256': digest or hashlib.sha256(raw).hexdigest()})
        if revoked is not None:
            index['revoked'] = revoked
        self.files[BASE + 'index.json'] = json.dumps(index).encode()

    def fetch(self, url, limit, timeout, hosts):
        self.requests.append(url)
        self.pu.check_url(url, hosts)
        if url not in self.files:
            raise self.pu.CatalogError('%s returned HTTP 404' % url)
        return self.files[url]

    def discover(self):
        return self.pu.discover(self.store, self.fetch)

    def found(self):
        return self.pu.scan()

    def events(self):
        return [e for (e,) in self.store.db.execute('SELECT event FROM audit ORDER BY seq')]

    def candidate_body(self):
        return json.loads(REAL_CANDIDATE.read_text())

    # UT-CAT: what the appliance accepts from the catalog -------------------

    def test_cat01_good_catalog_records_the_new_set_and_offers_it(self):
        ok, reason, new = self.discover()
        self.assertTrue(ok, reason)
        self.assertEqual(new, [CANDIDATE])
        record = self.store.manifest(CANDIDATE)
        self.assertEqual(record['source'], 'catalog')
        self.assertEqual(record['sha256'], hashlib.sha256(REAL_CANDIDATE.read_bytes()).hexdigest())
        self.assertEqual((self.pu.MANIFEST_DIR / (CANDIDATE + '.json')).read_bytes(), REAL_CANDIDATE.read_bytes())
        self.assertEqual(self.pu.catalog_status(self.store, self.found()), 'Update available: ' + CANDIDATE)
        self.assertIn('catalog.checked', self.events())

    def test_cat02_second_check_downloads_only_the_index(self):
        self.discover()
        self.requests.clear()
        ok, _, new = self.discover()
        self.assertTrue(ok)
        self.assertEqual((new, self.requests), ([], [BASE + 'index.json']))

    def test_cat03_tampered_manifest_is_refused_and_nothing_is_written(self):
        raw = REAL_CANDIDATE.read_bytes()
        self.publish(CANDIDATE, raw.replace(b'assets.nagios.com/downloads/nagioscore', b'assets.nagios.com/evil'),
                     digest=hashlib.sha256(raw).hexdigest())
        ok, reason, new = self.discover()
        self.assertFalse(ok)
        self.assertIn('does not match the SHA-256 in the catalog index', reason)
        self.assertIsNone(self.store.manifest(CANDIDATE))
        self.assertFalse((self.pu.MANIFEST_DIR / (CANDIDATE + '.json')).exists())
        self.assertIn('catalog.failed', self.events())
        self.assertTrue(self.pu.catalog_status(self.store, self.found()).startswith('UNKNOWN (last check failed'))

    def test_cat04_one_bad_file_refuses_the_whole_catalog(self):
        other = self.candidate_body()
        other['manifest_id'] = 'pp-mon-2026.12-1'
        self.publish('pp-mon-2026.12-1', json.dumps(other).encode(), digest='0' * 64)
        ok, _, _ = self.discover()
        self.assertFalse(ok)
        self.assertIsNone(self.store.manifest(CANDIDATE))  # listed first and valid, still not accepted

    def test_cat05_a_recorded_manifest_can_never_be_replaced(self):
        self.discover()
        changed = self.candidate_body()
        changed['compatibility']['state'] = 'verified'
        self.publish(CANDIDATE, json.dumps(changed).encode())
        ok, reason, _ = self.discover()
        self.assertFalse(ok)
        self.assertIn('needs a new ID', reason)
        self.assertEqual(self.store.manifest(CANDIDATE)['compat_state'], 'conditional')

    def test_cat06_only_https_on_the_catalog_host(self):
        for url in ('http://raw.githubusercontent.com/x/', 'https://example.com/catalog/',
                    'https://raw.githubusercontent.com.evil.net/x/', 'https://user:pw@raw.githubusercontent.com/x/',
                    'https://raw.githubusercontent.com:8443/x/'):
            self.pu.UPDATER_CONF.write_text('catalog_url = %s\n' % url)
            ok, reason, _ = self.discover()
            self.assertFalse(ok, url)
            self.assertIn('not an allowed HTTPS address', reason)
        self.assertEqual(self.requests, [])

    def test_cat07_redirect_to_another_host_is_refused(self):
        handler = self.pu.redirect_handler(self.pu.CATALOG_HOSTS)
        for target in ('https://evil.example.net/index.json', 'http://raw.githubusercontent.com/x/index.json'):
            with self.assertRaises(self.pu.CatalogError):
                handler.redirect_request(None, None, 302, 'Found', {}, target)

    def test_cat08_untrusted_or_unknown_settings_are_refused(self):
        self.pu.UPDATER_CONF.write_text('catalog_url = %s\nupdate_now = yes\n' % BASE)
        self.assertIn('unknown line', self.discover()[1])
        self.pu.UPDATER_CONF.write_text('catalog_url = %s\n' % BASE)
        self.pu.trusted_file = lambda path: Path(path) != self.pu.UPDATER_CONF
        self.assertIn('not owned by root', self.discover()[1])

    def test_cat09_network_failure_keeps_the_last_good_check_and_never_says_up_to_date(self):
        self.files[BASE + 'index.json'] = json.dumps({'schema_version': 1, 'manifests': []}).encode()
        self.assertTrue(self.discover()[0])
        self.assertTrue(self.pu.catalog_status(self.store, self.found()).startswith('Up to date'))
        del self.files[BASE + 'index.json']
        self.assertFalse(self.discover()[0])
        status = self.pu.catalog_status(self.store, self.found())
        self.assertTrue(status.startswith('UNKNOWN (last check failed'))
        self.assertIn('last good check: 20', status)

    def test_cat10_stale_catalog_is_unknown(self):
        self.files[BASE + 'index.json'] = json.dumps({'schema_version': 1, 'manifests': []}).encode()
        self.discover()
        state = self.pu.catalog_state()
        state['last_good'] = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=9)).isoformat()
        self.pu.save_catalog_state(state)
        self.assertIn('more than 7 days old', self.pu.catalog_status(self.store, self.found()))

    def test_cat11_catalog_revocation_deprecates_and_blocks(self):
        self.discover()
        self.publish(CANDIDATE, REAL_CANDIDATE.read_bytes(), revoked=[CANDIDATE])
        self.assertTrue(self.discover()[0])
        record = self.store.manifest(CANDIDATE)
        self.assertEqual(record['compat_state'], 'deprecated')
        self.assertIsNotNone(record['revoked_at'])
        self.assertTrue(self.pu.gate(self.store, CANDIDATE, self.found()))

    def test_cat12_invalid_index_is_refused(self):
        for index in ({'schema_version': 2, 'manifests': []}, {'schema_version': 1, 'manifests': 'x'},
                      {'schema_version': 1, 'manifests': [{'manifest_id': '../x', 'sha256': '0' * 64}]},
                      {'schema_version': 1, 'manifests': [{'manifest_id': 'a', 'sha256': '0' * 64}] * 2}):
            self.files[BASE + 'index.json'] = json.dumps(index).encode()
            self.assertFalse(self.discover()[0], index)

    def test_cat13_shipped_catalog_matches_its_index(self):
        index = json.loads((REPO / 'catalog/index.json').read_text())
        entries, _ = self.pu.check_index(index)
        for mid, digest in entries:
            raw = (REPO / ('catalog/manifests/%s.json' % mid)).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), digest, mid)
            self.pu.check_manifest(json.loads(raw))

    # UT-NTC: notices -------------------------------------------------------

    def objects_cache(self, emails):
        blocks = ['define contactgroup {\n\tcontactgroup_name\tsystem_users\n\tmembers\t%s\n\t}\n'
                  % ','.join('u%d' % n for n in range(len(emails)))]
        blocks += ['define contact {\n\tcontact_name\tu%d\n\temail\t%s\n\t}\n' % (n, e) for n, e in enumerate(emails)]
        blocks.append('define contact {\n\tcontact_name\tnot-a-member\n\temail\tother@uni.edu\n\t}\n')
        self.pu.OBJECTS_CACHE.write_text(''.join(blocks))

    def test_ntc01_recipients_are_real_system_users_only(self):
        self.objects_cache(['admin@uni.edu', 'admin@example.com', 'bad address', '-x@uni.edu', 'ops@uni.edu'])
        self.assertEqual(self.pu.recipients({}), ['admin@uni.edu', 'ops@uni.edu'])
        self.assertEqual(self.pu.recipients({'notify_to': 'it@uni.edu, x@localhost'}), ['it@uni.edu'])

    def test_ntc02_available_notice_is_sent_once_and_retried_on_failure(self):
        self.objects_cache(['admin@uni.edu'])
        self.discover()
        record = self.store.manifest(CANDIDATE)
        self.assertTrue(self.pu.notice_available(self.store, record))
        self.assertFalse(self.pu.notice_available(self.store, record))  # deduplicated
        sent = []
        self.assertEqual(self.pu.send_notices(self.store, lambda to, s, b: (False, 'msmtp: timeout')), 0)
        self.assertEqual(self.pu.send_notices(self.store, lambda to, s, b: sent.append((to, s, b)) or (True, None)), 1)
        self.assertEqual(self.pu.send_notices(self.store, lambda to, s, b: sent.append(1) or (True, None)), 0)
        to, subject, body = sent[0]
        self.assertEqual(to, ['admin@uni.edu'])
        self.assertIn('Conditional Nagios update available: ' + CANDIDATE, subject)
        self.assertIn('Nagios Core 4.5.14', body)
        self.assertIn('Nothing will be installed until an administrator approves it.', body)
        row = self.store.rows('SELECT attempts, sent_at FROM notice')[0]
        self.assertEqual(row['attempts'], 2)
        self.assertIsNotNone(row['sent_at'])

    def test_ntc03_without_a_real_address_the_notice_stays_pending(self):
        self.objects_cache(['admin@example.com'])
        self.discover()
        self.pu.notice_available(self.store, self.store.manifest(CANDIDATE))
        self.assertEqual(self.pu.send_notices(self.store, lambda *a: self.fail('must not send')), 0)
        self.assertEqual(self.store.rows('SELECT attempts FROM notice')[0]['attempts'], 0)

    def test_ntc04_declined_set_gets_no_notice(self):
        self.discover()
        self.pu.refuse(self.store, CANDIDATE, 'decline', 'not needed here')
        self.assertFalse(self.pu.notice_available(self.store, self.store.manifest(CANDIDATE)))

    def test_ntc05_notices_never_contain_secrets(self):
        self.objects_cache(['admin@uni.edu'])
        self.discover()
        self.pu.notice_available(self.store, self.store.manifest(CANDIDATE))
        body = self.store.rows('SELECT body FROM notice')[0]['body'].lower()
        for word in ('password', 'token', 'http://'):
            self.assertNotIn(word, body)

    # UT-BAN: login notice --------------------------------------------------

    def test_ban01_login_notice_shows_an_available_update_and_goes_away(self):
        self.discover()
        self.pu.write_login_notice(self.store, self.found())
        text = self.pu.LOGIN_NOTICE.read_text()
        self.assertIn('Update available: ' + CANDIDATE, text)
        self.pu.refuse(self.store, CANDIDATE, 'decline', 'not needed')
        self.files[BASE + 'index.json'] = json.dumps({'schema_version': 1, 'manifests': []}).encode()
        self.pu.revoke(self.store, [CANDIDATE], 'test')
        self.discover()
        self.pu.write_login_notice(self.store, self.found())
        self.assertFalse(self.pu.LOGIN_NOTICE.exists())

    def test_ban02_login_notice_shows_a_scheduled_update(self):
        self.discover()
        at = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)).replace(microsecond=0)
        self.pu.approve(self.store, CANDIDATE, self.found(), self.pu.utc(at), None, True)
        self.pu.write_login_notice(self.store, self.found())
        self.assertIn('is scheduled for', self.pu.LOGIN_NOTICE.read_text())

    # UT-MENU: menu and CLI -------------------------------------------------

    def run_menu(self, answers, caller='admin'):
        answers, out = iter(answers), io.StringIO()
        with patch.object(self.pu, 'start_run', side_effect=lambda store, txn: self.started.append(txn)):
            code = self.pu.menu(self.store, self.manifest, read=lambda prompt: next(answers),
                                write=lambda text='': out.write(text + '\n'), caller=caller,
                                sleep=lambda s: None, fetch=self.fetch)
        return code, out.getvalue()

    def test_menu01_reload_then_install_now_starts_the_runner(self):
        self.started = []

        def finish(store, txn, write=print, sleep=None, limit=0):
            write('  Result: SUCCEEDED')
        with patch.object(self.pu, 'follow', side_effect=finish):
            code, text = self.run_menu(['1', '2', '1', CANDIDATE, 'ACCEPT', '4'])
        self.assertEqual(code, 0)
        self.assertIn('Nagios Core     4.5.11 -> 4.5.14', text)
        self.assertIn('CONDITIONAL', text)
        self.assertEqual(len(self.started), 1)
        self.assertEqual(self.store.rows('SELECT state FROM txn')[0]['state'], 'approved')

    def test_menu02_wrong_confirmation_or_viewer_changes_nothing(self):
        self.started = []
        self.discover()
        self.run_menu(['2', '1', 'pp-mon-wrong', '6', '4'])
        code, text = self.run_menu(['2', '1', '6', '4'], caller='viewer')
        self.assertIn('Only members of pinpoint-update-admins', text)
        self.assertEqual((self.started, self.store.rows('SELECT * FROM txn')), ([], []))

    def test_menu03_schedule_defer_and_decline(self):
        self.started = []
        self.discover()
        at = (datetime.datetime.now() + datetime.timedelta(days=1)).strftime('%Y-%m-%d %H:%M')
        _, text = self.run_menu(['3', '1', '2', CANDIDATE, 'ACCEPT', at, '4'])
        self.assertIn('Scheduled: ' + CANDIDATE, text)
        self.assertEqual(self.started, [])
        txn = self.store.rows('SELECT txn_id FROM txn')[0]['txn_id']
        self.pu.cancel(self.store, txn)
        self.run_menu(['2', '4', 'waiting for the semester to end', '2027-01-15', '4'])
        self.assertEqual(self.pu.decisions(self.store, CANDIDATE, 'defer')[0]['review_date'], '2027-01-15')
        self.run_menu(['2', '5', 'not for this site', '4'])
        self.assertEqual(len(self.pu.decisions(self.store, CANDIDATE, 'decline')), 1)

    def test_menu04_screen_compares_with_the_installed_set_after_an_update(self):
        self.discover()
        self.pu.set_installed(self.store, CANDIDATE, 'txn-20261114000000-abcdef')
        self.versions['nagios-core'] = '4.5.14'
        rows = self.pu.compare(self.found(), self.pu.reference(self.store, self.manifest))
        self.assertEqual({r['status'] for r in rows}, {'baseline'})
        self.assertTrue(self.pu.catalog_status(self.store, self.found()).startswith('Up to date'))

    def test_menu05_discover_exit_code_and_ubuntu_security_line(self):
        out = io.StringIO()
        with patch.object(self.pu, 'http_get', side_effect=self.fetch), patch('sys.stdout', out):
            self.assertEqual(self.pu.main(['discover', '--json']), 0)
        self.assertEqual(json.loads(out.getvalue())['new_manifests'], [CANDIDATE])
        del self.files[BASE + 'index.json']
        with patch.object(self.pu, 'http_get', side_effect=self.fetch), patch('sys.stdout', io.StringIO()), \
                patch('sys.stderr', io.StringIO()):
            self.assertEqual(self.pu.main(['discover']), self.pu.CATALOG_UNAVAILABLE)
        self.assertEqual(self.pu.auto_security_updates(), 'off')
        self.pu.AUTO_UPGRADES.write_text('APT::Periodic::Update-Package-Lists "1";\n'
                                         'APT::Periodic::Unattended-Upgrade "1";\n')
        self.assertEqual(self.pu.auto_security_updates(), 'on')


if __name__ == '__main__':
    unittest.main()
