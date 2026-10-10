# Installer Integration: Required Changes to Network-Diagnosis-System

## Purpose

The **PinPoint Installer** deploys this repository automatically onto a fresh Ubuntu Server that also runs Nagios Core. It clones `main` into `/opt/pinpoint/Network-Diagnosis-System`, builds `client/`, and runs `server/` under Gunicorn behind Nginx.

This document lists the changes needed in **this repository** so the installer can deploy it cleanly and upgrade it later. Everything here was checked against `main` at commit `c7e28e3`.

## How the installer runs the app

```text
LAN browser
    |
    v
Nginx :80
    |-- /       -> client/dist (built with `npm ci && npm run build`)
    |-- /api/   -> Gunicorn 127.0.0.1:8000 -> Flask (app:app)
                                                |
                                                +-> SQLite (server/system.db, server/history.db)
                                                +-> Nagios 127.0.0.1:8081
```

- Gunicorn runs from `server/` as the `pinpoint` system user, with 1 worker and 4 threads.
- Machine-specific settings come from `/etc/pinpoint/pinpoint.env`, never from the repository.
- Nagios's Apache site is moved to `127.0.0.1:8081` so Nginx can own port 80.
- The installer creates a dedicated Nagios API account and a random web administrator account on each server.

`client/` needs no changes. It calls the relative `/api` path, which Nginx forwards to Gunicorn.

---

## What already works

### Nagios address

`server/config.py` still defaults `NAGIOS_HOST` to `192.168.130.10`, but it reads the environment variable first. The installer currently writes:

```bash
NAGIOS_HOST=127.0.0.1:8081
```

which produces `http://127.0.0.1:8081/nagios/cgi-bin/statusjson.cgi`. The installer checks that this URL works at the end of every install.

This works because the port is packed into the host value. Change 1 below replaces that with separate settings.

---

## Required changes

Changes are listed in priority order.

### 1. `server/config.py`: remove machine-specific values

**Problem.** Several values only work in the development lab or are insecure in production:

| Setting | Current value | Problem |
|---|---|---|
| `NETWORKS` | `["192.168.130.0/24"]` | Hard-coded with no environment override. On any other LAN, network discovery scans the wrong subnet. |
| `NAGIOS_HOST` | `"192.168.130.10"` | Lab IP. There is no separate port setting. |
| `SECRET_KEY` | fallback string in source | Anyone who can read the repo can forge sessions if the environment variable is missing. |
| `NAGIOS_USERNAME` / `NAGIOS_PASSWORD` | `nagiosadmin` / `password` | Predictable defaults. |
| `DOMAIN` | `"test.local"` | Not configurable. |

**Change.** Read these values from the environment, use localhost defaults, and fail at startup when a secret is missing:

```python
def _env_list(name, default):
    value = os.environ.get(name)
    return [item.strip() for item in value.split(",") if item.strip()] if value else default

class Config:
    SECRET_KEY = os.environ.get("SECRET_KEY")  # no fallback

    NETWORKS = _env_list("PINPOINT_NETWORKS", ["192.168.130.0/24"])
    DOMAIN = os.environ.get("PINPOINT_DOMAIN", "test.local")

    NAGIOS_HOST = os.environ.get("NAGIOS_HOST", "127.0.0.1")
    NAGIOS_PORT = os.environ.get("NAGIOS_PORT", "80")

    # Accept the old "host:port" form so existing installs keep working.
    NAGIOS_BASE_URL = (
        f"http://{NAGIOS_HOST}" if ":" in NAGIOS_HOST
        else f"http://{NAGIOS_HOST}:{NAGIOS_PORT}"
    )
    NAGIOS_STATUS_URL = f"{NAGIOS_BASE_URL}/nagios/cgi-bin/statusjson.cgi"
    NAGIOS_ARCHIVE_URL = f"{NAGIOS_BASE_URL}/nagios/cgi-bin/archivejson.cgi"
    NAGIOS_OBJECT_URL = f"{NAGIOS_BASE_URL}/nagios/cgi-bin/objectjson.cgi"

    NAGIOS_USERNAME = os.environ.get("NAGIOS_USERNAME")
    NAGIOS_PASSWORD = os.environ.get("NAGIOS_PASSWORD")
```

For local development, put these values in `server/.env` or `server/.flaskenv` (already git-ignored or dev-only). `python-dotenv` is already in `requirements.txt`.

**Coordination.** Keep the `":" in NAGIOS_HOST` check. Without it, an existing server that still has `NAGIOS_HOST=127.0.0.1:8081` would produce `127.0.0.1:8081:8081` and lose its Nagios connection when it pulls this change.

### 2. `server/migrations/`: commit the migration history

**Problem.** Flask-Migrate is set up in `server/app/__init__.py`, but no `migrations/` folder is committed. `server/reset_db.sh` runs `flask db init` each time, so every developer's migration history is different and nothing can be upgraded in place.

The installer creates the schema with `db.create_all()` for now. That works for a fresh install. However, when a model changes on `main`, an installed server cannot get the new columns without deleting its data.

**Change.** Generate the migration history once and commit it. The `history` models use `__bind_key__ = "history"`, so the folder must be created in multi-database mode:

```bash
cd server
rm -f system.db history.db
flask db init --multidb
flask db migrate -m "initial schema"
flask db upgrade          # confirm it builds both databases from nothing
git add migrations/
```

From then on, every model change ships with a `flask db migrate` revision in the same commit.

**What the installer does once `server/migrations/env.py` exists:**

- Fresh install: `flask db upgrade`
- Existing install: back up both databases, then `flask db upgrade`
- Servers already built with `create_all()`: `flask db stamp <first revision>` once, then upgrade normally

Because of that last point, the **first** revision must describe the schema exactly as `db.create_all()` builds it from the models on `main` today. Generate it before changing any model.

### 3. `server/app/api/commands/seed.py`: add a production admin command

**Problem.** `flask seed` creates about 33 test users (`admin@test.com`, `john@test.com`, …) that all share the password `Password123!`. That can't run on a real server. To avoid it, the installer imports `seed_permissions`, `seed_roles` and `seed_system_settings` directly and builds the `User` itself. If any of those internal functions is renamed or its behaviour changes, installs break.

**Change.** Add a supported command that seeds only reference data and creates one administrator:

```bash
flask init-production --admin-email admin-7f3a2@pinpoint.lan --password-stdin
```

Requirements:

- Creates the administrator with `Needs_Setup=True`, so the first sign-in goes through first-run setup (`POST /api/user/complete-setup`): a real email and a new password. The installer checks this before and after creating the admin and stops with an error if the application has no first-run setup.
- Seeds permissions, roles and system settings. Creates **no** test users.
- Reads the password from stdin, never from an argument (arguments show up in `ps` and shell history).
- Hashes the password with `User.set_password`.
- Refuses to run if any user already exists, so it can't silently add a second admin during an upgrade.
- Exits non-zero on any failure.

`flask seed` stays as it is for development.

### 4. `server/app/__init__.py`: make the scheduler optional

**Problem.** `init_scheduler()` runs whenever `app` is imported. Every `flask` command and every Python check the installer runs therefore starts Nagios polling and automation jobs in the background. The installer currently suppresses this by setting `FLASK_DEBUG=1`, which relies on a side effect rather than a setting meant for it.

**Change.** Start the scheduler only when an explicit setting allows it:

```python
if os.environ.get("PINPOINT_SCHEDULER", "0") == "1":
    init_scheduler()
```

The installer sets `PINPOINT_SCHEDULER=1` only for the Gunicorn service. Gunicorn runs a single worker because each process would start its own scheduler.

### 5. `server/reset_db.sh`: fix or remove

**Problem.** It changes into `/Users/karell/Documents/GitHub/Network-Diagnosis-System/server`, so it only works on one Mac. It also runs `flask db init`, which conflicts with a committed `migrations/` folder.

**Change.** Delete it, or rewrite it to use its own directory and only `flask db upgrade` and `flask seed --reset`:

```bash
cd "$(dirname "$0")"
```

### 6. Remove tracked runtime files

**Problem.** These files are committed, so every installed server receives them:

| Path | Why it matters |
|---|---|
| `server/cookies.txt`, `server/cookies.txt-X` | Saved session cookies. `.gitignore` lists them but they were committed before the ignore rule. |
| `server/host-config-files/*.cfg` | Nagios host configs from the lab network. |
| `server/running-host-config-backup/*.cfg` | Backups of the same. |
| `.DS_Store` files | macOS metadata. |

**Change.**

```bash
git rm --cached server/cookies.txt server/cookies.txt-X
git rm --cached -r server/host-config-files server/running-host-config-backup
git rm --cached $(git ls-files | grep .DS_Store)
```

Add the two config folders and `.DS_Store` to `.gitignore`. The app should create the folders at startup if they don't exist.

### 7. `README.md`: document production settings

Add a section listing every environment variable the app reads, its default, and whether it's required in production. The installer's `/etc/pinpoint/pinpoint.env` is built from this list, so this README section is the agreed interface between the two repositories.

Also confirm the supported Python version. The README says 3.14.2 and the installer installs 3.14.

---

## Environment variables the installer will provide

| Variable | Example | Required |
|---|---|---|
| `SECRET_KEY` | 64 random hex characters | yes |
| `NAGIOS_HOST` | `127.0.0.1` | yes |
| `NAGIOS_PORT` | `8081` | yes |
| `NAGIOS_USERNAME` | `pinpoint-api` | yes |
| `NAGIOS_PASSWORD` | random, generated per server | yes |
| `PINPOINT_NETWORKS` | `192.168.50.0/24` (detected from the server's own interface) | yes |
| `PINPOINT_DOMAIN` | `pinpoint.lan` | no |
| `PINPOINT_SCHEDULER` | `1` for Gunicorn only | yes |
| `SNMP_COMMUNITY_STRING` | `public` | no |
| `FLASK_DEBUG` | `0` | yes |

---

## Definition of done

- [ ] No lab IP, subnet, password or secret key is required from source code in production.
- [ ] `server/migrations/` is committed, and `flask db upgrade` builds both `system.db` and `history.db` from empty.
- [ ] `flask init-production` creates one administrator and no test users.
- [ ] `flask init-production` sets `Needs_Setup` on that administrator.
- [ ] Importing `app` does not start the scheduler unless `PINPOINT_SCHEDULER=1`.
- [ ] `reset_db.sh` has no user-specific paths.
- [ ] Cookie files and lab host configs are no longer tracked.
- [ ] README lists the production environment variables.
- [ ] Existing servers that use `NAGIOS_HOST=127.0.0.1:8081` still connect to Nagios after pulling `main`.

## What the installer already does

PinPoint-Installer is ready for these changes and still works with `main` as it is today. `setup/deploy-pinpoint-web.sh` checks the cloned code and uses each feature only when it is there:

| When the app has… | The installer… | Until then it… |
|---|---|---|
| `NAGIOS_PORT` in `config.py` | writes `NAGIOS_HOST=127.0.0.1` and `NAGIOS_PORT=8081` | writes `NAGIOS_HOST=127.0.0.1:8081` |
| `server/migrations/env.py` | runs `flask db upgrade` and checks both databases are at the latest revision | runs `db.create_all()` |
| `User.Needs_Setup` (first-run setup) | pipes the generated password to `flask init-production` | stops a new installation with an error (existing installs are unaffected) |

In every case it:

- writes `PINPOINT_NETWORKS` once, from the server's own subnet
- sets `PINPOINT_SCHEDULER=1` in the Gunicorn service only, and `PINPOINT_SCHEDULER=0` for its own one-off commands
- upgrades an existing install to the latest `main` when run again. It backs up the databases, `/etc/pinpoint/pinpoint.env`, the service and Nginx files and the built web interface to `/var/backups/pinpoint/`, and restores them if any check fails.

`setup/configure-pinpoint-privileges.sh` also gives the `pinpoint` account what the app needs at run time:

- ownership of `hosts.cfg` and `plugin-services.cfg`, both registered in `nagios.cfg`
- membership of the `nagios` group so `nagios -v` works
- `sudo systemctl reload nagios` and no other sudo rights
- an NCPA key at `~pinpoint/.ssh/pinpoint_ncpa_deploy`

Write access to `/usr/local/nagios/libexec` (custom plugin uploads) is **not** granted yet. Letting the web account add executables that Nagios runs is a security decision still to be made.
