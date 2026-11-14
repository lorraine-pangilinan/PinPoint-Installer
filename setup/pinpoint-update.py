#!/usr/bin/python3 -I
"""PinPoint Update Manager: inventory, catalog, approval and notices.

Scan the installed Nagios Core, Nagios Plugins and check_ncpa.py, compare them
with the installed manifest, record the scan in a root-only SQLite database
with a hash-chained audit log, and show the numbered console menu.

Manifests are read from the root-only folder /etc/pinpoint/updates/manifests/.
Manifests are not signed (decision of 28 October 2026). `discover` downloads
new ones from the update catalog: a fixed HTTPS address in the university's
GitHub repository (decision of 14 November 2026). The catalog's index.json
lists every manifest with its SHA-256; a manifest is accepted only if its
bytes match the index, and the whole download is refused if one file does
not. A recorded manifest can never be replaced: a change needs a new ID.

The compatibility gate decides whether a manifest may be installed on this
host, and admins approve, schedule, defer or decline it. An approval is bound
to the manifest digest, this host and the installed state, and is voided as
soon as one of them changes. The installation itself is done by
pinpoint-update-exec, started as pinpoint-update-exec@<txn>.service or by the
run timer when a scheduled window opens.
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
import time

NAGIOS = Path('/usr/local/nagios')
MANIFEST_DIR = Path('/etc/pinpoint/updates/manifests')
MANIFEST = MANIFEST_DIR / 'pp-mon-baseline-1.json'
REVOKED = 'revoked.json'
STATE_DIR = Path('/var/lib/pinpoint/updates')
APP_DIR = Path('/opt/pinpoint/Network-Diagnosis-System')
OS_RELEASE = Path('/etc/os-release')
LOG = Path('/var/log/pinpoint-update.log')
# Each audit row is also copied here, so deleting the database cannot erase history silently.
JOURNAL = ('logger', '-t', 'pinpoint-update', '--')
# Created by configure-monitoring-updates.sh on a fresh install only; the login
# hook opens the menu once while it exists. World-readable folder, unlike STATE_DIR.
MENU_PENDING = Path('/var/lib/pinpoint/update-menu-pending')
# Shown by the console login hook; world-readable, holds no secrets.
LOGIN_NOTICE = Path('/var/lib/pinpoint/update-notice')
UPDATER_CONF = Path('/etc/pinpoint/updates/updater.conf')
CONF_KEYS = ('catalog_url', 'notify_to')
# The update catalog (decision of 14 November 2026): only this host is accepted
# for the catalog, and only the official download sites for the artifacts.
DEFAULT_CATALOG_URL = 'https://raw.githubusercontent.com/lorraine-pangilinan/PinPoint-Installer/main/catalog/'
CATALOG_HOSTS = ('raw.githubusercontent.com',)
ARTIFACT_HOSTS = ('assets.nagios.com', 'nagios-plugins.org', 'github.com', 'objects.githubusercontent.com',
                  'release-assets.githubusercontent.com')
CATALOG_STATE = 'catalog.json'  # in STATE_DIR
INDEX_LIMIT, MANIFEST_LIMIT = 256 << 10, 64 << 10
STALE_DAYS = 7  # <PLACEHOLDER 7 days> in plan section 14
# Recipients until the app export command exists (plan 10.1, source A).
OBJECTS_CACHE = Path('/usr/local/nagios/var/objects.cache')
RECIPIENT_GROUP = 'system_users'
MAIL = '/bin/mail'
MAX_SEND_ATTEMPTS = 10
AUTO_UPGRADES = Path('/etc/apt/apt.conf.d/20auto-upgrades')
EXEC_UNIT = 'pinpoint-update-exec@%s.service'
COMPONENTS = (('nagios-core', 'Nagios Core'), ('nagios-plugins', 'Nagios Plugins'), ('check-ncpa', 'check_ncpa'))
# Build recipes shipped in the updater code; a manifest can only name one (plan 6.1).
BUILD_PROFILES = {'nagios-core': 'core-source-v1', 'nagios-plugins': 'plugins-source-v1',
                  'check-ncpa': 'ncpa-client-v1'}
COMPAT_STATES = ('verified', 'conditional', 'untested', 'incompatible', 'deprecated')
INSTALLABLE = ('verified', 'conditional')
MIGRATION_CLASSES = ('binary-only', 'config-compatible', 'config-migration', 'major')
ADMINS, VIEWERS = 'pinpoint-update-admins', 'pinpoint-update-viewers'
ADMIN_COMMANDS = ('approve', 'defer', 'decline', 'cancel', 'run')
APPROVAL_DAYS = 14  # <PLACEHOLDER 14 days> in plan section 7.1
DEFAULT_DOWNTIME = 15  # minutes, when a manifest does not say
ID_PATTERN = r'[a-z0-9.-]{1,64}'
TXN_PATTERN = r'txn-[0-9]{14}-[0-9a-f]{6}'
RUN_TIMEOUT = 15

OK, INVALID_INPUT, NOT_AUTHORISED, BLOCKED, BUSY, INVALID_TRANSITION = 0, 2, 3, 4, 5, 6
CATALOG_UNAVAILABLE = 7
CODE_NAMES = {OK: 'OK', INVALID_INPUT: 'INVALID_INPUT', NOT_AUTHORISED: 'NOT_AUTHORISED', BLOCKED: 'BLOCKED',
              BUSY: 'BUSY', INVALID_TRANSITION: 'INVALID_TRANSITION', CATALOG_UNAVAILABLE: 'CATALOG_UNAVAILABLE'}
FINISHED = ('succeeded', 'rolled_back', 'failed', 'recovery_failed', 'cancelled', 'missed_window', 'blocked')

ACTIVE = ('approved', 'preparing', 'staging', 'applying', 'health_check', 'rolling_back')
# Plan section 7.1. preparing -> failed is only used by reconcile, for a
# transaction that stopped before anything was touched.
TRANSITIONS = {
    'approved': ('preparing', 'cancelled', 'missed_window'),
    'preparing': ('blocked', 'staging', 'failed'),
    'staging': ('cancelled', 'failed', 'applying'),
    'applying': ('health_check', 'rolling_back'),
    'health_check': ('succeeded', 'rolling_back'),
    'rolling_back': ('rolled_back', 'recovery_failed'),
}
TXN_FIELDS = ('step', 'recovery_point_id', 'failure_code', 'recovery_status', 'started_at', 'finished_at',
              'downtime_seconds')

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
-- Two writers that read the same last row would fork the chain; this refuses the second.
CREATE UNIQUE INDEX IF NOT EXISTS audit_chain ON audit(prev_hash);
CREATE TABLE IF NOT EXISTS txn (
  txn_id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK (kind IN ('update', 'drill')),
  host_id TEXT NOT NULL, source_manifest_id TEXT NOT NULL, target_manifest_id TEXT NOT NULL,
  approval_id TEXT, state TEXT NOT NULL, step TEXT, recovery_point_id TEXT, failure_code TEXT,
  recovery_status TEXT, created_at TEXT NOT NULL, started_at TEXT, finished_at TEXT,
  downtime_seconds INTEGER);
CREATE UNIQUE INDEX IF NOT EXISTS one_active_txn ON txn(host_id)
  WHERE state NOT IN ('succeeded', 'rolled_back', 'failed', 'recovery_failed', 'cancelled',
                      'missed_window', 'blocked');
CREATE TABLE IF NOT EXISTS recovery_point (
  rp_id TEXT PRIMARY KEY, txn_id TEXT NOT NULL, kind TEXT NOT NULL, location TEXT NOT NULL,
  file_manifest_sha256 TEXT NOT NULL, size_bytes INTEGER NOT NULL, created_at TEXT NOT NULL,
  verified_at TEXT, restore_tested TEXT, retain_until TEXT);
CREATE TABLE IF NOT EXISTS manifest (
  manifest_id TEXT PRIMARY KEY, schema_version INTEGER NOT NULL, sha256 TEXT NOT NULL UNIQUE,
  compat_state TEXT NOT NULL CHECK (compat_state IN
                ('verified', 'conditional', 'untested', 'incompatible', 'deprecated')),
  source TEXT NOT NULL CHECK (source IN ('bundled', 'local', 'catalog')),
  body_json TEXT NOT NULL, first_seen_at TEXT NOT NULL, revoked_at TEXT);
CREATE TABLE IF NOT EXISTS approval (
  approval_id TEXT PRIMARY KEY, manifest_id TEXT NOT NULL REFERENCES manifest,
  manifest_sha256 TEXT NOT NULL, host_id TEXT NOT NULL, source_manifest_id TEXT NOT NULL,
  approver TEXT NOT NULL, decision TEXT NOT NULL CHECK (decision IN ('approve', 'defer', 'decline')),
  reason TEXT, window_start TEXT, window_end TEXT, review_date TEXT, created_at TEXT NOT NULL,
  expires_at TEXT,
  status TEXT NOT NULL CHECK (status IN ('active', 'used', 'expired', 'revoked', 'superseded')));
CREATE TABLE IF NOT EXISTS notice (
  notice_id TEXT PRIMARY KEY, kind TEXT NOT NULL, manifest_id TEXT, txn_id TEXT,
  subject TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL,
  sent_at TEXT, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT);
-- One notice per manifest and status change (plan 10.1, deduplication).
CREATE UNIQUE INDEX IF NOT EXISTS notice_once ON notice(kind, IFNULL(manifest_id, ''), IFNULL(txn_id, ''));
"""


class CommandError(Exception):
    """A refused command: an exit code from plan section 8.5 and a message for the admin."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class InvalidTransition(Exception):
    pass


def utc(moment):
    return moment.astimezone(datetime.timezone.utc).replace(microsecond=0).isoformat()


def now():
    return utc(datetime.datetime.now(datetime.timezone.utc))


def later(days=0, minutes=0):
    return utc(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days, minutes=minutes))


def make_id(prefix):
    return '%s-%s-%s' % (prefix, time.strftime('%Y%m%d%H%M%S', time.gmtime()), os.urandom(3).hex())


def actor():
    """The person behind sudo, or root for a direct root login."""
    return os.environ.get('SUDO_USER') or 'root'


def user_groups(user):
    import grp  # Linux only; imported here so the unit tests also run on other systems
    import pwd
    try:
        gids = os.getgrouplist(user, pwd.getpwnam(user).pw_gid)
    except KeyError:
        return set()
    names = set()
    for gid in gids:
        try:
            names.add(grp.getgrgid(gid).gr_name)
        except KeyError:
            pass
    return names


def role():
    """'admin', 'viewer' or None, from the sudo caller's groups (plan 8.3). Direct root is an admin."""
    user = os.environ.get('SUDO_USER')
    if not user or user == 'root':
        return 'admin'
    groups = user_groups(user)
    return 'admin' if ADMINS in groups else 'viewer' if VIEWERS in groups else None


def run(args):
    """Run a fixed command and return its output, or '' if it cannot run."""
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=RUN_TIMEOUT, check=False)
    except (OSError, subprocess.SubprocessError):
        return ''
    return done.stdout + done.stderr


def copy_out(line):
    """Copy an audit row to the log file and the journal. Neither may stop the program."""
    try:
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except OSError:
        pass
    if JOURNAL:
        try:
            subprocess.run([*JOURNAL, line], capture_output=True, timeout=RUN_TIMEOUT, check=False)
        except (OSError, subprocess.SubprocessError):
            pass


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()


##################################################
# Manifests
##################################################

def require(condition, problem):
    if not condition:
        raise ValueError(problem)


def text_field(value, pattern, name):
    require(isinstance(value, str) and re.fullmatch(pattern, value), 'invalid %s' % name)
    return value


def check_manifest(manifest):
    """Raise ValueError naming the first problem. A manifest is data and never names a command."""
    require(isinstance(manifest, dict), 'not a JSON object')
    require(manifest.get('schema_version') == 1, 'unsupported schema_version')
    text_field(manifest.get('manifest_id'), ID_PATTERN, 'manifest_id')
    target = manifest.get('platform')
    require(isinstance(target, dict), 'missing platform')
    for key in ('os', 'version', 'arch'):
        text_field(target.get(key), r'[A-Za-z0-9._-]{1,32}', 'platform.' + key)
    components = manifest.get('components')
    require(isinstance(components, dict) and set(components) == set(BUILD_PROFILES),
            'components must be exactly %s' % ', '.join(sorted(BUILD_PROFILES)))
    for key, profile in BUILD_PROFILES.items():
        part = components[key]
        require(isinstance(part, dict) and isinstance(part.get('artifact'), dict), 'invalid component ' + key)
        text_field(part.get('version'), r'[0-9A-Za-z.+-]{1,32}', key + ' version')
        text_field(part['artifact'].get('url'), r'https://[^\s]{1,500}', key + ' artifact url')
        text_field(part['artifact'].get('sha256'), r'[0-9a-f]{64}', key + ' artifact sha256')
        require(part.get('build_profile') == profile, '%s build_profile must be %s' % (key, profile))
    upgrade_from = manifest.get('upgrade_from')
    require(isinstance(upgrade_from, list), 'upgrade_from must be a list')
    for source in upgrade_from:
        text_field(source, ID_PATTERN, 'upgrade_from entry')
    require(manifest.get('migration_class') in MIGRATION_CLASSES, 'invalid migration_class')
    compat = manifest.get('compatibility')
    require(isinstance(compat, dict) and compat.get('state') in COMPAT_STATES, 'invalid compatibility.state')
    for key in ('evidence_ids', 'known_limitations'):
        values = compat.get(key, [])
        require(isinstance(values, list) and all(isinstance(v, str) for v in values), 'invalid compatibility.' + key)
    downtime = manifest.get('expected_downtime_minutes', DEFAULT_DOWNTIME)
    require(isinstance(downtime, int) and 1 <= downtime <= 240, 'invalid expected_downtime_minutes')
    return manifest


def load_manifest(path=None):
    with open(path or MANIFEST, encoding='utf-8') as f:
        return check_manifest(json.load(f))


def trusted_file(path):
    """Owned by root and writable by nobody else: what makes a manifest trusted while none are signed."""
    st = os.stat(path)
    return st.st_uid == 0 and not st.st_mode & 0o022


def register_manifests(store, catalog_ids=()):
    """Record every manifest in MANIFEST_DIR and apply revoked.json.

    CATALOG_IDS are the manifests discover() just downloaded, recorded with source 'catalog'.

    Returns {file name: problem} for the files that were refused. A manifest
    whose bytes changed after it was recorded is refused: a change needs a new
    manifest_id (plan 6.1).
    """
    problems = {}
    try:
        if not trusted_file(MANIFEST_DIR):
            return {MANIFEST_DIR.name: 'the folder is not root-only; no manifest is trusted'}
        paths = sorted(MANIFEST_DIR.glob('*.json'))
    except OSError as error:
        return {MANIFEST_DIR.name: 'cannot be read (%s)' % type(error).__name__}
    for path in paths:
        if path.name == REVOKED:
            continue
        try:
            require(trusted_file(path), 'not owned by root, or writable by others')
            raw = path.read_bytes()
            body = check_manifest(json.loads(raw))
            require(path.name == body['manifest_id'] + '.json', 'file name does not match manifest_id')
        except (OSError, ValueError) as error:
            problems[path.name] = str(error) or type(error).__name__
            continue
        digest, mid = hashlib.sha256(raw).hexdigest(), body['manifest_id']
        row = store.db.execute('SELECT sha256 FROM manifest WHERE manifest_id = ?', (mid,)).fetchone()
        if row is None:
            with store.db:
                store.db.execute('INSERT INTO manifest (manifest_id, schema_version, sha256, compat_state, source, '
                                 'body_json, first_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
                                 (mid, 1, digest, body['compatibility']['state'],
                                  'bundled' if path.name == MANIFEST.name else
                                  'catalog' if mid in catalog_ids else 'local', raw.decode(), now()))
                store.audit('manifest.registered', {'sha256': digest, 'compat_state': body['compatibility']['state']},
                            mid)
        elif row[0] != digest:
            problems[path.name] = 'changed after it was recorded; a changed manifest needs a new manifest_id'
            detail = {'recorded_sha256': row[0], 'file_sha256': digest}
            if not store.db.execute('SELECT 1 FROM audit WHERE event = ? AND manifest_id = ? AND detail_json = ?',
                                    ('manifest.changed', mid, canonical(detail))).fetchone():
                with store.db:
                    store.audit('manifest.changed', detail, mid)
    problems.update(apply_revocations(store))
    return problems


def apply_revocations(store):
    """revoked.json: {"schema_version": 1, "manifest_ids": [...]}. A revoked manifest becomes deprecated."""
    path = MANIFEST_DIR / REVOKED
    if not path.exists():
        return {}
    try:
        require(trusted_file(path), 'not owned by root, or writable by others')
        body = json.loads(path.read_bytes())
        require(isinstance(body, dict) and body.get('schema_version') == 1, 'unsupported schema_version')
        ids = body.get('manifest_ids')
        require(isinstance(ids, list), 'manifest_ids must be a list')
        for mid in ids:
            text_field(mid, ID_PATTERN, 'manifest id')
    except (OSError, ValueError) as error:
        return {REVOKED: str(error) or type(error).__name__}
    revoke(store, ids, 'revoked.json')
    return {}


def revoke(store, ids, source):
    """Mark recorded manifests deprecated. A revocation is never undone."""
    for mid in ids:
        with store.db:
            if store.db.execute("UPDATE manifest SET compat_state = 'deprecated', revoked_at = ? "
                                'WHERE manifest_id = ? AND revoked_at IS NULL', (now(), mid)).rowcount:
                store.audit('manifest.revoked', {'source': source}, mid)


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


def canonical(detail):
    return json.dumps(detail, sort_keys=True, separators=(',', ':'))


class Store:
    """Root-only SQLite state: inventory, manifests, approvals, transactions and the audit chain."""

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

    def audit(self, event, detail, manifest_id=None, txn_id=None, who=None):
        row = self.db.execute('SELECT hash FROM audit ORDER BY seq DESC LIMIT 1').fetchone()
        prev = row[0] if row else '0' * 64
        at, who = now(), who or actor()
        body = canonical(detail)
        chained = json.dumps([prev, at, who, event, txn_id, manifest_id, body], separators=(',', ':'))
        digest = hashlib.sha256(chained.encode()).hexdigest()
        self.db.execute('INSERT INTO audit (at, actor, event, txn_id, manifest_id, detail_json, prev_hash, hash) '
                        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)', (at, who, event, txn_id, manifest_id, body, prev, digest))
        copy_out('%s %s %s txn=%s manifest=%s %s hash=%s'
                 % (at, who, event, txn_id or '-', manifest_id or '-', body, digest))

    def verify_audit(self):
        """Return the seq of the first broken or missing row, or None if the chain is intact.

        Rows are numbered without gaps, so removing the newest rows is found as
        soon as another row is written; until then the log and journal copies
        are the record.
        """
        prev, expected = '0' * 64, 1
        for seq, at, who, event, txn, mid, body, prev_hash, digest in self.db.execute(
                'SELECT seq, at, actor, event, txn_id, manifest_id, detail_json, prev_hash, hash FROM audit ORDER BY seq'):
            chained = json.dumps([prev, at, who, event, txn, mid, body], separators=(',', ':'))
            if seq != expected or prev_hash != prev or hashlib.sha256(chained.encode()).hexdigest() != digest:
                return min(seq, expected)
            prev, expected = digest, seq + 1
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

    def manifest(self, manifest_id):
        """The recorded manifest as a dict with its parsed body, or None."""
        self.db.row_factory = sqlite3.Row
        try:
            row = self.db.execute('SELECT * FROM manifest WHERE manifest_id = ?', (manifest_id,)).fetchone()
        finally:
            self.db.row_factory = None
        if row is None:
            return None
        found = dict(row)
        found['body'] = json.loads(found.pop('body_json'))
        return found

    def rows(self, sql, args=()):
        """Query results as a list of dicts."""
        self.db.row_factory = sqlite3.Row
        try:
            return [dict(row) for row in self.db.execute(sql, args)]
        finally:
            self.db.row_factory = None


def active_txn(store):
    marks = ','.join('?' * len(ACTIVE))
    return store.db.execute('SELECT txn_id, state, step, recovery_point_id FROM txn WHERE host_id = ? '
                            'AND state IN (%s)' % marks, (host_id(), *ACTIVE)).fetchone()


def transition(store, txn_id, to, who='executor', **fields):
    """The only way a transaction changes state: checked against plan 7.1, audited in the same commit."""
    unknown = set(fields) - set(TXN_FIELDS)
    if unknown:
        raise ValueError('unknown txn fields: %s' % ', '.join(sorted(unknown)))
    with store.db:
        row = store.db.execute('SELECT state FROM txn WHERE txn_id = ?', (txn_id,)).fetchone()
        if row is None or to not in TRANSITIONS.get(row[0], ()):
            raise InvalidTransition('%s: %s -> %s' % (txn_id, row[0] if row else 'missing', to))
        if to not in ACTIVE:
            fields.setdefault('finished_at', now())
        values = {'state': to, **fields}
        store.db.execute('UPDATE txn SET %s WHERE txn_id = ?' % ', '.join('%s = ?' % k for k in values),
                         (*values.values(), txn_id))
        store.audit('txn.' + to, {'from': row[0], **fields}, txn_id=txn_id, who=who)


def inventory(store, manifest):
    found = scan()
    rows = compare(found, reference(store, manifest))
    store.record_scan(found, rows, manifest)
    return rows


##################################################
# Compatibility gate and approvals
##################################################

def gate(store, manifest_id, found):
    """Reasons this host may not install MANIFEST_ID now; an empty list means it may (plan 6.1, 10.2)."""
    record = store.manifest(manifest_id)
    if record is None:
        return ['%s is not a recorded manifest.' % manifest_id]
    body, reasons = record['body'], []
    if record['revoked_at']:
        reasons.append('%s was revoked on %s.' % (manifest_id, record['revoked_at']))
    elif record['compat_state'] not in INSTALLABLE:
        reasons.append('Compatibility is %s; only verified or conditional update sets can be installed.'
                       % record['compat_state'])
    if body['migration_class'] == 'major':
        reasons.append('A major change cannot be installed through the Update Manager.')
    here = os_profile()
    wanted = {key: body['platform'][key] for key in ('os', 'version', 'arch')}
    if wanted != here:
        reasons.append('Built for %(os)s %(version)s %(arch)s; ' % wanted
                       + 'this host is %(os)s %(version)s %(arch)s.' % here)
    installed = store.installed_manifest()
    if installed is None:
        reasons.append('The installed state is not recorded: the installed versions match no known manifest.')
    elif installed == manifest_id:
        reasons.append('%s is already installed.' % manifest_id)
    elif installed not in body['upgrade_from']:
        reasons.append('%s cannot be installed over %s (it upgrades from: %s).'
                       % (manifest_id, installed, ', '.join(body['upgrade_from']) or 'nothing'))
    else:
        current = store.manifest(installed)
        if current is None:
            reasons.append('The installed manifest %s is not recorded.' % installed)
        else:
            drift = [r['label'] for r in compare(found, current['body']) if r['status'] != 'baseline']
            if drift:
                reasons.append('Nagios was changed outside the Update Manager (%s differs from %s). '
                               'Investigate before approving.' % (', '.join(drift), installed))
    return reasons


def decisions(store, manifest_id=None, decision=None, status='active'):
    sql, args = 'SELECT * FROM approval WHERE host_id = ? AND status = ?', [host_id(), status]
    if manifest_id:
        sql, args = sql + ' AND manifest_id = ?', args + [manifest_id]
    if decision:
        sql, args = sql + ' AND decision = ?', args + [decision]
    return store.rows(sql + ' ORDER BY created_at, rowid', args)


def approval_txn(store, approval_id):
    """(txn_id, state) of the transaction an approval created, or (None, None)."""
    row = store.db.execute('SELECT txn_id, state FROM txn WHERE approval_id = ?', (approval_id,)).fetchone()
    return row or (None, None)


def approved_txn(store, approval_id):
    txn_id, state = approval_txn(store, approval_id)
    return txn_id if state == 'approved' else None


def end_approval(store, approval, status, why, txn_state='cancelled', who=None):
    """Void an approval and stop its transaction if it has not started."""
    txn_id = approved_txn(store, approval['approval_id'])
    if txn_id:
        transition(store, txn_id, txn_state, who or actor(), failure_code='APPROVAL_' + status.upper(),
                   recovery_status=why[:500])
    with store.db:
        store.db.execute('UPDATE approval SET status = ? WHERE approval_id = ?', (status, approval['approval_id']))
        store.audit('approval.' + status, {'approval_id': approval['approval_id'], 'reason': why,
                                           **({} if who else root_warning())},
                    approval['manifest_id'], txn_id, who)


def invalidate(store, found):
    """Void approvals that no longer hold (plan 7.1), and end deferrals whose review date has come."""
    stamp, today, installed = now(), datetime.date.today().isoformat(), store.installed_manifest()
    # Every host's approvals, so one made before the machine ID changed is voided too.
    for approval in store.rows("SELECT * FROM approval WHERE status = 'active' AND decision = 'approve'"):
        if approval_txn(store, approval['approval_id'])[1] in ACTIVE[1:]:
            continue  # already running: the executor re-checks it and owns the outcome
        why, status, txn_state = None, 'expired', 'cancelled'
        if approval['host_id'] != host_id():
            why = 'approved on another host (%s)' % approval['host_id']
        elif approval['window_end'] and approval['window_end'] <= stamp:
            why, txn_state = 'the maintenance window passed', 'missed_window'
        elif approval['expires_at'] <= stamp:
            why = 'the approval expired'
        elif installed != approval['source_manifest_id']:
            why = 'the installed state changed from %s' % approval['source_manifest_id']
        else:
            record = store.manifest(approval['manifest_id'])
            reasons = gate(store, approval['manifest_id'], found)
            if record and record['sha256'] != approval['manifest_sha256']:
                reasons.insert(0, 'the manifest digest changed')
            if reasons:
                why, status = reasons[0], 'revoked'
        if why:
            end_approval(store, approval, status, why, txn_state, who='system')
    for deferral in decisions(store, decision='defer'):
        if deferral['review_date'] <= today:
            with store.db:
                store.db.execute("UPDATE approval SET status = 'expired' WHERE approval_id = ?",
                                 (deferral['approval_id'],))
                store.audit('approval.review_due', {'approval_id': deferral['approval_id']},
                            deferral['manifest_id'], who='system')


def refresh(store, manifest):
    """Record manifests and a fresh inventory, then void what no longer holds. Returns refused files."""
    problems = register_manifests(store)
    found = scan()
    store.record_scan(found, compare(found, reference(store, manifest)), manifest)
    invalidate(store, found)
    write_login_notice(store, found)
    return found, problems


def approve(store, manifest_id, found, at=None, window_minutes=None, accept_limitations=False):
    """Approve MANIFEST_ID for this host and create its transaction (AwaitingApproval -> Approved)."""
    existing = decisions(store, manifest_id, 'approve')
    if existing:
        return existing[0], approval_txn(store, existing[0]['approval_id'])[0], False
    reasons = gate(store, manifest_id, found)
    if reasons:
        raise CommandError(BLOCKED, ' '.join(reasons))
    record = store.manifest(manifest_id)
    body = record['body']
    limitations = body['compatibility'].get('known_limitations', [])
    if record['compat_state'] == 'conditional' and not accept_limitations:
        raise CommandError(INVALID_INPUT, '%s is conditional. Known limitations: %s Add --accept-limitations '
                           'to approve it anyway.' % (manifest_id, ' '.join(limitations) or 'none listed.'))
    expires = later(days=APPROVAL_DAYS)
    window_start = window_end = None
    if at:
        downtime = body.get('expected_downtime_minutes', DEFAULT_DOWNTIME)
        minutes = window_minutes or max(60, 2 * downtime)
        if minutes < 2 * downtime:
            raise CommandError(INVALID_INPUT, 'The window must allow the update and a rollback: at least %d minutes.'
                               % (2 * downtime))
        start = datetime.datetime.fromisoformat(at)
        window_start, window_end = at, utc(start + datetime.timedelta(minutes=minutes))
        if window_start <= now():
            raise CommandError(INVALID_INPUT, 'The window must start in the future.')
        if window_end > expires:
            raise CommandError(INVALID_INPUT, 'The window must end before the approval expires (%s).' % expires)
    elif window_minutes:
        raise CommandError(INVALID_INPUT, '--window-minutes needs --at.')
    others = decisions(store, decision='approve')
    busy = active_txn(store)
    if busy and busy[0] not in [approved_txn(store, other['approval_id']) for other in others]:
        raise CommandError(BUSY, 'Transaction %s is %s; nothing was approved.' % (busy[0], busy[1]))
    for other in others:
        end_approval(store, other, 'superseded', 'superseded by an approval of %s' % manifest_id)
    approval_id, txn_id, stamp = make_id('apr'), make_id('txn'), now()
    source = store.installed_manifest()
    approval = {'approval_id': approval_id, 'manifest_id': manifest_id, 'manifest_sha256': record['sha256'],
                'host_id': host_id(), 'source_manifest_id': source, 'approver': actor(), 'decision': 'approve',
                'reason': None, 'window_start': window_start, 'window_end': window_end, 'review_date': None,
                'created_at': stamp, 'expires_at': expires, 'status': 'active'}
    try:
        with store.db:
            store.db.execute('INSERT INTO approval (%s) VALUES (%s)' % (', '.join(approval), ', '.join('?' * len(approval))),
                             tuple(approval.values()))
            store.db.execute('INSERT INTO txn (txn_id, kind, host_id, source_manifest_id, target_manifest_id, '
                             'approval_id, state, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                             (txn_id, 'update', host_id(), source, manifest_id, approval_id, 'approved', stamp))
            store.audit('approval.created', {'approval_id': approval_id, 'manifest_sha256': record['sha256'],
                                             'source_manifest_id': source, 'window_start': window_start,
                                             'window_end': window_end, 'expires_at': expires,
                                             'conditional': record['compat_state'] == 'conditional',
                                             **root_warning()}, manifest_id, txn_id)
    except sqlite3.IntegrityError:
        raise CommandError(BUSY, 'Another transaction started at the same time; nothing was approved.')
    return approval, txn_id, True


def refuse(store, manifest_id, decision, reason, review_date=None):
    """Record a deferral or a decline. Monitoring keeps running on the installed version (plan 8.2)."""
    if store.manifest(manifest_id) is None:
        raise CommandError(INVALID_INPUT, '%s is not a recorded manifest.' % manifest_id)
    approved = decisions(store, manifest_id, 'approve')
    if approved:
        raise CommandError(INVALID_TRANSITION, '%s is approved (transaction %s). Cancel it first.'
                           % (manifest_id, approval_txn(store, approved[0]['approval_id'])[0]))
    for earlier in decisions(store, manifest_id):
        if (earlier['decision'], earlier['reason'], earlier['review_date']) == (decision, reason, review_date):
            return earlier, False
    approval_id, stamp = make_id('apr'), now()
    approval = {'approval_id': approval_id, 'manifest_id': manifest_id,
                'manifest_sha256': store.manifest(manifest_id)['sha256'], 'host_id': host_id(),
                'source_manifest_id': store.installed_manifest() or '-', 'approver': actor(), 'decision': decision,
                'reason': reason, 'review_date': review_date, 'created_at': stamp, 'status': 'active'}
    with store.db:
        for earlier in decisions(store, manifest_id):
            store.db.execute("UPDATE approval SET status = 'superseded' WHERE approval_id = ?",
                             (earlier['approval_id'],))
        store.db.execute('INSERT INTO approval (%s) VALUES (%s)' % (', '.join(approval), ', '.join('?' * len(approval))),
                         tuple(approval.values()))
        store.audit({'defer': 'approval.deferred', 'decline': 'approval.declined'}[decision],
                    {'approval_id': approval_id, 'reason': reason, 'review_date': review_date, **root_warning()},
                    manifest_id)
    return approval, True


def cancel(store, txn_id):
    """Approved or Staging -> Cancelled. Applying and later cannot be cancelled (plan 7.1)."""
    row = store.db.execute('SELECT kind, state, approval_id, target_manifest_id FROM txn WHERE txn_id = ? '
                           'AND host_id = ?', (txn_id, host_id())).fetchone()
    if row is None or row[0] != 'update':
        raise CommandError(INVALID_INPUT, 'No update transaction %s on this host.' % txn_id)
    kind, state, approval_id, manifest_id = row
    if state == 'cancelled':
        return False
    if state not in ('approved', 'staging'):
        raise CommandError(INVALID_TRANSITION, 'Transaction %s is %s and can no longer be cancelled.' % (txn_id, state))
    why = 'cancelled by %s' % actor()
    if state == 'staging':
        transition(store, txn_id, 'cancelled', actor(), failure_code='CANCELLED', recovery_status=why)
    approval = store.rows("SELECT * FROM approval WHERE approval_id = ? AND status = 'active'", (approval_id,))
    if approval:
        end_approval(store, approval[0], 'revoked', why)  # also cancels the transaction while it is approved
    return True


def root_warning():
    """A direct root login is allowed for emergencies and recorded with a warning (plan 8.3)."""
    return {} if os.environ.get('SUDO_USER') else {'warning': 'direct root login, no SUDO_USER'}


def manifest_summary(store, record, found):
    body = record['body']
    latest = store.rows('SELECT decision, status, reason, review_date, approver, created_at FROM approval '
                        'WHERE manifest_id = ? AND host_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 1',
                        (record['manifest_id'], host_id()))
    reasons = gate(store, record['manifest_id'], found)
    return {'manifest_id': record['manifest_id'], 'sha256': record['sha256'], 'source': record['source'],
            'compat_state': record['compat_state'], 'revoked_at': record['revoked_at'],
            'versions': {key: body['components'][key]['version'] for key, _ in COMPONENTS},
            'upgrade_from': body['upgrade_from'], 'migration_class': body['migration_class'],
            'installable': not reasons, 'blocked_by': reasons, 'latest_decision': latest[0] if latest else None}


def set_installed(store, manifest_id, txn_id):
    """Commit step of an update (plan 10.2, step 15): the host now runs MANIFEST_ID."""
    with store.db:
        store.db.execute('UPDATE installed_state SET manifest_id = ?, since = ?, last_txn_id = ? WHERE host_id = ?',
                         (manifest_id, now(), txn_id, host_id()))
        store.audit('installed_state.changed', {'source': 'update'}, manifest_id, txn_id, who='executor')


def reference(store, manifest):
    """What the installed components should match: the installed manifest, or the baseline before one is recorded."""
    installed = store.installed_manifest()
    record = store.manifest(installed) if installed else None
    return record['body'] if record else manifest


##################################################
# Update catalog (plan 10.1; trust decision of 14 November 2026)
##################################################

class CatalogError(Exception):
    pass


def read_conf():
    """updater.conf: 'key = value' lines. Read only when root owns it and nobody else can write it."""
    if not UPDATER_CONF.exists():
        return {}
    if not trusted_file(UPDATER_CONF):
        raise CatalogError('%s is not owned by root, or is writable by others' % UPDATER_CONF)
    conf = {}
    for line in UPDATER_CONF.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        key = key.strip()
        if not sep or key not in CONF_KEYS:
            raise CatalogError('%s: unknown line "%s"' % (UPDATER_CONF.name, line[:60]))
        conf[key] = value.strip()
    return conf


def check_url(url, hosts):
    """HTTPS to one of HOSTS, default port, no user name or password in the address."""
    from urllib.parse import urlsplit
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        raise CatalogError('not a valid address: %s' % url[:200])
    if (parts.scheme != 'https' or parts.hostname not in hosts or port not in (None, 443)
            or parts.username or parts.password or any(c.isspace() for c in url)):
        raise CatalogError('not an allowed HTTPS address: %s' % url[:200])
    return url


def redirect_handler(hosts):
    """A redirect is followed only to an allowed HTTPS address."""
    import urllib.request

    class Redirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            check_url(newurl, hosts)
            return super().redirect_request(req, fp, code, msg, headers, newurl)
    return Redirect()


def http_get(url, limit, timeout, hosts):
    """Download at most LIMIT bytes over HTTPS. Certificates are checked; a redirect must stay on HOSTS."""
    import http.client
    import urllib.error
    import urllib.request

    check_url(url, hosts)
    opener = urllib.request.build_opener(redirect_handler(hosts))
    request = urllib.request.Request(url, headers={'User-Agent': 'pinpoint-update'})
    try:
        with opener.open(request, timeout=timeout) as response:
            data = response.read(limit + 1)
    except CatalogError:
        raise
    except urllib.error.HTTPError as error:
        raise CatalogError('%s returned HTTP %d' % (url[:200], error.code))
    except (OSError, ValueError, http.client.HTTPException) as error:
        reason = getattr(error, 'reason', None) or error
        raise CatalogError('cannot download %s (%s)' % (url[:200], str(reason)[:120] or type(error).__name__))
    if len(data) > limit:
        raise CatalogError('%s is larger than %d bytes' % (url[:200], limit))
    return data


def catalog_base(conf):
    url = conf.get('catalog_url') or DEFAULT_CATALOG_URL
    if not url.endswith('/'):
        raise CatalogError('catalog_url must end with "/"')
    return check_url(url, CATALOG_HOSTS)


def check_index(index):
    """index.json: {"schema_version": 1, "manifests": [{"manifest_id", "sha256"}], "revoked": [ids]}."""
    require(isinstance(index, dict) and index.get('schema_version') == 1, 'index.json: unsupported schema_version')
    listed = index.get('manifests')
    require(isinstance(listed, list) and len(listed) <= 500, 'index.json: manifests must be a list')
    entries = []
    for entry in listed:
        require(isinstance(entry, dict), 'index.json: invalid entry')
        entries.append((text_field(entry.get('manifest_id'), ID_PATTERN, 'index manifest_id'),
                        text_field(entry.get('sha256'), r'[0-9a-f]{64}', 'index sha256')))
    require(len({mid for mid, _ in entries}) == len(entries), 'index.json: a manifest is listed twice')
    revoked = index.get('revoked', [])
    require(isinstance(revoked, list), 'index.json: revoked must be a list')
    for mid in revoked:
        text_field(mid, ID_PATTERN, 'revoked manifest id')
    return entries, revoked


def catalog_state():
    try:
        return json.loads((Path(STATE_DIR) / CATALOG_STATE).read_text())
    except (OSError, ValueError):
        return {}


def save_catalog_state(state):
    path = Path(STATE_DIR) / CATALOG_STATE
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(state, indent=2, sort_keys=True))
    os.replace(str(temp), str(path))


def write_manifest_file(mid, raw):
    path = MANIFEST_DIR / (mid + '.json')
    temp = MANIFEST_DIR / ('.%s.json.tmp' % mid)
    temp.write_bytes(raw)
    os.chmod(temp, 0o644)
    os.replace(str(temp), str(path))


def discover(store, fetch=None, timeout=30):
    """Fetch the catalog and record new manifests. All or nothing: no partial catalog is trusted (plan 12.1).

    Returns (ok, reason, new manifest IDs). Nothing in Nagios is changed.
    """
    fetch = fetch or http_get
    state, new = catalog_state(), {}
    try:
        base = catalog_base(read_conf())
        entries, revoked = check_index(json.loads(fetch(base + 'index.json', INDEX_LIMIT, timeout, CATALOG_HOSTS)))
        for mid, digest in entries:
            row = store.db.execute('SELECT sha256 FROM manifest WHERE manifest_id = ?', (mid,)).fetchone()
            if row:
                if row[0] != digest:
                    raise CatalogError('the catalog lists %s with a different digest than the one recorded here; '
                                       'a changed manifest needs a new ID' % mid)
                continue
            path = MANIFEST_DIR / (mid + '.json')
            if path.exists() and sha256_file(path) == digest:
                continue
            raw = fetch(base + 'manifests/%s.json' % mid, MANIFEST_LIMIT, timeout, CATALOG_HOSTS)
            if hashlib.sha256(raw).hexdigest() != digest:
                raise CatalogError('%s does not match the SHA-256 in the catalog index' % mid)
            body = check_manifest(json.loads(raw))
            require(body['manifest_id'] == mid, '%s: manifest_id inside the file is %s' % (mid, body['manifest_id']))
            new[mid] = raw
        for mid, raw in new.items():
            write_manifest_file(mid, raw)
        revoke(store, [mid for mid in revoked if store.manifest(mid)], 'catalog')
        problems = register_manifests(store, set(new))
    except (CatalogError, ValueError, OSError, KeyError, TypeError) as error:
        reason = (str(error) or type(error).__name__)[:300]
        state.update(checked_at=now(), ok=False, error=reason)
        save_catalog_state(state)
        with store.db:
            store.audit('catalog.failed', {'reason': reason})
        return False, reason, []
    stamp = now()
    state.update(checked_at=stamp, ok=True, error=None, last_good=stamp, url=base)
    save_catalog_state(state)
    with store.db:
        store.audit('catalog.checked', {'url': base, 'listed': len(entries), 'new': sorted(new),
                                        'revoked': revoked, 'refused_files': problems})
    return True, '', sorted(new)


def offers(store, found):
    """Recorded manifests this host may install now, newest first (plan 8.1, option 2)."""
    items = []
    for (mid,) in store.db.execute('SELECT manifest_id FROM manifest WHERE revoked_at IS NULL'):
        if not gate(store, mid, found):
            items.append(store.manifest(mid))
    return sorted(items, key=lambda r: (r['body'].get('published_at', ''), r['manifest_id']), reverse=True)


def age_days(stamp):
    try:
        moment = datetime.datetime.fromisoformat(stamp)
    except (TypeError, ValueError):
        return None
    return (datetime.datetime.now(datetime.timezone.utc) - moment).total_seconds() / 86400


def catalog_status(store, found):
    """One line for the menu, the banner and --json. Never 'up to date' without a good, recent check."""
    state = catalog_state()
    available = [r['manifest_id'] for r in offers(store, found)]
    if not state.get('checked_at'):
        line = 'UNKNOWN (the catalog has not been checked yet; choose 1 to reload)'
    elif not state.get('ok'):
        line = 'UNKNOWN (last check failed: %s; last good check: %s)' % (state.get('error'),
                                                                       state.get('last_good') or 'never')
    elif (age_days(state.get('last_good')) or 0) > STALE_DAYS:
        line = 'UNKNOWN (last good check %s is more than %d days old)' % (state['last_good'], STALE_DAYS)
    elif not available:
        return 'Up to date (catalog checked %s)' % state['last_good']
    else:
        return 'Update available: %s' % ', '.join(available)
    return line + ('; known update: %s' % ', '.join(available) if available else '')


def auto_security_updates():
    """'on', 'off' or 'unknown': whether Ubuntu installs its own security updates daily."""
    try:
        text = AUTO_UPGRADES.read_text()
    except OSError:
        return 'off'
    values = dict(re.findall(r'APT::Periodic::([A-Za-z-]+)\s+"(\d+)"', text))
    return 'on' if values.get('Update-Package-Lists') == '1' and values.get('Unattended-Upgrade') == '1' else 'off'


##################################################
# Notices (plan 10.1 and 14)
##################################################

EMAIL_PATTERN = r'[A-Za-z0-9._%+][A-Za-z0-9._%+-]{0,63}@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}'
PLACEHOLDER_DOMAINS = ('example.com', 'example.org', 'example.net', 'localhost', 'invalid', 'test')


def nagios_objects(path=None):
    """Parse objects.cache into a list of (type, {directive: value}). Nagios writes it on every start."""
    objects, current = [], None
    for line in Path(path or OBJECTS_CACHE).read_text(encoding='utf-8', errors='replace').splitlines():
        line = line.strip()
        match = re.match(r'define\s+(\w+)\s*\{', line)
        if match:
            current = (match[1], {})
        elif line == '}' and current:
            objects.append(current)
            current = None
        elif current and line:
            key, _, value = line.partition('\t') if '\t' in line else line.partition(' ')
            current[1][key.strip()] = value.strip()
    return objects


def recipients(conf):
    """Real admin addresses: the updater.conf override, else the Nagios system_users contacts (source A)."""
    if conf.get('notify_to'):
        candidates = [a.strip() for a in conf['notify_to'].split(',')]
    else:
        try:
            objects = nagios_objects()
        except OSError:
            return []
        members = set()
        for kind, fields in objects:
            if kind == 'contactgroup' and fields.get('contactgroup_name') == RECIPIENT_GROUP:
                members.update(m.strip() for m in fields.get('members', '').split(',') if m.strip())
        candidates = [fields.get('email', '') for kind, fields in objects
                      if kind == 'contact' and fields.get('contact_name') in members]
    good = set()
    for address in candidates:
        domain = address.rpartition('@')[2].lower()
        if re.fullmatch(EMAIL_PATTERN, address) and not any(domain == d or domain.endswith('.' + d)
                                                           for d in PLACEHOLDER_DOMAINS):
            good.add(address)
    return sorted(good)


def send_mail(to, subject, body):
    """Send through /bin/mail and msmtp, the transport the Nagios alerts use. Returns (ok, error)."""
    try:
        done = subprocess.run([MAIL, '-s', subject, *to], input=body, capture_output=True, text=True,
                              timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        return False, type(error).__name__
    return done.returncode == 0, (done.stderr or done.stdout).strip()[:300] or None


def queue_notice(store, kind, subject, body, manifest_id=None, txn_id=None):
    """Store a notice once per kind, manifest and transaction. Returns True if it is new."""
    with store.db:
        added = store.db.execute('INSERT OR IGNORE INTO notice (notice_id, kind, manifest_id, txn_id, subject, body, '
                                 'created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
                                 (make_id('ntc'), kind, manifest_id, txn_id, subject[:200], body, now())).rowcount
        if added:
            store.audit('notice.queued', {'kind': kind}, manifest_id, txn_id, who='system')
    return bool(added)


def send_notices(store, sender=None):
    """Send what is pending. Without a real address the notice stays pending and the banner shows it."""
    pending = store.rows('SELECT * FROM notice WHERE sent_at IS NULL AND attempts < ? ORDER BY created_at, rowid',
                         (MAX_SEND_ATTEMPTS,))
    if not pending:
        return 0
    try:
        to = recipients(read_conf())
    except (CatalogError, OSError):
        to = []
    if not to:
        return 0
    sent = 0
    for notice in pending:
        ok, error = (sender or send_mail)(to, notice['subject'], notice['body'])
        with store.db:
            store.db.execute('UPDATE notice SET attempts = attempts + 1, sent_at = ?, last_error = ? '
                             'WHERE notice_id = ?', (now() if ok else None, error if not ok else None,
                                                     notice['notice_id']))
            store.audit('notice.sent' if ok else 'notice.failed',
                        {'kind': notice['kind'], 'recipients': len(to), **({} if ok else {'error': error})},
                        notice['manifest_id'], notice['txn_id'], who='system')
        sent += ok
    return sent


def subject(text):
    return '[PinPoint %s] %s' % (socket.gethostname(), text)


def versions_line(body):
    return ', '.join('%s %s' % (label, body['components'][key]['version']) for key, label in COMPONENTS)


def notice_available(store, record):
    """Verified (or conditional) update available, plan 14. Not sent again for a deferred or declined set."""
    body, installed = record['body'], store.manifest(store.installed_manifest() or '')
    if decisions(store, record['manifest_id'], 'defer') or decisions(store, record['manifest_id'], 'decline'):
        return False
    compat = body['compatibility']
    text = '\n'.join([
        'Installed:  %s' % (versions_line(installed['body']) if installed else 'not recorded'),
        'Proposed:   %s' % versions_line(body),
        'Status:     %s on %s %s %s%s' % (record['compat_state'].upper(), body['platform']['os'],
                                          body['platform']['version'], body['platform']['arch'],
                                          ' (evidence %s)' % ', '.join(compat['evidence_ids'])
                                          if compat.get('evidence_ids') else ''),
        'Security:   %s' % (', '.join(body.get('security', {}).get('advisories', [])) or 'none listed'),
        'Downtime:   about %d minutes (Nagios and PinPoint web stopped)'
        % body.get('expected_downtime_minutes', DEFAULT_DOWNTIME),
        'Recovery:   automatic rollback; recovery point verified before changes',
        *(['Limit:      ' + item for item in compat.get('known_limitations', [])]),
        *(['Notes:      ' + body['release_notes_url']] if body.get('release_notes_url') else []),
        '',
        'To review: sudo pinpoint-update   (option 2)',
        'Nothing will be installed until an administrator approves it.'])
    kind = 'Verified' if record['compat_state'] == 'verified' else 'Conditional'
    return queue_notice(store, 'available', subject('%s Nagios update available: %s' % (kind, record['manifest_id'])),
                        text + '\n', record['manifest_id'])


def notice_result(store, txn_id):
    """Successful, failed and rolled back, or recovery failed (CRITICAL), plan 14."""
    rows = store.rows('SELECT * FROM txn WHERE txn_id = ?', (txn_id,))
    if not rows or rows[0]['state'] not in ('succeeded', 'rolled_back', 'recovery_failed', 'failed', 'blocked'):
        return False
    t = rows[0]
    title = {'succeeded': 'Nagios update installed: %s',
             'rolled_back': 'Nagios update failed and was rolled back: %s',
             'recovery_failed': 'CRITICAL: Nagios update failed and recovery failed: %s',
             'failed': 'Nagios update stopped before any change: %s',
             'blocked': 'Nagios update blocked by its checks: %s'}[t['state']] % t['target_manifest_id']
    lines = ['Transaction: %s' % txn_id,
             'From:        %s' % t['source_manifest_id'],
             'To:          %s' % t['target_manifest_id'],
             'Result:      %s' % t['state'],
             'Reason:      %s' % (t['failure_code'] or '-'),
             'Detail:      %s' % (t['recovery_status'] or '-'),
             'Downtime:    %s' % ('%d s' % t['downtime_seconds'] if t['downtime_seconds'] is not None else '-')]
    if t['state'] == 'recovery_failed':
        lines += ['', 'Nothing more is done automatically. Monitoring may be down.',
                  'Follow "When recovery fails" in the update runbook (docs/Update-Runbook.md).']
    lines += ['', 'Details: sudo pinpoint-update history']
    return queue_notice(store, t['state'], subject(title), '\n'.join(lines) + '\n', t['target_manifest_id'], txn_id)


def write_login_notice(store, found):
    """The few lines the console login hook prints. Removed when there is nothing to say."""
    lines = []
    failed = store.rows("SELECT txn_id, target_manifest_id FROM txn WHERE host_id = ? AND kind = 'update' "
                        'ORDER BY created_at DESC, rowid DESC LIMIT 1', (host_id(),))
    last = store.rows('SELECT state FROM txn WHERE txn_id = ?', (failed[0]['txn_id'],)) if failed else []
    if last and last[0]['state'] == 'recovery_failed':
        lines.append('CRITICAL: Nagios update %s failed and recovery failed. See docs/Update-Runbook.md.'
                     % failed[0]['txn_id'])
    running = active_txn(store)
    if running:
        approval = store.rows('SELECT a.window_start FROM txn t JOIN approval a ON a.approval_id = t.approval_id '
                              'WHERE t.txn_id = ?', (running[0],))
        if running[1] == 'approved' and approval and approval[0]['window_start']:
            lines.append('Nagios update %s is scheduled for %s (UTC).' % (running[0], approval[0]['window_start']))
        elif running[1] != 'approved':
            lines.append('Nagios update %s is in progress (%s).' % (running[0], running[1]))
    status = catalog_status(store, found)
    if status.startswith('Update available'):
        lines.append('%s. Review it with: sudo pinpoint-update' % status)
    elif status.startswith('UNKNOWN') and catalog_state().get('checked_at'):
        lines.append('Update status ' + status)
    try:
        if lines:
            LOGIN_NOTICE.parent.mkdir(parents=True, exist_ok=True)
            temp = LOGIN_NOTICE.with_name(LOGIN_NOTICE.name + '.tmp')
            temp.write_text('PinPoint Update Manager:\n' + ''.join('  %s\n' % line for line in lines))
            os.chmod(temp, 0o644)
            os.replace(str(temp), str(LOGIN_NOTICE))
        elif LOGIN_NOTICE.exists():
            LOGIN_NOTICE.unlink()
    except OSError:
        pass
    return lines


def start_run(store, txn_id):
    """Run an approved transaction in its own unit, so closing the session does not stop it (plan 8.1)."""
    done = subprocess.run(['systemctl', 'start', '--no-block', EXEC_UNIT % txn_id], capture_output=True, text=True,
                          timeout=60, check=False)
    if done.returncode != 0:
        raise CommandError(BLOCKED, 'Could not start %s: %s. The approval is kept; run it again with: '
                           'sudo pinpoint-update run %s' % (EXEC_UNIT % txn_id, done.stderr.strip()[:200], txn_id))
    with store.db:
        store.audit('txn.start_requested', {'unit': EXEC_UNIT % txn_id}, txn_id=txn_id)


STEP_LABELS = {'approved': 'Waiting to start', 'preparing': 'Preflight checks',
               'staging': 'Downloading and building (monitoring still running)',
               'applying': 'Applying (PinPoint web and Nagios stopped)', 'health_check': 'Health checks',
               'rolling_back': 'Rolling back to the previous version'}


def follow(store, txn_id, write=print, sleep=time.sleep, limit=7200):
    """Print each step until the transaction ends. Ctrl-C stops watching, never the update."""
    seen, waited = None, 0
    try:
        while waited <= limit:
            row = store.db.execute('SELECT state, step, failure_code, recovery_status FROM txn WHERE txn_id = ?',
                                   (txn_id,)).fetchone()
            if row is None:
                write('  No transaction %s.' % txn_id)
                return INVALID_INPUT
            state, step = row[0], row[1]
            if (state, step) != seen:
                seen = (state, step)
                if state in FINISHED:
                    write('  Result: %s%s' % (state.upper(), ' (%s)' % row[2] if row[2] else ''))
                    if row[3]:
                        write('  %s' % row[3])
                    return OK if state == 'succeeded' else BLOCKED
                write('  [..] %s%s' % (STEP_LABELS.get(state, state), ' - ' + step if step else ''))
            sleep(2)
            waited += 2
    except KeyboardInterrupt:
        pass
    write('  Stopped watching. The update keeps running; see: sudo pinpoint-update status --follow')
    return OK


##################################################
# Console output
##################################################


def render(rows, manifest, store, update_status):
    width = 64
    profile = os_profile()
    lines = ['=' * width,
             '  PinPoint Update Manager'.ljust(width - 30) + ('host: ' + socket.gethostname())[:30].rjust(30),
             '  %s %s %s' % (profile['os'].capitalize(), profile['version'], profile['arch']),
             '-' * width,
             '  %-18s %-13s %-13s %s' % ('Component', 'Installed', 'Expected', 'Status')]
    for r in rows:
        lines.append('  %-18s %-13s %-13s %s' % (r['label'], r['installed'] or '-', r['baseline'],
                                                 'OK' if r['status'] == 'baseline' else r['status']))
    installed = store.installed_manifest()
    lines += ['-' * width,
              '  Installed update set: %s' % (installed or '%s (not recorded: versions differ)' % manifest['manifest_id']),
              '  Update status: ' + update_status]
    running = active_txn(store)
    for approval in decisions(store, decision='approve'):
        lines.append('  Approved: %s by %s, %s' % (approval['manifest_id'], approval['approver'],
                                                   'window ' + approval['window_start'] + ' UTC'
                                                   if approval['window_start'] else 'waiting to run'))
    if running and running[1] != 'approved':
        lines.append('  Running: %s - %s' % (running[0], STEP_LABELS.get(running[1], running[1])))
    lines.append('  Ubuntu security updates (nginx, Apache, OpenSSL...): %s' % {
        'on': 'installed automatically by Ubuntu', 'off': 'NOT automatic'}[auto_security_updates()])
    lines.append('=' * width)
    if any(r['status'] != 'baseline' for r in rows):
        lines.append('  Some components differ from the installed update set. Nothing was changed.')
    return '\n'.join(lines)


MENU = """
   1) Reload (check for updates)
   2) Install updates
   3) Choose what to update
   4) Exit
"""

DECISION_MENU = """
   1) Install now
   2) Schedule for later
   3) Not now (ask me again later)
   4) Defer (give a reason and a review date)
   5) Decline this release
   6) Back
"""


def describe_set(store, record):
    """The decision-screen summary of one update set (plan 8.1)."""
    body, compat = record['body'], record['body']['compatibility']
    current = reference(store, body)
    lines = ['', '  Update set: %s   (digest %s..%s)' % (record['manifest_id'], record['sha256'][:4],
                                                         record['sha256'][-2:])]
    for key, label in COMPONENTS:
        old, new = current['components'][key]['version'], body['components'][key]['version']
        lines.append('  %-15s %s' % (label, '%s -> %s' % (old, new) if old != new else '%s (unchanged)' % new))
    lines += ['  Compatibility: %s%s' % (record['compat_state'].upper(),
                                         ' (evidence: %s)' % ', '.join(compat['evidence_ids'])
                                         if compat.get('evidence_ids') else ''),
              '  Security fixes: %s' % (', '.join(body.get('security', {}).get('advisories', [])) or 'none listed'),
              '  Expected downtime: ~%d min   Rollback: automatic' % body.get('expected_downtime_minutes',
                                                                              DEFAULT_DOWNTIME)]
    lines += ['  Limitation: ' + item for item in compat.get('known_limitations', [])]
    if body.get('release_notes_url'):
        lines.append('  Release notes: ' + body['release_notes_url'])
    return '\n'.join(lines)


def ask(read, prompt):
    try:
        return read(prompt).strip()
    except (EOFError, KeyboardInterrupt):
        return None


def confirm_set(store, record, read, write):
    """Type the manifest ID; a conditional set shows its limitations and asks a second time."""
    mid = record['manifest_id']
    if ask(read, '  Type the update set ID to confirm (%s): ' % mid) != mid:
        write('  The ID does not match. Nothing was changed.')
        return None
    if record['compat_state'] == 'conditional':
        write('  This update set is CONDITIONAL. Its limitations are listed above.')
        if (ask(read, '  Type ACCEPT to approve it with these limitations: ') or '').upper() != 'ACCEPT':
            write('  Not accepted. Nothing was changed.')
            return None
        return True
    return False


def decision_screen(store, record, caller, read, write, sleep):
    """Install now, schedule, not now, defer, decline or back, for one update set."""
    mid = record['manifest_id']
    while True:
        write(describe_set(store, record))
        write(DECISION_MENU)
        choice = ask(read, '  Enter an option: ')
        if choice in (None, '6'):
            return
        if choice == '3':
            with store.db:
                store.audit('approval.not_now', {}, mid)
            write('  Nothing was changed. You will be reminded later.')
            return
        if choice not in ('1', '2', '4', '5'):
            write('  Please enter a number from 1 to 6.')
            continue
        if caller != 'admin':
            write('  Only members of %s can do this. Nothing was changed.' % ADMINS)
            continue
        try:
            found = scan()
            if choice in ('1', '2'):
                accept = confirm_set(store, record, read, write)
                if accept is None:
                    continue
                at = None
                if choice == '2':
                    text = ask(read, '  Start of the window (for example 2026-11-20 22:00, appliance time): ')
                    try:
                        at = time_arg(text or '')
                    except argparse.ArgumentTypeError as error:
                        write('  %s. Nothing was changed.' % error)
                        continue
                approval, txn_id, _ = approve(store, mid, found, at, None, accept)
                if choice == '2':
                    write('  Scheduled: %s runs in the window that starts %s UTC (transaction %s).'
                          % (mid, approval['window_start'], txn_id))
                    return
                start_run(store, txn_id)
                write('  Started %s (transaction %s). Do not power off the appliance.' % (mid, txn_id))
                follow(store, txn_id, write, sleep)
                return
            reason = ask(read, '  Reason: ')
            if choice == '4':
                review = ask(read, '  Review date (YYYY-MM-DD): ')
                refuse(store, mid, 'defer', reason_arg(reason or ''), date_arg(review or ''))
                write('  Deferred. The installed version keeps running.')
            else:
                refuse(store, mid, 'decline', reason_arg(reason or ''))
                write('  Declined. The installed version keeps running.')
            return
        except argparse.ArgumentTypeError as error:
            write('  %s. Nothing was changed.' % error)
        except CommandError as error:
            write('  %s: %s' % (CODE_NAMES[error.code], error))
            return


def choose_screen(store, read, write):
    """Option 3: update sets are installed whole; list each one with what it changes and pick one."""
    sets = offers(store, scan())
    if not sets:
        write('\n  No update set can be installed on this host now. Choose 1 to reload the catalog.')
        return None
    current = reference(store, sets[0]['body'])
    write('\n  Update sets that can be installed here (each is installed as a whole):')
    for n, record in enumerate(sets, 1):
        changes = ['%s %s -> %s' % (label, current['components'][key]['version'],
                                    record['body']['components'][key]['version'])
                   for key, label in COMPONENTS
                   if current['components'][key]['version'] != record['body']['components'][key]['version']
                   or current['components'][key]['artifact']['sha256']
                   != record['body']['components'][key]['artifact']['sha256']]
        write('   %d) %-22s %-12s %s' % (n, record['manifest_id'], record['compat_state'].upper(),
                                        '; '.join(changes) or 'no version change'))
    choice = ask(read, '  Choose a number (Enter to go back): ')
    if choice and choice.isdigit() and 1 <= int(choice) <= len(sets):
        return sets[int(choice) - 1]
    return None


def menu(store, manifest, read=input, write=print, caller='admin', sleep=time.sleep, fetch=None):
    found, _ = refresh(store, manifest)
    rows = compare(found, reference(store, manifest))
    while True:
        write(render(rows, manifest, store, catalog_status(store, found)))
        write(MENU)
        choice = ask(read, '  Enter an option: ')
        if choice is None:
            write('')
            return 0
        if choice == '1':
            ok, reason, new = discover(store, fetch)
            write('\n  %s\n' % ('Catalog checked%s.' % (': new update sets ' + ', '.join(new) if new else '')
                                if ok else 'The catalog could not be checked: %s. Nothing was changed.' % reason))
        elif choice in ('2', '3'):
            sets = offers(store, found)
            record = (sets[0] if sets else None) if choice == '2' else choose_screen(store, read, write)
            if record:
                decision_screen(store, record, caller, read, write, sleep)
            elif choice == '2':
                write('\n  No update can be installed on this host now. Choose 1 to reload the catalog.\n')
        elif choice == '4':
            return 0
        else:
            write('\n  Please enter 1, 2, 3 or 4.\n')
            continue
        found, _ = refresh(store, manifest)
        rows = compare(found, reference(store, manifest))


##################################################
# Command line
##################################################

def pattern_arg(pattern, what):
    def check(text):
        if not re.fullmatch(pattern, text):
            raise argparse.ArgumentTypeError('invalid %s: %r' % (what, text[:80]))
        return text
    return check


def reason_arg(text):
    """Reasons are stored as data, never run: 1 to 500 printable characters on one line."""
    text = text.strip()
    if not 1 <= len(text) <= 500 or not text.isprintable():
        raise argparse.ArgumentTypeError('a reason is 1 to 500 printable characters on one line')
    return text


def time_arg(text):
    """ISO 8601 date and time; without an offset it is the appliance's local time. Returns UTC."""
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?([+-]\d{2}:\d{2}|Z)?', text):
        raise argparse.ArgumentTypeError('expected a date and time such as 2026-11-20T22:00+08:00')
    try:
        moment = datetime.datetime.fromisoformat(text[:-1] + '+00:00' if text.endswith('Z') else text)
    except ValueError:
        raise argparse.ArgumentTypeError('not a valid date and time: %s' % text)
    return utc(moment if moment.tzinfo else moment.astimezone())


def date_arg(text):
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', text):
        raise argparse.ArgumentTypeError('expected a date such as 2026-12-01')
    try:
        return datetime.date.fromisoformat(text).isoformat()
    except ValueError:
        raise argparse.ArgumentTypeError('not a valid date: %s' % text)


def range_arg(low, high):
    def check(text):
        if not re.fullmatch(r'\d{1,6}', text) or not low <= int(text) <= high:
            raise argparse.ArgumentTypeError('expected a number from %d to %d' % (low, high))
        return int(text)
    return check


def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument('--json', action='store_true', help='print one JSON object (schema pinpoint-update/v1)')
    manifest_id = pattern_arg(ID_PATTERN, 'manifest ID')
    parser = argparse.ArgumentParser(prog='pinpoint-update', description='PinPoint Update Manager.')
    parser.add_argument('--first-login', action='store_true',
                        help='open the menu once after a fresh install (used by the console login hook)')
    sub = parser.add_subparsers(dest='command', metavar='COMMAND')
    sub.add_parser('menu', help='the numbered console menu (default on a terminal)')
    sub.add_parser('inventory', parents=[common], help='scan the installed versions')
    p = sub.add_parser('status', parents=[common], help='installed versions, approvals and update status')
    p.add_argument('--follow', action='store_true', help='watch the running update until it ends')
    p = sub.add_parser('discover', parents=[common], help='check the update catalog for new update sets')
    p.add_argument('--timeout', type=range_arg(1, 120), default=30, help='seconds per download, 1 to 120')
    p.add_argument('--quiet', action='store_true', help='print nothing unless the check fails (for the timer)')
    p = sub.add_parser('run', parents=[common], help='start an approved update now (admin)')
    p.add_argument('txn_id', type=pattern_arg(TXN_PATTERN, 'transaction ID'))
    p = sub.add_parser('list', parents=[common], help='recorded manifests and whether they can be installed')
    p.add_argument('--all', action='store_true', help='include revoked manifests')
    p = sub.add_parser('show', parents=[common], help='one manifest, its evidence and limitations')
    p.add_argument('manifest_id', type=manifest_id)
    p = sub.add_parser('validate', parents=[common], help='run the compatibility gate for one manifest')
    p.add_argument('manifest_id', type=manifest_id)
    p = sub.add_parser('approve', parents=[common], help='approve one manifest for this host (admin)')
    p.add_argument('manifest_id', type=manifest_id)
    p.add_argument('--confirm', required=True, type=manifest_id, help='type the manifest ID again')
    p.add_argument('--at', type=time_arg, help='start of the maintenance window (default: no window yet)')
    p.add_argument('--window-minutes', type=range_arg(30, 1440), help='length of the window, 30 to 1440')
    p.add_argument('--accept-limitations', action='store_true', help='confirm a conditional manifest')
    p.add_argument('--now', action='store_true', help='start the update right away (Nagios stops for a few minutes)')
    p = sub.add_parser('defer', parents=[common], help='defer one manifest until a review date (admin)')
    p.add_argument('manifest_id', type=manifest_id)
    p.add_argument('--reason', required=True, type=reason_arg)
    p.add_argument('--review-date', required=True, type=date_arg)
    p = sub.add_parser('decline', parents=[common], help='decline one manifest (admin)')
    p.add_argument('manifest_id', type=manifest_id)
    p.add_argument('--reason', required=True, type=reason_arg)
    p = sub.add_parser('cancel', parents=[common], help='cancel an approved transaction (admin)')
    p.add_argument('txn_id', type=pattern_arg(TXN_PATTERN, 'transaction ID'))
    p = sub.add_parser('history', parents=[common], help='past transactions')
    p.add_argument('--limit', type=range_arg(1, 1000), default=20)
    p = sub.add_parser('audit', parents=[common], help='the audit log')
    p.add_argument('--since', type=date_arg, help='only rows from this date (UTC)')
    p.add_argument('--verify', action='store_true', help='check the hash chain')
    return parser


def emit(args, data, text):
    if getattr(args, 'json', False):
        print(json.dumps({'schema': 'pinpoint-update/v1', 'command': args.command, 'result': 'OK', **data},
                         indent=2, sort_keys=True))
    else:
        print(text)


def command_list(store, args, found, problems):
    sql = 'SELECT manifest_id FROM manifest' + ('' if args.all else ' WHERE revoked_at IS NULL')
    items = [manifest_summary(store, store.manifest(mid), found) for (mid,) in store.db.execute(sql + ' ORDER BY 1')]
    lines = ['  %-24s %-9s %-9s %-7s %-13s %s' % ('Manifest', 'Core', 'Plugins', 'NCPA', 'Compatibility', 'Here')]
    installed = store.installed_manifest()
    for item in items:
        here = ('installed' if item['manifest_id'] == installed else 'installable' if item['installable']
                else 'blocked')
        decision = item['latest_decision']
        if decision and decision['status'] == 'active':
            here = {'approve': 'approved', 'defer': 'deferred to ' + str(decision['review_date']),
                    'decline': 'declined'}[decision['decision']]
        v = item['versions']
        lines.append('  %-24s %-9s %-9s %-7s %-13s %s' % (item['manifest_id'], v['nagios-core'], v['nagios-plugins'],
                                                         v['check-ncpa'], item['compat_state'], here))
    for name, problem in sorted(problems.items()):
        lines.append('  REFUSED %s: %s' % (name, problem))
    emit(args, {'installed_manifest': installed, 'manifests': items, 'refused_files': problems}, '\n'.join(lines))
    return OK


def command_show(store, args, found):
    record = store.manifest(args.manifest_id)
    if record is None:
        raise CommandError(INVALID_INPUT, '%s is not a recorded manifest.' % args.manifest_id)
    item, body = manifest_summary(store, record, found), record['body']
    compat = body['compatibility']
    lines = ['  Update set: %s   (digest %s..%s)' % (item['manifest_id'], record['sha256'][:4], record['sha256'][-2:]),
             '  Published: %s by %s' % (body.get('published_at', '-'), body.get('publisher', '-'))]
    for key, label in COMPONENTS:
        lines.append('  %-15s %s' % (label, body['components'][key]['version']))
    lines += ['  Compatibility: %s%s' % (record['compat_state'].upper(),
                                         ' (evidence: %s)' % ', '.join(compat.get('evidence_ids', []))
                                         if compat.get('evidence_ids') else ''),
              '  Upgrades from: %s' % (', '.join(body['upgrade_from']) or 'nothing'),
              '  Migration class: %s   Expected downtime: ~%d min   Rollback: automatic'
              % (body['migration_class'], body.get('expected_downtime_minutes', DEFAULT_DOWNTIME)),
              '  Security fixes: %s' % (', '.join(body.get('security', {}).get('advisories', [])) or 'none listed')]
    for limitation in compat.get('known_limitations', []):
        lines.append('  Limitation: ' + limitation)
    if body.get('release_notes_url'):
        lines.append('  Release notes: ' + body['release_notes_url'])
    lines.append('  On this host: ' + ('can be installed' if item['installable'] else 'BLOCKED'))
    lines += ['    - ' + reason for reason in item['blocked_by']]
    emit(args, {'manifest': item, 'body': body}, '\n'.join(lines))
    return OK


def command_validate(store, args, found):
    reasons = gate(store, args.manifest_id, found)
    with store.db:
        store.audit('manifest.validated', {'result': 'blocked' if reasons else 'installable', 'reasons': reasons},
                    args.manifest_id)
    if reasons:
        raise CommandError(BLOCKED, ' '.join(reasons))
    emit(args, {'manifest_id': args.manifest_id, 'installable': True},
         '  %s can be installed on this host.' % args.manifest_id)
    return OK


def command_history(store, args):
    items = store.rows('SELECT t.txn_id, t.kind, t.source_manifest_id, t.target_manifest_id, t.state, t.failure_code, '
                       't.recovery_status, t.recovery_point_id, t.created_at, t.finished_at, t.downtime_seconds, '
                       'a.approver '
                       'FROM txn t LEFT JOIN approval a ON a.approval_id = t.approval_id WHERE t.host_id = ? '
                       'ORDER BY t.created_at DESC LIMIT ?', (host_id(), args.limit))
    lines = ['  %-27s %-6s %-36s %-11s %-15s %s' % ('Transaction', 'Kind', 'From -> to', 'Approver', 'Result',
                                                    'Recovery')]
    for t in items:
        lines.append('  %-27s %-6s %-36s %-11s %-15s %s' % (
            t['txn_id'], t['kind'], '%s -> %s' % (t['source_manifest_id'], t['target_manifest_id']),
            t['approver'] or '-', t['state'], t['recovery_status'] or '-'))
    emit(args, {'transactions': items}, '\n'.join(lines))
    return OK


def command_audit(store, args):
    broken = store.verify_audit() if args.verify else None
    items = store.rows('SELECT seq, at, actor, event, txn_id, manifest_id, detail_json FROM audit '
                       'WHERE at >= ? ORDER BY seq', (args.since or '',))
    lines = ['%(seq)s %(at)s %(actor)s %(event)s %(manifest_id)s %(detail_json)s' % row for row in items]
    if args.verify:
        lines.append('Audit chain: ' + ('intact' if broken is None else 'BROKEN at row %d' % broken))
    emit(args, {'rows': items, 'chain': None if not args.verify else 'intact' if broken is None else broken},
         '\n'.join(lines))
    return OK if broken is None else 1


def command_discover(store, manifest, args, fetch=None):
    ok, reason, new = discover(store, fetch, args.timeout)
    found, problems = refresh(store, manifest)
    for record in offers(store, found):
        notice_available(store, record)
    send_notices(store)
    status = catalog_status(store, found)
    if not ok:
        raise CommandError(CATALOG_UNAVAILABLE, 'The catalog could not be checked: %s. Nothing was changed.' % reason)
    if not args.quiet or args.json:
        emit(args, {'new_manifests': new, 'update_status': status, 'refused_files': problems},
             '  Catalog checked. %s%s' % (status, '\n  New update sets: ' + ', '.join(new) if new else ''))
    return OK


def command_run(store, args):
    row = store.db.execute('SELECT state FROM txn WHERE txn_id = ? AND host_id = ? AND kind = ?',
                           (args.txn_id, host_id(), 'update')).fetchone()
    if row is None:
        raise CommandError(INVALID_INPUT, 'No update transaction %s on this host.' % args.txn_id)
    if row[0] != 'approved':
        raise CommandError(INVALID_TRANSITION, 'Transaction %s is %s, not approved.' % (args.txn_id, row[0]))
    start_run(store, args.txn_id)
    emit(args, {'txn_id': args.txn_id, 'started': True}, '  Started %s.' % args.txn_id)
    if sys.stdout.isatty() and not args.json:
        return follow(store, args.txn_id)
    return OK


def run_command(store, manifest, args):
    command = args.command
    if command == 'menu':
        return menu(store, manifest, caller=getattr(args, 'caller', 'admin'))
    if command == 'audit':
        return command_audit(store, args)
    if command == 'discover':
        return command_discover(store, manifest, args)
    found, problems = refresh(store, manifest)
    if command == 'run':
        return command_run(store, args)
    if command == 'status' and args.follow:
        running = active_txn(store)
        if not running:
            print('  No update is running.')
            return OK
        return follow(store, running[0])
    if command == 'list':
        return command_list(store, args, found, problems)
    if command == 'show':
        return command_show(store, args, found)
    if command == 'validate':
        return command_validate(store, args, found)
    if command == 'history':
        return command_history(store, args)
    if command == 'approve':
        if args.confirm != args.manifest_id:
            raise CommandError(INVALID_INPUT, 'The confirmation does not match the manifest ID. Nothing was approved.')
        if args.now and args.at:
            raise CommandError(INVALID_INPUT, 'Use --now or --at, not both.')
        approval, txn_id, created = approve(store, args.manifest_id, found, args.at, args.window_minutes,
                                            args.accept_limitations)
        when = ('It starts now.' if args.now else 'It runs in the window that starts %s UTC.' % approval['window_start']
                if approval['window_start'] else 'Start it with: sudo pinpoint-update run %s' % txn_id)
        emit(args, {'approval': approval, 'txn_id': txn_id, 'created': created, 'started': args.now},
             '  %s %s for this host (approval %s, transaction %s, expires %s).\n  %s'
             % ('Approved' if created else 'Already approved:', args.manifest_id, approval['approval_id'], txn_id,
                approval['expires_at'], when))
        if args.now:
            start_run(store, txn_id)
            if sys.stdout.isatty() and not args.json:
                return follow(store, txn_id)
        return OK
    if command in ('defer', 'decline'):
        approval, created = refuse(store, args.manifest_id, command, args.reason, getattr(args, 'review_date', None))
        emit(args, {'approval': approval, 'created': created},
             '  %s %s. The installed version keeps running.' % ('Deferred' if command == 'defer' else 'Declined',
                                                                args.manifest_id))
        return OK
    if command == 'cancel':
        changed = cancel(store, args.txn_id)
        emit(args, {'txn_id': args.txn_id, 'changed': changed},
             '  Transaction %s %s.' % (args.txn_id, 'cancelled' if changed else 'was already cancelled'))
        return OK
    rows = compare(found, reference(store, manifest))
    status = catalog_status(store, found)
    if args.json:
        emit(args, {'manifest_id': manifest['manifest_id'], 'installed_manifest': store.installed_manifest(),
                    'os': os_profile(), 'pinpoint_commit': app_commit(), 'update_status': status,
                    'components': rows, 'approvals': decisions(store, decision='approve'),
                    'active_txn': (active_txn(store) or [None])[0], 'refused_files': problems,
                    'ubuntu_security_updates': auto_security_updates()}, '')
    else:
        print(render(rows, manifest, store, status))
    return OK


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        print('pinpoint-update must be run as root: sudo pinpoint-update', file=sys.stderr)
        return NOT_AUTHORISED
    try:
        manifest = load_manifest()
    except (OSError, ValueError, KeyError) as error:
        print('Baseline manifest is missing or invalid (%s): %s' % (MANIFEST, type(error).__name__), file=sys.stderr)
        return BLOCKED
    if args.first_login:
        if not MENU_PENDING.exists():
            return OK
        # Removed before showing, so a dropped session cannot reopen it on every login.
        MENU_PENDING.unlink()
    store = Store()
    try:
        args.command = 'menu' if args.first_login else args.command or ('menu' if sys.stdin.isatty() else 'status')
        caller = role()
        if caller is None or (args.command in ADMIN_COMMANDS and caller != 'admin'):
            with store.db:
                store.audit('auth.refused', {'command': args.command, 'role': caller})
            raise CommandError(NOT_AUTHORISED, '%s may not run "%s". Ask an administrator to add you to %s.'
                               % (actor(), args.command, VIEWERS if caller is None else ADMINS))
        args.caller = caller
        return run_command(store, manifest, args)
    except InvalidTransition as error:
        return report(args, CommandError(INVALID_TRANSITION, 'Invalid transition: %s' % error))
    except CommandError as error:
        return report(args, error)
    finally:
        store.close()


def report(args, error):
    if getattr(args, 'json', False):
        print(json.dumps({'schema': 'pinpoint-update/v1', 'command': args.command,
                          'result': CODE_NAMES[error.code], 'message': str(error)}, indent=2, sort_keys=True))
    else:
        print('%s: %s' % (CODE_NAMES[error.code], error), file=sys.stderr)
    return error.code


if __name__ == '__main__':
    sys.exit(main())
