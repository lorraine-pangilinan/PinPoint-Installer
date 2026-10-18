#!/usr/bin/python3 -I
"""Privileged fixed-destination writer for Pinpoint's Nagios resource block.

Accept exactly resource_path (an assertion, never a selected destination),
outside_digest and block on stdin. A null block removes the owned block for
rollback. Read and preserve all external bytes ourselves. No mutable app
imports, command execution, arbitrary destinations or caller-selected owners.
"""
import fcntl
import grp
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import stat
import sys
import tempfile

CONFIG = '/usr/local/nagios/etc/resource.cfg'
LOCK = '/run/pinpoint-resource.lock'
MAX_BYTES = 1024 * 1024
BEGIN, END = '# BEGIN PINPOINT', '# END PINPOINT'
FORBIDDEN = frozenset("'\"`!$;\\\n\r\0")


class Rejected(Exception):
    """Invalid request; details must never echo supplied content."""


def split_resource(text):
    """Split an exact unique owned block without changing any byte outside it."""
    starts, ends, offset = [], [], 0
    for line in text.splitlines(keepends=True):
        if line.rstrip('\r\n') == BEGIN: starts.append(offset)
        if line.rstrip('\r\n') == END: ends.append(offset + len(line))
        offset += len(line)
    if not starts and not ends: return text, None, ''
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]: raise Rejected()
    return text[:starts[0]], text[starts[0]:ends[0]], text[ends[0]:]


def outside_digest(before, after):
    """Hash the two external regions without transmitting their contents."""
    return hashlib.sha256(json.dumps([before, after], separators=(',', ':')).encode()).hexdigest()


def validate_block(block, outside):
    """Accept only bounded managed slots and key comments, never directives."""
    if block is None: return
    if not isinstance(block, str) or len(block.encode()) > MAX_BYTES: raise Rejected()
    lines = block.splitlines()
    if not lines or lines[0] != BEGIN or lines[-1] != END: raise Rejected()
    slots, keys, metadata = set(), set(), set()
    for line in lines[1:-1]:
        if not line: continue
        match = re.fullmatch(r'\$USER([0-9]+)\$=(.*)', line)
        if match:
            slot, value = int(match[1]), match[2]
            if not 2 <= slot <= 256 or slot in slots or not value or len(value) > 4096: raise Rejected()
            if any(char in FORBIDDEN or ord(char) < 32 for char in value): raise Rejected()
            slots.add(slot)
            continue
        match = re.fullmatch(r'# PINPOINT KEY (.+) \$USER([0-9]+)\$', line)
        if not match: raise Rejected()
        key, slot = json.loads(match[1]), int(match[2])
        if not isinstance(key, str) or not re.fullmatch(r'(?:ncpa_token:[0-9]+|custom_check:[0-9]+:[a-z_]+)', key): raise Rejected()
        if key in keys or slot in metadata or not 2 <= slot <= 256: raise Rejected()
        keys.add(key); metadata.add(slot)
    if not metadata <= slots: raise Rejected()
    reserved = {int(value) for value in re.findall(r'^\s*\$USER([0-9]+)\$\s*=', outside, re.M)}
    if slots & reserved: raise Rejected()


def apply(request):
    """Atomically apply a validated owned block, preserving configured metadata."""
    if not isinstance(request, dict) or set(request) != {'resource_path', 'outside_digest', 'block'}: raise Rejected()
    if request['resource_path'] != CONFIG: raise Rejected()
    path = Path(CONFIG)
    parent_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    stage_fd, stage_name = None, None
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        with os.fdopen(fd, 'rb') as stream:
            original = os.fstat(stream.fileno())
            if not stat.S_ISREG(original.st_mode) or stat.S_IMODE(original.st_mode) != 0o660: raise Rejected()
            if (original.st_uid, original.st_gid) != (pwd.getpwnam('nagios').pw_uid, grp.getgrnam('nagios').gr_gid): raise Rejected()
            data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES: raise Rejected()
        before, old_block, after = split_resource(data.decode('utf-8'))
        if outside_digest(before, after) != request['outside_digest']: raise Rejected()
        validate_block(request['block'], before + after)
        if before and not before.endswith('\n') and request['block'] is not None: raise Rejected()
        if after and request['block'] is not None and not request['block'].endswith('\n'): raise Rejected()
        contents = (before + (request['block'] or '') + after).encode()
        if len(contents) > MAX_BYTES: raise Rejected()
        if contents == data: return
        # Use a private directory on the same filesystem. A caller with group
        # write on Nagios's directory cannot swap the staged file after chown.
        stage_path = tempfile.mkdtemp(prefix='.pinpoint-resource-stage-', dir=path.parent)
        stage_name = Path(stage_path).name
        stage_fd = os.open(stage_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        stage_stat = os.fstat(stage_fd)
        if stage_stat.st_uid != os.geteuid() or stat.S_IMODE(stage_stat.st_mode) != 0o700: raise Rejected()
        fd = os.open('resource', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=stage_fd)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(contents); stream.flush()
            os.fchown(stream.fileno(), original.st_uid, original.st_gid)
            os.fchmod(stream.fileno(), 0o660)
            os.fsync(stream.fileno())
        os.replace('resource', path.name, src_dir_fd=stage_fd, dst_dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        if stage_fd is not None:
            try: os.unlink('resource', dir_fd=stage_fd)
            except FileNotFoundError: pass
            # Remove only the directory we opened, if still at its original name.
            try:
                current = os.stat(stage_name, dir_fd=parent_fd, follow_symlinks=False)
                opened = os.fstat(stage_fd)
                if (current.st_dev, current.st_ino) == (opened.st_dev, opened.st_ino): os.rmdir(stage_name, dir_fd=parent_fd)
            except FileNotFoundError: pass
            os.close(stage_fd)
        os.close(parent_fd)


def main():
    """Serialize privileged requests; emit only a fixed safe success/failure."""
    try:
        if len(sys.argv) != 1 or os.geteuid() != 0: raise Rejected()
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES: raise Rejected()
        request = json.loads(raw)
        fd = os.open(LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'rb') as lock:
            info = os.fstat(lock.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600: raise Rejected()
            fcntl.flock(lock, fcntl.LOCK_EX)
            apply(request)
        return 0
    except Exception:
        print('pinpoint-apply-resources: request rejected or update failed.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
