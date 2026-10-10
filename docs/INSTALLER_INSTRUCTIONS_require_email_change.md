# Installer Instructions: Require a Real Admin Email on First Login

For the installer maintainer. Source plan: `SMTP_Admin_Email_Plan.md` (PinPoint repo).

The installer creates the administrator with a placeholder email (`admin-xxxxx@pinpoint.lan`).
PinPoint now makes that administrator replace it with a real, deliverable address at first
sign-in, so Nagios notification emails can reach a real inbox.

Everything goes through the PinPoint CLI. The installer never writes to the database.

## Phase 3: request the email gate (`setup/deploy-pinpoint-web.sh`)

| # | Change | Why |
|---|---|---|
| 1 | Pass `--require-email-change` to `flask init-production`. | Sets `Must_Change_Email` on the new administrator. |
| 2 | Before creating the database on a new install, check that `flask init-production --help` lists `--require-email-change`. If not, stop with: `Step 9/12: this PinPoint version has no 'flask init-production --require-email-change'.` | The check runs before the database exists. A re-run sees an existing database and skips admin creation, so failing later would leave an install with no administrator. |
| 3 | Delete the inline-Python fallback that created the admin directly. | It cannot set `Must_Change_Email`, and every install now uses a PinPoint release that has the command. |
| 4 | After creation, read the database and confirm `Must_Change_Email` is true for the new administrator. Pass only the email to that check, never the password. | Detects a silent regression. |
| 5 | Keep `ADMIN_EMAIL_DOMAIN="pinpoint.lan"` and comment that it must match the server's reserved domain. | The server rejects that domain as a real email, so both sides must agree. |
| 6 | Change the credentials file to label the username a temporary placeholder and tell the operator they will be asked for a real email at first sign-in. | Without this the operator would not know why the login changes. |

Existing installs: no administrator is created, so nothing is gated. The migration defaults
the flag to false.

## Acceptance test (fresh Ubuntu 22.04 VM)

1. Run the installer. A PinPoint release without the option must stop at step 9/12 with the
   message above, before `system.db` exists.
2. With a current release, install completes and logs
   `Administrator must set a real email at first sign-in.`
3. Sign in with the placeholder from the credentials file. The "Set your email" screen appears
   and every other page is blocked.
4. Enter a real email, confirm it and the current password. The app opens.
5. The `define contact` line in `/usr/local/nagios/etc/objects/hosts.cfg` carries the new
   address, not `pinpoint.lan`.
6. Signing in with the placeholder no longer works; the new address does.

## Phase 4 (separate branch, not part of this change)

msmtp and `bsd-mailx`, `/etc/msmtprc`, the root-owned Python helper
`/usr/local/sbin/pinpoint-apply-smtp` and its single-command sudoers rule, all in
`setup/configure-pinpoint-privileges.sh`. The helper reads settings on stdin, validates them,
and writes `/etc/msmtprc` mode 640 `root:nagios`. Do not install `mailutils` (it can pull in
Postfix).
