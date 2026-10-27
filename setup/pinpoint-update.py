#!/usr/bin/python3 -I
"""PinPoint Update Manager, milestone 1: read-only.

Scan the installed Nagios Core, Nagios Plugins and check_ncpa.py, compare them
with the bundled baseline manifest, record the scan in a root-only SQLite
database with a hash-chained audit log, and show the numbered console menu.
Nothing here installs, downloads or changes Nagios. Options 2 and 3 of the menu
say so. There is no update catalog yet, so Reload reports the update status as
UNKNOWN rather than "up to date".
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import socket
import sqlite3
import subprocess
import sys

NAGIOS = Path('/usr/local/nagios')
MANIFEST = Path('/etc/pinpoint/updates/manifests/pp-mon-baseline-1.json')
STATE_DIR = Path('/var/lib/pinpoint/updates')
APP_DIR = Path('/opt/pinpoint/Network-Diagnosis-System')
OS_RELEASE = Path('/etc/os-release')
# Created by configure-monitoring-updates.sh on a fresh install only; the login
# hook opens the menu once while it exists. World-readable folder, unlike STATE_DIR.
MENU_PENDING = Path('/var/lib/pinpoint/update-menu-pending')
CATALOG_URL = None  # No signed catalog exists yet (plan section 6.1).
COMPONENTS = (('nagios-core', 'Nagios Core'), ('nagios-plugins', 'Nagios Plugins'), ('check-ncpa', 'check_ncpa'))
RUN_TIMEOUT = 15

SCHEMA = """
CREATE TABLE IF NOT EXISTS inventory (
  scan_id TEXT NOT NULL, host_id TEXT NOT NULL, component TEXT NOT NULL,
  installed_version TEXT, managed INTEGER NOT NULL, artifact_sha256 TEXT,
  scanned_at TEXT NOT NULL, PRIMARY KEY (scan_id, component));
CREATE TABLE IF NOT EXISTS installed_state (
  host_id TEXT PRIMARY KEY, manifest_id TEXT NOT NULL, since TEXT NOT NULL, last_txn_id TEXT);
CREATE TABLE IF NOT EXISTS audit (
  seq INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, actor TEXT NOT NULL,
  event TEXT NOT NULL, txn_id TEXT, manifest_id TEXT, detail_json TEXT NOT NULL,
  prev_hash TEXT NOT NULL, hash TEXT NOT NULL);
"""


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def actor():
    """The person behind sudo, or root for a direct root login."""
    return os.environ.get('SUDO_USER') or 'root'


def run(args):
    """Run a fixed command and return its output, or '' if it cannot run."""
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=RUN_TIMEOUT, check=False)
    except (OSError, subprocess.SubprocessError):
        return ''
    return done.stdout + done.stderr


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path=None):
    with open(path or MANIFEST, encoding='utf-8') as f:
        manifest = json.load(f)
    if manifest.get('schema_version') != 1 or not re.fullmatch(r'[a-z0-9.-]{1,64}', manifest.get('manifest_id', '')):
        raise ValueError('unsupported manifest')
    return manifest


def parse_core_version(text):
    match = re.search(r'Nagios Core ([0-9][0-9A-Za-z.+-]*)', text)
    return match[1] if match else None


def parse_plugins_version(text):
    match = re.search(r'nagios-plugins ([0-9][0-9A-Za-z.+-]*)', text)
    return match[1] if match else None


def parse_ncpa_version(text):
    match = re.search(r'check_ncpa\.py, Version ([0-9][0-9A-Za-z.+-]*)', text)
    return match[1] if match else None


def host_id():
    try:
        return Path('/etc/machine-id').read_text().strip() or socket.gethostname()
    except OSError:
        return socket.gethostname()


def os_profile():
    fields = {}
    try:
        for line in OS_RELEASE.read_text().splitlines():
            key, _, value = line.partition('=')
            fields[key] = value.strip('"')
    except OSError:
        pass
    return {'os': fields.get('ID', 'unknown'), 'version': fields.get('VERSION_ID', 'unknown'),
            'arch': platform.machine() or 'unknown'}


def app_commit():
    """Read the PinPoint checkout's HEAD without running git as root in another user's repo."""
    git = APP_DIR / '.git'
    try:
        head = (git / 'HEAD').read_text().strip()
        if not head.startswith('ref: '):
            return head[:40] or None
        ref = head[5:]
        if (git / ref).is_file():
            return (git / ref).read_text().strip()[:40]
        for line in (git / 'packed-refs').read_text().splitlines():
            if line.endswith(' ' + ref):
                return line.split(' ', 1)[0][:40]
    except OSError:
        pass
    return None


def scan():
    """Return {component: {'version', 'sha256'}} for the managed components."""
    core = NAGIOS / 'bin/nagios'
    ping = NAGIOS / 'libexec/check_ping'
    ncpa = NAGIOS / 'libexec/check_ncpa.py'
    found = {
        'nagios-core': {'version': parse_core_version(run([str(core), '-V'])) if core.is_file() else None,
                        'sha256': sha256_file(core) if core.is_file() else None},
        'nagios-plugins': {'version': parse_plugins_version(run([str(ping), '-V'])) if ping.is_file() else None,
                           'sha256': None},
        'check-ncpa': {'version': parse_ncpa_version(run([str(ncpa), '--version'])) if ncpa.is_file() else None,
                       'sha256': sha256_file(ncpa) if ncpa.is_file() else None},
    }
    return found


def compare(found, manifest):
    """Status of each component against the manifest: up to date, differs, not installed or unknown."""
    rows = []
    for key, label in COMPONENTS:
        wanted = manifest['components'][key]['version']
        have = found.get(key, {}).get('version')
        if have is None:
            exists = {'nagios-core': NAGIOS / 'bin/nagios', 'nagios-plugins': NAGIOS / 'libexec/check_ping',
                      'check-ncpa': NAGIOS / 'libexec/check_ncpa.py'}[key].exists()
            status = 'UNKNOWN' if exists else 'NOT INSTALLED'
        else:
            status = 'baseline' if have == wanted else 'DIFFERS'
        rows.append({'component': key, 'label': label, 'installed': have, 'baseline': wanted, 'status': status})
    return rows


class Store:
    """Root-only SQLite state: inventory scans, installed state and the audit chain."""

    def __init__(self, state_dir=None):
        self.dir = Path(state_dir or STATE_DIR)
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.path = self.dir / 'updates.db'
        self.db = sqlite3.connect(str(self.path), timeout=10)
        os.chmod(self.path, 0o600)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.executescript(SCHEMA)

    def close(self):
        self.db.close()

    def audit(self, event, detail, manifest_id=None, txn_id=None):
        row = self.db.execute('SELECT hash FROM audit ORDER BY seq DESC LIMIT 1').fetchone()
        prev = row[0] if row else '0' * 64
        at, who = now(), actor()
        body = json.dumps(detail, sort_keys=True, separators=(',', ':'))
        canonical = json.dumps([prev, at, who, event, txn_id, manifest_id, body], separators=(',', ':'))
        digest = hashlib.sha256(canonical.encode()).hexdigest()
        self.db.execute('INSERT INTO audit (at, actor, event, txn_id, manifest_id, detail_json, prev_hash, hash) '
                        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)', (at, who, event, txn_id, manifest_id, body, prev, digest))

    def verify_audit(self):
        """Return the seq of the first broken row, or None if the chain is intact."""
        prev = '0' * 64
        for seq, at, who, event, txn, mid, body, prev_hash, digest in self.db.execute(
                'SELECT seq, at, actor, event, txn_id, manifest_id, detail_json, prev_hash, hash FROM audit ORDER BY seq'):
            canonical = json.dumps([prev, at, who, event, txn, mid, body], separators=(',', ':'))
            if prev_hash != prev or hashlib.sha256(canonical.encode()).hexdigest() != digest:
                return seq
            prev = digest
        return None

    def record_scan(self, found, rows, manifest):
        scan_id, at, host = now() + '-' + os.urandom(4).hex(), now(), host_id()
        with self.db:
            for key, _ in COMPONENTS:
                self.db.execute('INSERT INTO inventory VALUES (?, ?, ?, ?, 1, ?, ?)',
                                (scan_id, host, key, found[key]['version'], found[key]['sha256'], at))
            if all(r['status'] == 'baseline' for r in rows) and not self.installed_manifest():
                self.db.execute('INSERT INTO installed_state VALUES (?, ?, ?, NULL)', (host, manifest['manifest_id'], at))
                self.audit('installed_state.recorded', {'source': 'installer-baseline'}, manifest['manifest_id'])
            self.audit('inventory.scanned', {'scan_id': scan_id, 'status': {r['component']: r['status'] for r in rows}},
                       manifest['manifest_id'])
        return scan_id

    def installed_manifest(self):
        row = self.db.execute('SELECT manifest_id FROM installed_state WHERE host_id = ?', (host_id(),)).fetchone()
        return row[0] if row else None


def inventory(store, manifest):
    found = scan()
    rows = compare(found, manifest)
    store.record_scan(found, rows, manifest)
    return rows


def catalog_status():
    """Milestone 1 has no catalog: the result is always UNKNOWN, never 'up to date'."""
    if CATALOG_URL is None:
        return 'UNKNOWN (no update catalog is configured yet)'
    return 'UNKNOWN'


def render(rows, manifest, store, update_status):
    width = 64
    profile = os_profile()
    lines = ['=' * width,
             '  PinPoint Update Manager'.ljust(width - 30) + ('host: ' + socket.gethostname())[:30].rjust(30),
             '  %s %s %s' % (profile['os'].capitalize(), profile['version'], profile['arch']),
             '-' * width,
             '  %-18s %-13s %-13s %s' % ('Component', 'Installed', 'Baseline', 'Status')]
    for r in rows:
        lines.append('  %-18s %-13s %-13s %s' % (r['label'], r['installed'] or '-', r['baseline'], r['status']))
    installed = store.installed_manifest()
    lines += ['-' * width,
              '  Baseline manifest: %s%s' % (manifest['manifest_id'], '' if installed else ' (not recorded: versions differ)'),
              '  Update status: ' + update_status,
              '=' * width]
    if any(r['status'] != 'baseline' for r in rows):
        lines.append('  Some components differ from the baseline. Nothing was changed.')
    return '\n'.join(lines)


MENU = """
   1) Reload (check for updates)
   2) Install updates
   3) Choose what to update
   4) Exit
"""


def menu(store, manifest, read=input, write=print):
    rows = inventory(store, manifest)
    status = catalog_status()
    while True:
        write(render(rows, manifest, store, status))
        write(MENU)
        try:
            choice = read('  Enter an option: ').strip()
        except (EOFError, KeyboardInterrupt):
            write('')
            return 0
        if choice == '1':
            rows = inventory(store, manifest)
            status = catalog_status()
            with store.db:
                store.audit('catalog.unavailable', {'reason': 'no catalog configured'}, manifest['manifest_id'])
        elif choice in ('2', '3'):
            write('\n  Installing updates is not available in this version of PinPoint.\n'
                  '  Nothing was changed.\n')
        elif choice == '4':
            return 0
        else:
            write('\n  Please enter 1, 2, 3 or 4.\n')


def main(argv=None):
    parser = argparse.ArgumentParser(prog='pinpoint-update', description='PinPoint Update Manager (read-only).')
    parser.add_argument('command', nargs='?', choices=('menu', 'inventory', 'status', 'audit'),
                        help='menu (default on a terminal), inventory, status, or audit')
    parser.add_argument('--json', action='store_true', help='print one JSON object (inventory, status)')
    parser.add_argument('--verify', action='store_true', help='audit: check the hash chain')
    parser.add_argument('--first-login', action='store_true',
                        help='open the menu once after a fresh install (used by the console login hook)')
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        print('pinpoint-update must be run as root: sudo pinpoint-update', file=sys.stderr)
        return 3
    try:
        manifest = load_manifest()
    except (OSError, ValueError, KeyError) as error:
        print('Baseline manifest is missing or invalid (%s): %s' % (MANIFEST, type(error).__name__), file=sys.stderr)
        return 4
    if args.first_login:
        if not MENU_PENDING.exists():
            return 0
        # Removed before showing, so a dropped session cannot reopen it on every login.
        MENU_PENDING.unlink()
    store = Store()
    try:
        command = 'menu' if args.first_login else args.command or ('menu' if sys.stdin.isatty() else 'status')
        if command == 'menu':
            return menu(store, manifest)
        if command == 'audit':
            broken = store.verify_audit() if args.verify else None
            for row in store.db.execute('SELECT seq, at, actor, event, manifest_id, detail_json FROM audit ORDER BY seq'):
                print('%s %s %s %s %s %s' % row)
            if args.verify:
                print('Audit chain: ' + ('intact' if broken is None else 'BROKEN at row %d' % broken))
            return 0 if broken is None else 1
        rows = inventory(store, manifest)
        if args.json:
            print(json.dumps({'schema': 'pinpoint-update/v1', 'manifest_id': manifest['manifest_id'],
                              'installed_manifest': store.installed_manifest(), 'os': os_profile(),
                              'pinpoint_commit': app_commit(), 'update_status': catalog_status(),
                              'components': rows}, indent=2))
        else:
            print(render(rows, manifest, store, catalog_status()))
        return 0
    finally:
        store.close()


if __name__ == '__main__':
    sys.exit(main())
