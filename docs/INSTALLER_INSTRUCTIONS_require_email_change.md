# Installer Instructions: Require a Real Admin Email on First Login

For the installer maintainer. Source plan: `SMTP_Admin_Email_Plan.md` (PinPoint repo).

The installer creates the administrator with a placeholder email (`admin-xxxxx@pinpoint.lan`).
PinPoint already makes that administrator replace it, and choose a new password, at first
sign-in, so Nagios notification emails can reach a real inbox. The installer does not add this
behaviour; it relies on it and checks that it is in place.

**What PinPoint provides (already merged in the PinPoint repo, not part of this repo):**
`flask init-production` always creates the administrator with `Needs_Setup=True`. While that is
set, the API refuses everything except login, logout, `/me` and `POST /api/user/complete-setup`,
and the web app shows the `FirstRunSetup` screen. `complete-setup` takes the current password,
a real email (it rejects `@pinpoint.lan` and reserved domains such as `.lan`) and a new
password, then clears the flag and regenerates the Nagios contact.

The earlier plan (`--require-email-change`, `Must_Change_Email`, `PATCH /api/user/me/email`) was
never built and must not be used; PinPoint has no such option.

Everything goes through the PinPoint CLI. The installer never writes to the database.

## Phase 3: rely on first-run setup (`setup/deploy-pinpoint-web.sh`)

| # | Change | Why |
|---|---|---|
| 1 | Call `flask init-production --admin-email ... --password-stdin` with no extra option. | `init-production` already sets `Needs_Setup`. |
| 2 | Before creating the database on a new install, import `User` and require `User.Needs_Setup` to exist. If not, stop with: `Step 9/12: this PinPoint version has no first-run setup (User.Needs_Setup)...` | The check runs before the database exists. A re-run sees an existing database and skips admin creation, so failing later would leave an install with no administrator. |
| 3 | Delete the inline-Python fallback that created the admin directly. | It did not set `Needs_Setup`, so it would create an ungated administrator. |
| 4 | After creation, read the database and confirm `Needs_Setup` is true for the new administrator. Pass only the email to that check, never the password. | Detects a later change in PinPoint that stops forcing the setup. |
| 5 | Keep `ADMIN_EMAIL_DOMAIN="pinpoint.lan"` and comment that it must match the server's `PLACEHOLDER_EMAIL_DOMAIN`. | The server rejects that domain as a real email, so both sides must agree. |
| 6 | The credentials file labels the username a temporary placeholder and says the operator will be asked for a real email **and a new password** at first sign-in. | The operator would otherwise not know why the login stops working. |
| 7 | A repository left by a failed first install is cloned again, not treated as an upgrade (only a service file or a database makes it an upgrade). | Avoids a misleading `Rollback could not restart pinpoint-gunicorn`. |

Existing installs: no administrator is created, so nothing changes for them.

## Acceptance test (fresh Ubuntu 22.04 VM)

Automated by `tests/smtp-admin-email-tests.sh` (cases A3-A7, P1, B1-B9, A10-A11).

1. Run the installer. It completes and logs
   `Administrator must complete first-run setup (real email and new password).`
2. Exactly one user exists, with the placeholder email and `Needs_Setup=1`.
3. Sign in with the placeholder from the credentials file. Every other API returns 403.
4. `complete-setup` refuses the placeholder and reserved domains, a wrong current password, a
   mismatching, weak or unchanged password.
5. `complete-setup` with a real email and a strong new password succeeds. The old placeholder
   login fails and the new one works.
6. `configure-pinpoint-privileges.sh` has run, so PinPoint can write `hosts.cfg`. The `define
   contact` lines in `/usr/local/nagios/etc/objects/hosts.cfg` carry the new address and
   `nagios -v` reports no errors.

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

- `tls`: must be `starttls` (use port 587, which is what Gmail expects). `none` and `ssl` are
  refused: the login is always sent, so an unencrypted connection would expose the password.
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
