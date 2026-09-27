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
NAGIOS_BIND="127.0.0.1:8081"

PINPOINT_ETC="/etc/pinpoint"
APP_ENV="$PINPOINT_ETC/pinpoint.env"
API_CREDENTIALS="$PINPOINT_ETC/nagios-api.env"

SERVICE_NAME="pinpoint-gunicorn"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
NGINX_SITE="/etc/nginx/sites-available/pinpoint"

ADMIN_EMAIL_DOMAIN="pinpoint.lan"
CREDENTIALS_FILE="/root/pinpoint-install-credentials.txt"
CREDENTIALS_MARKER="/var/lib/pinpoint/web-credentials-pending"

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
# FLASK_DEBUG=1 stops the app's background scheduler
# from starting during these one-off commands.
run_app_python() {
    runuser -u "$APP_USER" -- bash -c "
        set -a
        . '$APP_ENV'
        set +a
        export FLASK_DEBUG=1
        cd '$SERVER_DIR'
        exec '$VENV_DIR/bin/python' -
    "
}

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
# [5/12] Clone Repository
##################################################

echo
echo "[5/12] Cloning PinPoint repository..." | tee -a "$LOG"

if [ -d "$APP_DIR/.git" ]; then

    # Existing installation: never overwrite code or databases here.
    echo "✓ Existing installation found. Skipping clone." | tee -a "$LOG"

else

    rm -rf "$APP_DIR"

    git clone --branch "$REPO_BRANCH" --single-branch \
        "$REPO_URL" "$APP_DIR" >> "$LOG" 2>&1 \
        || fail "Could not clone $REPO_URL."

    CURRENT_BRANCH="$(git -C "$APP_DIR" branch --show-current)"

    if [ "$CURRENT_BRANCH" != "$REPO_BRANCH" ]; then
        fail "Repository is on branch '$CURRENT_BRANCH', expected '$REPO_BRANCH'."
    fi

    chown -R "$APP_USER:$APP_USER" "$APP_DIR"

    echo "✓ Cloned $REPO_BRANCH ($(git -C "$APP_DIR" -c safe.directory="$APP_DIR" rev-parse --short HEAD))." | tee -a "$LOG"

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
    -r "$SERVER_DIR/requirements.txt" gunicorn >> "$LOG" 2>&1 \
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
        echo "NAGIOS_HOST=$NAGIOS_BIND"
        grep '^NAGIOS_USERNAME=' "$API_CREDENTIALS"
        grep '^NAGIOS_PASSWORD=' "$API_CREDENTIALS"
        echo "SNMP_COMMUNITY_STRING=public"
    } > "$APP_ENV"

    unset SECRET_KEY

    echo "✓ $APP_ENV created." | tee -a "$LOG"

fi

chown "root:$APP_USER" "$APP_ENV"
chmod 640 "$APP_ENV"

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

NEW_ADMIN=0

if [ "$DB_EXISTS" = "1" ]; then

    # Existing installation: never replace the database here.
    echo "✓ Existing database found. Skipping initialization." | tee -a "$LOG"

else

    ADMIN_EMAIL="admin-$(openssl rand -hex 3 | cut -c1-5)@$ADMIN_EMAIL_DOMAIN"
    ADMIN_PASSWORD="$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-24)"

    export ADMIN_EMAIL ADMIN_PASSWORD

    # Seed only permissions, roles and settings. The app's
    # "flask seed" command also creates test users with a
    # shared password, so it must not be used here.
    run_app_python >> "$LOG" 2>&1 <<'EOF' || fail "Database initialization failed."
import os

import sqlalchemy as sa
from email_validator import validate_email

from app import app, db
from app.api.commands.seed import (
    seed_permissions,
    seed_roles,
    seed_system_settings,
)
from app.system_models import Role, User, UserStatus

email = os.environ["ADMIN_EMAIL"]
password = os.environ["ADMIN_PASSWORD"]

# Same check the login endpoint uses.
validate_email(email, check_deliverability=False)

with app.app_context():
    db.create_all()

    seed_permissions()
    seed_roles()
    seed_system_settings()

    role = db.session.scalar(
        sa.select(Role).where(Role.Name == "Administrator")
    )

    admin = User(
        First_Name="PinPoint",
        Last_Name="Administrator",
        Email=email,
        RoleID=role.RoleID,
        Status=UserStatus.ACTIVE,
    )
    admin.set_password(password)

    db.session.add(admin)
    db.session.commit()

print("Database initialized. Administrator created.")
EOF

    NEW_ADMIN=1

    echo "✓ Database initialized." | tee -a "$LOG"
    echo "✓ Administrator account created." | tee -a "$LOG"

fi

for DB_FILE in system.db history.db; do
    if [ ! -f "$SERVER_DIR/$DB_FILE" ]; then
        fail "$DB_FILE was not created."
    fi
done

##################################################
# [10/12] Configure Gunicorn
##################################################

echo
echo "[10/12] Configuring Gunicorn..." | tee -a "$LOG"

# One worker only: the app starts a background scheduler
# in every process, so more workers would duplicate Nagios
# polling and automation. Threads handle concurrent requests.
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PinPoint Web Application (Gunicorn)
After=network-online.target nagios.service apache2.service
Wants=network-online.target

[Service]
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$SERVER_DIR
EnvironmentFile=$APP_ENV

ExecStart=$VENV_DIR/bin/gunicorn \\
    --workers 1 \\
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

# Server LAN address, used only for the displayed URL
SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"

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

Username (email):
$ADMIN_EMAIL

Password:
$ADMIN_PASSWORD

IMPORTANT:
Change the password after first login.
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

##################################################
# Footer
##################################################

echo
echo "======================================" | tee -a "$LOG"
echo " PinPoint web interface deployed." | tee -a "$LOG"
echo " URL: http://$SERVER_IP/" | tee -a "$LOG"
echo " Finished: $(date)" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

exit 0
