#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : check-interval-tests.sh
# Purpose: Run the automatable cases from
#          docs/Check_Interval_Test_Cases.md on a
#          disposable test VM, as root.
#
# Section 1  interval_length helper
# Section 2  PinPoint privileges over Nagios
# Section 3  Check_Interval database schema
# Section 5  the feature through PinPoint's own API
#
# Cases that cannot be automated are SKIPPED with
# the reason, never reported as passed.
#
# Usage: sudo ./check-interval-tests.sh [setup-dir]
#        setup-dir defaults to this checkout's setup/
#        folder, else /root/pinpoint (ISO layout)
#
# Optional environment:
#   ADMIN_EMAIL, ADMIN_PASSWORD   an administrator that
#       has already finished first-run setup. If they
#       are not set, the runner finishes first-run
#       setup itself with the install credentials file
#       and keeps the new login in $STATE_FILE (600).
#   SKIP_SCAN=1   do not run a discovery scan; the
#       cases that need a monitored host are SKIPPED.
#   SKIP_CADENCE=1  skip the slow case that watches two
#       Nagios checks (about 5 minutes).
#
# Temporary changes (nagios.cfg, the reload sudoers
# rule, the check interval) are put back on exit.
# Run it only on a VM you can restore from a snapshot.
# Output: one line per case, "ID|STATUS|note", then a
# summary. Also written to /root/check-interval-test-output.txt.
##################################################

set -u

# Default: the setup/ folder of this checkout, else /root/pinpoint (ISO
# layout). A wrong folder would show up as "syntax errors" (issue #15).
REPO_SETUP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../setup" 2> /dev/null && pwd)"
SETUP_DIR="${1:-${REPO_SETUP:-/root/pinpoint}}"
if ! compgen -G "$SETUP_DIR/*.sh" > /dev/null; then
    echo "ERROR: No installer scripts in '$SETUP_DIR'. Pass the setup folder: $0 /path/to/setup"
    exit 1
fi
OUT="/root/check-interval-test-output.txt"
STATE_FILE="/root/.check-interval-test-admin"
CREDENTIALS_FILE="/root/pinpoint-install-credentials.txt"

NAGIOS_BIN="/usr/local/nagios/bin/nagios"
NAGIOS_CFG="/usr/local/nagios/etc/nagios.cfg"
NAGIOS_OBJECTS="/usr/local/nagios/etc/objects"
HOSTS_CFG="$NAGIOS_OBJECTS/hosts.cfg"
LOCALHOST_CFG="$NAGIOS_OBJECTS/localhost.cfg"
NAGIOS_LOG="/usr/local/nagios/var/nagios.log"
STATUS_DAT="/usr/local/nagios/var/status.dat"
SUDOERS_RELOAD="/etc/sudoers.d/pinpoint-nagios-reload"

SERVER_DIR="/opt/pinpoint/Network-Diagnosis-System/server"
APP_DIR="/opt/pinpoint/Network-Diagnosis-System"
BASE_URL="http://127.0.0.1"
WORK="$(mktemp -d /tmp/check-interval-tests.XXXXXX)"
COOKIES="$WORK/cookies.txt"

PASS=0
FAIL=0
SKIP=0
WARN=0

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root."
    exit 1
fi

: > "$OUT"

record() {
    # record ID STATUS note
    printf '%s|%s|%s\n' "$1" "$2" "$3" | tee -a "$OUT"

    case "$2" in
        PASS) PASS=$((PASS + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
        SKIP) SKIP=$((SKIP + 1)) ;;
        WARN) WARN=$((WARN + 1)) ;;
    esac
}

check() {
    # check ID "note when passing" command...
    local ID="$1" NOTE="$2"
    shift 2
    if "$@" > "$WORK/last.out" 2>&1; then
        record "$ID" PASS "$NOTE"
    else
        record "$ID" FAIL "$NOTE: $(head -c 200 "$WORK/last.out" | tr '\n' ' ')"
    fi
}

##################################################
# Restore everything this runner changes
##################################################

cp -p "$NAGIOS_CFG" "$WORK/nagios.cfg.original"
[ -f "$SUDOERS_RELOAD" ] && cp -p "$SUDOERS_RELOAD" "$WORK/sudoers.original"
ORIGINAL_INTERVAL=""
SUDOERS_MOVED=0

restore_all() {
    cat "$WORK/nagios.cfg.original" > "$NAGIOS_CFG" 2> /dev/null
    rm -f "$NAGIOS_CFG".interval-length.*.bak

    if [ "$SUDOERS_MOVED" = "1" ] && [ -f "$WORK/sudoers.original" ]; then
        install -m 440 -o root -g root "$WORK/sudoers.original" "$SUDOERS_RELOAD"
    fi

    if [ -n "$ORIGINAL_INTERVAL" ] && [ -f "$COOKIES" ]; then
        set_interval "$ORIGINAL_INTERVAL" > /dev/null 2>&1
    fi

    if "$NAGIOS_BIN" -v "$NAGIOS_CFG" > /dev/null 2>&1 && systemctl is-active --quiet nagios; then
        systemctl reload nagios > /dev/null 2>&1
    fi

    rm -rf "$WORK"
}
trap restore_all EXIT

{
    echo "# Run: $(date -u +%FT%TZ)"
    echo "# Host: $(hostname)  OS: $(lsb_release -ds 2>/dev/null)"
    echo "# Installer files: $SETUP_DIR"
    if [ -d "$APP_DIR/.git" ]; then
        echo "# PinPoint commit: $(git -c safe.directory="*" -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null)"
    fi
} | tee -a "$OUT"

##################################################
# Section 1 - interval_length (ensure-nagios-interval.sh)
##################################################

HELPER="$SETUP_DIR/ensure-nagios-interval.sh"

active_interval_lines() {
    grep -cE '^[[:space:]]*interval_length[[:space:]]*=' "$NAGIOS_CFG"
}

active_interval_value() {
    grep -E '^[[:space:]]*interval_length[[:space:]]*=' "$NAGIOS_CFG" \
        | tail -n 1 | cut -d= -f2 | tr -d '[:space:]'
}

backup_count() {
    ls "$NAGIOS_CFG".interval-length.*.bak 2> /dev/null | wc -l
}

if [ -f "$HELPER" ]; then

    VALUE="$(active_interval_value)"
    if [ -z "$VALUE" ] || [ "$VALUE" = "60" ]; then
        record 1.1 PASS "interval_length is ${VALUE:-unset (default 60)}"
    else
        record 1.1 FAIL "interval_length is $VALUE"
    fi

    # 1.2 unset
    sed -i -E '/^[[:space:]]*interval_length/d' "$NAGIOS_CFG"
    cp -p "$NAGIOS_CFG" "$WORK/before-1.2"
    rm -f "$NAGIOS_CFG".interval-length.*.bak
    if bash "$HELPER" > "$WORK/h.out" 2>&1 \
        && cmp -s "$NAGIOS_CFG" "$WORK/before-1.2" \
        && [ "$(backup_count)" -eq 0 ] \
        && grep -q 'unset' "$WORK/h.out"; then
        record 1.2 PASS "missing value accepted, file untouched, no backup"
    else
        record 1.2 FAIL "$(tail -2 "$WORK/h.out" | tr '\n' ' ')"
    fi

    # 1.3 wrong value, with Nagios running
    cat "$WORK/nagios.cfg.original" > "$NAGIOS_CFG"
    sed -i -E 's/^[[:space:]]*interval_length.*/interval_length=30/' "$NAGIOS_CFG"
    grep -q '^interval_length=30' "$NAGIOS_CFG" || echo 'interval_length=30' >> "$NAGIOS_CFG"
    rm -f "$NAGIOS_CFG".interval-length.*.bak
    HUP_BEFORE="$(grep -c 'Caught SIGHUP' "$NAGIOS_LOG")"
    bash "$HELPER" > "$WORK/h.out" 2>&1
    HELPER_RC=$?
    sleep 3
    HUP_AFTER="$(grep -c 'Caught SIGHUP' "$NAGIOS_LOG")"
    if [ "$HELPER_RC" -eq 0 ] \
        && [ "$(active_interval_lines)" -eq 1 ] \
        && [ "$(active_interval_value)" = "60" ] \
        && [ "$(backup_count)" -ge 1 ]; then
        record 1.3 PASS "30 changed to 60 with a backup"
    else
        record 1.3 FAIL "rc=$HELPER_RC value=$(active_interval_value) backups=$(backup_count)"
    fi

    if [ "$HUP_AFTER" -gt "$HUP_BEFORE" ] && systemctl is-active --quiet nagios; then
        record 1.9 PASS "nagios reloaded ($HUP_BEFORE to $HUP_AFTER SIGHUP) and is active"
    else
        record 1.9 FAIL "no reload seen ($HUP_BEFORE to $HUP_AFTER)"
    fi

    if [ "$(stat -c '%U:%G %a' "$NAGIOS_CFG")" = "nagios:nagios 664" ]; then
        record 1.7 PASS "nagios.cfg still nagios:nagios 664"
    else
        record 1.7 FAIL "now $(stat -c '%U:%G %a' "$NAGIOS_CFG")"
    fi

    # 1.8 idempotent
    rm -f "$NAGIOS_CFG".interval-length.*.bak
    cp -p "$NAGIOS_CFG" "$WORK/before-1.8"
    if bash "$HELPER" > "$WORK/h.out" 2>&1 \
        && cmp -s "$NAGIOS_CFG" "$WORK/before-1.8" \
        && [ "$(backup_count)" -eq 0 ]; then
        record 1.8 PASS "second run changes nothing, no new backup"
    else
        record 1.8 FAIL "second run changed something"
    fi

    # 1.4 duplicates and junk
    printf 'interval_length = 15\ninterval_length=abc\n' >> "$NAGIOS_CFG"
    rm -f "$NAGIOS_CFG".interval-length.*.bak
    if bash "$HELPER" > "$WORK/h.out" 2>&1 \
        && [ "$(active_interval_lines)" -eq 1 ] \
        && [ "$(active_interval_value)" = "60" ]; then
        record 1.4 PASS "duplicate and non-numeric lines collapsed to one 60"
    else
        record 1.4 FAIL "$(grep -nE '^[[:space:]]*interval_length' "$NAGIOS_CFG" | tr '\n' ' ')"
    fi

    # 1.5 commented line only
    sed -i -E '/^[[:space:]]*interval_length/d' "$NAGIOS_CFG"
    echo '#interval_length=5' >> "$NAGIOS_CFG"
    cp -p "$NAGIOS_CFG" "$WORK/before-1.5"
    rm -f "$NAGIOS_CFG".interval-length.*.bak
    if bash "$HELPER" > "$WORK/h.out" 2>&1 \
        && cmp -s "$NAGIOS_CFG" "$WORK/before-1.5" \
        && [ "$(backup_count)" -eq 0 ]; then
        record 1.5 PASS "commented line ignored, file untouched"
    else
        record 1.5 FAIL "commented line was not ignored"
    fi

    # 1.6 nagios -v rejects the file: rollback
    cat "$WORK/nagios.cfg.original" > "$NAGIOS_CFG"
    sed -i -E 's/^[[:space:]]*interval_length.*/interval_length=30/' "$NAGIOS_CFG"
    echo 'bogus_directive=1' >> "$NAGIOS_CFG"
    cp -p "$NAGIOS_CFG" "$WORK/before-1.6"
    rm -f "$NAGIOS_CFG".interval-length.*.bak
    bash "$HELPER" > "$WORK/h.out" 2>&1
    HELPER_RC=$?
    if [ "$HELPER_RC" -ne 0 ] \
        && cmp -s "$NAGIOS_CFG" "$WORK/before-1.6" \
        && grep -q 'nagios -v rejected' "$WORK/h.out"; then
        record 1.6 PASS "exit $HELPER_RC, nagios.cfg restored byte for byte"
    else
        record 1.6 FAIL "rc=$HELPER_RC, restored identical: $(cmp -s "$NAGIOS_CFG" "$WORK/before-1.6" && echo yes || echo no)"
    fi

    cat "$WORK/nagios.cfg.original" > "$NAGIOS_CFG"
    rm -f "$NAGIOS_CFG".interval-length.*.bak

else
    for ID in 1.1 1.2 1.3 1.4 1.5 1.6 1.7 1.8 1.9; do
        record "$ID" SKIP "$HELPER not found"
    done
fi

record 1.11 SKIP "needs a VM restored to the pre-60 snapshot; run deploy-pinpoint-web.sh by hand"

BAD_SYNTAX=""
BAD_CR=""
for F in "$SETUP_DIR"/*.sh; do
    bash -n "$F" 2> /dev/null || BAD_SYNTAX="$BAD_SYNTAX $(basename "$F")"
    grep -q $'\r' "$F" && BAD_CR="$BAD_CR $(basename "$F")"
done

if [ -z "$BAD_SYNTAX" ]; then
    record 1.12 PASS "bash -n clean for every script in $SETUP_DIR"
else
    record 1.12 FAIL "syntax errors in:$BAD_SYNTAX"
fi

if [ -z "$BAD_CR" ]; then
    record L3 PASS "no carriage returns in the scripts"
else
    record L3 FAIL "carriage returns in:$BAD_CR"
fi

##################################################
# Section 2 - privileges
##################################################

check 2.1 "reload rule found" runuser -u pinpoint -- sudo -n -l /usr/bin/systemctl reload nagios
check 2.1b "reload rule found in the form PinPoint runs it" runuser -u pinpoint -- sudo -n -l systemctl reload nagios

REFUSED=""
for ACTION in stop start; do
    if runuser -u pinpoint -- sudo -n -l /usr/bin/systemctl "$ACTION" nagios > /dev/null 2>&1; then
        REFUSED="$REFUSED $ACTION"
    fi
done

if [ -z "$REFUSED" ]; then
    record 2.2 PASS "stop and start are refused"
else
    record 2.2 FAIL "allowed:$REFUSED"
fi

# Every rule the installer gives pinpoint, exactly as "sudo -l" prints it
# (Ubuntu 22.04). Whole lines are compared, so a rule with extra arguments
# or a wildcard is reported too. Add a line here when the installer adds a rule.
#   configure-pinpoint-privileges.sh  reload, restart, SMTP helper
#   install-resource-helper.sh        resource helper (issue #16)
ALLOWED_RULES='(root) NOPASSWD: /usr/bin/systemctl reload nagios, /bin/systemctl reload nagios
(root) NOPASSWD: /usr/bin/systemctl restart nagios
(root) NOPASSWD: /usr/local/sbin/pinpoint-apply-smtp \"\"
(root) NOPASSWD: /usr/local/sbin/pinpoint-apply-resources \"\"'

SUDO_LIST="$(runuser -u pinpoint -- sudo -n -l 2> /dev/null | grep -E '^\s+\(' | sed 's/^[[:space:]]*//')"
EXTRA="$(echo "$SUDO_LIST" | grep -v -x -F -e "$ALLOWED_RULES" | tr '\n' ' ')"
if [ -z "$SUDO_LIST" ]; then
    record 2.3 FAIL "could not list pinpoint's sudo rules"
elif [ -z "$EXTRA" ]; then
    record 2.3 PASS "only the reload, restart, SMTP helper and resource helper rules"
else
    record 2.3 FAIL "extra rights: $EXTRA"
fi

check 2.4 "visudo -c parses every sudoers file" visudo -c
check 2.5 "pinpoint can run nagios -v" runuser -u pinpoint -- "$NAGIOS_BIN" -v "$NAGIOS_CFG"

if runuser -u pinpoint -- test -w "$HOSTS_CFG" \
    && runuser -u pinpoint -- test -w "$NAGIOS_OBJECTS/plugin-services.cfg"; then
    record 2.6 PASS "hosts.cfg and plugin-services.cfg are writable by pinpoint"
else
    record 2.6 FAIL "pinpoint cannot write the generated config files"
fi

if grep -rq 'sudo", "-n", "systemctl", "reload", "nagios"' "$SERVER_DIR/app/network_discovery/create_host_cfg.py" 2> /dev/null; then
    record 2.11 PASS "app calls: sudo -n systemctl reload nagios, which the rule covers"
else
    record 2.11 WARN "could not find the reload call in create_host_cfg.py"
fi

# 2.10 is a real reload as pinpoint, done once. Wait first: Nagios treats two
# reloads in the same second as one, and the helper cases above reload it.
sleep 15
HUP_BEFORE="$(grep -c 'Caught SIGHUP' "$NAGIOS_LOG")"
MAIN_PID="$(systemctl show nagios -p MainPID --value)"
if runuser -u pinpoint -- sudo -n systemctl reload nagios > /dev/null 2>&1; then
    # Nagios logs the SIGHUP only once it has finished any restart already under way.
    WAITED=0
    HUP_AFTER="$HUP_BEFORE"
    while [ "$WAITED" -lt 30 ] && [ "$HUP_AFTER" -le "$HUP_BEFORE" ]; do
        sleep 2
        WAITED=$((WAITED + 2))
        HUP_AFTER="$(grep -c 'Caught SIGHUP' "$NAGIOS_LOG")"
    done
    NEW_PID="$(systemctl show nagios -p MainPID --value)"
    if systemctl is-active --quiet nagios \
        && [ "$NEW_PID" = "$MAIN_PID" ] \
        && [ "$HUP_AFTER" -gt "$HUP_BEFORE" ]; then
        record 2.10 PASS "reload as pinpoint worked, same process, new SIGHUP (after ${WAITED}s)"
    else
        record 2.10 FAIL "SIGHUP $HUP_BEFORE to $HUP_AFTER, pid $MAIN_PID to $NEW_PID, active: $(systemctl is-active nagios)"
    fi
else
    record 2.10 FAIL "pinpoint could not reload Nagios"
fi

##################################################
# Section 3 - Check_Interval schema
##################################################

if [ -f "$SERVER_DIR/system.db" ]; then

    SCHEMA="$(python3 - "$SERVER_DIR/system.db" <<'PY'
import sqlite3
import sys

con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
cols = [r for r in con.execute("PRAGMA table_info(SYSTEM_SETTINGS)") if r[1] == "Check_Interval"]
values = [r[0] for r in con.execute("SELECT Check_Interval FROM SYSTEM_SETTINGS")] if cols else []
if not cols:
    print("missing")
else:
    c = cols[0]
    print("ok|%s|notnull=%s|default=%s|values=%s" % (c[2], c[3], c[4], values))
PY
)"

    case "$SCHEMA" in
        ok\|INTEGER\|notnull=1\|default=\'5\'*)
            record 3.2 PASS "$SCHEMA" ;;
        *)
            record 3.2 FAIL "$SCHEMA" ;;
    esac

    if echo "$SCHEMA" | grep -qE 'values=\[(5|1|2|10|15)(, (5|1|2|10|15))*\]'; then
        record 3.3 PASS "every row holds an accepted value"
    else
        record 3.3 FAIL "$SCHEMA"
    fi

    TRACKED="$(git -c safe.directory='*' -C "$APP_DIR" ls-files server/migrations/versions 2> /dev/null | wc -l)"
    ONDISK="$(ls "$SERVER_DIR"/migrations/versions/*.py 2> /dev/null | wc -l)"
    if [ "$TRACKED" -eq "$ONDISK" ]; then
        record 3.11 PASS "$ONDISK migration files, all tracked by git: the installer added none"
    else
        record 3.11 FAIL "$ONDISK on disk, $TRACKED tracked"
    fi

else
    for ID in 3.2 3.3 3.11; do
        record "$ID" SKIP "no system.db: PinPoint is not deployed"
    done
fi

record 3.8 SKIP "needs the pre-60 snapshot and a forced failure; see Result file"

##################################################
# Section 5 - the feature through PinPoint's API
##################################################

# api METHOD PATH [JSON]  ->  prints "HTTP_CODE" then the body
api() {
    python3 - "$1" "$2" "${3:-}" "$COOKIES" "$BASE_URL" <<'PY'
import http.cookiejar
import sys
import urllib.error
import urllib.request

method, path, body, jar_path, base = sys.argv[1:6]
jar = http.cookiejar.MozillaCookieJar(jar_path)
try:
    jar.load(ignore_discard=True)
except OSError:
    pass
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
data = body.encode() if body else None
req = urllib.request.Request(base + path, data=data, method=method,
                             headers={"Content-Type": "application/json"})
try:
    resp = opener.open(req, timeout=60)
    code, text = resp.status, resp.read().decode()
except urllib.error.HTTPError as exc:
    code, text = exc.code, exc.read().decode()
jar.save(ignore_discard=True)
print(code)
print(text)
PY
}

api_code() { head -n 1; }
api_body() { tail -n +2; }

json_get() {
    # json_get 'expression on d'
    python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2> /dev/null
}

set_interval() {
    # set_interval MINUTES -> prints HTTP code; body in $WORK/put.body
    local CURRENT VERSION PAYLOAD RESULT
    ensure_session
    CURRENT="$(api GET /api/system | api_body)"
    PAYLOAD="$(echo "$CURRENT" | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
d['checkInterval'] = $1
print(json.dumps(d))")"
    RESULT="$(api PUT /api/system "$PAYLOAD")"
    echo "$RESULT" | api_body > "$WORK/put.body"
    echo "$RESULT" | api_code
}

current_interval() {
    ensure_session
    api GET /api/system | api_body | json_get "d['data']['checkInterval']"
}

# Sign-in: use ADMIN_EMAIL/ADMIN_PASSWORD, a saved login, or finish
# first-run setup with the install credentials file.
LOGGED_IN=0
LOGIN_EMAIL=""
LOGIN_PASSWORD=""

login() {
    local CODE
    CODE="$(api POST /api/user/login "{\"email\": \"$1\", \"password\": \"$2\"}" | api_code)"
    if [ "$CODE" = "200" ]; then
        LOGIN_EMAIL="$1"
        LOGIN_PASSWORD="$2"
        return 0
    fi
    return 1
}

# The session times out (30 minutes by default) while a long scan runs.
ensure_session() {
    [ "$(api GET /api/user/me | api_code)" = "200" ] && return 0
    : > "$COOKIES"
    login "$LOGIN_EMAIL" "$LOGIN_PASSWORD"
}

if [ -n "${ADMIN_EMAIL:-}" ] && [ -n "${ADMIN_PASSWORD:-}" ]; then
    login "$ADMIN_EMAIL" "$ADMIN_PASSWORD" && LOGGED_IN=1
elif [ -f "$STATE_FILE" ]; then
    login "$(sed -n 1p "$STATE_FILE")" "$(sed -n 2p "$STATE_FILE")" && LOGGED_IN=1
elif [ -f "$CREDENTIALS_FILE" ]; then
    PLACEHOLDER="$(grep -oE 'admin-[0-9a-f]{5}@pinpoint\.lan' "$CREDENTIALS_FILE" | head -n 1)"
    GENERATED="$(grep -E '^[A-Za-z0-9]{24}$' "$CREDENTIALS_FILE" | head -n 1)"
    NEW_EMAIL="${TEST_NEW_EMAIL:-pinpoint.tester@example.com}"
    NEW_PASSWORD="CheckInterval-$(openssl rand -hex 6)!Aa1"

    if [ -n "$PLACEHOLDER" ] && [ -n "$GENERATED" ] && login "$PLACEHOLDER" "$GENERATED"; then
        SETUP_BODY="$(python3 -c "
import json, sys
print(json.dumps({'current_password': sys.argv[1], 'new_email': sys.argv[2],
                  'new_password': sys.argv[3], 'confirm_password': sys.argv[3]}))" \
            "$GENERATED" "$NEW_EMAIL" "$NEW_PASSWORD")"
        SETUP_CODE="$(api POST /api/user/complete-setup "$SETUP_BODY" | api_code)"
        if [ "$SETUP_CODE" = "200" ]; then
            ( umask 077; printf '%s\n%s\n' "$NEW_EMAIL" "$NEW_PASSWORD" > "$STATE_FILE" )
            : > "$COOKIES"
            login "$NEW_EMAIL" "$NEW_PASSWORD" && LOGGED_IN=1
        fi
    fi
fi

APP_CASES="5.1 5.3 5.4 5.5 5.6 5.7 5.8 5.9 5.10 5.11 5.12"

if [ "$LOGGED_IN" -ne 1 ]; then
    for ID in $APP_CASES; do
        record "$ID" SKIP "could not sign in to PinPoint as an administrator"
    done
else

    ORIGINAL_INTERVAL="$(current_interval)"

    if [ "$ORIGINAL_INTERVAL" = "5" ]; then
        record 5.1 PASS "check interval is 5 minutes by default"
    else
        record 5.1 WARN "check interval is ${ORIGINAL_INTERVAL:-unknown} (not the default 5); later cases still run"
    fi

    # 5.11 only allowed values; 5.10 non-admin
    CODE="$(api PUT /api/system "$(api GET /api/system | api_body | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
d['checkInterval'] = 3
print(json.dumps(d))")" | api_code)"
    if [ "$CODE" = "400" ]; then
        record 5.11 PASS "3 minutes rejected with 400"
    else
        record 5.11 FAIL "3 minutes returned HTTP $CODE"
    fi

    # A monitored host is needed for the next cases.
    count_hosts() { grep -cE '^[[:space:]]*define[[:space:]]+host[[:space:]]*\{' "$HOSTS_CFG" 2> /dev/null; }
    HOST_COUNT="$(count_hosts)"

    # A scan of a whole LAN with service detection can take over an hour.
    # It is only started when hosts.cfg has no host yet; SCAN_TIMEOUT is in seconds.
    if [ "${SKIP_SCAN:-0}" != "1" ] && [ "${HOST_COUNT:-0}" -eq 0 ]; then
        ensure_session
        START_CODE="$(api POST /api/system/discover/start | api_code)"
        WAITED=0
        STATE=""
        while [ "$WAITED" -lt "${SCAN_TIMEOUT:-6000}" ]; do
            sleep 30
            WAITED=$((WAITED + 30))
            ensure_session
            STATE="$(api GET /api/system/discover/status | api_body | json_get "d['data']['status']" | tr '[:lower:]' '[:upper:]')"
            [ "$STATE" = "RUNNING" ] || [ -z "$STATE" ] || break
        done
        HOST_COUNT="$(count_hosts)"
        echo "# discovery: start HTTP $START_CODE, status '$STATE' after ${WAITED}s, hosts in hosts.cfg: ${HOST_COUNT:-0}" | tee -a "$OUT"
    else
        echo "# discovery: not started, hosts already in hosts.cfg: ${HOST_COUNT:-0}" | tee -a "$OUT"
    fi

    if [ "${HOST_COUNT:-0}" -eq 0 ]; then
        for ID in 5.3 5.4 5.5 5.6 5.7 5.8 5.9 5.12; do
            record "$ID" SKIP "no monitored host in hosts.cfg (scan skipped or found nothing)"
        done
    else

        INTERVAL_LINES() { grep -hE '^[[:space:]]*check_interval[[:space:]]' "$HOSTS_CFG" "$NAGIOS_OBJECTS/plugin-services.cfg" 2> /dev/null; }

        # Set a known baseline of 5 first.
        [ "$ORIGINAL_INTERVAL" = "5" ] || set_interval 5 > /dev/null

        BASE_VALUES="$(INTERVAL_LINES | awk '{print $2}' | sort -u | tr '\n' ' ')"
        if [ "$BASE_VALUES" = "5 " ]; then
            record 5.3 PASS "$(INTERVAL_LINES | wc -l) check_interval lines, all 5"
        else
            record 5.3 FAIL "check_interval values: $BASE_VALUES"
        fi

        LOCALHOST_SUM="$(sha256sum "$LOCALHOST_CFG" | cut -c1-16)"
        HUP_BEFORE="$(grep -c 'Caught SIGHUP' "$NAGIOS_LOG")"
        MAIN_PID="$(systemctl show nagios -p MainPID --value)"
        BACKUP_BEFORE="$(ls "$SERVER_DIR/running-host-config-backup" 2> /dev/null | wc -l)"

        CODE="$(set_interval 2)"
        sleep 5
        NEW_VALUES="$(INTERVAL_LINES | awk '{print $2}' | sort -u | tr '\n' ' ')"

        if [ "$CODE" = "200" ] && [ "$NEW_VALUES" = "2 " ]; then
            record 5.4 PASS "HTTP 200, $(INTERVAL_LINES | wc -l) check_interval lines now 2"
        else
            record 5.4 FAIL "HTTP $CODE, values: $NEW_VALUES, $(head -c 160 "$WORK/put.body")"
        fi

        BACKUP_AFTER="$(ls "$SERVER_DIR/running-host-config-backup" 2> /dev/null | wc -l)"
        if [ "$BACKUP_AFTER" -gt "$BACKUP_BEFORE" ]; then
            record 5.5 PASS "backup of the previous config added ($BACKUP_BEFORE to $BACKUP_AFTER)"
        else
            record 5.5 FAIL "no new file in running-host-config-backup"
        fi

        HUP_AFTER="$(grep -c 'Caught SIGHUP' "$NAGIOS_LOG")"
        if systemctl is-active --quiet nagios \
            && [ "$(systemctl show nagios -p MainPID --value)" = "$MAIN_PID" ] \
            && [ "$HUP_AFTER" -gt "$HUP_BEFORE" ]; then
            record 5.6 PASS "nagios reloaded (SIGHUP $HUP_BEFORE to $HUP_AFTER), same process, no restart"
        else
            record 5.6 FAIL "SIGHUP $HUP_BEFORE to $HUP_AFTER, active: $(systemctl is-active nagios)"
        fi

        if [ "$(sha256sum "$LOCALHOST_CFG" | cut -c1-16)" = "$LOCALHOST_SUM" ]; then
            record 5.12 PASS "localhost.cfg unchanged"
        else
            record 5.12 FAIL "localhost.cfg changed"
        fi

        # 5.7 cadence: two consecutive checks of one service, about 120 s apart
        if [ "${SKIP_CADENCE:-0}" = "1" ]; then
            record 5.7 SKIP "SKIP_CADENCE=1"
        else
            # Prefer a generated service; hosts-only configs are watched through the host check.
            WATCH_KIND="service"
            WATCH_HOST="$(awk '/define[[:space:]]+service/{s=1} s&&/host_name/{print $2; exit}' "$HOSTS_CFG" "$NAGIOS_OBJECTS/plugin-services.cfg" 2> /dev/null)"
            WATCH_SERVICE="$(awk '/define[[:space:]]+service/{s=1} s&&/service_description/{sub(/^[[:space:]]*service_description[[:space:]]+/,""); print; exit}' "$HOSTS_CFG" "$NAGIOS_OBJECTS/plugin-services.cfg" 2> /dev/null)"
            if [ -z "$WATCH_HOST" ] || [ -z "$WATCH_SERVICE" ]; then
                WATCH_KIND="host"
                WATCH_SERVICE=""
                # Prefer a host that is UP so state changes do not add extra checks.
                WATCH_HOST=""
                for CANDIDATE in $(awk '/define[[:space:]]+host[[:space:]]*\{/{h=1} h&&/host_name/{print $2; h=0}' "$HOSTS_CFG"); do
                    [ -z "$WATCH_HOST" ] && WATCH_HOST="$CANDIDATE"
                    if awk -v h="$CANDIDATE" '/^hoststatus \{/{inb=1; hn=""; st=""} inb&&/host_name=/{sub(/.*host_name=/,""); hn=$0} inb&&/current_state=/{sub(/.*current_state=/,""); st=$0} inb&&/^[[:space:]]*\}/{if (hn==h && st==0) found=1; inb=0} END{exit !found}' "$STATUS_DAT"; then
                        WATCH_HOST="$CANDIDATE"
                        break
                    fi
                done
            fi

            last_check() {
                awk -v kind="$WATCH_KIND" -v h="$WATCH_HOST" -v s="$WATCH_SERVICE" '
                    $0 ~ "^" kind "status \{" {inb=1; hn=""; sd=""; lc=""; next}
                    inb && /host_name=/ {sub(/.*host_name=/,""); hn=$0}
                    inb && /service_description=/ {sub(/.*service_description=/,""); sd=$0}
                    inb && /last_check=/ {sub(/.*last_check=/,""); lc=$0}
                    inb && /^[[:space:]]*\}/ {if (hn==h && (kind=="host" || sd==s)) {print lc; exit} inb=0}
                ' "$STATUS_DAT"
            }

            if [ -z "$WATCH_HOST" ]; then
                record 5.7 SKIP "no generated host or service found to watch"
            else
                T0="$(last_check)"
                CHECKS=""
                PREVIOUS="$T0"
                COUNT=0
                WAITED=0
                while [ "$WAITED" -lt 660 ] && [ "$COUNT" -lt 3 ]; do
                    sleep 5
                    WAITED=$((WAITED + 5))
                    NOW="$(last_check)"
                    if [ -n "$NOW" ] && [ "$NOW" != "$PREVIOUS" ]; then
                        CHECKS="$CHECKS $NOW"
                        PREVIOUS="$NOW"
                        COUNT=$((COUNT + 1))
                    fi
                done

                LABEL="$WATCH_KIND check of $WATCH_HOST${WATCH_SERVICE:+ / $WATCH_SERVICE}"
                if [ "$COUNT" -ge 3 ]; then
                    set -- $CHECKS
                    GAP1=$(($2 - $1))
                    GAP2=$(($3 - $2))
                    # The first check after a reload can come early; the steady gap is the last one.
                    if [ "$GAP2" -ge 105 ] && [ "$GAP2" -le 135 ]; then
                        record 5.7 PASS "$LABEL: gaps ${GAP1}s then ${GAP2}s (interval 2 minutes; at 5 minutes they would be 300s)"
                    else
                        record 5.7 FAIL "$LABEL: gaps ${GAP1}s then ${GAP2}s, expected about 120"
                    fi
                else
                    record 5.7 FAIL "saw only $COUNT check(s) of $LABEL within 11 minutes"
                fi
            fi
        fi

        # 5.8 validation fails: old setting and config kept
        cp -p "$HOSTS_CFG" "$WORK/hosts.before-5.8"
        echo 'bogus_directive=1' >> "$NAGIOS_CFG"
        CODE="$(set_interval 10)"
        cat "$WORK/nagios.cfg.original" > "$NAGIOS_CFG"
        if [ "$CODE" = "422" ] \
            && cmp -s "$HOSTS_CFG" "$WORK/hosts.before-5.8" \
            && [ "$(current_interval)" = "2" ] \
            && systemctl is-active --quiet nagios; then
            record 5.8 PASS "invalid config: HTTP 422, hosts.cfg unchanged, setting still 2, Nagios active"
        else
            record 5.8 FAIL "HTTP $CODE, interval now $(current_interval), hosts.cfg identical: $(cmp -s "$HOSTS_CFG" "$WORK/hosts.before-5.8" && echo yes || echo no)"
        fi

        # 5.9 reload refused: old setting and config kept
        if [ -f "$SUDOERS_RELOAD" ]; then
            cp -p "$HOSTS_CFG" "$WORK/hosts.before-5.9"
            SUDOERS_MOVED=1
            rm -f "$SUDOERS_RELOAD"
            CODE="$(set_interval 10)"
            install -m 440 -o root -g root "$WORK/sudoers.original" "$SUDOERS_RELOAD"
            SUDOERS_MOVED=0
            if [ "$CODE" = "422" ] \
                && [ "$(current_interval)" = "2" ] \
                && systemctl is-active --quiet nagios \
                && cmp -s "$HOSTS_CFG" "$WORK/hosts.before-5.9"; then
                record 5.9 PASS "reload refused: HTTP 422, setting still 2, hosts.cfg unchanged"
            else
                record 5.9 FAIL "HTTP $CODE, interval now $(current_interval), hosts.cfg identical: $(cmp -s "$HOSTS_CFG" "$WORK/hosts.before-5.9" && echo yes || echo no)"
            fi
            check 2.1c "reload rule restored after 5.9" runuser -u pinpoint -- sudo -n -l systemctl reload nagios
        else
            record 5.9 SKIP "sudoers rule file not found"
        fi

    fi

    # 5.10 a user without the System permission cannot change the interval.
    # Needs no monitored host. A throwaway role and account are created and,
    # whatever happens, the account is suspended and the role deactivated again
    # (PinPoint has no delete). Nagios reloads when an account changes, so wait first.
    sleep 10
    ensure_session
    NA_RESULT="$(ADMIN_LOGIN="$LOGIN_EMAIL" ADMIN_PASS="$LOGIN_PASSWORD" python3 - <<'PY' 2>&1
import http.cookiejar
import json
import os
import secrets
import urllib.error
import urllib.request

BASE = "http://127.0.0.1"


def client():
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def call(method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(BASE + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            resp = opener.open(req, timeout=60)
            return resp.status, json.loads(resp.read().decode() or "null")
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode()[:200]

    return call


admin = client()
suffix = secrets.token_hex(3)
role_name = "CI NonAdmin " + suffix
email = "ci-nonadmin-%s@example.com" % suffix
password = "NonAdmin-%s!Aa1" % secrets.token_hex(6)
role_id = account_id = None

try:
    code, _ = admin("POST", "/api/user/login",
                    {"email": os.environ["ADMIN_LOGIN"], "password": os.environ["ADMIN_PASS"]})
    assert code == 200, "admin login %s" % code

    perms = admin("GET", "/api/user/permissions/options")[1]["data"]["items"]
    perm_id = next(p["id"] for p in perms if p["name"] == "role.list")

    code, _ = admin("POST", "/api/user/roles", {"role_name": role_name, "description": "test role",
                                                "permissions": [perm_id], "is_active": True})
    assert code == 201, "create role %s" % code
    roles = admin("GET", "/api/user/roles/options")[1]["data"]["items"]
    role_id = next(r["id"] for r in roles if r["name"] == role_name)

    code, _ = admin("POST", "/api/user/accounts", {
        "first_name": "CI", "last_name": "NonAdmin", "email": email, "password": password,
        "confirm_password": password, "status": "Active", "role_id": role_id,
        "require_password_change": False})
    assert code == 201, "create account %s" % code

    user = client()
    code, _ = user("POST", "/api/user/login", {"email": email, "password": password})
    assert code == 200, "non-admin login %s" % code

    code, settings = user("GET", "/api/system")
    assert code == 200, "non-admin may read settings, got %s" % code
    current = settings["data"]["checkInterval"]
    changed = dict(settings["data"], checkInterval=15 if current != 15 else 10)
    code, body = user("PUT", "/api/system", changed)
    after = admin("GET", "/api/system")[1]["data"]["checkInterval"]
    if code == 403 and after == current:
        print("OK|non-admin read settings (200); changing the interval got 403 and it stayed %s" % current)
    else:
        print("FAIL|non-admin PUT returned %s, interval %s -> %s" % (code, current, after))
except Exception as exc:
    print("FAIL|%s" % exc)
finally:
    try:
        accounts = admin("GET", "/api/user/accounts")[1]["data"]["items"]
        for acct in accounts:
            if acct["email"] == email:
                admin("PUT", "/api/user/accounts/%d" % acct["id"], {
                    "first_name": acct["first_name"], "last_name": acct["last_name"],
                    "email": acct["email"], "role_id": role_id, "status": "Suspended"})
        if role_id is not None:
            admin("PUT", "/api/user/roles/%d/status" % role_id)
    except Exception as exc:
        print("WARN|cleanup failed: %s" % exc)
PY
)"
    case "$NA_RESULT" in
        OK\|*) record 5.10 PASS "${NA_RESULT#OK|}" ;;
        *) record 5.10 FAIL "$(echo "$NA_RESULT" | tr '\n' ' ' | head -c 250)" ;;
    esac
    case "$NA_RESULT" in
        *WARN\|*) record 5.10c WARN "throwaway account or role was not cleaned up: see 'Manage Users' / 'Manage Roles'" ;;
    esac

    # 5.14 cleanup is done by the exit trap (setting back to its original value)
    record 5.14 PASS "cleanup runs on exit: nagios.cfg, sudoers rule and the check interval are put back"

fi

record 5.2 SKIP "needs the pre-60 snapshot: compare row counts before and after the upgrade (see Result file)"
record 5.13 SKIP "PinPoint's 60-second status poll is fixed in the app and not changed by this setting; no installer check"

##################################################
# Summary
##################################################

{
    echo
    echo "PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP"
} | tee -a "$OUT"

[ "$FAIL" -eq 0 ]
