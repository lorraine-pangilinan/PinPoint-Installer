#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : update-recovery-tests.sh
# Purpose: Phase 2 of the update plan on a real
#          appliance: install the recovery executor,
#          health suite and reconcile services, then
#          run the restore drill and the failure-
#          injection cases FI-06 to FI-11 and FI-13.
#
# Usage: sudo ./update-recovery-tests.sh           (main cases)
#        sudo ./update-recovery-tests.sh reboot-prepare
#        (reboot the VM)
#        sudo ./update-recovery-tests.sh reboot-check
#
# The reboot pair is FI-10: a change is interrupted,
# the VM restarts, and the boot-time reconcile must
# restore Nagios before it starts.
#
# Expects the module scripts in /root/pinpoint/
# (or PINPOINT_MODULE_DIR). Every drill stops Nagios
# and PinPoint web for a few minutes and FI-11 leaves
# a recovery point that does not verify on disk: run
# it only on a VM you can restore from a snapshot.
# Output: one line per case, "ID|STATUS|note", then a
# summary. Also written to /root/update-recovery-output.txt
# (the reboot cases append to it).
##################################################

set -u

OUT="/root/update-recovery-output.txt"
DIR="${PINPOINT_MODULE_DIR:-/root/pinpoint}"
EXEC="/usr/local/sbin/pinpoint-update-exec"
PROGRAM="/usr/local/sbin/pinpoint-update"
HEALTH="/usr/local/lib/pinpoint-update/pinpoint-update-health.sh"
DB="/var/lib/pinpoint/updates/updates.db"
RP_DIR="/usr/local/.pinpoint-rp"
NAGIOS="/usr/local/nagios"
LOCK="/run/lock/pinpoint-update.lock"
DRILL_LINE="pinpoint_drill_invalid_directive=1"

PASS=0
FAIL=0

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root."
    exit 1
fi

record() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" | tee -a "$OUT"

    case "$2" in
        PASS) PASS=$((PASS + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
    esac
}

# check ID NOTE COMMAND...: PASS if the command succeeds.
check() {
    local ID="$1" NOTE="$2"
    shift 2
    if "$@" > /dev/null 2>&1; then
        record "$ID" PASS "$NOTE"
    else
        record "$ID" FAIL "$NOTE"
    fi
}

# SQL against the update database (no sqlite3 CLI needed).
sql() {
    python3 -I -c 'import sqlite3, sys
con = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
for row in con.execute(sys.argv[2]):
    print("|".join("" if v is None else str(v) for v in row))' "$DB" "$1"
}

last_txn() {
    sql "SELECT txn_id, state, failure_code, downtime_seconds FROM txn ORDER BY created_at DESC, rowid DESC LIMIT 1"
}

# Hash of the parts of Nagios a change may touch. Runtime
# files under var/ change on their own while Nagios runs.
static_tree_hash() {
    (cd "$NAGIOS" && find bin sbin share etc libexec -printf '%p %m %U:%G\n' -type f -exec sha256sum {} + 2> /dev/null) \
        | sort | sha256sum | cut -d ' ' -f 1
}

services_up() {
    systemctl is-active --quiet nagios && systemctl is-active --quiet pinpoint-gunicorn
}

# drill ID NOTE EXPECTED_EXIT EXPECTED_STATE [drill args]
drill_case() {
    local ID="$1" NOTE="$2" WANT_RC="$3" WANT_STATE="$4"
    shift 4
    local BEFORE AFTER RC ROW STATE TIMES

    BEFORE="$(static_tree_hash)"
    "$EXEC" drill --yes "$@" > "/root/update-recovery-$ID.txt" 2>&1
    RC=$?
    ROW="$(last_txn)"
    STATE="$(echo "$ROW" | cut -d '|' -f 2)"
    TIMES="$(grep -m1 'Recovery point:' "/root/update-recovery-$ID.txt" | sed 's/^ *//')"
    AFTER="$(static_tree_hash)"

    if [ "$RC" -ne "$WANT_RC" ] || [ "$STATE" != "$WANT_STATE" ]; then
        record "$ID" FAIL "$NOTE: exit $RC (want $WANT_RC), state $STATE (want $WANT_STATE). See /root/update-recovery-$ID.txt"
    elif [ "$WANT_STATE" = "rolled_back" ] && [ "$BEFORE" != "$AFTER" ]; then
        record "$ID" FAIL "$NOTE: Nagios files differ after the restore"
    elif [ "$WANT_STATE" = "rolled_back" ] && ! services_up; then
        record "$ID" FAIL "$NOTE: nagios or pinpoint-gunicorn not running after the restore"
    else
        record "$ID" PASS "$NOTE ($TIMES)"
    fi
}

##################################################
# FI-10, part 1: interrupt a change, then reboot
##################################################

if [ "${1:-}" = "reboot-prepare" ]; then
    static_tree_hash > /root/update-recovery-reboot.hash
    "$EXEC" drill --yes --inject config --crash-after-apply > /root/update-recovery-R20.txt 2>&1
    ROW="$(last_txn)"
    if [ "$(echo "$ROW" | cut -d '|' -f 2)" = "applying" ] && grep -qx "$DRILL_LINE" "$NAGIOS/etc/nagios.cfg"; then
        record R20 PASS "Change interrupted in applying with a broken nagios.cfg ($(echo "$ROW" | cut -d '|' -f 1)). Reboot now."
    else
        record R20 FAIL "Interrupted change not set up: $ROW"
    fi
    exit "$FAIL"
fi

##################################################
# FI-10, part 2: after the reboot
##################################################

if [ "${1:-}" = "reboot-check" ]; then
    # The finish unit runs the health suite, about 2-3 minutes after boot.
    for _ in $(seq 1 60); do
        case "$(last_txn | cut -d '|' -f 2)" in
            applying|rolling_back) sleep 10 ;;
            *) break ;;
        esac
    done
    ROW="$(last_txn)"
    if [ "$(echo "$ROW" | cut -d '|' -f 2)" = "rolled_back" ]; then
        record R21 PASS "Boot-time reconcile rolled back: $ROW"
    else
        record R21 FAIL "State after reboot: $ROW (journalctl -u pinpoint-update-reconcile -u pinpoint-update-reconcile-finish)"
    fi
    if journalctl -b -u pinpoint-update-reconcile --no-pager 2> /dev/null | grep -q 'Files restored'; then
        record R22 PASS "Files were restored before nagios.service started."
    else
        record R22 FAIL "No restore found in this boot's pinpoint-update-reconcile log."
    fi
    check R23 "nagios.cfg no longer has the injected line" bash -c "! grep -qx '$DRILL_LINE' '$NAGIOS/etc/nagios.cfg'"
    check R24 "Nagios files equal those before the interrupted change" \
        bash -c "[ \"\$(cat /root/update-recovery-reboot.hash)\" = \"$(static_tree_hash)\" ]"
    check R25 "nagios and pinpoint-gunicorn running" services_up
    check R26 "Audit chain intact" "$PROGRAM" audit --verify
    echo "reboot-check: PASS $PASS, FAIL $FAIL" | tee -a "$OUT"
    exit "$FAIL"
fi

: > "$OUT"

##################################################
# Install
##################################################

if ! bash "$DIR/configure-monitoring-updates.sh" > /root/update-recovery-install.txt 2>&1; then
    record R01 FAIL "configure-monitoring-updates.sh failed. See /root/update-recovery-install.txt"
    echo "PASS $PASS, FAIL $FAIL" | tee -a "$OUT"
    exit 1
fi
record R01 PASS "configure-monitoring-updates.sh installed the executor and health suite"

check R02 "pinpoint-update-exec is root:root 755" \
    bash -c "[ \"\$(stat -c '%U:%G %a' $EXEC)\" = 'root:root 755' ]"
check R03 "Recovery point folder is root:root 700 on the Nagios filesystem" \
    bash -c "[ \"\$(stat -c '%U:%G %a' $RP_DIR)\" = 'root:root 700' ] && [ \"\$(stat -c %d $RP_DIR)\" = \"\$(stat -c %d $NAGIOS)\" ]"
check R04 "Both reconcile services are enabled" \
    systemctl is-enabled pinpoint-update-reconcile.service pinpoint-update-reconcile-finish.service
check R05 "Reconcile with nothing to do exits 0" "$EXEC" reconcile
check R06 "Running the install module again succeeds" bash "$DIR/configure-monitoring-updates.sh"

##################################################
# Health suite
##################################################

SAVE_DIR="$(mktemp -d)"
"$HEALTH" --save "$SAVE_DIR" > /root/update-recovery-health.txt 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    record R07 PASS "Health suite passes on the installed appliance ($(tail -1 /root/update-recovery-health.txt))"
else
    record R07 FAIL "Health suite: $RC critical failure(s): $(grep '|FAIL|' /root/update-recovery-health.txt | cut -d '|' -f 1 | tr '\n' ' ')"
fi
check R08 "Health suite output never contains the pinpoint-api password" \
    bash -c "! grep -qF \"\$(sed -n 's/^NAGIOS_PASSWORD=//p' /etc/pinpoint/nagios-api.env)\" /root/update-recovery-health.txt"
rm -rf "$SAVE_DIR"

##################################################
# Drills
##################################################

drill_case R10 "Restore drill, no fault" 0 rolled_back
drill_case R11 "FI-06 invalid Nagios config is rolled back" 0 rolled_back --inject config
drill_case R12 "FI-07 nagios.service fails to start, rolled back" 0 rolled_back --inject service
drill_case R13 "FI-08 plugin regression is rolled back" 0 rolled_back --inject plugin

for ID in R11 R12 R13; do
    grep -q 'failed: HC-' "/root/update-recovery-$ID.txt" \
        && record "${ID}a" PASS "Health suite reported: $(grep -m1 -o 'failed: .*' "/root/update-recovery-$ID.txt")" \
        || record "${ID}a" FAIL "The injected fault was not reported by the health suite"
done

##################################################
# FI-09: executor killed during the change
##################################################

BEFORE="$(static_tree_hash)"
"$EXEC" drill --yes --inject config --crash-after-apply > /root/update-recovery-R14.txt 2>&1
STATE="$(last_txn | cut -d '|' -f 2)"
"$EXEC" reconcile > /root/update-recovery-R14-reconcile.txt 2>&1
RC=$?
if [ "$STATE" = "applying" ] && [ "$RC" -eq 10 ] && [ "$(last_txn | cut -d '|' -f 2)" = "rolled_back" ] \
    && [ "$BEFORE" = "$(static_tree_hash)" ] && services_up; then
    record R14 PASS "FI-09 killed in applying; reconcile rolled back (exit 10)"
else
    record R14 FAIL "FI-09: state before reconcile $STATE, reconcile exit $RC, now $(last_txn)"
fi

##################################################
# FI-13: busy lock
##################################################

flock "$LOCK" sleep 60 &
HOLDER=$!
sleep 1
"$EXEC" drill --yes > /root/update-recovery-R15.txt 2>&1
RC=$?
[ "$RC" -eq 5 ] && record R15 PASS "FI-13 drill refused while the lock is held (exit 5)" \
    || record R15 FAIL "FI-13 drill exit $RC while the lock is held (want 5)"
bash "$DIR/deploy-pinpoint-web.sh" > /root/update-recovery-R16.txt 2>&1
RC=$?
if [ "$RC" -ne 0 ] && grep -q 'Nagios update or recovery drill is running' /root/update-recovery-R16.txt; then
    record R16 PASS "FI-13 deploy-pinpoint-web.sh refused while the lock is held"
else
    record R16 FAIL "deploy-pinpoint-web.sh exit $RC while the lock is held. See /root/update-recovery-R16.txt"
fi
kill "$HOLDER" 2> /dev/null
wait "$HOLDER" 2> /dev/null
check R17 "PinPoint web still running after the refused deploy" systemctl is-active --quiet pinpoint-gunicorn

##################################################
# FI-11: damaged recovery copy (last: needs repair)
##################################################

drill_case R18 "FI-11 damaged recovery copy gives RecoveryFailed (exit 11)" 11 recovery_failed --inject corrupt
RP="$(sql "SELECT recovery_point_id FROM txn ORDER BY created_at DESC, rowid DESC LIMIT 1")"
if [ -d "$RP_DIR/$RP/nagios" ] && grep -q 'CRITICAL: recovery failed' /root/update-recovery-R18.txt; then
    record R18a PASS "Evidence kept in $RP_DIR/$RP; CRITICAL message shown"
else
    record R18a FAIL "Recovery copy or CRITICAL message missing"
fi

# Manual repair, as the runbook will describe: remove the fault, start, check.
sed -i "/^$DRILL_LINE\$/d" "$NAGIOS/etc/nagios.cfg"
systemctl start nagios pinpoint-gunicorn
sleep 15
"$EXEC" verify > /root/update-recovery-R19-verify.txt 2>&1
VERIFY_RC=$?
[ "$VERIFY_RC" -eq 11 ] && grep -q "$RP DOES NOT VERIFY" /root/update-recovery-R19-verify.txt \
    && record R19 PASS "pinpoint-update-exec verify reports the damaged recovery point" \
    || record R19 FAIL "verify exit $VERIFY_RC. See /root/update-recovery-R19-verify.txt"
check R19a "Appliance healthy again after the manual repair" services_up

##################################################
# Audit
##################################################

check R30 "Audit chain intact" "$PROGRAM" audit --verify
MISSING="$(sql "SELECT COUNT(*) FROM txn WHERE kind = 'drill' AND state = 'rolled_back' AND downtime_seconds IS NULL AND failure_code IS NOT 'INTERRUPTED'")"
[ "$MISSING" = "0" ] && record R31 PASS "Every completed drill recorded its downtime" \
    || record R31 FAIL "$MISSING completed drill(s) without a downtime"

echo | tee -a "$OUT"
sql "SELECT txn_id, state, failure_code, downtime_seconds FROM txn ORDER BY created_at" | tee -a "$OUT"
echo "PASS $PASS, FAIL $FAIL" | tee -a "$OUT"

exit "$FAIL"
