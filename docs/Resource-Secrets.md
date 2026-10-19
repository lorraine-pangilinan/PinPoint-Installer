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


## Installing and updating

`setup/install-resource-helper.sh` installs the helper (`root:root 0755`) and
the sudoers rule `/etc/sudoers.d/pinpoint-apply-resources` (`root:root 0440`).
It is idempotent and is run by both `configure-pinpoint-privileges.sh` (new
installs) and `deploy-pinpoint-web.sh` (every install and upgrade), before the
application restarts. A server installed before the helper existed therefore
gets it when it is updated with the deploy script. If the helper cannot be
installed, the deploy script stops with an error and an in-progress upgrade is
rolled back.

After installing, the script tests the grant as `pinpoint`: `sudo -n -l` lists
the exact rule (and refuses extra arguments and any other command), a no-op
request (the unchanged block) is accepted, and a request with a wrong digest is
refused. Request contents are never printed. The helper itself still prints one
fixed line on any failure.

Custom-check key comments accept `custom_check:<id>:<field>` where the field
matches `[A-Za-z0-9_.-]+`, because the application does not restrict field names.

On a Linux test VM, `tests/resource-helper-update-tests.sh` removes the helper,
runs the deploy script twice and checks installation, idempotence, ordering and
the helper's accept/reject behaviour.

Isolated checks (no sudo or installed config changes):

```bash
python3 -m unittest discover -s tests -p test_resource_helper.py
bash -n setup/configure-pinpoint-privileges.sh scripts/build.sh
```

The helper from commit 15c27d1 is installed on the existing QA appliance with
its exact sudo grant. The application client passed writes, external/metadata
preservation, validation and byte-exact rollback as pinpoint. Packaging script
syntax passes; a complete ISO build and full generated-config live apply/reload
remain unverified. Both repositories require their paired changes on production
upgrade. Custom resource paths are unsupported by this fixed
helper and must fail safely rather than updating a different file.
