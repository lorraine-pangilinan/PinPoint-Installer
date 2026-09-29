#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : pinpoint-healthcheck.sh
# Purpose: Read-only health check of a deployed
#          PinPoint server:
#            - Nagios Core + Apache (127.0.0.1:8081)
#            - Gunicorn (127.0.0.1:8000)
#            - Database migrations
#            - Nagios config access (Discovery,
#              Plugin Manager) and NCPA key
#            - Nginx (:80)
#            - nmap capabilities (Discovery)
#
# Nothing is restarted or modified. Every check runs
# and is reported; the exit code is the number of
# failed checks (0 = healthy).
#
# Usage: sudo bash pinpoint-healthcheck.sh
#
# Secrets are passed on stdin and never printed.
##################################################

NAGIOS_BIN="/usr/local/nagios/bin/nagios"
NAGIOS_CFG="/usr/local/nagios/etc/nagios.cfg"
NAGIOS_STATUS="/usr/local/nagios/var/status.dat"
NAGIOS_CMD="/usr/local/nagios/var/rw/nagios.cmd"
NAGIOS_LIBEXEC="/usr/local/nagios/libexec"
CGI_CFG="/usr/local/nagios/etc/cgi.cfg"
NAGIOS_BIND="127.0.0.1:8081"
NAGIOS_URL="http://$NAGIOS_BIND/nagios"

APP_USER="pinpoint"
APP_ROOT="/opt/pinpoint"
SERVER_DIR="$APP_ROOT/Network-Diagnosis-System/server"
CLIENT_DIR="$APP_ROOT/Network-Diagnosis-System/client"
VENV_DIR="$APP_ROOT/venv"

PINPOINT_ETC="/etc/pinpoint"
APP_ENV="$PINPOINT_ETC/pinpoint.env"
API_CREDENTIALS="$PINPOINT_ETC/nagios-api.env"

GUNICORN_SERVICE="pinpoint-gunicorn"
GUNICORN_BIND="127.0.0.1:8000"
NGINX_SITE="/etc/nginx/sites-available/pinpoint"

NMAP_BIN="/usr/bin/nmap"
NMAP_WRAPPER="/usr/local/bin/nmap-sudo"
NMAP_CAPS_HELPER="/usr/local/sbin/pinpoint-nmap-caps"
APT_HOOK="/etc/apt/apt.conf.d/80pinpoint-nmap-caps"
GUNICORN_DROPIN="/etc/systemd/system/$GUNICORN_SERVICE.service.d/nmap-capabilities.conf"

NAGIOS_GROUP="nagios"
NAGIOS_HOST_CFG="/usr/local/nagios/etc/objects/hosts.cfg"
PLUGIN_SERVICE_CFG="/usr/local/nagios/etc/objects/plugin-services.cfg"
NCPA_KEY="$APP_ROOT/.ssh/pinpoint_ncpa_deploy"

# status.dat is rewritten every 10 seconds by default.
STATUS_MAX_AGE=120

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

##################################################
# Helpers
##################################################

pass() { echo "  [PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
warn() { echo "  [WARN] $1"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { echo "  [FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

section() { echo; echo "== $1 =="; }

# HTTP status code of a URL, or 000 if unreachable.
http_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true
}

# GET a Nagios CGI as pinpoint-api. The password is fed
# to curl on stdin so it never appears in the process list.
nagios_api() {
    printf 'user = "%s:%s"\n' "$API_USER" "$API_PASSWORD" \
        | curl -s --max-time 15 -K - "$NAGIOS_URL/cgi-bin/$1" || true
}

check_service() {
    if systemctl is-active --quiet "$1"; then
        pass "$1 is running."
    else
        fail "$1 is not running ($(systemctl is-active "$1"))."
    fi

    if systemctl is-enabled --quiet "$1" 2> /dev/null; then
        pass "$1 starts at boot."
    else
        fail "$1 is not enabled at boot."
    fi
}

# Local addresses listening on a TCP port, one per line.
listeners() {
    ss -ltnH "sport = :$1" | awk '{print $4}' | sort -u
}

# Run Python (from stdin) in the application environment
# as the service account, without starting the scheduler.
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

##################################################
# Root Check
##################################################

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

echo "======================================"
echo " PinPoint - Health Check"
echo " $(hostname) - $(date)"
echo "======================================"

##################################################
# Nagios Core
##################################################

section "Nagios Core"

if [ -x "$NAGIOS_BIN" ]; then
    pass "Nagios installed: $("$NAGIOS_BIN" --version 2> /dev/null | grep -m1 -o 'Nagios Core [0-9.]*')."
else
    fail "$NAGIOS_BIN not found."
fi

check_service nagios

VERIFY_OUTPUT="$("$NAGIOS_BIN" -v "$NAGIOS_CFG" 2>&1)"
VERIFY_RC=$?
NAGIOS_WARNINGS="$(printf '%s' "$VERIFY_OUTPUT" | sed -n 's/^Total Warnings: *//p')"
NAGIOS_ERRORS="$(printf '%s' "$VERIFY_OUTPUT" | sed -n 's/^Total Errors: *//p')"

if [ "$VERIFY_RC" -eq 0 ] && [ "${NAGIOS_ERRORS:-1}" = "0" ]; then
    pass "Configuration valid (${NAGIOS_WARNINGS:-0} warnings, 0 errors)."
    if [ "${NAGIOS_WARNINGS:-0}" != "0" ]; then
        warn "Review warnings with: $NAGIOS_BIN -v $NAGIOS_CFG"
    fi
else
    fail "Configuration invalid (${NAGIOS_ERRORS:-?} errors)."
    printf '%s\n' "$VERIFY_OUTPUT" | grep -E '^(Error|Warning):' | head -10 | sed 's/^/         /'
fi

if [ -f "$NAGIOS_STATUS" ]; then
    STATUS_AGE=$(( $(date +%s) - $(stat -c %Y "$NAGIOS_STATUS") ))
    if [ "$STATUS_AGE" -le "$STATUS_MAX_AGE" ]; then
        pass "status.dat updated ${STATUS_AGE}s ago."
    else
        fail "status.dat is stale (${STATUS_AGE}s old). Nagios may be hung."
    fi
else
    fail "$NAGIOS_STATUS not found."
fi

if [ -p "$NAGIOS_CMD" ]; then
    pass "External command pipe exists."
else
    warn "External command pipe $NAGIOS_CMD not found."
fi

for PLUGIN in check_ping check_http check_snmp; do
    if [ -x "$NAGIOS_LIBEXEC/$PLUGIN" ]; then
        pass "Plugin $PLUGIN installed."
    else
        fail "Plugin $PLUGIN missing from $NAGIOS_LIBEXEC."
    fi
done

##################################################
# Apache (Nagios web / CGIs)
##################################################

section "Apache (Nagios CGIs)"

check_service apache2

if apache2ctl configtest > /dev/null 2>&1; then
    pass "Apache configuration valid."
else
    fail "Apache configuration invalid (run: apache2ctl configtest)."
fi

APACHE_LISTENERS="$(ss -ltnpH | grep '"apache2"' | awk '{print $4}' | sort -u)"

if [ "$APACHE_LISTENERS" = "$NAGIOS_BIND" ]; then
    pass "Apache listens on $NAGIOS_BIND only."
else
    fail "Apache listens on: $(echo $APACHE_LISTENERS) (expected $NAGIOS_BIND only)."
fi

CODE="$(http_code "$NAGIOS_URL/")"

if [ "$CODE" = "401" ]; then
    pass "Nagios web requires authentication (HTTP 401)."
elif [ "$CODE" = "200" ]; then
    fail "Nagios web is reachable without a password (HTTP 200)."
else
    fail "Nagios web returned HTTP $CODE."
fi

##################################################
# Nagios API Account
##################################################

section "Nagios API (pinpoint-api)"

API_USER=""
API_PASSWORD=""

if [ -f "$API_CREDENTIALS" ]; then
    API_USER="$(sed -n 's/^NAGIOS_USERNAME=//p' "$API_CREDENTIALS")"
    API_PASSWORD="$(sed -n 's/^NAGIOS_PASSWORD=//p' "$API_CREDENTIALS")"

    if [ "$(stat -c '%U:%G %a' "$API_CREDENTIALS")" = "root:root 600" ]; then
        pass "$API_CREDENTIALS is root-only (600)."
    else
        fail "$API_CREDENTIALS permissions are $(stat -c '%U:%G %a' "$API_CREDENTIALS") (expected root:root 600)."
    fi
else
    fail "$API_CREDENTIALS not found."
fi

if [ -n "$API_USER" ]; then

    for KEY in \
        authorized_for_system_information \
        authorized_for_configuration_information \
        authorized_for_all_hosts \
        authorized_for_all_services; do

        if ! grep -q "^$KEY=.*\b$API_USER\b" "$CGI_CFG"; then
            fail "$API_USER missing from $KEY in cgi.cfg."
        fi
    done

    for KEY in \
        authorized_for_all_host_commands \
        authorized_for_all_service_commands; do

        if grep -q "^$KEY=.*\b$API_USER\b" "$CGI_CFG"; then
            warn "$API_USER has command rights ($KEY). Expected read-only."
        fi
    done

    RESPONSE="$(nagios_api 'statusjson.cgi?query=programstatus')"

    if printf '%s' "$RESPONSE" | grep -Eq '"type_code":[[:space:]]*0'; then
        pass "$API_USER can read statusjson."
    else
        fail "$API_USER cannot read statusjson."
    fi

    RESPONSE="$(nagios_api 'objectjson.cgi?query=hostcount')"
    HOST_COUNT="$(printf '%s' "$RESPONSE" | grep -o '"count":[[:space:]]*[0-9]*' | grep -o '[0-9]*$')"

    if [ -n "$HOST_COUNT" ] && [ "$HOST_COUNT" -gt 0 ]; then
        pass "Nagios is monitoring $HOST_COUNT host(s)."
    else
        fail "objectjson returned no hosts."
    fi

    RESPONSE="$(nagios_api 'statusjson.cgi?query=hostcount')"
    HOSTS_UP="$(printf '%s' "$RESPONSE" | grep -o '"up":[[:space:]]*[0-9]*' | grep -o '[0-9]*$')"
    HOSTS_DOWN="$(printf '%s' "$RESPONSE" | grep -o '"down":[[:space:]]*[0-9]*' | grep -o '[0-9]*$')"

    if [ -n "$HOSTS_UP" ]; then
        if [ "${HOSTS_DOWN:-0}" = "0" ]; then
            pass "Host status: $HOSTS_UP up, 0 down."
        else
            warn "Host status: $HOSTS_UP up, $HOSTS_DOWN down."
        fi
    fi

fi

unset API_PASSWORD RESPONSE

##################################################
# Gunicorn
##################################################

section "Gunicorn ($GUNICORN_SERVICE)"

check_service "$GUNICORN_SERVICE"

RESTARTS="$(systemctl show -p NRestarts --value "$GUNICORN_SERVICE" 2> /dev/null)"

if [ "${RESTARTS:-0}" -gt 0 ]; then
    warn "$GUNICORN_SERVICE has restarted $RESTARTS time(s) since boot."
fi

GUNICORN_LISTENERS="$(listeners 8000)"

if [ "$GUNICORN_LISTENERS" = "$GUNICORN_BIND" ]; then
    pass "Gunicorn listens on $GUNICORN_BIND only."
elif [ -z "$GUNICORN_LISTENERS" ]; then
    fail "Nothing is listening on port 8000."
else
    fail "Port 8000 listeners: $(echo $GUNICORN_LISTENERS) (expected $GUNICORN_BIND only)."
fi

# One master + one worker. More workers would duplicate the
# app's background scheduler.
MAIN_PID="$(systemctl show -p MainPID --value "$GUNICORN_SERVICE")"
WORKERS=0

if [ "${MAIN_PID:-0}" != "0" ]; then
    WORKERS="$(pgrep -c -P "$MAIN_PID")"
fi

if [ "$WORKERS" = "1" ]; then
    pass "Gunicorn has 1 worker."
else
    fail "Gunicorn has $WORKERS worker(s) (expected 1)."
fi

if systemctl show -p Environment --value "$GUNICORN_SERVICE" | grep -qw 'PINPOINT_SCHEDULER=1'; then
    pass "Background scheduler enabled for $GUNICORN_SERVICE."
else
    fail "$GUNICORN_SERVICE does not set PINPOINT_SCHEDULER=1."
fi

if [ "$(stat -c '%U:%G %a' "$APP_ENV" 2> /dev/null)" = "root:$APP_USER 640" ]; then
    pass "$APP_ENV permissions are root:$APP_USER 640."
else
    fail "$APP_ENV permissions are $(stat -c '%U:%G %a' "$APP_ENV" 2> /dev/null || echo missing)."
fi

NETWORKS_VALUE="$(sed -n 's/^PINPOINT_NETWORKS=//p' "$APP_ENV" 2> /dev/null)"

if [ -n "$NETWORKS_VALUE" ]; then
    pass "Discovery range: $NETWORKS_VALUE."
else
    warn "PINPOINT_NETWORKS not set in $APP_ENV. Re-run deploy-pinpoint-web.sh."
fi

for DB_FILE in system.db history.db; do
    if [ -f "$SERVER_DIR/$DB_FILE" ]; then
        pass "$DB_FILE present."
    else
        fail "$SERVER_DIR/$DB_FILE missing."
    fi
done

if [ -f "$SERVER_DIR/migrations/env.py" ]; then

    MIGRATION_RESULT="$(run_app_python 2>&1 <<'EOF'
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
                raise SystemExit("system.db has no migration revision")
            continue
        current = {row[0] for row in con.execute("SELECT version_num FROM alembic_version")}
    finally:
        con.close()

    if current != heads:
        raise SystemExit(f"{name} is at {sorted(current)}, expected {sorted(heads)}")

print(", ".join(sorted(heads)))
EOF
)"

    if [ $? -eq 0 ]; then
        pass "Database schema at latest migration ($MIGRATION_RESULT)."
    else
        fail "Database schema out of date: $(printf '%s' "$MIGRATION_RESULT" | tail -1). Re-run deploy-pinpoint-web.sh."
    fi

else
    warn "Application has no migrations; database upgrades are not possible."
fi

CODE="$(http_code "http://$GUNICORN_BIND/api/user/login")"

case "$CODE" in
    000|5*) fail "Gunicorn API returned HTTP $CODE." ;;
    *)      pass "Gunicorn API responds directly (HTTP $CODE)." ;;
esac

# Same check deploy-pinpoint-web.sh runs: the app's own
# config and credentials must reach Nagios.
run_app_python > /dev/null 2>&1 <<'EOF'
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
    raise SystemExit(1)
EOF

if [ $? -eq 0 ]; then
    pass "Flask can read Nagios with its configured credentials."
else
    fail "Flask cannot read Nagios. Check NAGIOS_* in $APP_ENV."
fi

TRACEBACKS="$(journalctl -u "$GUNICORN_SERVICE" --since '-1h' --no-pager 2> /dev/null | grep -c 'Traceback')"

if [ "$TRACEBACKS" = "0" ]; then
    pass "No Python tracebacks in the last hour."
else
    warn "$TRACEBACKS Python traceback(s) in the last hour (journalctl -u $GUNICORN_SERVICE)."
fi

##################################################
# Nagios Config Access (Discovery, Plugin Manager)
##################################################

section "Nagios Config Access"

if id -nG "$APP_USER" 2> /dev/null | grep -qw "$NAGIOS_GROUP"; then
    pass "$APP_USER is in the $NAGIOS_GROUP group."
else
    fail "$APP_USER is not in the $NAGIOS_GROUP group."
fi

for CFG in "$NAGIOS_HOST_CFG" "$PLUGIN_SERVICE_CFG"; do

    if [ "$(stat -c '%U:%G %a' "$CFG" 2> /dev/null)" = "$APP_USER:$NAGIOS_GROUP 664" ]; then
        pass "$(basename "$CFG") is $APP_USER:$NAGIOS_GROUP 664."
    else
        fail "$CFG is $(stat -c '%U:%G %a' "$CFG" 2> /dev/null || echo missing) (expected $APP_USER:$NAGIOS_GROUP 664)."
    fi

    if grep -qx "cfg_file=$CFG" "$NAGIOS_CFG"; then
        pass "nagios.cfg loads $(basename "$CFG")."
    else
        fail "nagios.cfg does not load $CFG."
    fi

done

if runuser -u "$APP_USER" -- "$NAGIOS_BIN" -v "$NAGIOS_CFG" > /dev/null 2>&1; then
    pass "$APP_USER can validate the Nagios configuration."
else
    fail "$APP_USER cannot run $NAGIOS_BIN -v."
fi

if runuser -u "$APP_USER" -- sudo -n -l /usr/bin/systemctl reload nagios > /dev/null 2>&1; then
    pass "$APP_USER can reload Nagios through sudo."
else
    fail "$APP_USER cannot run 'sudo systemctl reload nagios'."
fi

if runuser -u "$APP_USER" -- sudo -n -l /usr/bin/systemctl restart nagios > /dev/null 2>&1; then
    fail "$APP_USER has sudo rights beyond 'systemctl reload nagios'."
fi

if runuser -u "$APP_USER" -- test -r "$NCPA_KEY"; then
    pass "NCPA deployment key present."
else
    fail "$NCPA_KEY missing or unreadable by $APP_USER."
fi

##################################################
# nmap (Discovery)
##################################################

section "nmap (Discovery)"

if [ -x "$NMAP_BIN" ]; then
    pass "nmap installed."
else
    fail "$NMAP_BIN not found."
fi

if [ "$(stat -c '%U:%G %a' "$NMAP_BIN" 2> /dev/null)" = "root:$APP_USER 750" ]; then
    pass "$NMAP_BIN permissions are root:$APP_USER 750."
else
    fail "$NMAP_BIN permissions are $(stat -c '%U:%G %a' "$NMAP_BIN" 2> /dev/null || echo missing)."
fi

if getcap "$NMAP_BIN" 2> /dev/null | grep -q 'cap_net_raw'; then
    pass "nmap has raw-socket capabilities."
else
    fail "nmap has no capabilities. Run $NMAP_CAPS_HELPER."
fi

if [ -x "$NMAP_WRAPPER" ]; then
    pass "$NMAP_WRAPPER installed."
else
    fail "$NMAP_WRAPPER missing."
fi

if [ -f "$APT_HOOK" ] && [ -f "$GUNICORN_DROPIN" ]; then
    pass "Capabilities are re-applied after upgrades and on restart."
else
    warn "Capability re-apply hook missing. An nmap upgrade will break Discovery."
fi

# Same SYN scan type Discovery uses, as the service account.
SCAN_OUTPUT="$(runuser -u "$APP_USER" -- \
    timeout 60 "$NMAP_WRAPPER" -sS -Pn -p 22 127.0.0.1 2>&1)"

if [ $? -eq 0 ] && ! printf '%s' "$SCAN_OUTPUT" | grep -Eqi 'QUITTING|requires root|Operation not permitted'; then
    pass "$APP_USER can run a SYN scan."
else
    fail "$APP_USER cannot run a SYN scan with $NMAP_WRAPPER."
fi

##################################################
# Nginx
##################################################

section "Nginx"

check_service nginx

if nginx -t > /dev/null 2>&1; then
    pass "Nginx configuration valid."
else
    fail "Nginx configuration invalid (run: nginx -t)."
fi

if [ "$(readlink -f /etc/nginx/sites-enabled/pinpoint)" = "$NGINX_SITE" ]; then
    pass "PinPoint site enabled."
else
    fail "PinPoint site is not enabled in /etc/nginx/sites-enabled."
fi

if [ -e /etc/nginx/sites-enabled/default ]; then
    fail "Default Nginx site is still enabled."
fi

if ss -ltnpH 'sport = :80' | grep -q '"nginx"'; then
    pass "Nginx owns port 80 ($(echo $(listeners 80)))."
else
    fail "Nginx is not listening on port 80."
fi

if curl -fsS --max-time 10 http://127.0.0.1/ | grep -q 'id="root"'; then
    pass "Web interface served at /."
else
    fail "Web interface not served at /."
fi

# Single-page app routes must fall back to index.html.
if curl -fsS --max-time 10 http://127.0.0.1/pinpoint-healthcheck-route | grep -q 'id="root"'; then
    pass "Client-side routes fall back to index.html."
else
    fail "Client-side routes do not fall back to index.html."
fi

ASSET="$(ls "$CLIENT_DIR/dist/assets/"*.js 2> /dev/null | head -1)"

if [ -n "$ASSET" ]; then
    CODE="$(http_code "http://127.0.0.1/assets/$(basename "$ASSET")")"
    if [ "$CODE" = "200" ]; then
        pass "Static assets served (HTTP 200)."
    else
        fail "Static asset returned HTTP $CODE."
    fi
else
    fail "No built assets in $CLIENT_DIR/dist/assets."
fi

CODE="$(http_code http://127.0.0.1/api/user/login)"

case "$CODE" in
    000|502|503|504) fail "Nginx cannot reach Gunicorn (HTTP $CODE)." ;;
    *)               pass "Nginx forwards /api/ to Gunicorn (HTTP $CODE)." ;;
esac

##################################################
# LAN Exposure
##################################################

section "LAN Exposure"

SERVER_IP="$(ip -4 route get 1.1.1.1 2> /dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')"

if [ -z "$SERVER_IP" ]; then
    SERVER_IP="$(hostname -I | awk '{print $1}')"
fi

if [ -n "$SERVER_IP" ]; then

    if [ "$(http_code "http://$SERVER_IP/")" = "200" ]; then
        pass "Web interface reachable at http://$SERVER_IP/."
    else
        fail "Web interface not reachable at http://$SERVER_IP/."
    fi

    # Backend ports must stay on localhost.
    for PORT in 8000 8081; do
        if [ "$(http_code "http://$SERVER_IP:$PORT/")" = "000" ]; then
            pass "Port $PORT not exposed on $SERVER_IP."
        else
            fail "Port $PORT is reachable on $SERVER_IP."
        fi
    done

else
    warn "Could not determine the server LAN address."
fi

if command -v ufw > /dev/null && ufw status | grep -q '^Status: active'; then
    if ufw status | grep -Eq '^(80|80/tcp|Nginx (HTTP|Full))[[:space:]]+ALLOW'; then
        pass "UFW allows HTTP."
    else
        fail "UFW is active but does not allow port 80."
    fi
fi

##################################################
# Summary
##################################################

echo
echo "======================================"
echo " $PASS_COUNT passed, $WARN_COUNT warnings, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo " PinPoint is healthy."
else
    echo " PinPoint has problems. See [FAIL] lines above."
fi
echo "======================================"

exit "$FAIL_COUNT"
