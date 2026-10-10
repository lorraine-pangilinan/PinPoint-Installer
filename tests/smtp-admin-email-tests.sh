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
# Not automated here
##################################################

for ID in A3 A4 A5 A6 A7 A8 A9 A10 A11 B1 B2 B3 B4 B5 B6 B7 B8 B9 B10 D1 E1 E3 E8; do
    record "$ID" SKIP "not automated or needs a PinPoint release with the feature"
done

echo | tee -a "$OUT"
echo "SUMMARY|PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP" | tee -a "$OUT"

[ "$FAIL" -eq 0 ]
