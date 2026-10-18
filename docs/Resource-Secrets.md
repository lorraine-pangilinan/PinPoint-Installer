# Restricted Nagios resource writer

The installer installs `/usr/local/sbin/pinpoint-apply-resources` as root:root
0755. Its `/usr/bin/python3 -I` interpreter uses only the standard library;
no application-owned code is imported while privileged. An exact sudoers rule
allows `pinpoint` to run this helper with no arguments. No generic chown,
shell, interpreter or directory privileges are added.

The helper accepts JSON on stdin with exactly `resource_path`, `outside_digest`
and `block`. The path is an assertion that must match the fixed
`/usr/local/nagios/etc/resource.cfg`; it cannot select another destination.
The digest is SHA256 of compact JSON `[before, after]` containing the two
regions outside the exact owned markers. The helper reads those regions itself,
rejects a changed digest, and never accepts replacement external content.
`block` contains the complete owned markers, managed USER2..USER256 values and
optional key comments. Null removes the block for rollback. Duplicate slots,
external-slot collisions, unknown directives and unsafe values are refused.

The existing file must be regular, nagios:nagios and 0660. Replacement and
rollback retain that metadata. Private staging directories on the same
filesystem protect temporary files even when the Nagios directory is writable
by the application group. A root-owned `/run/pinpoint-resource.lock` serializes
helper requests; the application must also hold its shared config lock through
generation, validation and apply/rollback. Errors contain no request content.

## Installation and upgrades

`setup/install-resource-helper.sh` is the single installation step used by both
`configure-pinpoint-privileges.sh` (fresh-install privileges) and
`deploy-pinpoint-web.sh` (including web-only upgrades, before Gunicorn restarts).
It requires the existing `pinpoint` account and sudo tooling. It validates the
exact no-argument sudoers rule before installing either file, installs root-owned
files with modes 0755/0440, and checks the effective sudo policy without writing
any resource data. Re-running it is supported. It does not change `resource.cfg`
or restart a service. A failed application upgrade can leave this compatible
helper installed; the helper grants no additional general commands.

Copy the complete `setup/` directory for installed upgrades; the web deploy script
checks both companions before package/application updates. ISO staging includes
the shell installer through `setup/*.sh` and explicitly includes the Python helper.
An older ISO's own scripts cannot acquire a patch they never contained: refresh
the installer files before upgrading or applying the narrow repair.

To repair just this missing dependency on an existing server, place both
`install-resource-helper.sh` and `pinpoint-apply-resources.py` from this release in
the same root-controlled directory, then run the shell script as root and retry
the failed configuration/plugin action. Do not make `resource.cfg` world-readable
or give Pinpoint generic sudo/chown access.

## Tests

Isolated checks (no sudo or installed config changes):

```bash
python3 -m unittest discover -s tests -p 'test_resource*.py'
bash -n setup/install-resource-helper.sh setup/configure-pinpoint-privileges.sh setup/deploy-pinpoint-web.sh scripts/build.sh tests/resource-helper-vm-tests.sh
```

Installed integration checks, **only on a disposable Pinpoint appliance**:

```bash
sudo bash tests/resource-helper-vm-tests.sh
```

This installs the repair, rebuilds/applies the current application configuration,
checks real sudo restrictions and Nagios validation, and leaves the repair
installed. It stores private pre-test configuration/helper copies under
`/var/backups/pinpoint-resource-test.*`; it does not snapshot or restore databases.
Keep a VM snapshot for broader rollback. See the [test report](../tests/resource-helper-tests-Result.md)
for what was observed and the untested full-ISO/web-rebuild paths.

The application integration and installer must be upgraded together. Custom
resource paths are unsupported by this fixed helper and must fail safely rather
than updating a different file.
