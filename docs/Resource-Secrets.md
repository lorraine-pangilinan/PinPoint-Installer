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
