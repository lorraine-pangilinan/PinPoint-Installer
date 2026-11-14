# Catalog test fixtures

Used by `tests/update-install-tests.sh` on a staging VM, which points `updater.conf` at these folders
on the branch under test. Each one must be refused, with nothing written and nothing changed:

| Folder | What is wrong | Expected |
|---|---|---|
| `bad-digest/` | The manifest's bytes do not match the SHA-256 in `index.json` (a tampered file) | `discover` exits 7, the manifest is not recorded |
| `changed/` | `index.json` lists `pp-mon-baseline-1` with a different digest than the one the appliance recorded | `discover` exits 7; a changed manifest needs a new ID |
