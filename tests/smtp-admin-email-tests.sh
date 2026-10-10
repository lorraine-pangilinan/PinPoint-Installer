#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : smtp-admin-email-tests.sh
# Purpose: Run the automatable cases from
#          docs/SMTP_Admin_Email_Test_Cases.md on a
#          disposable test VM, as root.
#
# Cases whose feature does not exist yet are SKIPPED
# with the reason, never reported as passed.
#
# Usage: sudo ./smtp-admin-email-tests.sh [setup-dir]
#        setup-dir defaults to /root/pinpoint
#
# Output: one line per case, "ID|STATUS|note", then a
# summary. Also written to /root/smtp-test-output.txt.
# Run it only on a VM you can restore from a snapshot.
##################################################

set -u

SETUP_DIR="${1:-/root/pinpoint}"
OUT="/root/smtp-test-output.txt"
DEPLOY_LOG="/var/log/pinpoint-web.log"
SERVER_DIR="/opt/pinpoint/Network-Diagnosis-System/server"
CREDENTIALS_FILE="/root/pinpoint-install-credentials.txt"

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

{
    echo "# Run: $(date -u +%FT%TZ)"
    echo "# Host: $(hostname)  OS: $(lsb_release -ds 2>/dev/null)"
    echo "# Installer files: $SETUP_DIR"
    if [ -d "$SERVER_DIR/../.git" ]; then
        echo "# PinPoint commit: $(git -c safe.directory="*" -C "$SERVER_DIR/.." rev-parse --short HEAD 2>/dev/null)"
    fi
} | tee -a "$OUT"

##################################################
# A12 / F6: syntax and line endings
##################################################

BAD_SYNTAX=""
BAD_CR=""

for F in "$SETUP_DIR"/*.sh; do
    bash -n "$F" 2>/dev/null || BAD_SYNTAX="$BAD_SYNTAX $(basename "$F")"
    grep -q $'\r' "$F" && BAD_CR="$BAD_CR $(basename "$F")"
done

if [ -z "$BAD_SYNTAX" ]; then
    record A12 PASS "bash -n clean for every script in $SETUP_DIR"
else
    record A12 FAIL "syntax errors in:$BAD_SYNTAX"
fi

if [ -z "$BAD_CR" ]; then
    record F6 PASS "no carriage returns in the scripts"
else
    record F6 FAIL "carriage returns in:$BAD_CR"
fi

##################################################
# A3 - A9, P1, B1 - B9: fresh install and first-run setup
#
# Needs a VM restored to a snapshot with no PinPoint
# database. On an installed system these are skipped
# and A10 / A11 test the upgrade instead.
##################################################

DB_BEFORE=0
[ -f "$SERVER_DIR/system.db" ] && DB_BEFORE=1

PLACEHOLDER_RE='^admin-[0-9a-f]{5}@pinpoint\.lan$'
TEST_NEW_EMAIL="${TEST_NEW_EMAIL:-pinpoint.tester@example.com}"
TEST_NEW_PASSWORD="${TEST_NEW_PASSWORD:-Str0ng-Setup-Passw0rd!}"

# Print "email|needs_setup|count" from the user table.
user_rows() {
    python3 - "$SERVER_DIR/system.db" <<'PY'
import sqlite3
import sys

con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
rows = con.execute('SELECT "Email", "Needs_Setup" FROM "USER"').fetchall()
print("%d|%s" % (len(rows), "|".join("%s:%s" % row for row in rows)))
PY
}

skip_fresh() {
    local ID
    for ID in A3 A4 A5 A6 A7 P1 B1 B2 B3 B4 B5 B6 B7 B8 B9; do
        record "$ID" SKIP "$1"
    done
}

if [ "$DB_BEFORE" -eq 1 ]; then
    skip_fresh "not a fresh install (a database already exists); restore the snapshot"
else
    DEPLOY_OUT="$(mktemp)"
    "$SETUP_DIR/deploy-pinpoint-web.sh" > "$DEPLOY_OUT" 2>&1
    DEPLOY_RC=$?

    if [ "$DEPLOY_RC" -ne 0 ]; then
        record A3 FAIL "install failed: $(grep -m1 '^ERROR' "$DEPLOY_OUT")"
        skip_fresh "install did not complete"
    else
        grep -q 'Administrator must complete first-run setup' "$DEPLOY_OUT" \
            && record A3 PASS "install completed and reported the first-run setup requirement" \
            || record A3 FAIL "install completed without the first-run setup message"

        # A4: exactly one user, a placeholder email, setup required.
        ROWS="$(user_rows 2>&1)"
        COUNT="${ROWS%%|*}"
        ADMIN_ROW="${ROWS#*|}"
        ADMIN_ADDR="${ADMIN_ROW%%:*}"
        ADMIN_FLAG="${ADMIN_ROW##*:}"

        if [ "$COUNT" = "1" ] && [ "$ADMIN_FLAG" = "1" ] \
            && printf '%s' "$ADMIN_ADDR" | grep -Eq "$PLACEHOLDER_RE"; then
            record A4 PASS "one user, placeholder email, Needs_Setup=1"
        else
            record A4 FAIL "users=$COUNT row=$ADMIN_ROW"
        fi

        # A5 / A6: the credentials file.
        if [ ! -f "$CREDENTIALS_FILE" ]; then
            record A5 FAIL "credentials file missing"
            record A6 FAIL "credentials file missing"
        else
            [ "$(stat -c '%U:%G %a' "$CREDENTIALS_FILE")" = "root:root 600" ] \
                && grep -Eq "$(printf '%s' "$PLACEHOLDER_RE" | sed 's/^\^//; s/\$$//')" "$CREDENTIALS_FILE" \
                && record A5 PASS "credentials file is root:root 600 and shows the placeholder username" \
                || record A5 FAIL "credentials file mode/content wrong: $(stat -c '%U:%G %a' "$CREDENTIALS_FILE")"

            grep -q 'temporary placeholder' "$CREDENTIALS_FILE" \
                && grep -q 'new password' "$CREDENTIALS_FILE" \
                && ! grep -q 'Change the password after first login' "$CREDENTIALS_FILE" \
                && record A6 PASS "credentials file explains the email and password step" \
                || record A6 FAIL "credentials file wording is wrong"
        fi

        # A7: the generated password is not in the log or console output.
        GEN_PASSWORD="$(sed -n '/^Password:/{n;p;}' "$CREDENTIALS_FILE" 2>/dev/null)"
        if [ -z "$GEN_PASSWORD" ]; then
            record A7 FAIL "could not read the generated password to check for leaks"
        elif grep -qF -- "$GEN_PASSWORD" "$DEPLOY_LOG" "$DEPLOY_OUT" 2> /dev/null; then
            record A7 FAIL "generated password found in the log or console output"
        else
            record A7 PASS "generated password is not in the log or console output"
        fi

        # P1: the privileges script, including its own mail checks.
        if "$SETUP_DIR/configure-pinpoint-privileges.sh" > /tmp/privileges-out.txt 2>&1; then
            record P1 PASS "configure-pinpoint-privileges.sh completed (its own verification passed)"
        else
            record P1 FAIL "privileges script failed: $(grep -m1 '^ERROR' /tmp/privileges-out.txt)"
        fi

        # B1 - B9: sign in with the placeholder and complete the setup.
        FIRSTRUN_OUT="$(python3 - "$CREDENTIALS_FILE" "$TEST_NEW_EMAIL" "$TEST_NEW_PASSWORD" <<'PY'
import http.cookiejar
import json
import re
import sys
import urllib.error
import urllib.request

creds, new_email, new_password = sys.argv[1:4]
text = open(creds, encoding="utf-8").read()
placeholder = re.search(r"^(admin-\S+@pinpoint\.lan)$", text, re.M).group(1)
password = re.search(r"^Password:\n(.+)$", text, re.M).group(1)
BASE = "http://127.0.0.1"


def session():
    return urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def call(opener, method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(BASE + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
    try:
        with opener.open(request, timeout=30) as response:
            code, raw = response.status, response.read()
    except urllib.error.HTTPError as exc:
        code, raw = exc.code, exc.read()
    try:
        return code, json.loads(raw)
    except ValueError:
        return code, {"raw": raw.decode(errors="replace")[:200]}


def say(case, ok, note):
    print("%s|%s|%s" % (case, "PASS" if ok else "FAIL", note))


def text_of(payload):
    return json.dumps(payload).lower()


ses = session()

# B1: the placeholder signs in and is told setup is needed.
code, body = call(ses, "POST", "/api/user/login",
                  {"email": placeholder, "password": password})
code2, me = call(ses, "GET", "/api/user/me")
say("B1", code == 200 and '"needs_setup": true' in json.dumps(me),
    "login %s, /me %s, needs_setup in /me: %s" % (code, code2, '"needs_setup": true' in json.dumps(me)))

# B2: every other API is blocked.
code, body = call(ses, "GET", "/api/system/discovery-settings")
say("B2", code == 403 and "setup" in text_of(body),
    "protected endpoint returned %s: %s" % (code, text_of(body)[:80]))

SETUP = "/api/user/complete-setup"


def setup(**changes):
    payload = {"current_password": password, "new_email": new_email,
               "new_password": new_password, "confirm_password": new_password}
    payload.update(changes)
    return call(ses, "POST", SETUP, payload)


# B3: placeholder and reserved domains are refused and the flag stays.
code, body = setup(new_email="someone@pinpoint.lan")
code_b, body_b = setup(new_email="someone@company.lan")
_, still = call(ses, "GET", "/api/user/me")
say("B3", code == 400 and code_b == 400 and '"needs_setup": true' in json.dumps(still),
    "placeholder %s, reserved .lan %s, still gated" % (code, code_b))

# B4: wrong current password.
code, _ = setup(current_password="definitely-wrong")
say("B4", code == 400, "wrong current password returned %s" % code)

# B5: password rules.
code_a, _ = setup(confirm_password=new_password + "x")
code_b, _ = setup(new_password="short", confirm_password="short")
code_c, _ = setup(new_password=password, confirm_password=password)
say("B5", code_a == 400 and code_b == 400 and code_c == 400,
    "mismatch %s, too weak %s, same as old %s" % (code_a, code_b, code_c))

# B6: valid setup succeeds.
code, body = setup()
say("B6", code == 200 and body.get("success") is not False,
    "setup returned %s: %s" % (code, text_of(body)[:100]))

# B7: gate released, old placeholder dead, new credentials work.
_, me = call(ses, "GET", "/api/user/me")
code_api, _ = call(ses, "GET", "/api/system/discovery-settings")
old_code, _ = call(session(), "POST", "/api/user/login",
                   {"email": placeholder, "password": password})
new_code, _ = call(session(), "POST", "/api/user/login",
                   {"email": new_email, "password": new_password})
say("B7", '"needs_setup": false' in json.dumps(me) and code_api == 200
    and old_code != 200 and new_code == 200,
    "needs_setup cleared, API %s, placeholder login %s, new login %s"
    % (code_api, old_code, new_code))
PY
)"

        FIRSTRUN_RC=$?

        FIRSTRUN_LINES="$(printf '%s\n' "$FIRSTRUN_OUT" | grep -E '^B[0-9]+\|' || true)"

        if [ -z "$FIRSTRUN_LINES" ]; then
            record B1 FAIL "first-run test script produced no results (rc=$FIRSTRUN_RC): $(printf '%s' "$FIRSTRUN_OUT" | tail -n 2 | tr '\n' ' ')"
        else
            # A here-string keeps the loop in this shell, so the counts survive.
            while IFS='|' read -r ID STATUS NOTE; do
                record "$ID" "$STATUS" "$NOTE"
            done <<< "$FIRSTRUN_LINES"
        fi

        # B8: Nagios contact carries the new address, not the placeholder.
        HOSTS_CFG="/usr/local/nagios/etc/objects/hosts.cfg"
        if ! grep -q 'define contact' "$HOSTS_CFG" 2> /dev/null; then
            record B8 SKIP "no 'define contact' in $HOSTS_CFG (nothing generated yet)"
        elif grep -q "$TEST_NEW_EMAIL" "$HOSTS_CFG" && ! grep -q 'pinpoint\.lan' "$HOSTS_CFG"; then
            record B8 PASS "Nagios contact has $TEST_NEW_EMAIL and no placeholder"
        else
            record B8 FAIL "Nagios contact does not carry the new address"
        fi

        # B9: Nagios still accepts its configuration.
        /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg > /dev/null 2>&1 \
            && record B9 PASS "nagios -v passes" \
            || record B9 FAIL "nagios -v reports errors"
    fi

    rm -f "$DEPLOY_OUT"
fi

##################################################
# A10 / A11: an installed system is upgraded, not re-created
##################################################

if [ ! -f "$SERVER_DIR/system.db" ]; then
    record A10 SKIP "no installed system to upgrade"
    record A11 SKIP "no installed system to upgrade"
else
    ROWS_BEFORE="$(user_rows 2>&1)"
    CRED_BEFORE="$( [ -f "$CREDENTIALS_FILE" ] && md5sum < "$CREDENTIALS_FILE" || echo none )"
    UPGRADE_OUT="$(mktemp)"
    "$SETUP_DIR/deploy-pinpoint-web.sh" > "$UPGRADE_OUT" 2>&1
    UPGRADE_RC=$?
    ROWS_AFTER="$(user_rows 2>&1)"
    CRED_AFTER="$( [ -f "$CREDENTIALS_FILE" ] && md5sum < "$CREDENTIALS_FILE" || echo none )"

    if [ "$UPGRADE_RC" -eq 0 ] && grep -q 'Upgrading PinPoint repository' "$UPGRADE_OUT" \
        && ! grep -q 'Administrator account created' "$UPGRADE_OUT"; then
        record A10 PASS "re-run took the upgrade path and created no administrator"
    else
        record A10 FAIL "rc=$UPGRADE_RC: $(grep -m1 '^ERROR' "$UPGRADE_OUT")"
    fi

    if [ "$ROWS_BEFORE" = "$ROWS_AFTER" ] && [ "$CRED_BEFORE" = "$CRED_AFTER" ]; then
        record A11 PASS "users and credentials file unchanged by the upgrade"
    else
        record A11 FAIL "users or credentials changed: $ROWS_BEFORE -> $ROWS_AFTER"
    fi

    rm -f "$UPGRADE_OUT"
fi

##################################################
# C: mail transport (Phase 4)
##################################################

if ! dpkg -s msmtp-mta > /dev/null 2>&1; then
    for ID in C1 C2 C3 C4 C5 C6 C7; do
        record "$ID" SKIP "Phase 4 not built: msmtp-mta is not installed"
    done
else
    dpkg -s bsd-mailx > /dev/null 2>&1 \
        && ! dpkg -s mailutils > /dev/null 2>&1 \
        && ! dpkg -s postfix > /dev/null 2>&1 \
        && record C1 PASS "msmtp-mta and bsd-mailx installed; mailutils and postfix absent" \
        || record C1 FAIL "package set is wrong"

    ss -ltn | grep -q ':25 ' \
        && record C2 FAIL "something listens on port 25" \
        || record C2 PASS "nothing listens on port 25"

    [ "$(stat -c '%U:%G %a' /etc/msmtprc 2>/dev/null)" = "root:nagios 640" ] \
        && record C3 PASS "/etc/msmtprc is root:nagios 640" \
        || record C3 FAIL "/etc/msmtprc is $(stat -c '%U:%G %a' /etc/msmtprc 2>&1)"

    [ "$(stat -c '%U:%G %a' /usr/local/sbin/pinpoint-apply-smtp 2>/dev/null)" = "root:root 755" ] \
        && record C4 PASS "helper is root:root 755" \
        || record C4 FAIL "helper is $(stat -c '%U:%G %a' /usr/local/sbin/pinpoint-apply-smtp 2>&1)"

    visudo -c > /dev/null 2>&1 \
        && record C5 PASS "sudoers parses" \
        || record C5 FAIL "visudo -c failed"

    runuser -u pinpoint -- sudo -n -l /usr/local/sbin/pinpoint-apply-smtp > /dev/null 2>&1 \
        && ! runuser -u pinpoint -- sudo -n -l /bin/cat > /dev/null 2>&1 \
        && record C6 PASS "pinpoint may run the helper and not /bin/cat" \
        || record C6 FAIL "sudo rights for pinpoint are wrong"

    runuser -u pinpoint -- touch /etc/msmtprc > /dev/null 2>&1 \
        && record C7 FAIL "pinpoint can write /etc/msmtprc" \
        || record C7 PASS "pinpoint cannot write /etc/msmtprc"
fi

##################################################
# D: pinpoint-apply-smtp helper (Phase 4)
##################################################

HELPER="/usr/local/sbin/pinpoint-apply-smtp"
CFG="/etc/msmtprc"
GOOD_PASSWORD="abcdEFGHijklMNOP"

if [ ! -x "$HELPER" ]; then
    for ID in D1 D2 D4 D5 D6 D7 D8 D9 D10 D11 D12 D13 D15; do
        record "$ID" SKIP "Phase 4 not built: $HELPER is not installed"
    done
else
    CFG_BACKUP="$(mktemp)"
    cp -p "$CFG" "$CFG_BACKUP"
    trap 'cp -p "$CFG_BACKUP" "$CFG"; rm -f "$CFG_BACKUP"' EXIT

    # Print a valid settings object; "key=<json>" overrides a field
    # and "del:key" removes one.
    mk() {
        python3 - "$@" <<'PY'
import json
import sys

data = {
    "host": "smtp.gmail.com",
    "port": 587,
    "tls": "starttls",
    "username": "user@gmail.com",
    "password": "abcdEFGHijklMNOP",
    "sender": "user@gmail.com",
}

for arg in sys.argv[1:]:
    if arg.startswith("del:"):
        data.pop(arg[4:], None)
    else:
        key, value = arg.split("=", 1)
        data[key] = json.loads(value)

print(json.dumps(data))
PY
    }

    cfg_sum() { md5sum < "$CFG"; }

    # Feed $1 to the helper; sets RC and HOUT (stdout and stderr).
    run_helper() {
        HOUT="$(printf '%s' "$1" | timeout 20 "$HELPER" 2>&1)"
        RC=$?
    }

    # reject ID label payload: must exit 1 and leave the file alone.
    reject() {
        local ID="$1" LABEL="$2" PAYLOAD="$3" BEFORE

        BEFORE="$(cfg_sum)"
        run_helper "$PAYLOAD"

        if [ "$RC" -ne 1 ]; then
            record "$ID" FAIL "$LABEL: expected exit 1, got $RC"
            return 1
        fi

        if [ "$(cfg_sum)" != "$BEFORE" ]; then
            record "$ID" FAIL "$LABEL: rejected but $CFG changed"
            return 1
        fi

        return 0
    }

    # Run several rejections under one case ID.
    # $1 = ID, then label/payload pairs.
    reject_all() {
        local ID="$1" BAD=0
        shift

        while [ "$#" -gt 1 ]; do
            reject "$ID" "$1" "$2" || BAD=1
            shift 2
        done

        [ "$BAD" -eq 0 ] && record "$ID" PASS "all rejected with exit 1; $CFG unchanged"
    }

    echo "# sentinel" > "$CFG"

    # D4 - D9: rejections first, while the sentinel is in place.
    reject_all D4 \
        "port 0" "$(mk port=0)" \
        "port 70000" "$(mk port=70000)" \
        "port -1" "$(mk port=-1)" \
        "port as string" "$(mk 'port="587"')" \
        "port true" "$(mk port=true)" \
        "port 587.5" "$(mk port=587.5)"

    reject_all D5 \
        "tls none (never unencrypted)" "$(mk 'tls="none"')" \
        "tls ssl (only starttls is supported)" "$(mk 'tls="ssl"')" \
        "tls SSLv3" "$(mk 'tls="SSLv3"')" \
        "tls empty" "$(mk 'tls=""')" \
        "tls uppercase" "$(mk 'tls="STARTTLS"')"

    # Newlines could add extra msmtp directives to the file.
    reject_all D6 \
        "username trailing newline" "$(mk 'username="user@gmail.com\n"')" \
        "username inner newline" "$(mk 'username="a\npassword evil"')" \
        "password trailing newline" "$(mk 'password="abcdEFGHijklMNOP\n"')" \
        "password inner newline" "$(mk 'password="abc\ntls off"')" \
        "host trailing newline" "$(mk 'host="smtp.gmail.com\n"')" \
        "host inner newline" "$(mk 'host="a.com\nhost b.com"')" \
        "sender trailing newline" "$(mk 'sender="user@gmail.com\n"')" \
        "sender inner newline" "$(mk 'sender="a@b.com\nfrom c@d.com"')"

    reject_all D8 \
        "missing password" "$(mk del:password)" \
        "missing host" "$(mk del:host)" \
        "empty host" "$(mk 'host=""')" \
        "empty password" "$(mk 'password=""')" \
        "extra field" "$(mk 'extra="1"')" \
        "not JSON" "host=smtp.gmail.com" \
        "JSON array" "[]" \
        "empty input" "" \
        "duplicate field" '{"host":"a.com","host":"b.com","port":587,"tls":"ssl","username":"u","password":"p","sender":"u@a.com"}'

    BIG="$(python3 -c "print('a' * 5000)")"
    reject D9 "5000-character password" "$(mk "password=\"$BIG\"")" \
        && { head -c 3000000 /dev/zero | tr '\0' 'a' | timeout 20 "$HELPER" > /dev/null 2>&1; RC=$?
             if [ "$RC" -eq 1 ]; then
                 record D9 PASS "oversized input rejected with exit 1; $CFG unchanged"
             else
                 record D9 FAIL "3 MB input: expected exit 1, got $RC"
             fi; }

    # Control characters and non-ASCII are rejected. Ordinary
    # punctuation and spaces are allowed (checked in D15).
    D7_BAD=0
    for ESCAPED in '\t' '\u0001' '\u007f' 'é' '\r'; do
        reject D7 "password with $ESCAPED" "$(mk "password=\"ab${ESCAPED}cd\"")" || D7_BAD=1
        reject D7 "username with $ESCAPED" "$(mk "username=\"ab${ESCAPED}cd\"")" || D7_BAD=1
    done

    # D10: arguments are refused, even with valid input.
    "$HELPER" --x < /dev/null > /dev/null 2>&1
    RC_ARG=$?
    printf '%s' "$(mk)" | "$HELPER" --x > /dev/null 2>&1
    RC_ARG2=$?
    if [ "$RC_ARG" -eq 2 ] && [ "$RC_ARG2" -eq 2 ]; then
        record D10 PASS "arguments refused with exit 2"
    else
        record D10 FAIL "expected exit 2, got $RC_ARG and $RC_ARG2"
    fi

    # D12: not root.
    printf '%s' "$(mk)" | runuser -u nobody -- "$HELPER" > /dev/null 2>&1
    RC=$?
    [ "$RC" -eq 2 ] \
        && record D12 PASS "non-root run refused with exit 2" \
        || record D12 FAIL "non-root run: expected exit 2, got $RC"

    # D1 / D2: a valid object is written, the password stays quiet.
    echo "# sentinel" > "$CFG"
    run_helper "$(mk)"

    if [ "$RC" -ne 0 ]; then
        record D1 FAIL "valid settings: exit $RC: $HOUT"
    elif [ "$(stat -c '%U:%G %a' "$CFG")" != "root:nagios 640" ]; then
        record D1 FAIL "written, but $CFG is $(stat -c '%U:%G %a' "$CFG")"
    elif ! grep -qx 'host smtp.gmail.com' "$CFG" \
        || ! grep -qx 'tls_starttls on' "$CFG" \
        || ! grep -qx "password \"$GOOD_PASSWORD\"" "$CFG"; then
        record D1 FAIL "written, but the expected lines are missing"
    else
        record D1 PASS "valid settings written to $CFG as root:nagios 640"
    fi

    if printf '%s' "$HOUT" | grep -q "$GOOD_PASSWORD"; then
        record D2 FAIL "password appeared in helper output"
    elif ls /etc/msmtprc.tmp > /dev/null 2>&1; then
        record D2 FAIL "temporary file left behind"
    else
        record D2 PASS "password not in helper output; no temp file left"
    fi

    # D7: shell syntax is written literally and never executed.
    rm -f /tmp/pwned-by-helper
    run_helper "$(mk 'password="$(touch/tmp/pwned-by-helper)"')"
    [ "$D7_BAD" -eq 0 ] \
        && [ "$RC" -eq 0 ] \
        && [ ! -e /tmp/pwned-by-helper ] \
        && grep -qxF 'password "$(touch/tmp/pwned-by-helper)"' "$CFG" \
        && record D7 PASS "control and non-ASCII characters rejected; shell syntax written literally, nothing executed" \
        || record D7 FAIL "D7_BAD=$D7_BAD rc=$RC"

    # D11: repeated applies keep owner and mode.
    for N in 1 2 3; do run_helper "$(mk)"; done
    [ "$RC" -eq 0 ] && [ "$(stat -c '%U:%G %a' "$CFG")" = "root:nagios 640" ] \
        && record D11 PASS "owner and mode unchanged after repeated applies" \
        || record D11 FAIL "after repeats: rc=$RC, $(stat -c '%U:%G %a' "$CFG")"

    # D13: the real path the web interface uses.
    if id pinpoint > /dev/null 2>&1; then
        printf '%s' "$(mk 'host="smtp.example.com"')" \
            | runuser -u pinpoint -- sudo -n "$HELPER" > /dev/null 2>&1
        RC=$?
        [ "$RC" -eq 0 ] && grep -qx 'host smtp.example.com' "$CFG" \
            && record D13 PASS "pinpoint applied settings through sudo" \
            || record D13 FAIL "through sudo: exit $RC"
    else
        record D13 SKIP "no pinpoint account"
    fi

    # D15: what msmtp sends equals what the admin typed. Each
    # password goes through the real helper, then the written
    # file (pointed at a fake local SMTP server) is used by the
    # real msmtp. TLS is switched off in the copy only, because
    # the fake server cannot do TLS.
    if command -v msmtp > /dev/null 2>&1; then
        D15_OUT="$(python3 - "$HELPER" "$CFG" <<'PY'
import base64
import json
import re
import socketserver
import subprocess
import sys
import tempfile
import threading

HELPER, CONFIG = sys.argv[1], sys.argv[2]
received = []


class Handler(socketserver.StreamRequestHandler):
    def send(self, text):
        self.wfile.write((text + "\r\n").encode())

    def handle(self):
        self.send("220 fake ESMTP")
        in_data = False
        for raw in self.rfile:
            line = raw.decode(errors="replace").rstrip("\r\n")
            upper = line.upper()
            if in_data:
                if line == ".":
                    in_data = False
                    self.send("250 ok")
            elif upper.startswith(("EHLO", "HELO")):
                self.wfile.write(b"250-fake\r\n250 AUTH PLAIN\r\n")
            elif upper.startswith("AUTH PLAIN"):
                parts = line.split()
                if len(parts) < 3:
                    self.send("334 ")
                    parts.append(self.rfile.readline().decode().strip())
                _, user, password = base64.b64decode(parts[2]).decode().split("\0")
                received.append((user, password))
                self.send("235 ok")
            elif upper.startswith("DATA"):
                self.send("354 go")
                in_data = True
            elif upper.startswith("QUIT"):
                self.send("221 bye")
                return
            else:
                self.send("250 ok")


socketserver.TCPServer.allow_reuse_address = True
server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
port = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()

PASSWORDS = [
    "Admin-123!", "a b c", " leading", "trailing ", "ab#cd", "a #b",
    'ab"cd', '"abc"', 'abc"', '"', '""', "abc\\", "\\", "$x%y`z",
    "$(touch /tmp/x)", "'single'", "p@ss;word|&<>", "x" * 256,
]
USERS = ["user@gmail.com", "first last", 'we"ird', "#name"]

bad = []
for user in USERS:
    for password in PASSWORDS:
        payload = json.dumps({
            "host": "smtp.gmail.com", "port": 587, "tls": "starttls",
            "username": user, "password": password,
            "sender": "user@gmail.com",
        })
        done = subprocess.run([HELPER], input=payload.encode(),
                              capture_output=True)
        if done.returncode != 0:
            bad.append("helper rejected %r: %s" % (password[:20], done.stderr.decode().strip()))
            continue

        text = open(CONFIG, encoding="ascii").read()
        text = re.sub(r"(?m)^host .*$", "host 127.0.0.1", text)
        text = re.sub(r"(?m)^port .*$", "port %d" % port, text)
        text = re.sub(r"(?m)^tls on$", "tls off", text)
        text = re.sub(r"(?m)^tls_starttls .*$", "tls_starttls off", text)
        text = re.sub(r"(?m)^auth on$", "auth plain", text)

        with tempfile.NamedTemporaryFile("w", suffix=".conf") as handle:
            handle.write(text)
            handle.flush()
            before = len(received)
            subprocess.run(["msmtp", "-C", handle.name, "-a", "pinpoint",
                            "to@example.com"], input=b"Subject: t\n\nhi\n",
                           capture_output=True, timeout=20)

        if len(received) != before + 1 or received[-1] != (user, password):
            got = received[-1] if len(received) > before else "nothing"
            bad.append("user=%r password=%r -> server got %r" % (user, password[:20], got))

total = len(USERS) * len(PASSWORDS)
if bad:
    print("FAIL %d of %d: %s" % (len(bad), total, "; ".join(bad[:3])))
    sys.exit(1)
print("PASS %d user/password pairs reached the server exactly as typed" % total)
PY
        )"
        D15_RC=$?

        if [ "$D15_RC" -eq 0 ]; then
            record D15 PASS "${D15_OUT#PASS }"
        else
            record D15 FAIL "$D15_OUT"
        fi
    else
        record D15 SKIP "msmtp is not installed"
    fi
fi

##################################################
# Not automated here
##################################################

for ID in B10 E1 E3 E8; do
    record "$ID" SKIP "not automated or needs a PinPoint release with the feature"
done

echo | tee -a "$OUT"
echo "SUMMARY|PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP" | tee -a "$OUT"

[ "$FAIL" -eq 0 ]
