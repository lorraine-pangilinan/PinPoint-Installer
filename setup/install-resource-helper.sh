#!/bin/bash

##################################################
# PinPoint Installer Module
# Module : install-resource-helper.sh
# Purpose: Install the root-owned helper the web
#          application uses to write its managed
#          block into Nagios's resource.cfg (NCPA
#          tokens, custom check secrets), and the
#          sudoers rule that lets pinpoint run it.
#
# Run by:
#   - configure-pinpoint-privileges.sh (new installs)
#   - deploy-pinpoint-web.sh (every install and
#     upgrade), before the application restarts, so
#     a server installed before the helper existed
#     gets it when it is updated.
#
# Safe to run any number of times: it rewrites the
# same two files and leaves one helper and one rule.
# It exits nonzero, with a clear message, if the helper
# cannot be installed or does not work for pinpoint.
#
# Secrets are never written to the log or console. The
# self-test sends the helper the unchanged block, so
# resource.cfg is not modified.
##################################################

set -e

LOG="${RESOURCE_HELPER_LOG:-/var/log/pinpoint-privileges.log}"

APP_USER="pinpoint"

RESOURCE_HELPER="/usr/local/sbin/pinpoint-apply-resources"
RESOURCE_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pinpoint-apply-resources.py"
RESOURCE_SUDOERS="/etc/sudoers.d/pinpoint-apply-resources"
RESOURCE_CFG="/usr/local/nagios/etc/resource.cfg"

fail() {
    echo "ERROR: $1" | tee -a "$LOG"
    echo "Check $LOG for details." | tee -a "$LOG"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

##################################################
# Install
##################################################

id "$APP_USER" > /dev/null 2>&1 \
    || fail "Account $APP_USER not found. The resource helper cannot be authorised."

[ -f "$RESOURCE_SOURCE" ] || fail "Resource helper source is missing: $RESOURCE_SOURCE."

# The helper runs as root with /usr/bin/python3 -I; refuse to install one that
# cannot be compiled, rather than leaving a broken file behind.
python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$RESOURCE_SOURCE" \
    >> "$LOG" 2>&1 || fail "Resource helper source does not parse with python3."

install -m 755 -o root -g root "$RESOURCE_SOURCE" "$RESOURCE_HELPER" \
    || fail "Could not install $RESOURCE_HELPER."

RESOURCE_SUDOERS_TMP="$(mktemp)"
cat > "$RESOURCE_SUDOERS_TMP" <<EOF
# Managed by PinPoint Installer. Fixed resource destination, managed block only.
$APP_USER ALL=(root) NOPASSWD: $RESOURCE_HELPER ""
EOF

if ! visudo -cf "$RESOURCE_SUDOERS_TMP" >> "$LOG" 2>&1; then
    rm -f "$RESOURCE_SUDOERS_TMP"
    fail "Generated resource sudoers rule is invalid."
fi

install -m 440 -o root -g root "$RESOURCE_SUDOERS_TMP" "$RESOURCE_SUDOERS" \
    || { rm -f "$RESOURCE_SUDOERS_TMP"; fail "Could not install $RESOURCE_SUDOERS."; }
rm -f "$RESOURCE_SUDOERS_TMP"

echo "✓ Restricted resource block helper installed." | tee -a "$LOG"

##################################################
# Self-test
##################################################

if [ "$(stat -c '%U:%G %a' "$RESOURCE_HELPER")" != "root:root 755" ]; then
    fail "$RESOURCE_HELPER must be root:root 755."
fi

if [ "$(stat -c '%U:%G %a' "$RESOURCE_SUDOERS")" != "root:root 440" ]; then
    fail "$RESOURCE_SUDOERS must be root:root 440."
fi

# -l only checks the rule; the helper is not run.
if ! runuser -u "$APP_USER" -- sudo -n -l "$RESOURCE_HELPER" > /dev/null 2>&1; then
    fail "$APP_USER cannot run $RESOURCE_HELPER through sudo."
fi

# The rule allows no arguments, and nothing else with it.
if runuser -u "$APP_USER" -- sudo -n -l "$RESOURCE_HELPER" extra > /dev/null 2>&1; then
    fail "$APP_USER may pass arguments to $RESOURCE_HELPER."
fi

if runuser -u "$APP_USER" -- sudo -n -l /bin/cat > /dev/null 2>&1; then
    fail "$APP_USER has more sudo rights than the resource helper allows."
fi

[ -f "$RESOURCE_CFG" ] \
    || fail "$RESOURCE_CFG not found. Run install-nagios-core.sh first."

# No-op request: the file's own outside regions and its current block, unchanged.
# The helper's digest and block-splitting code is reused so the test cannot drift
# from it. The request is piped straight to the helper and is never printed.
noop_request() {
    python3 -I - "$RESOURCE_HELPER" "$RESOURCE_CFG" <<'PY'
import importlib.machinery, importlib.util, json, sys
sys.dont_write_bytecode = True  # no __pycache__ next to the root-owned helper
loader = importlib.machinery.SourceFileLoader('resource_helper', sys.argv[1])
spec = importlib.util.spec_from_loader('resource_helper', loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)
before, block, after = helper.split_resource(open(sys.argv[2], encoding='utf-8').read())
print(json.dumps({'resource_path': helper.CONFIG,
                  'outside_digest': helper.outside_digest(before, after),
                  'block': block}))
PY
}

if ! noop_request | runuser -u "$APP_USER" -- sudo -n "$RESOURCE_HELPER" > /dev/null 2>> "$LOG"; then
    fail "$RESOURCE_HELPER rejected an unchanged-block request from $APP_USER. $RESOURCE_CFG must be nagios:nagios 0660 and hold at most one PinPoint block."
fi

# Same request with a wrong digest must be refused.
if noop_request | sed 's/"outside_digest": "[0-9a-f]*"/"outside_digest": "0"/' \
    | runuser -u "$APP_USER" -- sudo -n "$RESOURCE_HELPER" > /dev/null 2>&1; then
    fail "$RESOURCE_HELPER accepted a request with a wrong digest."
fi

echo "✓ Resource helper installed and authorised for $APP_USER (no-op request accepted, wrong digest refused)." | tee -a "$LOG"

exit 0
