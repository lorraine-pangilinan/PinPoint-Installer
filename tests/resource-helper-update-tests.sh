#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : resource-helper-update-tests.sh
# Purpose: Check that updating an appliance installed
#          before the resource helper existed installs
#          the helper and its sudoers rule (issue #234),
#          on a disposable test VM, as root.
#
# Usage: sudo ./resource-helper-update-tests.sh
#
# Expects the module scripts, including
# pinpoint-apply-resources.py, in /root/pinpoint/.
# Output: one line per case, "ID|STATUS|note", then a
# summary. Also written to /root/resource-helper-output.txt.
#
# Case U2 runs deploy-pinpoint-web.sh twice (it pulls the
# latest application and restarts the service). Run it only
# on a VM you can restore from a snapshot. Request contents
# are never printed.
##################################################

set -u

OUT="/root/resource-helper-output.txt"
DIR="${PINPOINT_MODULE_DIR:-/root/pinpoint}"
HELPER="/usr/local/sbin/pinpoint-apply-resources"
RULE="/etc/sudoers.d/pinpoint-apply-resources"
CFG="/usr/local/nagios/etc/resource.cfg"

PASS=0
FAIL=0

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root."
    exit 1
fi

: > "$OUT"

record() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" | tee -a "$OUT"

    case "$2" in
        PASS) PASS=$((PASS + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
    esac
}

as_pinpoint() {
    runuser -u pinpoint -- "$@"
}

# A request for the file as it is now, with the block left unchanged.
request() {
    python3 -I - "$HELPER" "$CFG" "${1:-}" <<'PY'
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader('h', sys.argv[1])
spec = importlib.util.spec_from_loader('h', loader)
h = importlib.util.module_from_spec(spec)
loader.exec_module(h)
before, block, after = h.split_resource(open(sys.argv[2], encoding='utf-8').read())
req = {'resource_path': h.CONFIG, 'outside_digest': h.outside_digest(before, after), 'block': block}
if sys.argv[3] == 'bad-digest': req['outside_digest'] = '0' * 64
if sys.argv[3] == 'bad-path': req['resource_path'] = '/etc/passwd'
print(json.dumps(req))
PY
}

# U1: simulate a server installed before the helper existed.
rm -f "$HELPER" "$RULE"
if [ ! -e "$HELPER" ] && [ ! -e "$RULE" ]; then
    record U1 PASS "helper and sudoers rule removed (pre-helper state)"
else
    record U1 FAIL "could not remove helper or rule"
fi

# U2: the update script alone installs both, with the right owners and modes.
if bash "$DIR/deploy-pinpoint-web.sh" > /root/resource-helper-deploy1.log 2>&1 \
    && [ "$(stat -c '%U:%G %a' "$HELPER" 2> /dev/null)" = "root:root 755" ] \
    && [ "$(stat -c '%U:%G %a' "$RULE" 2> /dev/null)" = "root:root 440" ]; then
    record U2 PASS "deploy script installed helper (root:root 755) and rule (root:root 440)"
else
    record U2 FAIL "deploy script did not leave helper and rule in place; see /root/resource-helper-deploy1.log"
fi

# U3: a second update leaves exactly one helper and one rule.
bash "$DIR/deploy-pinpoint-web.sh" > /root/resource-helper-deploy2.log 2>&1
RC=$?
RULES="$(grep -c 'pinpoint-apply-resources' "$RULE" 2> /dev/null)"
RULE_FILES="$(grep -rl 'pinpoint-apply-resources' /etc/sudoers /etc/sudoers.d 2> /dev/null | wc -l)"
if [ "$RC" -eq 0 ] && [ "$RULES" = "1" ] && [ "$RULE_FILES" = "1" ] \
    && [ "$(ls /usr/local/sbin | grep -c '^pinpoint-apply-resources')" = "1" ]; then
    record U3 PASS "second update exit 0, one rule file, one helper"
else
    record U3 FAIL "second update rc=$RC, grant lines=$RULES (1 expected), rule files=$RULE_FILES"
fi

# U4: the helper is in place before the application restarts.
FIRST_HELPER="$(grep -n 'Installing the resource helper' /root/resource-helper-deploy2.log | head -n 1 | cut -d: -f1)"
FIRST_SERVICE="$(grep -n 'pinpoint-gunicorn service started' /root/resource-helper-deploy2.log | head -n 1 | cut -d: -f1)"
if [ -n "$FIRST_HELPER" ] && [ -n "$FIRST_SERVICE" ] && [ "$FIRST_HELPER" -lt "$FIRST_SERVICE" ]; then
    record U4 PASS "helper installed before the service restarted"
else
    record U4 FAIL "helper step not found before the service restart message"
fi

# U5: as pinpoint, a valid request is accepted.
if request ok | as_pinpoint sudo -n "$HELPER" > /dev/null 2>&1; then
    record U5 PASS "valid request accepted as pinpoint"
else
    record U5 FAIL "valid request rejected"
fi

# U6: a wrong digest and a wrong path are rejected.
if request bad-digest | as_pinpoint sudo -n "$HELPER" > /dev/null 2>&1; then
    record U6 FAIL "wrong digest accepted"
elif request bad-path | as_pinpoint sudo -n "$HELPER" > /dev/null 2>&1; then
    record U6 FAIL "wrong resource_path accepted"
else
    record U6 PASS "wrong digest and wrong resource_path rejected"
fi

# U7: the rule is exact: no arguments, nothing else.
if as_pinpoint sudo -n -l "$HELPER" extra > /dev/null 2>&1; then
    record U7 FAIL "helper may be run with arguments"
elif as_pinpoint sudo -n -l /bin/cat > /dev/null 2>&1; then
    record U7 FAIL "pinpoint may run /bin/cat through sudo"
else
    record U7 PASS "helper only without arguments; no extra rights"
fi

# U8: resource.cfg is untouched and not writable by pinpoint.
if [ "$(stat -c '%U:%G %a' "$CFG")" = "nagios:nagios 660" ] && ! as_pinpoint test -w "$CFG" 2> /dev/null; then
    record U8 PASS "resource.cfg is nagios:nagios 660 and pinpoint reaches it only through the helper"
else
    record U8 FAIL "resource.cfg owner, mode or writability changed"
fi

# U9: if the helper cannot be installed, the installer stops with an error.
TMP="$(mktemp -d)"
cp "$DIR/install-resource-helper.sh" "$TMP/"
RESOURCE_HELPER_LOG="$TMP/log" bash "$TMP/install-resource-helper.sh" > "$TMP/out" 2>&1
if [ $? -ne 0 ] && grep -q 'source is missing' "$TMP/out"; then
    record U9 PASS "missing helper source stops the install with a clear error"
else
    record U9 FAIL "install did not stop on a missing helper source"
fi
rm -rf "$TMP"

echo
echo "Summary: $PASS passed, $FAIL failed." | tee -a "$OUT"

[ "$FAIL" -eq 0 ]
