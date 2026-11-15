#!/usr/bin/python3 -I
"""Check every manifest in catalog/manifests/ and write catalog/index.json.

Run by the release team before committing a new or revoked update set:

    python3 scripts/catalog-index.py            # check and write the index
    python3 scripts/catalog-index.py --check    # only check; exit 1 if the index is out of date
    python3 scripts/catalog-index.py --revoke pp-mon-2026.11-1

Each manifest is checked with the same rules the appliances use
(setup/pinpoint-update.py check_manifest). A manifest already listed in the
index may not change: appliances refuse a changed manifest, so publish a new
manifest ID instead. Revoked IDs stay revoked.
"""
import argparse
import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parents[1]
CATALOG = REPO / 'catalog'
INDEX = CATALOG / 'index.json'


def controller():
    loader = importlib.machinery.SourceFileLoader('pinpoint_update', str(REPO / 'setup/pinpoint-update.py'))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


def build(pu, old, revoke):
    listed = {e['manifest_id']: e['sha256'] for e in old.get('manifests', [])}
    entries, problems = [], []
    for path in sorted((CATALOG / 'manifests').glob('*.json')):
        raw = path.read_bytes()
        try:
            body = pu.check_manifest(json.loads(raw))
            if path.name != body['manifest_id'] + '.json':
                raise ValueError('file name does not match manifest_id %s' % body['manifest_id'])
            if b'\r' in raw:
                raise ValueError('CRLF line endings; save the file with LF endings')
        except ValueError as error:
            problems.append('%s: %s' % (path.name, error))
            continue
        digest = hashlib.sha256(raw).hexdigest()
        if listed.get(body['manifest_id'], digest) != digest:
            problems.append('%s changed after it was published; publish a new manifest ID instead' % path.name)
        entries.append({'manifest_id': body['manifest_id'], 'sha256': digest})
    for mid in set(listed) - {e['manifest_id'] for e in entries}:
        problems.append('%s is in the index but its file is missing; revoke it instead of deleting it' % mid)
    revoked = sorted(set(old.get('revoked', [])) | set(revoke))
    return {'schema_version': 1, 'manifests': entries, 'revoked': revoked}, problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--check', action='store_true', help='do not write; exit 1 if the index is out of date')
    parser.add_argument('--revoke', action='append', default=[], metavar='MANIFEST_ID')
    args = parser.parse_args()
    pu = controller()
    old = json.loads(INDEX.read_text()) if INDEX.exists() else {}
    index, problems = build(pu, old, args.revoke)
    for problem in problems:
        print('ERROR: ' + problem, file=sys.stderr)
    if problems:
        return 1
    pu.check_index(index)
    text = json.dumps(index, indent=2) + '\n'
    if args.check:
        same = INDEX.exists() and INDEX.read_text() == text
        print('index.json is %s.' % ('up to date' if same else 'OUT OF DATE: run scripts/catalog-index.py'))
        return 0 if same else 1
    INDEX.write_bytes(text.encode())
    for entry in index['manifests']:
        print('%-24s %s' % (entry['manifest_id'], entry['sha256']))
    print('Revoked: %s' % (', '.join(index['revoked']) or 'none'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
