#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : deploy-pinpoint-web.sh
# Purpose: Deploy the PinPoint web interface
#          (Network-Diagnosis-System) behind
#          Nginx + Gunicorn on the Nagios server.
#
# Traffic flow:
#   LAN -> Nginx :80 -> Gunicorn 127.0.0.1:8000
#       -> Flask -> Nagios 127.0.0.1:8081
#
# Must run after configure-nagios.sh, which frees
# port 80 and creates the pinpoint-api account.
#
# Running it again on an installed server upgrades
# the application to the latest main: databases,
# configuration and the built web interface are
# backed up first and restored if the upgrade fails.
#
# Works with Network-Diagnosis-System before and
# after the changes in docs/Network-Diagnosis-
# System-Installer-Integration.md: NAGIOS_PORT and
# migrations are used only when the cloned application
# has them. A new installation requires the application's
# first-run setup (User.Needs_Setup, set by
# "flask init-production"), which makes the administrator
# replace the placeholder email and password at first
# sign-in, and stops with an error if the application
# lacks it.
#
# Secrets are never written to the log or console.
# Generated web credentials are shown once at the
# next login by pinpoint-web-credentials.
##################################################

set -e

LOG="/var/log/pinpoint-web.log"

REPO_URL="https://github.com/esfen14/Network-Diagnosis-System.git"
REPO_BRANCH="main"

APP_USER="pinpoint"
APP_ROOT="/opt/pinpoint"
APP_DIR="$APP_ROOT/Network-Diagnosis-System"
SERVER_DIR="$APP_DIR/server"
CLIENT_DIR="$APP_DIR/client"
VENV_DIR="$APP_ROOT/venv"

PYTHON_VERSION="3.14"
NODE_MAJOR="22"
export UV_PYTHON_INSTALL_DIR="$APP_ROOT/python"

GUNICORN_BIND="127.0.0.1:8000"
# 25.1 added --no-control-socket, used in the service below.
GUNICORN_REQUIREMENT="gunicorn>=25.1"
NAGIOS_ADDRESS="127.0.0.1"
NAGIOS_PORT="8081"
NAGIOS_BIND="$NAGIOS_ADDRESS:$NAGIOS_PORT"

PINPOINT_ETC="/etc/pinpoint"
APP_ENV="$PINPOINT_ETC/pinpoint.env"
API_CREDENTIALS="$PINPOINT_ETC/nagios-api.env"

SERVICE_NAME="pinpoint-gunicorn"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
NGINX_SITE="/etc/nginx/sites-available/pinpoint"

BACKUP_ROOT="/var/backups/pinpoint"
BACKUP_KEEP=5

# Reserved placeholder domain. The PinPoint server rejects it as
# a real email, so this must match the server's constant.
ADMIN_EMAIL_DOMAIN="pinpoint.lan"
CREDENTIALS_FILE="/root/pinpoint-install-credentials.txt"
CREDENTIALS_MARKER="/var/lib/pinpoint/web-credentials-pending"

UPGRADE=0
UPGRADE_IN_PROGRESS=0
SERVICE_STOPPED=0
PREVIOUS_COMMIT=""
BACKUP_DIR=""

##################################################
# Helpers
##################################################

fail() {
    echo "ERROR: $1" | tee -a "$LOG"
    echo "Check $LOG for details." | tee -a "$LOG"
    exit 1
}

# Run Python inside the application environment as
# the service account. The script is read from stdin.
# PINPOINT_SCHEDULER=0 (and FLASK_DEBUG=1 for older
# versions of the app) stop the background scheduler
# from starting during these one-off commands.
run_app_python() {
    runuser -u "$APP_USER" -- bash -c "
        set -a
        . '$APP_ENV'
        set +a
        export FLASK_DEBUG=1 PINPOINT_SCHEDULER=0
        cd '$SERVER_DIR'
        exec '$VENV_DIR/bin/python' -
    "
}

# Run a flask CLI command the same way. Stdin is passed
# through, so passwords can be piped in.
run_app_flask() {
    runuser -u "$APP_USER" -- bash -c "
        set -a
        . '$APP_ENV'
        set +a
        export FLASK_DEBUG=1 PINPOINT_SCHEDULER=0
        cd '$SERVER_DIR'
        exec '$VENV_DIR/bin/flask' --app server.py \"\$@\"
    " run_app_flask "$@"
}

run_app_git() {
    runuser -u "$APP_USER" -- git -C "$APP_DIR" "$@"
}

# Set KEY=VALUE in the environment file, replacing an
# existing KEY. Values are passed through the environment,
# so they need no escaping and never appear in the log.
env_set() {
    local TMP_FILE

    TMP_FILE="$(mktemp "$APP_ENV.XXXXXX")"

    KEY="$1" VALUE="$2" awk '
        BEGIN { key = ENVIRON["KEY"]; value = ENVIRON["VALUE"]; done = 0 }
        index($0, key "=") == 1 { if (!done) print key "=" value; done = 1; next }
        { print }
        END { if (!done) print key "=" value }
    ' "$APP_ENV" > "$TMP_FILE"

    # cat keeps the owner and mode of the existing file.
    cat "$TMP_FILE" > "$APP_ENV"
    rm -f "$TMP_FILE"
}

env_has() {
    grep -q "^$1=" "$APP_ENV"
}

# Server LAN address, used only for the displayed URL.
detect_server_ip() {
    ip -4 route get 1.1.1.1 2> /dev/null \
        | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

# Subnet of the interface that holds the default route,
# e.g. 192.168.50.0/24. Used as the Discovery scan range.
detect_lan_subnet() {
    local DEV

    DEV="$(ip -4 route get 1.1.1.1 2> /dev/null \
        | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"

    [ -n "$DEV" ] || return 0

    ip -4 -o route show dev "$DEV" proto kernel scope link \
        | awk '{print $1; exit}'
}

# Succeeds if system.db already records a migration
# revision (alembic_version table exists).
db_is_stamped() {
    run_app_python >> "$LOG" 2>&1 <<'EOF'
import sqlite3
import sys

con = sqlite3.connect("file:system.db?mode=ro", uri=True)
try:
    row = con.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'alembic_version'"
    ).fetchone()
finally:
    con.close()

sys.exit(0 if row else 1)
EOF
}

# Fails unless the databases are at the latest migration.
# history.db is checked only if it is under migration
# control (flask db init --multidb).
db_at_head() {
    run_app_python >> "$LOG" 2>&1 <<'EOF'
import sqlite3

from alembic.config import Config
from alembic.script import ScriptDirectory

cfg = Config()
cfg.set_main_option("script_location", "migrations")
heads = set(ScriptDirectory.from_config(cfg).get_heads())

for name in ("system.db", "history.db"):
    con = sqlite3.connect(f"file:{name}?mode=ro", uri=True)
    try:
        has_table = con.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'alembic_version'"
        ).fetchone()
        if not has_table:
            if name == "system.db":
                raise SystemExit("system.db has no alembic_version table.")
            continue
        current = {row[0] for row in con.execute("SELECT version_num FROM alembic_version")}
    finally:
        con.close()

    if current != heads:
        raise SystemExit(f"{name} is at {sorted(current)}, expected {sorted(heads)}.")

print("Database schema at", ", ".join(sorted(heads)))
EOF
}

# Restore the application from $BACKUP_DIR after a
# failed upgrade. Runs from the EXIT trap.
rollback_upgrade() {
    UPGRADE_IN_PROGRESS=0

    # Restore as much as possible even if one step fails.
    set +e

    echo | tee -a "$LOG"
    echo "Upgrade failed. Restoring $PREVIOUS_COMMIT from $BACKUP_DIR..." | tee -a "$LOG"

    systemctl stop "$SERVICE_NAME" 2> /dev/null || true

    run_app_git reset --hard "$PREVIOUS_COMMIT" >> "$LOG" 2>&1 || true

    for DB_FILE in system.db history.db; do
        if [ -f "$BACKUP_DIR/$DB_FILE" ]; then
            cp -p "$BACKUP_DIR/$DB_FILE" "$SERVER_DIR/$DB_FILE"
        fi
    done

    [ -f "$BACKUP_DIR/pinpoint.env" ] && cp -p "$BACKUP_DIR/pinpoint.env" "$APP_ENV"
    [ -f "$BACKUP_DIR/$SERVICE_NAME.service" ] && cp -p "$BACKUP_DIR/$SERVICE_NAME.service" "$SERVICE_FILE"
    [ -f "$BACKUP_DIR/nginx-pinpoint" ] && cp -p "$BACKUP_DIR/nginx-pinpoint" "$NGINX_SITE"

    if [ -f "$BACKUP_DIR/client-dist.tar.gz" ]; then
        rm -rf "$CLIENT_DIR/dist"
        tar -xzf "$BACKUP_DIR/client-dist.tar.gz" -C "$CLIENT_DIR"
    fi

    # New requirements may have been installed; put the
    # previous versions back.
    uv pip install --python "$VENV_DIR/bin/python" \
        -r "$SERVER_DIR/requirements.txt" "$GUNICORN_REQUIREMENT" >> "$LOG" 2>&1 || true

    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME" >> "$LOG" 2>&1 || true

    if nginx -t >> "$LOG" 2>&1; then
        systemctl reload nginx >> "$LOG" 2>&1 || true
    fi

    if [ ! -f "$SERVICE_FILE" ]; then
        echo "✓ Restored $PREVIOUS_COMMIT. No $SERVICE_NAME service existed before this run, so none was restarted." | tee -a "$LOG"
    elif systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "✓ Restored $PREVIOUS_COMMIT. PinPoint is running the previous version." | tee -a "$LOG"
    else
        echo "ERROR: Rollback could not restart $SERVICE_NAME." | tee -a "$LOG"
        echo "Backup is kept in $BACKUP_DIR." | tee -a "$LOG"
    fi
}

on_exit() {
    local RC=$?

    if [ "$RC" -ne 0 ] && [ "$UPGRADE_IN_PROGRESS" = "1" ]; then
        rollback_upgrade
    elif [ "$RC" -ne 0 ] && [ "$SERVICE_STOPPED" = "1" ]; then
        # Failed before the code changed: bring the app back.
        systemctl start "$SERVICE_NAME" 2> /dev/null || true
    fi

    exit "$RC"
}

trap on_exit EXIT

##################################################
# Root Check
##################################################

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

##################################################
# Header
##################################################

echo "======================================" | tee -a "$LOG"
echo " PinPoint - Deploying Web Interface" | tee -a "$LOG"
echo " Started: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

##################################################
# [1/12] Check Prerequisites
##################################################

echo
echo "[1/12] Checking prerequisites..." | tee -a "$LOG"

if ! systemctl is-active --quiet nagios; then
    fail "Nagios is not running. Run configure-nagios.sh first."
fi

if [ ! -f "$API_CREDENTIALS" ]; then
    fail "$API_CREDENTIALS not found. Run configure-nagios.sh first."
fi

if ss -ltnpH 'sport = :80' | grep -q '"apache2"'; then
    fail "Apache is still using port 80. Run configure-nagios.sh first."
fi

if ! curl -fsS -o /dev/null --max-time 20 https://github.com; then
    fail "Cannot reach github.com. Check the gateway and DNS settings."
fi

echo "✓ Nagios, Apache and network are ready." | tee -a "$LOG"

##################################################
# [2/12] Install Web Packages
##################################################

echo
echo "[2/12] Installing web packages..." | tee -a "$LOG"

# Nginx is installed here rather than in install-packages.sh:
# it starts on port 80 when installed, which only works after
# configure-nagios.sh has moved Apache off that port.
apt-get install -y nginx git curl ca-certificates >> "$LOG" 2>&1 \
    || fail "Could not install Nginx."

echo "✓ Nginx installed." | tee -a "$LOG"

# The web interface is built with Vite, which needs a newer
# Node.js than Ubuntu provides.
CURRENT_NODE_MAJOR="$(node --version 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')"

if [ -z "$CURRENT_NODE_MAJOR" ] || [ "$CURRENT_NODE_MAJOR" -lt "$NODE_MAJOR" ]; then

    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" \
        | bash - >> "$LOG" 2>&1 \
        || fail "Could not add the Node.js $NODE_MAJOR repository."

    apt-get install -y nodejs >> "$LOG" 2>&1 \
        || fail "Could not install Node.js $NODE_MAJOR."

fi

echo "✓ Node.js $(node --version) installed." | tee -a "$LOG"

##################################################
# [3/12] Install Python
##################################################

echo
echo "[3/12] Installing Python $PYTHON_VERSION..." | tee -a "$LOG"

# uv provides the Python version used by the developers,
# which Ubuntu 22.04 does not package.
if ! command -v uv > /dev/null; then

    curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh >> "$LOG" 2>&1 \
        || fail "Could not install uv."

fi

mkdir -p "$APP_ROOT"
chmod 755 "$APP_ROOT"

uv python install "$PYTHON_VERSION" >> "$LOG" 2>&1 \
    || fail "Could not install Python $PYTHON_VERSION."

echo "✓ Python $PYTHON_VERSION installed." | tee -a "$LOG"

##################################################
# [4/12] Create Service Account
##################################################

echo
echo "[4/12] Creating service account..." | tee -a "$LOG"

if id "$APP_USER" > /dev/null 2>&1; then
    echo "✓ Account $APP_USER already exists." | tee -a "$LOG"
else
    useradd --system --user-group \
        --home-dir "$APP_ROOT" --no-create-home \
        --shell /usr/sbin/nologin \
        "$APP_USER"
    echo "✓ Account $APP_USER created." | tee -a "$LOG"
fi

##################################################
# [5/12] Get Repository
##################################################

# A repository alone is not an installation: a first install that
# failed before step 10 leaves the clone behind with no service or
# database. That is cloned again instead of "upgraded", so a re-run
# is a clean first install and rollback never expects a service
# that never existed.
if [ -d "$APP_DIR/.git" ] \
    && { [ -f "$SERVICE_FILE" ] \
         || [ -f "$SERVER_DIR/system.db" ] \
         || [ -f "$SERVER_DIR/history.db" ]; }; then

    echo
    echo "[5/12] Upgrading PinPoint repository..." | tee -a "$LOG"

    UPGRADE=1
    PREVIOUS_COMMIT="$(run_app_git rev-parse HEAD)"

    # Only files the app generates at run time (databases,
    # host configs) may differ; local code edits would be lost.
    LOCAL_CHANGES="$(run_app_git status --porcelain --untracked-files=no)"

    if [ -n "$LOCAL_CHANGES" ]; then
        echo "$LOCAL_CHANGES" >> "$LOG"
        fail "$APP_DIR has local code changes. Commit or discard them before upgrading."
    fi

    run_app_git fetch origin "$REPO_BRANCH" >> "$LOG" 2>&1 \
        || fail "Could not fetch $REPO_BRANCH from $REPO_URL."

    NEW_COMMIT="$(run_app_git rev-parse "origin/$REPO_BRANCH")"

    # Stop the app so the databases are not written
    # while they are copied.
    systemctl stop "$SERVICE_NAME" 2> /dev/null || true
    SERVICE_STOPPED=1

    BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p -m 700 "$BACKUP_ROOT"
    mkdir -p -m 700 "$BACKUP_DIR"

    for DB_FILE in system.db history.db; do
        if [ -f "$SERVER_DIR/$DB_FILE" ]; then
            cp -p "$SERVER_DIR/$DB_FILE" "$BACKUP_DIR/$DB_FILE"
        fi
    done

    [ -f "$APP_ENV" ] && cp -p "$APP_ENV" "$BACKUP_DIR/pinpoint.env"
    [ -f "$SERVICE_FILE" ] && cp -p "$SERVICE_FILE" "$BACKUP_DIR/$SERVICE_NAME.service"
    [ -f "$NGINX_SITE" ] && cp -p "$NGINX_SITE" "$BACKUP_DIR/nginx-pinpoint"

    if [ -d "$CLIENT_DIR/dist" ]; then
        tar -czf "$BACKUP_DIR/client-dist.tar.gz" -C "$CLIENT_DIR" dist
    fi

    echo "$PREVIOUS_COMMIT" > "$BACKUP_DIR/commit"

    # Keep only the most recent backups.
    ls -1dt "$BACKUP_ROOT"/*/ 2> /dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -rf

    echo "✓ Backup saved to $BACKUP_DIR." | tee -a "$LOG"

    # From here on, any failure restores the backup.
    UPGRADE_IN_PROGRESS=1

    run_app_git merge --ff-only "origin/$REPO_BRANCH" >> "$LOG" 2>&1 \
        || fail "Could not fast-forward to origin/$REPO_BRANCH."

    if [ "$PREVIOUS_COMMIT" = "$NEW_COMMIT" ]; then
        echo "✓ Already at the latest $REPO_BRANCH (${NEW_COMMIT:0:7})." | tee -a "$LOG"
    else
        echo "✓ Upgraded ${PREVIOUS_COMMIT:0:7} -> ${NEW_COMMIT:0:7}." | tee -a "$LOG"
    fi

else

    echo
    echo "[5/12] Cloning PinPoint repository..." | tee -a "$LOG"

    rm -rf "$APP_DIR"

    git clone --branch "$REPO_BRANCH" --single-branch \
        "$REPO_URL" "$APP_DIR" >> "$LOG" 2>&1 \
        || fail "Could not clone $REPO_URL."

    CURRENT_BRANCH="$(git -C "$APP_DIR" branch --show-current)"

    if [ "$CURRENT_BRANCH" != "$REPO_BRANCH" ]; then
        fail "Repository is on branch '$CURRENT_BRANCH', expected '$REPO_BRANCH'."
    fi

    chown -R "$APP_USER:$APP_USER" "$APP_DIR"

    echo "✓ Cloned $REPO_BRANCH ($(run_app_git rev-parse --short HEAD))." | tee -a "$LOG"

fi

##################################################
# [6/12] Install Backend Dependencies
##################################################

echo
echo "[6/12] Installing backend dependencies..." | tee -a "$LOG"

if [ ! -x "$VENV_DIR/bin/python" ]; then
    uv venv --python "$PYTHON_VERSION" "$VENV_DIR" >> "$LOG" 2>&1 \
        || fail "Could not create the Python virtual environment."
fi

uv pip install --python "$VENV_DIR/bin/python" \
    -r "$SERVER_DIR/requirements.txt" "$GUNICORN_REQUIREMENT" >> "$LOG" 2>&1 \
    || fail "Could not install backend requirements."

uv pip check --python "$VENV_DIR/bin/python" >> "$LOG" 2>&1 \
    || fail "Backend dependencies have conflicts."

echo "✓ Backend dependencies installed." | tee -a "$LOG"

##################################################
# [7/12] Build Web Interface
##################################################

echo
echo "[7/12] Building web interface..." | tee -a "$LOG"

runuser -u "$APP_USER" -- bash -c "
    cd '$CLIENT_DIR'
    export HOME='$CLIENT_DIR' npm_config_cache='$CLIENT_DIR/.npm'
    npm ci --no-audit --no-fund
    npm run build
" >> "$LOG" 2>&1 \
    || fail "Could not build the web interface."

if [ ! -f "$CLIENT_DIR/dist/index.html" ]; then
    fail "Web interface build did not produce dist/index.html."
fi

echo "✓ Web interface built." | tee -a "$LOG"

##################################################
# [8/12] Write Environment Configuration
##################################################

echo
echo "[8/12] Writing environment configuration..." | tee -a "$LOG"

mkdir -p "$PINPOINT_ETC"
chmod 755 "$PINPOINT_ETC"

if [ -f "$APP_ENV" ]; then

    # Keep the existing SECRET_KEY so sessions stay valid.
    echo "✓ Existing $APP_ENV kept." | tee -a "$LOG"

else

    SECRET_KEY="$(openssl rand -hex 32)"

    {
        echo "# Managed by PinPoint Installer. Contains secrets - do not share."
        echo "SECRET_KEY=$SECRET_KEY"
        echo "FLASK_DEBUG=0"
        grep '^NAGIOS_USERNAME=' "$API_CREDENTIALS"
        grep '^NAGIOS_PASSWORD=' "$API_CREDENTIALS"
        echo "SNMP_COMMUNITY_STRING=public"
    } > "$APP_ENV"

    unset SECRET_KEY

    echo "✓ $APP_ENV created." | tee -a "$LOG"

fi

chown "root:$APP_USER" "$APP_ENV"
chmod 640 "$APP_ENV"

# Older versions of the app build the Nagios URL from
# NAGIOS_HOST alone, so the port has to be part of it.
if grep -q 'NAGIOS_PORT' "$SERVER_DIR/config.py"; then
    env_set NAGIOS_HOST "$NAGIOS_ADDRESS"
    env_set NAGIOS_PORT "$NAGIOS_PORT"
    echo "✓ Nagios at $NAGIOS_ADDRESS, port $NAGIOS_PORT." | tee -a "$LOG"
else
    env_set NAGIOS_HOST "$NAGIOS_BIND"
    echo "✓ Nagios at $NAGIOS_BIND (app has no NAGIOS_PORT setting)." | tee -a "$LOG"
fi

# Discovery scan range. Set once from the server's own
# subnet; an administrator may change it afterwards.
if env_has PINPOINT_NETWORKS; then
    echo "✓ Discovery range kept: $(sed -n 's/^PINPOINT_NETWORKS=//p' "$APP_ENV")." | tee -a "$LOG"
else
    LAN_SUBNET="$(detect_lan_subnet)"

    if [ -z "$LAN_SUBNET" ]; then
        fail "Could not detect the server's LAN subnet."
    fi

    env_set PINPOINT_NETWORKS "$LAN_SUBNET"
    echo "✓ Discovery range set to $LAN_SUBNET." | tee -a "$LOG"
fi

if ! grep -qs 'PINPOINT_NETWORKS' "$SERVER_DIR/config.py"; then
    echo "  Note: this app version ignores PINPOINT_NETWORKS and scans its built-in range." | tee -a "$LOG"
fi

# Decide before the app is first imported, so nothing it
# creates on import can be mistaken for an existing database.
if [ -f "$SERVER_DIR/system.db" ]; then
    DB_EXISTS=1
else
    DB_EXISTS=0
fi

run_app_python >> "$LOG" 2>&1 <<'EOF' || fail "Flask application could not be imported."
from app import app
print("Flask OK:", app.name)
EOF

echo "✓ Flask application imports successfully." | tee -a "$LOG"

##################################################
# [9/12] Initialize Database and Administrator
##################################################

echo
echo "[9/12] Initializing database and administrator..." | tee -a "$LOG"

if [ -f "$SERVER_DIR/migrations/env.py" ]; then
    HAS_MIGRATIONS=1
else
    HAS_MIGRATIONS=0
fi

NEW_ADMIN=0

if [ "$DB_EXISTS" = "1" ]; then

    # Existing installation: never replace the database here.
    if [ "$HAS_MIGRATIONS" = "1" ]; then

        # Databases created before the app shipped migrations
        # were built with create_all(), which matches the first
        # revision. Mark them as such, then upgrade normally.
        if ! db_is_stamped; then

            BASE_REVISION="$(run_app_python 2>> "$LOG" <<'EOF'
from alembic.config import Config
from alembic.script import ScriptDirectory

cfg = Config()
cfg.set_main_option("script_location", "migrations")
bases = ScriptDirectory.from_config(cfg).get_bases()

if len(bases) != 1:
    raise SystemExit(f"Expected one base revision, found {bases}.")

print(bases[0])
EOF
)" || fail "Could not find the first database migration."

            run_app_flask db stamp "$BASE_REVISION" >> "$LOG" 2>&1 \
                || fail "Could not mark the existing database as revision $BASE_REVISION."

            echo "✓ Existing database marked as revision $BASE_REVISION." | tee -a "$LOG"

        fi

        run_app_flask db upgrade >> "$LOG" 2>&1 \
            || fail "Database migration failed."

        echo "✓ Existing database migrated." | tee -a "$LOG"

    else
        echo "✓ Existing database kept (app has no migrations)." | tee -a "$LOG"
    fi

else

    # Fail before the database exists: a re-run would treat an
    # existing database as installed and never create the admin.
    # Importing the model creates nothing.
    run_app_python >> "$LOG" 2>&1 <<'EOF' || fail "Step 9/12: this PinPoint version has no first-run setup (User.Needs_Setup), so the administrator would not be made to replace the placeholder email. Install a newer PinPoint release."
from app.system_models import User

if not hasattr(User, "Needs_Setup"):
    raise SystemExit("User.Needs_Setup is missing.")
EOF

    # Create the schema.
    if [ "$HAS_MIGRATIONS" = "1" ]; then

        run_app_flask db upgrade >> "$LOG" 2>&1 \
            || fail "Database migration failed."

    else

        run_app_python >> "$LOG" 2>&1 <<'EOF' || fail "Database creation failed."
from app import app, db

with app.app_context():
    db.create_all()

print("Database schema created.")
EOF

    fi

    echo "✓ Database initialized." | tee -a "$LOG"

    ADMIN_EMAIL="admin-$(openssl rand -hex 3 | cut -c1-5)@$ADMIN_EMAIL_DOMAIN"
    ADMIN_PASSWORD="$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-24)"

    # The password is piped in, never passed as an argument.
    # init-production creates the administrator with
    # Needs_Setup, so the first sign-in goes through the
    # application's first-run setup.
    printf '%s\n' "$ADMIN_PASSWORD" \
        | run_app_flask init-production \
            --admin-email "$ADMIN_EMAIL" --password-stdin >> "$LOG" 2>&1 \
        || fail "Step 9/12: 'flask init-production' failed. The administrator was not created."

    # Read-only check that the gate was really set. Only the
    # email is passed in, never the password.
    export ADMIN_EMAIL

    run_app_python >> "$LOG" 2>&1 <<'EOF' || fail "Step 9/12: the administrator was created without first-run setup (Needs_Setup is not set), so nothing would make them replace the placeholder email."
import os

import sqlalchemy as sa

from app import app, db
from app.system_models import User

with app.app_context():
    admin = db.session.scalar(
        sa.select(User).where(User.Email == os.environ["ADMIN_EMAIL"])
    )

    if admin is None or not admin.Needs_Setup:
        raise SystemExit("Administrator is missing or Needs_Setup is not set.")

print("Administrator must complete first-run setup at first sign-in.")
EOF

    NEW_ADMIN=1

    echo "✓ Administrator account created." | tee -a "$LOG"
    echo "✓ Administrator must complete first-run setup (real email and new password)." | tee -a "$LOG"

fi

for DB_FILE in system.db history.db; do
    if [ ! -f "$SERVER_DIR/$DB_FILE" ]; then
        fail "$DB_FILE was not created."
    fi
done

if [ "$HAS_MIGRATIONS" = "1" ]; then
    db_at_head || fail "Database is not at the latest migration."
    echo "✓ Database schema is at the latest migration." | tee -a "$LOG"
fi

##################################################
# [10/12] Configure Gunicorn
##################################################

echo
echo "[10/12] Configuring Gunicorn..." | tee -a "$LOG"

# One worker only: the app starts a background scheduler
# in every process, so more workers would duplicate Nagios
# polling and automation. Threads handle concurrent requests.
# PINPOINT_SCHEDULER=1 enables that scheduler in this
# service only, not in one-off flask/python commands.
# --no-control-socket: Gunicorn would otherwise create
# ~/.gunicorn in /opt/pinpoint, which pinpoint cannot
# write. The service is managed with systemctl instead.
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PinPoint Web Application (Gunicorn)
After=network-online.target nagios.service apache2.service
Wants=network-online.target

[Service]
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$SERVER_DIR
Environment=PINPOINT_SCHEDULER=1
EnvironmentFile=$APP_ENV

ExecStart=$VENV_DIR/bin/gunicorn \\
    --workers 1 \\
    --no-control-socket \\
    --threads 4 \\
    --bind $GUNICORN_BIND \\
    --timeout 300 \\
    --access-logfile - \\
    --error-logfile - \\
    app:app

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >> "$LOG" 2>&1
systemctl restart "$SERVICE_NAME"

echo "✓ $SERVICE_NAME service started." | tee -a "$LOG"

##################################################
# [11/12] Configure Nginx
##################################################

echo
echo "[11/12] Configuring Nginx..." | tee -a "$LOG"

cat > "$NGINX_SITE" <<EOF
# Managed by PinPoint Installer.
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    client_max_body_size 50M;

    # Built React web interface.
    root $CLIENT_DIR/dist;
    index index.html;

    # Flask API served by Gunicorn.
    location /api/ {
        proxy_pass http://$GUNICORN_BIND;

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }

    # Single-page app: unknown paths load index.html.
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/pinpoint

if [ -e /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
    echo "✓ Default Nginx site disabled." | tee -a "$LOG"
fi

nginx -t >> "$LOG" 2>&1 || fail "Nginx configuration test failed."

systemctl enable nginx >> "$LOG" 2>&1
systemctl restart nginx

echo "✓ Nginx configured." | tee -a "$LOG"

##################################################
# [12/12] Verify Deployment
##################################################

echo
echo "[12/12] Verifying deployment..." | tee -a "$LOG"

# Gunicorn service and local listener
GUNICORN_UP=0

for ATTEMPT in $(seq 1 15); do
    if curl -s -o /dev/null "http://$GUNICORN_BIND/api/user/login"; then
        GUNICORN_UP=1
        break
    fi
    sleep 2
done

if [ "$GUNICORN_UP" != "1" ] || ! systemctl is-active --quiet "$SERVICE_NAME"; then
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager >> "$LOG" 2>&1 || true
    fail "Gunicorn is not responding on $GUNICORN_BIND."
fi

if ss -ltnH 'sport = :8000' | awk '{print $4}' | grep -qv "^$GUNICORN_BIND$"; then
    fail "Gunicorn is listening on more than $GUNICORN_BIND."
fi

echo "✓ Gunicorn is running on $GUNICORN_BIND only." | tee -a "$LOG"

# Nginx serves the web interface
if ! systemctl is-active --quiet nginx; then
    fail "Nginx is not running."
fi

if ! curl -fsS http://127.0.0.1/ | grep -q 'id="root"'; then
    fail "Nginx is not serving the web interface."
fi

echo "✓ Nginx is serving the web interface." | tee -a "$LOG"

# Nginx forwards the API to Gunicorn
API_STATUS="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/api/user/login || true)"

case "$API_STATUS" in
    000|502|503|504)
        fail "Nginx could not reach Gunicorn (HTTP $API_STATUS)."
        ;;
esac

echo "✓ Nginx forwards /api/ to Gunicorn." | tee -a "$LOG"

# Flask can reach Nagios through localhost
run_app_python >> "$LOG" 2>&1 <<'EOF' || fail "Flask could not read Nagios status data."
import requests

from config import Config

response = requests.get(
    Config.NAGIOS_STATUS_URL,
    params={"query": "programstatus"},
    auth=(Config.NAGIOS_USERNAME, Config.NAGIOS_PASSWORD),
    timeout=15,
)
response.raise_for_status()

if response.json()["result"]["type_code"] != 0:
    raise SystemExit("Nagios returned an error result.")

print("Flask -> Nagios OK:", Config.NAGIOS_STATUS_URL)
EOF

echo "✓ Flask can read Nagios through $NAGIOS_BIND." | tee -a "$LOG"

SERVER_IP="$(detect_server_ip)"

if [ -z "$SERVER_IP" ]; then
    SERVER_IP="$(hostname -I | awk '{print $1}')"
fi

# Generated administrator can log in through Nginx
if [ "$NEW_ADMIN" = "1" ]; then

    LOGIN_RESPONSE="$(printf '{"email": "%s", "password": "%s"}' "$ADMIN_EMAIL" "$ADMIN_PASSWORD" \
        | curl -s -H 'Content-Type: application/json' --data-binary @- \
            http://127.0.0.1/api/user/login || true)"

    if ! printf '%s' "$LOGIN_RESPONSE" | grep -Eq '"success":[[:space:]]*true'; then
        fail "Generated administrator could not log in."
    fi

    echo "✓ Administrator login verified." | tee -a "$LOG"

    ( umask 077; cat > "$CREDENTIALS_FILE" ) <<EOF
PinPoint Web Installation
=========================

URL:
http://$SERVER_IP/

Username (temporary placeholder email):
$ADMIN_EMAIL

Password:
$ADMIN_PASSWORD

IMPORTANT:
On first sign-in you will be asked to set your real email
address and choose a new password. Notifications are sent to
the email, and it becomes your sign-in name from then on. The
placeholder and password above only work until you do.
Do not commit or share this file.
EOF

    chown root:root "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"

    mkdir -p -m 755 "$(dirname "$CREDENTIALS_MARKER")"
    touch "$CREDENTIALS_MARKER"
    chmod 644 "$CREDENTIALS_MARKER"

    unset ADMIN_PASSWORD LOGIN_RESPONSE

    echo "✓ Credentials saved to $CREDENTIALS_FILE." | tee -a "$LOG"

fi

# Every check passed: keep the upgrade.
UPGRADE_IN_PROGRESS=0

##################################################
# Footer
##################################################

echo
echo "======================================" | tee -a "$LOG"
if [ "$UPGRADE" = "1" ]; then
    echo " PinPoint web interface upgraded." | tee -a "$LOG"
    echo " Backup: $BACKUP_DIR" | tee -a "$LOG"
else
    echo " PinPoint web interface deployed." | tee -a "$LOG"
fi
echo " URL: http://$SERVER_IP/" | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
