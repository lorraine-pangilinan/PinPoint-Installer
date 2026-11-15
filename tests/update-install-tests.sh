#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : update-install-tests.sh
# Purpose: Phases 4 and 5 of the update plan on a
#          real appliance: catalog check, refusals,
#          a real Nagios update that is broken on
#          purpose and rolled back, an interrupted
#          update, the scheduled-window rules, and a
#          real successful update.
#
# Usage: sudo CATALOG_URL=https://raw.githubusercontent.com/<owner>/<repo>/<branch>/catalog/ \
#             PINPOINT_MODULE_DIR=/root/pinpoint-phase45 ./update-install-tests.sh
#
# CATALOG_URL must hold an update set that upgrades
# pp-mon-baseline-1 (pp-mon-2026.11-1, Nagios Core
# 4.5.14). The fixtures are read from the same
# branch: <CATALOG_URL>/../tests/catalog-fixtures/.
#
# Run it on a staging VM you can restore from a
# snapshot: it stops Nagios and PinPoint web several
# times and ends with Nagios Core 4.5.14 installed.
# Output: one line per case, "ID|STATUS|note", then a
# summary. Also written to /root/update-install-output.txt.
##################################################

set -u

OUT="/root/update-install-output.txt"
DIR="${PINPOINT_MODULE_DIR:-/root/pinpoint}"
CATALOG_URL="${CATALOG_URL:?set CATALOG_URL to the catalog folder of the branch under test}"
FIXTURES="${CATALOG_URL%catalog/}tests/catalog-fixtures"
PROGRAM="/usr/local/sbin/pinpoint-update"
EXEC="/usr/local/sbin/pinpoint-update-exec"
DB="/var/lib/pinpoint/updates/updates.db"
CONF="/etc/pinpoint/updates/updater.conf"
MANIFESTS="/etc/pinpoint/updates/manifests"
NOTICE="/var/lib/pinpoint/update-notice"
MARKER="/etc/pinpoint/updates/allow-fault-injection"
NAGIOS_BIN="/usr/local/nagios/bin/nagios"
CANDIDATE="pp-mon-2026.11-1"
BASELINE="pp-mon-baseline-1"
NEW_VERSION="4.5.14"

PASS=0
FAIL=0

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root."
    exit 1
fi

: > "$OUT"

record() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" | tee -a "$OUT"
    if [ "$2" = "PASS" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

check() {
    local ID="$1" NOTE="$2"
    shift 2
    if "$@" > /dev/null 2>&1; then
        record "$ID" PASS "$NOTE"
    else
        record "$ID" FAIL "$NOTE"
    fi
}

# is ID NOTE ACTUAL EXPECTED
is() {
    if [ "$3" = "$4" ]; then
        record "$1" PASS "$2"
    else
        record "$1" FAIL "$2: got '$3', want '$4'"
    fi
}

sql() {
    python3 -c 'import sqlite3, sys
con = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
for row in con.execute(sys.argv[2]):
    print("|".join("" if v is None else str(v) for v in row))' "$DB" "$1"
}

core_version() {
    "$NAGIOS_BIN" -V 2> /dev/null | sed -n 's/^Nagios Core \([0-9.]*\).*/\1/p' | head -n 1
}

set_catalog() {
    sed -i "s|^catalog_url = .*|catalog_url = $1|" "$CONF"
}

approve() {
    "$PROGRAM" approve "$CANDIDATE" --confirm "$CANDIDATE" --accept-limitations "$@" --json 2>&1 \
        | python3 -c 'import json, sys; print(json.load(sys.stdin).get("txn_id") or "")'
}

txn_state() {
    sql "SELECT state || '|' || IFNULL(failure_code, '') FROM txn WHERE txn_id = '$1'"
}

##################################################
# Install and settings
##################################################

bash "$DIR/configure-monitoring-updates.sh" > /root/update-install-I01.txt 2>&1
check I01 "configure-monitoring-updates.sh succeeds (see /root/update-install-I01.txt)" \
    grep -q 'Update Manager configured' /root/update-install-I01.txt
check I02 "Build user pinpoint-updater exists and cannot log in" \
    bash -c '[ "$(getent passwd pinpoint-updater | cut -d: -f7)" = /usr/sbin/nologin ]'
check I03 "Daily catalog timer and scheduled-window timer are enabled" \
    systemctl is-enabled --quiet pinpoint-update-discover.timer pinpoint-update-run.timer
check I04 "Ubuntu security updates are automatic" \
    bash -c "$PROGRAM status --json | grep -q '\"ubuntu_security_updates\": \"on\"'"
check I05 "updater.conf is root:root 644 and points to the main catalog" \
    bash -c "[ \"\$(stat -c '%U:%G %a' $CONF)\" = 'root:root 644' ] && grep -q '/main/catalog/' $CONF"
check I06 "No update set is offered before the catalog is checked" \
    bash -c "$PROGRAM status --json | grep -q '\"update_status\": \"UNKNOWN'"

##################################################
# Catalog: good, tampered, changed, wrong host
##################################################

set_catalog "$CATALOG_URL"
"$PROGRAM" discover > /root/update-install-I07.txt 2>&1
RC=$?
if [ "$RC" -eq 0 ] && grep -q "Update available: $CANDIDATE" /root/update-install-I07.txt; then
    record I07 PASS "discover finds $CANDIDATE (Nagios Core $NEW_VERSION) on the branch catalog"
else
    record I07 FAIL "discover exit $RC. See /root/update-install-I07.txt"
fi
is I08 "$CANDIDATE recorded with source catalog" \
    "$(sql "SELECT source FROM manifest WHERE manifest_id = '$CANDIDATE'")" catalog
check I09 "Login notice says an update is available" grep -q "Update available: $CANDIDATE" "$NOTICE"

set_catalog "$FIXTURES/bad-digest/"
"$PROGRAM" discover > /root/update-install-I10.txt 2>&1
RC=$?
if [ "$RC" -eq 7 ] && [ ! -f "$MANIFESTS/pp-mon-2099.01-1.json" ] \
    && [ -z "$(sql "SELECT 1 FROM manifest WHERE manifest_id = 'pp-mon-2099.01-1'")" ]; then
    record I10 PASS "Tampered manifest refused (exit 7), nothing written: $(tail -n 1 /root/update-install-I10.txt)"
else
    record I10 FAIL "Tampered manifest: exit $RC. See /root/update-install-I10.txt"
fi

set_catalog "$FIXTURES/changed/"
"$PROGRAM" discover > /root/update-install-I11.txt 2>&1
RC=$?
if [ "$RC" -eq 7 ] && grep -q 'needs a new ID' /root/update-install-I11.txt; then
    record I11 PASS "Changed digest for a recorded manifest refused (exit 7)"
else
    record I11 FAIL "Changed manifest: exit $RC. See /root/update-install-I11.txt"
fi

set_catalog "https://example.com/catalog/"
"$PROGRAM" discover > /root/update-install-I12.txt 2>&1
RC=$?
if [ "$RC" -eq 7 ] && grep -q 'not an allowed HTTPS address' /root/update-install-I12.txt; then
    record I12 PASS "Catalog on another host refused before any download (exit 7)"
else
    record I12 FAIL "Other host: exit $RC. See /root/update-install-I12.txt"
fi
check I13 "Status is UNKNOWN after a failed check, never up to date" \
    bash -c "$PROGRAM status --json | grep -q '\"update_status\": \"UNKNOWN (last check failed'"

set_catalog "$CATALOG_URL"
check I14 "Catalog check works again on the branch catalog" "$PROGRAM" discover --quiet

##################################################
# F1: real update, broken on purpose, rolled back
##################################################

install -o root -g root -m 0644 /dev/null "$MARKER"
TXN="$(approve)"
"$EXEC" run "$TXN" --inject config > /root/update-install-F1.txt 2>&1
RC=$?
ROW="$(txn_state "$TXN")"
if [ "$RC" -eq 10 ] && [ "$ROW" = "rolled_back|HEALTH_FAILED" ] && [ "$(core_version)" = "4.5.11" ]; then
    record F1 PASS "Nagios $NEW_VERSION built and installed, broken config detected, rolled back to 4.5.11 ($TXN)"
else
    record F1 FAIL "exit $RC, state $ROW, Nagios $(core_version). See /root/update-install-F1.txt"
fi
is F1a "Installed set is still $BASELINE" "$(sql "SELECT manifest_id FROM installed_state")" "$BASELINE"
check F1b "Build was done by pinpoint-updater (build log written, build folder removed)" \
    bash -c "[ -s /var/lib/pinpoint/updates/txn/$TXN/build.log ] && [ ! -e /var/lib/pinpoint/update-build/$TXN ]"
is F1c "Approval used up; rolled_back notice queued" \
    "$(sql "SELECT a.status || '|' || n.kind FROM txn t JOIN approval a ON a.approval_id = t.approval_id
            JOIN notice n ON n.txn_id = t.txn_id WHERE t.txn_id = '$TXN'")" "used|rolled_back"
check F1d "nagios and pinpoint-gunicorn running after the rollback" \
    systemctl is-active --quiet nagios pinpoint-gunicorn

##################################################
# F2: update interrupted after install, reconciled
##################################################

TXN="$(approve)"
"$EXEC" run "$TXN" --crash-after-apply > /root/update-install-F2.txt 2>&1
RC=$?
BEFORE="$(txn_state "$TXN")"
"$EXEC" reconcile >> /root/update-install-F2.txt 2>&1
RC2=$?
ROW="$(txn_state "$TXN")"
if [ "$RC" -eq 11 ] && [ "${BEFORE%%|*}" = applying ] && [ "$RC2" -eq 10 ] \
    && [ "$ROW" = "rolled_back|INTERRUPTED" ] && [ "$(core_version)" = "4.5.11" ]; then
    record F2 PASS "Killed after installing $NEW_VERSION; reconcile rolled back to 4.5.11 ($TXN)"
else
    record F2 FAIL "exits $RC/$RC2, state $BEFORE -> $ROW, Nagios $(core_version). See /root/update-install-F2.txt"
fi
check F2a "nagios and pinpoint-gunicorn running after reconcile" systemctl is-active --quiet nagios pinpoint-gunicorn
rm -f "$MARKER"
check F2b "Fault injection is refused without the staging marker" \
    bash -c "! $EXEC run txn-20990101000000-abcdef --inject config"

##################################################
# W: scheduled window rules
##################################################

AT="$(date -u -d '+1 day' '+%Y-%m-%dT%H:%MZ')"
TXN="$(approve --at "$AT" --window-minutes 60)"
"$EXEC" run-due > /root/update-install-W1.txt 2>&1
is W1 "Run timer does nothing before the window opens" "$(txn_state "$TXN")" "approved|"
check W2 "Login notice shows the scheduled update" grep -q 'is scheduled for' "$NOTICE"
"$EXEC" run "$TXN" > /root/update-install-W3.txt 2>&1
is W3 "Starting it by hand before the window is refused (exit 4)" "$?" 4
"$PROGRAM" cancel "$TXN" > /dev/null 2>&1
is W4 "Scheduled update cancelled" "$(txn_state "$TXN" | cut -d '|' -f 1)" cancelled

##################################################
# S: real successful update, the admin's way (--now)
##################################################

"$PROGRAM" approve "$CANDIDATE" --confirm "$CANDIDATE" --accept-limitations --now > /root/update-install-S1.txt 2>&1
TXN="$(sql "SELECT txn_id FROM txn WHERE kind = 'update' ORDER BY created_at DESC, rowid DESC LIMIT 1")"
for _ in $(seq 1 180); do
    case "$(txn_state "$TXN")" in
        succeeded*|rolled_back*|recovery_failed*|failed*|blocked*) break ;;
    esac
    sleep 10
done
ROW="$(txn_state "$TXN")"
if [ "${ROW%%|*}" = succeeded ] && [ "$(core_version)" = "$NEW_VERSION" ]; then
    record S1 PASS "approve --now ran in pinpoint-update-exec@$TXN.service: Nagios Core $NEW_VERSION installed"
else
    record S1 FAIL "state $ROW, Nagios $(core_version). journalctl -u pinpoint-update-exec@$TXN"
fi
is S2 "Installed set is now $CANDIDATE" "$(sql "SELECT manifest_id FROM installed_state")" "$CANDIDATE"
check S3 "Status says up to date; login notice removed" \
    bash -c "$PROGRAM status --json | grep -q '\"update_status\": \"Up to date' && [ ! -s $NOTICE ]"
check S4 "Health suite passes on $NEW_VERSION" \
    bash -c "/usr/local/lib/pinpoint-update/pinpoint-update-health.sh --save /root/update-install-S4 --target-version $NEW_VERSION > /root/update-install-S4.txt 2>&1"
check S5 "Nagios config kept: hosts.cfg unchanged by the update (make install-config never ran)" \
    bash -c "[ -s /usr/local/nagios/etc/objects/hosts.cfg ] && $NAGIOS_BIN -v /usr/local/nagios/etc/nagios.cfg | grep -q 'Total Errors:   0'"
RP="$(sql "SELECT recovery_point_id FROM txn WHERE txn_id = '$TXN'")"
check S6 "Recovery point $RP of the update kept for a manual restore" test -d "/usr/local/.pinpoint-rp/$RP/nagios"
check S7 "nagios and pinpoint-gunicorn running" systemctl is-active --quiet nagios pinpoint-gunicorn
check S8 "Audit chain intact" "$PROGRAM" audit --verify
is S9 "A succeeded notice was queued" "$(sql "SELECT kind FROM notice WHERE txn_id = '$TXN'")" succeeded
check S10 "Installing the same set again is refused (already installed)" \
    bash -c "! $PROGRAM approve $CANDIDATE --confirm $CANDIDATE --accept-limitations"

echo
sql "SELECT txn_id, state, IFNULL(failure_code, ''), IFNULL(downtime_seconds, '') FROM txn WHERE kind = 'update' ORDER BY created_at" | tee -a "$OUT"
sql "SELECT kind, IFNULL(txn_id, manifest_id), IFNULL(sent_at, 'pending'), attempts FROM notice ORDER BY created_at" | tee -a "$OUT"
echo "PASS $PASS, FAIL $FAIL" | tee -a "$OUT"
[ "$FAIL" -eq 0 ]
