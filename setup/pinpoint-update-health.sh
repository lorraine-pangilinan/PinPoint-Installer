#!/bin/bash

##################################################
# PinPoint Update Manager
# Module : pinpoint-update-health.sh
# Purpose: Versioned health suite run before and
#          after a change to Nagios (plan section
#          13.1, checks HC-01 to HC-13; HC-14 is
#          checked by pinpoint-update-exec).
#
# Usage:
#   pinpoint-update-health.sh --save DIR [--target-version X.Y.Z]
#   pinpoint-update-health.sh --compare DIR --target-version X.Y.Z
#                             [--since EPOCH] [--ncpa-sha256 HEX]
#
# --save records what "healthy" looked like before
# the change (host and service counts, sudo rules
# of pinpoint, owners and modes, health check
# failures that already existed) and runs every
# check. --compare checks the system against that
# record. --since is when Nagios was started after
# the change.
#
# Output: one line per check, "ID|LEVEL|STATUS|note"
# (LEVEL critical or warning, STATUS PASS or FAIL),
# then "SUITE|<version>|<critical failures>|<warnings>".
# Exit code: number of failed critical checks.
#
# Read-only: nothing is started, stopped or changed
# outside DIR. The pinpoint-api password is passed
# to curl on stdin and never printed.
##################################################

set -u

SUITE_VERSION="1"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_HEALTHCHECK="$HERE/pinpoint-healthcheck.sh"

NAGIOS_BIN="/usr/local/nagios/bin/nagios"
NAGIOS_CFG="/usr/local/nagios/etc/nagios.cfg"
NAGIOS_STATUS="/usr/local/nagios/var/status.dat"
NAGIOS_LOG="/usr/local/nagios/var/nagios.log"
LIBEXEC="/usr/local/nagios/libexec"
SPOOL_DIR="/usr/local/nagios/var/spool/pinpoint-events"
NAGIOS_URL="http://127.0.0.1:8081/nagios"
API_CREDENTIALS="/etc/pinpoint/nagios-api.env"
GUNICORN_SERVICE="pinpoint-gunicorn"

# Files whose owner and mode the appliance depends on
# (plan section 2.2). Globs are expanded when checked.
OWNED_PATHS=(
    /usr/local/nagios/etc/nagios.cfg
    /usr/local/nagios/etc/cgi.cfg
    /usr/local/nagios/etc/resource.cfg
    /usr/local/nagios/etc/htpasswd.users
    /usr/local/nagios/etc/objects/hosts.cfg
    /usr/local/nagios/etc/objects/plugin-services.cfg
    /usr/local/nagios/var/spool/pinpoint-events
    /usr/local/nagios/libexec/check_ncpa.py
    /etc/msmtprc
    /etc/pinpoint/nagios-api.env
    /etc/sudoers.d/pinpoint-*
    /usr/local/sbin/pinpoint-*
)

# Nagios must stay up this long after it starts, and
# status.dat must be rewritten within this time.
SETTLE_SECONDS="${PINPOINT_HEALTH_SETTLE:-120}"

MODE=""
DIR=""
TARGET_VERSION=""
SINCE=0
NCPA_SHA256=""

CRITICAL_FAILED=0
WARNINGS=0

usage() {
    echo "Usage: $0 --save DIR [--target-version X.Y.Z]" >&2
    echo "       $0 --compare DIR --target-version X.Y.Z [--since EPOCH] [--ncpa-sha256 HEX]" >&2
    exit 64
}

while [ $# -gt 0 ]; do
    case "$1" in
        --save|--compare)
            [ $# -ge 2 ] || usage
            MODE="${1#--}"; DIR="$2"; shift 2 ;;
        --target-version)
            [ $# -ge 2 ] || usage
            TARGET_VERSION="$2"; shift 2 ;;
        --since)
            [ $# -ge 2 ] || usage
            SINCE="$2"; shift 2 ;;
        --ncpa-sha256)
            [ $# -ge 2 ] || usage
            NCPA_SHA256="$2"; shift 2 ;;
        *)
            usage ;;
    esac
done

[ -n "$MODE" ] || usage
[ "$MODE" = "save" ] || [ -n "$TARGET_VERSION" ] || usage
[[ "$SINCE" =~ ^[0-9]+$ ]] || usage
[ -z "$NCPA_SHA256" ] || [[ "$NCPA_SHA256" =~ ^[0-9a-f]{64}$ ]] || usage

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 64
fi

if [ "$MODE" = "save" ]; then
    install -d -m 700 "$DIR" || exit 64
elif [ ! -d "$DIR" ]; then
    echo "ERROR: No saved baseline in $DIR." >&2
    exit 64
fi

##################################################
# Helpers
##################################################

# report ID LEVEL PASS|FAIL NOTE
report() {
    printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"

    if [ "$3" = "FAIL" ]; then
        if [ "$2" = "critical" ]; then
            CRITICAL_FAILED=$((CRITICAL_FAILED + 1))
        else
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
}

# GET a Nagios CGI as pinpoint-api, password on stdin.
nagios_api() {
    printf 'user = "%s:%s"\n' "$API_USER" "$API_PASSWORD" \
        | curl -s --max-time 15 -K - "$NAGIOS_URL/cgi-bin/$1" || true
}

# First number after "KEY": in a JSON reply.
json_number() {
    grep -o "\"$1\":[[:space:]]*[0-9]*" | head -1 | grep -o '[0-9]*$'
}

# save NAME (stdin) or compare NAME (stdin): 0 if equal.
# In save mode the record is written and counts as equal.
record_or_compare() {
    if [ "$MODE" = "save" ]; then
        cat > "$DIR/$1"
        return 0
    fi
    [ -f "$DIR/$1" ] && cmp -s - "$DIR/$1"
}

API_USER="$(sed -n 's/^NAGIOS_USERNAME=//p' "$API_CREDENTIALS" 2> /dev/null)"
API_PASSWORD="$(sed -n 's/^NAGIOS_PASSWORD=//p' "$API_CREDENTIALS" 2> /dev/null)"

##################################################
# HC-01 Nagios version
##################################################

INSTALLED_VERSION="$("$NAGIOS_BIN" -V 2> /dev/null | grep -m1 -o 'Nagios Core [0-9][0-9A-Za-z.+-]*' | cut -d ' ' -f 3)"

if [ -z "$TARGET_VERSION" ]; then
    if [ -n "$INSTALLED_VERSION" ]; then
        report HC-01 critical PASS "Nagios Core $INSTALLED_VERSION installed."
    else
        report HC-01 critical FAIL "Cannot read the Nagios Core version."
    fi
elif [ "$INSTALLED_VERSION" = "$TARGET_VERSION" ]; then
    report HC-01 critical PASS "Nagios Core $INSTALLED_VERSION is the expected version."
else
    report HC-01 critical FAIL "Nagios Core is '${INSTALLED_VERSION:-unreadable}', expected $TARGET_VERSION."
fi

##################################################
# HC-02 Configuration
##################################################

VERIFY_OUTPUT="$("$NAGIOS_BIN" -v "$NAGIOS_CFG" 2>&1)"
VERIFY_RC=$?
NAGIOS_ERRORS="$(printf '%s' "$VERIFY_OUTPUT" | sed -n 's/^Total Errors: *//p')"

if [ "$VERIFY_RC" -eq 0 ] && [ "${NAGIOS_ERRORS:-1}" = "0" ]; then
    report HC-02 critical PASS "nagios -v: 0 errors."
else
    FIRST_ERROR="$(printf '%s\n' "$VERIFY_OUTPUT" | grep -m1 -E '^(Error|Warning):' | cut -c 1-160)"
    report HC-02 critical FAIL "nagios -v: ${NAGIOS_ERRORS:-?} errors. ${FIRST_ERROR}"
fi

##################################################
# HC-03 nagios.service stays active
##################################################

if systemctl is-active --quiet nagios; then
    PID_BEFORE="$(systemctl show -p MainPID --value nagios)"
    STARTED="$(date -d "$(systemctl show -p ActiveEnterTimestamp --value nagios)" +%s 2> /dev/null || echo 0)"
    WAIT=$(( STARTED + SETTLE_SECONDS - $(date +%s) ))

    if [ "$WAIT" -gt 0 ]; then
        sleep "$WAIT"
    fi

    if systemctl is-active --quiet nagios \
        && [ "$(systemctl show -p MainPID --value nagios)" = "$PID_BEFORE" ]; then
        report HC-03 critical PASS "nagios.service active for at least ${SETTLE_SECONDS}s."
    else
        report HC-03 critical FAIL "nagios.service stopped or restarted within ${SETTLE_SECONDS}s."
    fi
else
    report HC-03 critical FAIL "nagios.service is $(systemctl is-active nagios)."
fi

##################################################
# HC-04 status.dat is being written
##################################################

STATUS_OK=0
DEADLINE=$(( $(date +%s) + SETTLE_SECONDS ))

while :; do
    if [ -f "$NAGIOS_STATUS" ]; then
        MTIME="$(stat -c %Y "$NAGIOS_STATUS")"
        if [ "$MTIME" -ge "$SINCE" ] && [ $(( $(date +%s) - MTIME )) -le "$SETTLE_SECONDS" ]; then
            STATUS_OK=1
            break
        fi
    fi
    [ "$(date +%s)" -lt "$DEADLINE" ] || break
    sleep 5
done

if [ "$STATUS_OK" -eq 1 ]; then
    report HC-04 critical PASS "status.dat updated $(( $(date +%s) - MTIME ))s ago."
else
    report HC-04 critical FAIL "status.dat not updated within ${SETTLE_SECONDS}s."
fi

##################################################
# HC-05 statusjson.cgi
##################################################

if [ -n "$API_USER" ]; then
    RESPONSE="$(nagios_api 'statusjson.cgi?query=programstatus')"
    if printf '%s' "$RESPONSE" | grep -Eq '"type_code":[[:space:]]*0' \
        && printf '%s' "$RESPONSE" | grep -q '"programstatus"' \
        && printf '%s' "$RESPONSE" | grep -Eq '"version":[[:space:]]*"'; then
        report HC-05 critical PASS "statusjson programstatus returns the expected fields."
    else
        report HC-05 critical FAIL "statusjson programstatus did not return the expected JSON."
    fi
else
    report HC-05 critical FAIL "No pinpoint-api account in $API_CREDENTIALS."
fi

##################################################
# HC-06 Same hosts and services as before
##################################################

if [ -n "$API_USER" ]; then
    HOSTS="$(nagios_api 'objectjson.cgi?query=hostcount' | json_number count)"
    SERVICES="$(nagios_api 'objectjson.cgi?query=servicecount' | json_number count)"

    if [ -z "$HOSTS" ] || [ -z "$SERVICES" ]; then
        report HC-06 critical FAIL "objectjson did not return host and service counts."
    elif printf '%s %s\n' "$HOSTS" "$SERVICES" | record_or_compare object-counts; then
        report HC-06 critical PASS "$HOSTS hosts and $SERVICES services configured."
    else
        report HC-06 critical FAIL "$HOSTS hosts and $SERVICES services; before the change: $(cat "$DIR/object-counts" 2> /dev/null)."
    fi
else
    report HC-06 critical FAIL "No pinpoint-api account in $API_CREDENTIALS."
fi

unset API_PASSWORD RESPONSE

##################################################
# HC-07 Plugins run as nagios
##################################################

PLUGIN_PROBLEMS=""

runuser -u nagios -- "$LIBEXEC/check_ping" -H 127.0.0.1 -w 3000.0,80% -c 5000.0,100% -p 1 > /dev/null 2>&1 \
    || PLUGIN_PROBLEMS="$PLUGIN_PROBLEMS check_ping(exit $?)"
runuser -u nagios -- "$LIBEXEC/check_mysql" -V > /dev/null 2>&1 \
    || PLUGIN_PROBLEMS="$PLUGIN_PROBLEMS check_mysql(exit $?)"

# Every script plugin's interpreter must exist for nagios,
# as install-nagios-plugins.sh checks at install time.
for FILE in "$LIBEXEC"/*; do
    [ -f "$FILE" ] || continue
    [ "$(head -c 2 "$FILE" 2> /dev/null)" = "#!" ] || continue

    read -r -a PARTS <<< "$(head -n 1 "$FILE" | tr -d '\r' | cut -c 3-)"
    INTERP="${PARTS[0]:-}"

    if [ "$(basename "$INTERP")" = "env" ]; then
        INTERP=""
        for WORD in "${PARTS[@]:1}"; do
            case "$WORD" in
                -*|*=*) continue ;;
            esac
            INTERP="$WORD"
            break
        done
    fi

    if [ -z "$INTERP" ] || ! runuser -u nagios -- bash -c 'command -v "$1" > /dev/null 2>&1' _ "$INTERP"; then
        PLUGIN_PROBLEMS="$PLUGIN_PROBLEMS $(basename "$FILE")(interpreter)"
    fi
done

if [ -z "$PLUGIN_PROBLEMS" ]; then
    report HC-07 critical PASS "check_ping, check_mysql and plugin interpreters work as nagios."
else
    report HC-07 critical FAIL "Plugin problems:$PLUGIN_PROBLEMS."
fi

##################################################
# HC-08 check_ncpa.py
##################################################

if runuser -u nagios -- "$LIBEXEC/check_ncpa.py" --help > /dev/null 2>&1; then
    NCPA_HASH="$(sha256sum "$LIBEXEC/check_ncpa.py" | cut -d ' ' -f 1)"
    if [ -z "$NCPA_SHA256" ] || [ "$NCPA_HASH" = "$NCPA_SHA256" ]; then
        report HC-08 critical PASS "check_ncpa.py runs as nagios${NCPA_SHA256:+ and its SHA-256 matches}."
    else
        report HC-08 critical FAIL "check_ncpa.py SHA-256 is ${NCPA_HASH:0:12}.., expected ${NCPA_SHA256:0:12}..."
    fi
else
    report HC-08 critical FAIL "check_ncpa.py does not run as nagios."
fi

##################################################
# HC-09 Event spool
##################################################

if runuser -u nagios -- test -w "$SPOOL_DIR" \
    && runuser -u pinpoint -- test -r "$SPOOL_DIR" \
    && runuser -u pinpoint -- test -x "$SPOOL_DIR"; then
    report HC-09 critical PASS "Event spool writable by nagios and readable by pinpoint."
else
    report HC-09 critical FAIL "Event spool $SPOOL_DIR is not writable by nagios or not readable by pinpoint."
fi

##################################################
# HC-10 sudo rules of pinpoint
##################################################

if sudo -l -U pinpoint 2> /dev/null | record_or_compare sudo-rules; then
    report HC-10 critical PASS "sudo rules of pinpoint are unchanged."
else
    report HC-10 critical FAIL "sudo rules of pinpoint differ from before the change (sudo -l -U pinpoint)."
fi

##################################################
# HC-11 PinPoint web application
##################################################

# pinpoint-healthcheck.sh is not required to exit 0: on
# a current appliance it already fails one check (it
# treats the installer's "restart nagios" sudo rule as
# too broad). What must hold is that the change adds no
# new failure. Numbers are masked so "stale (300s old)"
# and "stale (310s old)" count as the same failure.
if systemctl is-active --quiet "$GUNICORN_SERVICE"; then
    if [ -f "$APP_HEALTHCHECK" ]; then
        APP_FAILS="$(bash "$APP_HEALTHCHECK" 2> /dev/null | grep '\[FAIL\]' | sed 's/[0-9][0-9]*/N/g' | sort -u)"

        if [ "$MODE" = "save" ]; then
            printf '%s\n' "$APP_FAILS" > "$DIR/app-failures"
            NEW_FAILS=""
        else
            NEW_FAILS="$(printf '%s\n' "$APP_FAILS" | grep -vxF -f "$DIR/app-failures" 2> /dev/null | grep -v '^$')"
        fi

        if [ -z "$NEW_FAILS" ]; then
            report HC-11 critical PASS "$GUNICORN_SERVICE active; no new pinpoint-healthcheck failures."
        else
            report HC-11 critical FAIL "New pinpoint-healthcheck failures: $(printf '%s' "$NEW_FAILS" | sed 's/^ *\[FAIL\] *//' | tr '\n' ';' | cut -c 1-300)"
        fi
    else
        report HC-11 critical FAIL "$APP_HEALTHCHECK not found."
    fi
else
    report HC-11 critical FAIL "$GUNICORN_SERVICE is $(systemctl is-active "$GUNICORN_SERVICE")."
fi

##################################################
# HC-12 Owners and modes
##################################################

for PATTERN in "${OWNED_PATHS[@]}"; do
    for FILE in $PATTERN; do
        stat -c '%n %U:%G %a' "$FILE" 2> /dev/null || echo "$FILE missing"
    done
done > "$DIR/.owners.now"

if record_or_compare owners < "$DIR/.owners.now"; then
    report HC-12 critical PASS "Owners and modes of $(wc -l < "$DIR/.owners.now") appliance files are unchanged."
else
    CHANGED="$(diff "$DIR/owners" "$DIR/.owners.now" | sed -n 's/^> //p' | tr '\n' ';' | cut -c 1-300)"
    report HC-12 critical FAIL "Owner or mode changed: $CHANGED"
fi

rm -f "$DIR/.owners.now"

##################################################
# HC-13 New errors in nagios.log (warning)
##################################################

if [ "$SINCE" -gt 0 ] && [ -f "$NAGIOS_LOG" ]; then
    NEW_ERRORS="$(awk -v since="$SINCE" '
        match($0, /^\[[0-9]+\]/) {
            t = substr($0, 2, RLENGTH - 2) + 0
            if (t >= since && $0 ~ /Error:/) n++
        }
        END { print n + 0 }' "$NAGIOS_LOG")"

    if [ "$NEW_ERRORS" = "0" ]; then
        report HC-13 warning PASS "No new Error: lines in nagios.log."
    else
        report HC-13 warning FAIL "$NEW_ERRORS new Error: line(s) in nagios.log."
    fi
else
    report HC-13 warning PASS "Not checked: no change start time given."
fi

##################################################
# Summary
##################################################

echo "SUITE|$SUITE_VERSION|$CRITICAL_FAILED|$WARNINGS"

exit "$CRITICAL_FAILED"
