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
NO_FLAG_MESSAGE="has no 'flask init-production --require-email-change'"

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
# A1 / A2: old PinPoint is refused, twice
##################################################

# Run the deploy script and check what it left behind.
# $1 = case ID.
check_refusal() {
    local ID="$1" RC OUTPUT_FILE

    OUTPUT_FILE="$(mktemp)"
    "$SETUP_DIR/deploy-pinpoint-web.sh" > "$OUTPUT_FILE" 2>&1
    RC=$?

    if [ "$RC" -eq 0 ]; then
        record "$ID" SKIP "deploy succeeded: this PinPoint supports the flag, so the refusal cannot be tested (use A3)"
        rm -f "$OUTPUT_FILE"
        return
    fi

    if ! grep -q "$NO_FLAG_MESSAGE" "$OUTPUT_FILE"; then
        record "$ID" FAIL "failed for another reason: $(grep -m1 '^ERROR' "$OUTPUT_FILE")"
        rm -f "$OUTPUT_FILE"
        return
    fi

    local PROBLEMS=""

    ls "$SERVER_DIR"/*.db > /dev/null 2>&1 && PROBLEMS="$PROBLEMS database-exists"
    [ -f "$CREDENTIALS_FILE" ] && PROBLEMS="$PROBLEMS credentials-file-exists"

    if [ -n "$PROBLEMS" ]; then
        record "$ID" FAIL "refused with the right message but left:$PROBLEMS"
    else
        record "$ID" PASS "refused at step 9/12 with the expected message; no database, no credentials file"
    fi

    # Known issue, not part of the pass/fail of this case.
    if grep -q 'Rollback could not restart' "$OUTPUT_FILE"; then
        record "$ID-note" WARN "rollback tried to restart a service that never existed (upgrade path after a failed first install)"
    fi

    rm -f "$OUTPUT_FILE"
}

check_refusal A1
check_refusal A2

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

for ID in A3 A4 A5 A6 A7 A8 A9 A10 A11 B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 E1 E3 E8; do
    record "$ID" SKIP "not automated or needs a PinPoint release with the feature"
done

echo | tee -a "$OUT"
echo "SUMMARY|PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP" | tee -a "$OUT"

[ "$FAIL" -eq 0 ]
