# Resource helper installation and web-upgrade regression

Date: 2026-10-19 (Asia/Manila; VM journal timestamps 2026-10-18 UTC).
Executor: Codex, scripted local checks and SSH on the user's disposable second
Pinpoint appliance. User authorized investigation, tests and a fork/PR.

## Versions and scope

- Initial investigation used the user's linked fork at `697869e01819c6e0925152d3033947567821f7de`.
- After the user corrected the repository, upstream `lorraine-pangilinan/PinPoint-Installer`
  main `86381cea131c1ef5cc658cbe458393e04877c677` was fetched and inspected. It also
  lacks the helper, sudoers installation and web-upgrade dependency step. This PR
  is based on that current upstream main and preserves its newer unrelated changes.
- The 14 isolated tests and shell syntax checks were rerun on the upstream-based
  branch. The shared installer, Python helper and installed VM harness are byte-identical
  to the versions already exercised on the real guest; the full upstream installer
  was not rerun on the VM.
- Reused restricted-writer implementation: upstream PR 7, through
  `b166953d2e7e5b4bae12bf723712224cc97fae94`, with the upgrade integration and tests
  in this PR. The user's fork already existed; no additional fork was created.
- Installed application: `65a5862c375dd7dfe1dd98433ca017dc4efe0cec` (read from the VM's checkout).
- Actual guest: Ubuntu 22.04.5 LTS, service account `pinpoint`, real Nagios and
  system sudo. No mocked sudo was used for the installed tests.
- Raw diagnostic logs and private pre-repair copies remain on the appliance under
  `/root/pinpoint-resource-234/`; the repeatable integration harness wrote its
  own private backup directory under `/var/backups/pinpoint-resource-test.*`.
  Credentials, resource contents and private addresses are omitted here.

## Root cause

The fork's main branch did not package or install the resource block writer or
its sudoers rule. The application enables the plugin in its database but needs
that helper to preserve Nagios-owned resource metadata when regenerating config.
The guest had `check_ncpa.py` and `resource.cfg` as `nagios:nagios 0660`, but neither
`/usr/local/sbin/pinpoint-apply-resources` nor its sudoers file existed. The app
journal showed sudo authentication failure for `pinpoint` during plugin enable.

An additional integration gap existed in the earlier helper patch: it only
installed the writer in the privileges module, whereas the documented web-only
upgrade runs `deploy-pinpoint-web.sh` by itself. This PR invokes the same shared
installer from both paths and detects missing companion files before updates.

## Observations

| Check | Result | Observed evidence |
|---|---|---|
| Upgrade integration regression, before fix | Fail as expected | Four new installation/packaging contracts failed against the earlier helper-only implementation |
| Isolated helper and upgrade contracts, after fix | Pass | `python3 -m unittest discover -s tests -p 'test_resource*.py'`: 14 tests |
| Shell syntax | Pass | New installer, privileges, web deploy, ISO build and installed-test harness all parse with `bash -n` |
| Reproduce installed application failure | Pass (defect reproduced) | `regenerate_and_apply_config_status()` as `pinpoint` returned `failed` and the exact known generic resource/configuration error before installing either dependency |
| Shared dependency install, two consecutive runs | Pass | Both returned success; helper `root:root 0755`, sudoers `root:root 0440` |
| Effective sudo policy and syntax | Pass | Installer's policy lookup succeeded; dedicated rule and complete sudoers validation passed |
| Extra helper argument | Pass | Actual `sudo -n ... unexpected` as `pinpoint` was denied |
| Invalid destination request | Pass | Actual no-argument helper rejected JSON asserting `/etc/sudoers` as its destination |
| Installed application config after repair | Pass | Same application generation function as `pinpoint` returned `applied`; no resource error |
| Repeatable installed harness | Pass | `tests/resource-helper-vm-tests.sh` ran from a root-owned copy of the new sources; repeated application generation returned `unchanged` |
| Incomplete repair package | Pass | Installer with its Python companion omitted failed; checksums of both existing installed files remained unchanged |
| Nagios and service checks | Pass | Native `nagios -v`: 0 warnings, 0 errors; Nagios and pinpoint-gunicorn both active |
| Resource metadata | Pass | Still `nagios:nagios 0660` after the successful apply and repeated checks |
| Whitespace | Pass | `git diff --check` |

The isolated helper tests cover owned-block update and rollback, preservation of
external bytes and metadata, duplicate slots/markers, external slot collisions,
malformed content, wrong path/owner/mode, symlink rejection, unknown request keys,
and replacement-failure cleanup. Four source-contract tests cover both installer
entry points, early companion detection, and ISO staging declarations.

## Restoration and limits

The repair is intentionally **left installed** on the disposable appliance.
Configuration was regenerated from its existing database; no account passwords,
NCPA agent installations or monitoring thresholds were changed. Private copies
of the prior resource and hosts configuration were saved before testing. The
harness does not perform a database/snapshot restore.

A full fresh ISO boot, complete web rebuild/upgrade with package installation,
and complete privileges-module rerun were **not** executed. The shared dependency
installer itself and the actual failing application generation/apply operation
were exercised on the real guest. The pipeline calls and ISO packaging are
covered by source contracts and shell syntax, not a full ISO execution. Metric
arrival, browser notification text and consistency of deployment result labels
were not assessed by these tests; the application-side issue remains
[Pinpoint #234](https://github.com/esfen14/Pinpoint/issues/234).
