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

## Phase 4: mail transport (`setup/configure-pinpoint-privileges.sh`, step 8/9)

| # | Change | Why |
|---|---|---|
| 1 | Install `msmtp-mta` and `bsd-mailx` with `--no-install-recommends`. Never `mailutils` (it can pull in Postfix). | Nagios' `notify-*-by-email` commands in `/usr/local/nagios/etc/objects/commands.cfg` pipe each message to `/bin/mail`, which does not exist by default. No change to `commands.cfg` is needed. |
| 2 | Create `/etc/msmtprc` as `root:nagios 640`, and keep its content on a re-run. | Nagios runs `mail`, so it must read the file. Nobody else may; it holds the SMTP password. |
| 3 | Install the root-owned Python helper `/usr/local/sbin/pinpoint-apply-smtp` (755). | The web interface runs unprivileged and cannot write `/etc`. |
| 4 | Add `/etc/sudoers.d/pinpoint-apply-smtp`: `pinpoint ALL=(root) NOPASSWD: /usr/local/sbin/pinpoint-apply-smtp ""`. | Lets PinPoint run only that helper, with no arguments. |
| 5 | Extend the verification step (now 9/9) to check the above, including that `pinpoint` cannot write `/etc/msmtprc` and has no other new sudo rights. | Catches a wrong mode or rule at install time. |

Helper input contract, for the PinPoint server to build against. One JSON object on **stdin**
(never arguments), exactly these fields, nothing else:

```json
{"host": "smtp.gmail.com", "port": 587, "tls": "starttls",
 "username": "you@gmail.com", "password": "<app password>", "sender": "you@gmail.com"}
```

- `tls`: `starttls` (port 587) or `ssl` (port 465). `none` is refused: the login is always
  sent, so an unencrypted connection would expose the password.
- `username` and `password`: any printable ASCII character, spaces included, so the admin can
  choose freely. Control characters and non-ASCII are rejected. The helper writes both inside
  double quotes, which msmtp removes as one outer pair (tested with spaces, `#`, quotes and
  backslashes). Gmail shows app passwords with spaces; Gmail expects them as 16 letters.
- Input over 4 KiB, duplicate or extra fields, wrong types, or a newline anywhere are rejected.
- Exit codes: `0` applied, `1` rejected input (reason on stderr, never the password), `2`
  misuse (arguments given, or not run as root). The server should show stderr in the card.
- Run it as `sudo -n /usr/local/sbin/pinpoint-apply-smtp`. The password also exists in plain
  text in `/etc/msmtprc` (msmtp needs it), readable only by root and `nagios`.

Messages are sent through syslog (`journalctl -t msmtp`); msmtp does not retry.
