#!/usr/bin/python3 -I
"""PinPoint update executor, Phase 2: recovery points, restore and reconcile.

Before anything in Nagios changes, a recovery point is taken: a copy of
/usr/local/nagios (on the same filesystem, so restoring is a rename) plus
nagios.service and the Apache site, with a per-file SHA-256, owner and mode
list that is verified before it is trusted. A failed change is undone by
swapping the copy back and running the health suite on the old version.
Every restore step is recorded first, so running it twice gives the same
result, and an interrupted transaction is always finished toward the
previous version, never forward (plan sections 7.2 and 11).

Phase 2 installs no update. The `drill` command runs the whole recovery
path on a staging appliance, with an optional injected fault (plan section
13.4), and records how long each part took.
"""
import argparse
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import time

sys.dont_write_bytecode = True  # no __pycache__ next to the root-owned controller

CONTROLLER = Path('/usr/local/sbin/pinpoint-update')
HEALTH = Path('/usr/local/lib/pinpoint-update/pinpoint-update-health.sh')
NAGIOS = Path('/usr/local/nagios')
RP_ROOT = Path('/usr/local/.pinpoint-rp')
LOCK = Path('/run/lock/pinpoint-update.lock')
LOG = Path('/var/log/pinpoint-update.log')
APACHE_SITE = Path('/etc/apache2/sites-enabled/nagios.conf')
NAGIOS_UNIT = Path('/lib/systemd/system/nagios.service')
# Stopped in this order, started in reverse: the web app first, so it cannot
# write Nagios config or restart Nagios while the tree is being swapped.
SERVICES = ('pinpoint-gunicorn', 'nagios')
# Recreated by Nagios on start, so not part of the verified file list (plan 11.1).
UNVERIFIED = ('var/rw', 'var/nagios.lock')
SPACE_MARGIN = 1 << 30  # <PLACEHOLDER 1 GB> in plan section 10.2, step 9
HEALTH_TIMEOUT = 900

OK, NOT_AUTHORISED, BUSY, INVALID_TRANSITION, PREFLIGHT_FAILED = 0, 3, 5, 6, 8
ROLLED_BACK, RECOVERY_FAILED, DRILL_FAULT_MISSED = 10, 11, 12

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
FAULTS = ('config', 'service', 'plugin', 'corrupt')
DRILL_FAULT_LINE = 'pinpoint_drill_invalid_directive=1\n'

pu = None  # the controller module, loaded in main()


class InvalidTransition(Exception):
    pass


class RecoveryError(Exception):
    pass


def load_controller(path=None):
    """The controller (pinpoint-update) owns the database schema and the audit chain."""
    loader = importlib.machinery.SourceFileLoader('pinpoint_update', str(path or CONTROLLER))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


def say(text):
    """Print and log. A closed SSH session must not stop a restore, so output errors are ignored."""
    line = '%s %s' % (pu.now(), text)
    try:
        with open(LOG, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except OSError:
        pass
    try:
        print(text, flush=True)
    except OSError:
        pass


def systemctl(*args):
    subprocess.run(['systemctl', *args], check=True, capture_output=True, timeout=300)


def stop_services():
    for unit in SERVICES:
        systemctl('stop', unit)


def start_services():
    """Start every service even if one fails, then report the first failure."""
    error = None
    for unit in reversed(SERVICES):
        try:
            systemctl('start', unit)
        except subprocess.SubprocessError as failure:
            error = error or failure
    if error:
        raise error


def ignore_interrupts():
    """From the first change on, a closed terminal or Ctrl-C must not leave Nagios half-changed."""
    for sig in (signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, signal.SIG_IGN)


def copy_tree(source, target):
    subprocess.run(['cp', '-a', '--reflink=auto', str(source), str(target)], check=True,
                   capture_output=True, timeout=1800)


def take_lock():
    """The lock deploy-pinpoint-web.sh also takes. Returns the open descriptor, or None if busy."""
    import fcntl  # Linux only; imported here so the unit tests also run on other systems
    fd = os.open(str(LOCK), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


##################################################
# Transactions
##################################################

def new_txn(store, kind, source, target):
    txn_id = 'txn-%s-%s' % (time.strftime('%Y%m%d%H%M%S', time.gmtime()), os.urandom(3).hex())
    with store.db:
        store.db.execute('INSERT INTO txn (txn_id, kind, host_id, source_manifest_id, target_manifest_id, state, '
                         'created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
                         (txn_id, kind, pu.host_id(), source, target, 'preparing', pu.now()))
        store.audit('txn.created', {'kind': kind, 'requested_by': pu.actor()}, target, txn_id, who='executor')
    return txn_id


def active_txn(store):
    marks = ','.join('?' * len(ACTIVE))
    return store.db.execute('SELECT txn_id, state, step, recovery_point_id FROM txn WHERE host_id = ? '
                            'AND state IN (%s)' % marks, (pu.host_id(), *ACTIVE)).fetchone()


def txn_state(store, txn_id):
    row = store.db.execute('SELECT state FROM txn WHERE txn_id = ?', (txn_id,)).fetchone()
    return row[0] if row else None


def update_txn(store, txn_id, who='executor', **fields):
    """Record a sub-step or field without changing state; the step is written before it runs."""
    unknown = set(fields) - set(TXN_FIELDS)
    if unknown:
        raise ValueError('unknown txn fields: %s' % ', '.join(sorted(unknown)))
    with store.db:
        store.db.execute('UPDATE txn SET %s WHERE txn_id = ?' % ', '.join('%s = ?' % k for k in fields),
                         (*fields.values(), txn_id))
        store.audit('txn.step', fields, txn_id=txn_id, who=who)


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
            fields.setdefault('finished_at', pu.now())
        values = {'state': to, **fields}
        store.db.execute('UPDATE txn SET %s WHERE txn_id = ?' % ', '.join('%s = ?' % k for k in values),
                         (*values.values(), txn_id))
        store.audit('txn.' + to, {'from': row[0], **fields}, txn_id=txn_id, who=who)


def workdir(txn_id):
    path = pu.STATE_DIR / 'txn' / txn_id
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def save_context(txn_id, context):
    (workdir(txn_id) / 'context.json').write_text(json.dumps(context, indent=2, sort_keys=True))


def load_context(txn_id):
    return json.loads((workdir(txn_id) / 'context.json').read_text())


##################################################
# Recovery points
##################################################

def file_list(root):
    """{relative path: [type, mode, uid, gid, sha256 or link target]} for a whole tree, root included."""
    root = str(root)
    st = os.lstat(root)
    entries = {'.': ['dir', stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, None]}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in dirnames + sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace(os.sep, '/')
            if any(rel == skip or rel.startswith(skip + '/') for skip in UNVERIFIED):
                continue
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                kind, value = 'link', os.readlink(path)
            elif stat.S_ISREG(st.st_mode):
                kind, value = 'file', pu.sha256_file(path)
            elif stat.S_ISDIR(st.st_mode):
                kind, value = 'dir', None
            elif stat.S_ISFIFO(st.st_mode):
                kind, value = 'fifo', None
            else:
                kind, value = 'other', None
            entries[rel] = [kind, stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, value]
    return entries


def tree_size(root):
    total = 0
    for dirpath, dirnames, filenames in os.walk(str(root)):
        for name in filenames:
            try:
                total += os.lstat(os.path.join(dirpath, name)).st_size
            except OSError:
                pass
    return total


def extra_files():
    """Files outside the tree that `make install-daemoninit` and `make install-webconf` write."""
    unit = NAGIOS_UNIT
    try:
        done = subprocess.run(['systemctl', 'show', '-p', 'FragmentPath', '--value', 'nagios'],
                              capture_output=True, text=True, timeout=30, check=False)
        if done.stdout.strip():
            unit = Path(done.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return [p for p in (unit, APACHE_SITE.resolve()) if p.is_file()]


def describe(path):
    st = os.stat(path)
    return [stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid, pu.sha256_file(path)]


def create_recovery_point(store, txn_id):
    """Copy the stopped Nagios tree and the extra files, then prove the copy equals the original."""
    rp_id = 'rp-%s-%s' % (time.strftime('%Y%m%d%H%M%S', time.gmtime()), os.urandom(3).hex())
    RP_ROOT.mkdir(mode=0o700, exist_ok=True)
    os.chmod(RP_ROOT, 0o700)
    rp = RP_ROOT / rp_id
    rp.mkdir(mode=0o700)
    copy_tree(NAGIOS, rp / 'nagios')
    (rp / 'files').mkdir(mode=0o700)
    extras = {}
    for n, path in enumerate(extra_files()):
        shutil.copy2(str(path), str(rp / 'files' / str(n)))
        extras[str(path)] = [str(n)] + describe(path)
    tree = file_list(NAGIOS)
    if file_list(rp / 'nagios') != tree:
        raise RecoveryError('the recovery copy differs from %s' % NAGIOS)
    body = json.dumps({'tree': tree, 'extra': extras, 'unverified': UNVERIFIED}, sort_keys=True).encode()
    (rp / 'filelist.json').write_bytes(body)
    os.chmod(rp / 'filelist.json', 0o600)
    with store.db:
        store.db.execute('INSERT INTO recovery_point (rp_id, txn_id, kind, location, file_manifest_sha256, '
                         'size_bytes, created_at, verified_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
                         (rp_id, txn_id, 'tree-copy-v1', str(rp), hashlib.sha256(body).hexdigest(),
                          tree_size(rp / 'nagios'), pu.now(), pu.now()))
        store.audit('recovery_point.created', {'rp_id': rp_id, 'files': len(tree), 'extra': sorted(extras)},
                    txn_id=txn_id, who='executor')
    return rp_id


def recovery_files(store, rp_id):
    """The stored file list, after checking it against the digest kept in the database."""
    row = store.db.execute('SELECT file_manifest_sha256 FROM recovery_point WHERE rp_id = ?', (rp_id,)).fetchone()
    if row is None:
        raise RecoveryError('recovery point %s is not recorded' % rp_id)
    body = (RP_ROOT / rp_id / 'filelist.json').read_bytes()
    if hashlib.sha256(body).hexdigest() != row[0]:
        raise RecoveryError('the file list of %s was changed' % rp_id)
    return json.loads(body)


def verify_recovery_point(store, rp_id):
    """True when the saved copy and extra files still match their list (HC-14)."""
    try:
        files = recovery_files(store, rp_id)
        rp = RP_ROOT / rp_id
        if file_list(rp / 'nagios') != files['tree']:
            return False
        return all(pu.sha256_file(rp / 'files' / saved[0]) == saved[4] for saved in files['extra'].values())
    except (OSError, ValueError, KeyError, RecoveryError):
        return False


def restore(store, txn_id, rp_id, at_boot=False, who='executor'):
    """Put the recovery point back. Each step is safe to repeat after a crash.

    At boot the services are not running yet and must not be touched: stopping
    or starting a unit that waits for this one would cancel or deadlock it.
    """
    files = recovery_files(store, rp_id)
    rp = RP_ROOT / rp_id
    saved, failed = rp / 'nagios', rp / 'failed'
    if not at_boot:
        update_txn(store, txn_id, who, step='restore.stop')
        stop_services()
    update_txn(store, txn_id, who, step='restore.swap')
    if saved.exists():
        if NAGIOS.exists() or NAGIOS.is_symlink():
            target = failed if not failed.exists() else rp / ('failed-' + os.urandom(3).hex())
            os.rename(str(NAGIOS), str(target))
        os.rename(str(saved), str(NAGIOS))
    elif not NAGIOS.exists():
        raise RecoveryError('neither the recovery copy nor %s exists' % NAGIOS)
    update_txn(store, txn_id, who, step='restore.extra')
    unit_changed = False
    for path, (name, mode, uid, gid, digest) in sorted(files['extra'].items()):
        path = Path(path)
        if path.is_file() and describe(path) == [mode, uid, gid, digest]:
            continue
        temp = path.with_name('.%s.pinpoint-restore' % path.name)
        shutil.copy2(str(rp / 'files' / name), str(temp))
        os.chown(str(temp), uid, gid)
        os.chmod(str(temp), mode)
        os.replace(str(temp), str(path))
        unit_changed = unit_changed or path.suffix == '.service'
    if unit_changed:
        systemctl('daemon-reload')
    update_txn(store, txn_id, who, step='restore.verify')
    if file_list(NAGIOS) != files['tree']:
        raise RecoveryError('%s does not match the recovery point after restoring' % NAGIOS)
    if at_boot:
        update_txn(store, txn_id, who, step='restore.files-restored')
        return
    update_txn(store, txn_id, who, step='restore.start')
    start_services()
    try:
        systemctl('reload', 'apache2')
    except (OSError, subprocess.SubprocessError):
        pass  # the health suite (HC-05) reports an Apache that does not serve the CGIs
    update_txn(store, txn_id, who, step='restore.started')


##################################################
# Health
##################################################

def run_health(txn_id, mode, context, since=0):
    """Run the health suite. Returns (number of failed critical checks, output lines)."""
    args = [str(HEALTH), '--' + mode, str(workdir(txn_id) / 'health-baseline')]
    if context.get('version'):
        args += ['--target-version', context['version']]
    if mode == 'compare':
        args += ['--since', str(int(since))]
        if context.get('ncpa_sha256'):
            args += ['--ncpa-sha256', context['ncpa_sha256']]
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=HEALTH_TIMEOUT, check=False)
        lines, failed = done.stdout.splitlines(), done.returncode
    except (OSError, subprocess.SubprocessError) as error:
        lines, failed = ['HEALTH|critical|FAIL|%s' % type(error).__name__], 1
    name = 'health-%s-%d.txt' % (mode, int(time.time()))
    (workdir(txn_id) / name).write_text('\n'.join(lines) + '\n')
    return failed, lines


def failed_checks(lines):
    return [line.split('|')[0] for line in lines if line.count('|') >= 3 and line.split('|')[2] == 'FAIL']


def rollback(store, txn_id, rp_id, at_boot=False, who='executor'):
    """Restore and re-check the old version. Returns ROLLED_BACK, RECOVERY_FAILED, or None at boot."""
    context = load_context(txn_id)
    try:
        if rp_id is None:
            # Stopped before the recovery point existed: nothing in Nagios was changed yet.
            if at_boot:
                update_txn(store, txn_id, who, step='restore.files-restored')
            else:
                update_txn(store, txn_id, who, step='restore.start')
                start_services()
        else:
            if (RP_ROOT / rp_id / 'nagios').exists() and not verify_recovery_point(store, rp_id):
                raise RecoveryError('recovery point %s does not verify' % rp_id)
            restore(store, txn_id, rp_id, at_boot, who)
    except (RecoveryError, OSError, ValueError, subprocess.SubprocessError) as error:
        return recovery_failed(store, txn_id, who, 'RESTORE_FAILED', str(error))
    if at_boot:
        say('Files restored from %s; the health suite runs after Nagios starts.' % rp_id)
        return None
    return finish_rollback(store, txn_id, who, context)


def finish_rollback(store, txn_id, who, context):
    started = time.time()
    failed, lines = run_health(txn_id, 'compare', context, since=started - 5)
    if failed:
        return recovery_failed(store, txn_id, who, 'HEALTH_AFTER_RESTORE', ','.join(failed_checks(lines)))
    transition(store, txn_id, 'rolled_back', who, recovery_status='restored and healthy')
    say('Rolled back: the previous version is restored and passes the critical health checks.')
    return ROLLED_BACK


def recovery_failed(store, txn_id, who, code, detail):
    transition(store, txn_id, 'recovery_failed', who, failure_code=code, recovery_status=detail[:500])
    say('CRITICAL: recovery failed (%s: %s).' % (code, detail))
    say('Nothing more is done automatically. The failed tree, the recovery copy and logs are kept in %s '
        'and %s. Follow "When recovery fails" in the runbook.' % (RP_ROOT, workdir(txn_id)))
    return RECOVERY_FAILED


##################################################
# Drill
##################################################

def inject(fault, rp_id):
    """Break the live installation the way a bad update would (staging only)."""
    if fault in ('config', 'corrupt'):
        with open(NAGIOS / 'etc/nagios.cfg', 'a', encoding='utf-8') as f:
            f.write(DRILL_FAULT_LINE)
    if fault == 'service':
        os.chmod(NAGIOS / 'bin/nagios', 0)
    if fault == 'plugin':
        (NAGIOS / 'libexec/check_ping').write_text('#!/bin/sh\necho "PinPoint drill: broken plugin"\nexit 3\n')
    if fault == 'corrupt':
        with open(RP_ROOT / rp_id / 'nagios/etc/cgi.cfg', 'a', encoding='utf-8') as f:
            f.write('# PinPoint drill: damaged recovery copy\n')


def preflight(store, txn_id, context):
    problems = []
    if not (NAGIOS / 'bin/nagios').is_file() or not context.get('version'):
        problems.append('Nagios Core is not installed or its version cannot be read.')
    RP_ROOT.mkdir(mode=0o700, exist_ok=True)
    if os.stat(str(NAGIOS)).st_dev != os.stat(str(RP_ROOT)).st_dev:
        problems.append('%s and %s are on different filesystems.' % (NAGIOS, RP_ROOT))
    need = 2 * tree_size(NAGIOS) + SPACE_MARGIN
    free = shutil.disk_usage(str(RP_ROOT)).free
    if free < need:
        problems.append('Not enough free space: %d MB free, %d MB needed.' % (free >> 20, need >> 20))
    if not problems:
        failed, lines = run_health(txn_id, 'save', context)
        if failed:
            problems.append('The system is not healthy before the change: %s.' % ', '.join(failed_checks(lines)))
    return problems


def drill(store, fault=None, crash_after_apply=False):
    manifest = pu.load_manifest()
    found = pu.scan()
    source = store.installed_manifest() or manifest['manifest_id']
    lock = take_lock()
    if lock is None:
        say('BUSY: another update, drill or PinPoint web deployment is running.')
        return BUSY
    if active_txn(store):
        say('BUSY: transaction %s is not finished. Run: pinpoint-update-exec reconcile' % active_txn(store)[0])
        return BUSY
    txn_id = new_txn(store, 'drill', source, source)
    context = {'version': found['nagios-core']['version'], 'ncpa_sha256': found['check-ncpa']['sha256'],
               'fault': fault}
    save_context(txn_id, context)
    say('Drill %s: %s' % (txn_id, 'injected fault "%s"' % fault if fault else 'copy and restore, no fault'))

    say('[1/5] Preflight and baseline health checks...')
    problems = preflight(store, txn_id, context)
    if problems:
        transition(store, txn_id, 'blocked', failure_code='PREFLIGHT_FAILED', recovery_status=' '.join(problems))
        for problem in problems:
            say('  ' + problem)
        say('Blocked: nothing was changed.')
        return PREFLIGHT_FAILED
    transition(store, txn_id, 'staging')

    ignore_interrupts()
    transition(store, txn_id, 'applying', started_at=pu.now())
    say('[2/5] Stopping PinPoint web and Nagios, creating the recovery point...')
    down = time.time()
    rp_id = None
    try:
        update_txn(store, txn_id, step='apply.stop')
        stop_services()
        update_txn(store, txn_id, step='apply.recovery-point')
        rp_id = create_recovery_point(store, txn_id)
        update_txn(store, txn_id, recovery_point_id=rp_id, step='apply.change')
        rp_seconds = time.time() - down
        say('  %s created and verified in %.1fs.' % (rp_id, rp_seconds))
        if fault:
            inject(fault, rp_id)
    except (OSError, RecoveryError, subprocess.SubprocessError) as error:
        say('  Could not prepare the change: %s' % error)
        transition(store, txn_id, 'rolling_back', failure_code='APPLY_FAILED')
        return rollback(store, txn_id, rp_id)
    if crash_after_apply:
        say('Stopping here on purpose (--crash-after-apply). Run "pinpoint-update-exec reconcile" or reboot.')
        os._exit(RECOVERY_FAILED)
    update_txn(store, txn_id, step='apply.start')
    started = time.time()
    try:
        start_services()
    except subprocess.SubprocessError:
        pass  # a service that will not start is what the health suite reports
    transition(store, txn_id, 'health_check')

    say('[3/5] Health checks after the change...')
    failed, lines = run_health(txn_id, 'compare', context, since=started - 5)
    detected = failed_checks(lines)
    say('  %s' % ('failed: ' + ', '.join(detected) if failed else 'all critical checks pass'))

    say('[4/5] Restoring the recovery point...')
    transition(store, txn_id, 'rolling_back', failure_code='HEALTH_FAILED' if failed else None)
    restore_start = time.time()
    result = rollback(store, txn_id, rp_id)
    restore_seconds = time.time() - restore_start
    downtime = int(time.time() - down)
    with store.db:
        store.db.execute('UPDATE txn SET downtime_seconds = ? WHERE txn_id = ?', (downtime, txn_id))
        if result == ROLLED_BACK:
            store.db.execute('UPDATE recovery_point SET restore_tested = ? WHERE rp_id = ?', (pu.now(), rp_id))
        store.audit('drill.finished', {'fault': fault, 'detected': detected, 'result': result,
                                       'recovery_point_seconds': round(rp_seconds, 1),
                                       'restore_seconds': round(restore_seconds, 1), 'downtime_seconds': downtime},
                    txn_id=txn_id, who='executor')
    if result == ROLLED_BACK:
        shutil.rmtree(str(RP_ROOT / rp_id / 'failed'), ignore_errors=True)

    say('[5/5] Result')
    say('  Recovery point: %.1fs   Restore and health checks: %.1fs   Downtime: %ds'
        % (rp_seconds, restore_seconds, downtime))
    if result != ROLLED_BACK:
        return result
    if fault and not failed:
        say('  DRILL FAILED: the injected fault was not detected by the health suite.')
        return DRILL_FAULT_MISSED
    say('  DRILL PASSED: %s' % ('the fault was detected and rolled back.' if fault
                                else 'the installation was copied, restored and is healthy.'))
    return OK


##################################################
# Reconcile
##################################################

def reconcile(store, mode):
    """Finish an interrupted transaction toward the previous version (plan 7.2).

    mode 'now'    : by hand or after a killed executor; may stop and start services.
    mode 'boot'   : before nagios.service at boot; restores files only.
    mode 'finish' : after the services started at boot; runs the health suite.
    """
    row = active_txn(store)
    if row is None:
        return OK
    txn_id, state, step, rp_id = row
    who = 'reconcile'
    if mode == 'finish':
        if state == 'rolling_back' and step == 'restore.files-restored':
            return finish_rollback(store, txn_id, who, load_context(txn_id))
        return OK
    say('Reconciling %s (state %s, last step %s).' % (txn_id, state, step))
    if state in ('preparing', 'staging'):
        shutil.rmtree(str(pu.STATE_DIR / 'build' / txn_id), ignore_errors=True)
        transition(store, txn_id, 'failed', who, failure_code='INTERRUPTED',
                   recovery_status='stopped before Nagios was changed')
        if mode == 'now':
            start_services()
        say('Marked failed: it stopped before anything was changed.')
        return OK
    if state == 'approved':
        return OK  # no approvals before Phase 3
    if state in ('applying', 'health_check'):
        transition(store, txn_id, 'rolling_back', who, failure_code='INTERRUPTED')
    return rollback(store, txn_id, rp_id, at_boot=(mode == 'boot'), who=who) or OK


def main(argv=None):
    global pu
    parser = argparse.ArgumentParser(prog='pinpoint-update-exec',
                                     description='PinPoint update executor: recovery points, drills, reconcile.')
    sub = parser.add_subparsers(dest='command', required=True)
    d = sub.add_parser('drill', help='copy, optionally break, and restore Nagios on a staging appliance')
    d.add_argument('--inject', choices=FAULTS, help='fault to inject after the recovery point (staging only)')
    d.add_argument('--crash-after-apply', action='store_true',
                   help='stop after the change, as if the executor was killed or the power failed')
    d.add_argument('--yes', action='store_true', help='confirm that Nagios and PinPoint web may stop')
    r = sub.add_parser('reconcile', help='finish an interrupted transaction toward the previous version')
    r.add_argument('--boot', action='store_true', help='at boot, before nagios.service: restore files only')
    r.add_argument('--finish', action='store_true', help='at boot, after the services: run the health suite')
    sub.add_parser('verify', help='check every recorded recovery point that is still on disk')
    args = parser.parse_args(argv)
    if os.geteuid() != 0:
        print('pinpoint-update-exec must be run as root.', file=sys.stderr)
        return NOT_AUTHORISED
    pu = pu or load_controller()
    store = pu.Store()
    try:
        if args.command == 'drill':
            if not args.yes:
                print('A drill stops Nagios and PinPoint web for several minutes. Run it on a staging '
                      'appliance only, and add --yes to confirm.', file=sys.stderr)
                return PREFLIGHT_FAILED
            return drill(store, args.inject, args.crash_after_apply)
        if args.command == 'reconcile':
            if args.boot and args.finish:
                parser.error('choose --boot or --finish, not both')
            lock = take_lock()
            if lock is None:
                say('BUSY: another update, drill or PinPoint web deployment is running.')
                return BUSY
            return reconcile(store, 'boot' if args.boot else 'finish' if args.finish else 'now')
        broken = 0
        for rp_id, location in store.db.execute('SELECT rp_id, location FROM recovery_point ORDER BY created_at'):
            if (Path(location) / 'nagios').exists():
                good = verify_recovery_point(store, rp_id)
                broken += not good
                print('%s %s' % (rp_id, 'verified' if good else 'DOES NOT VERIFY'))
        return OK if not broken else RECOVERY_FAILED
    except InvalidTransition as error:
        say('Invalid transition: %s' % error)
        return INVALID_TRANSITION
    finally:
        store.close()


if __name__ == '__main__':
    sys.exit(main())
