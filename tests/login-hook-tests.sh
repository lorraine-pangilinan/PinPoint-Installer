#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : login-hook-tests.sh
# Purpose: Check setup/pinpoint-login-hook.sh: the
#          install credentials come first, then the
#          PinPoint Update Manager opens once after a
#          fresh install, and never otherwise.
#
# Usage: bash tests/login-hook-tests.sh
#
# Runs on any machine with bash. The hook is copied with
# its paths pointed at a temporary folder; sudo, the
# credentials viewer and pinpoint-update are stubs.
# Output: one line per case, "ID|STATUS|note", then a
# summary.
##################################################

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export SB

mkdir -p "$SB/bin" "$SB/lib"

sed -e "s#/var/lib/pinpoint/#$SB/lib/#g" \
    -e "s#/usr/local/bin/pinpoint-web-credentials#$SB/bin/creds#" \
    -e "s#/usr/local/sbin/pinpoint-update#$SB/bin/pinpoint-update#" \
    "$REPO/setup/pinpoint-login-hook.sh" > "$SB/hook.sh"

# sudo stub: run the command as is.
printf '#!/bin/bash\n"$@"\n' > "$SB/bin/sudo"

# Credentials stub: removes its marker unless KEEP_CREDS=1
# (the administrator did not confirm).
cat > "$SB/bin/creds" <<'EOF'
#!/bin/bash
echo "CREDENTIALS SHOWN"
[ "${KEEP_CREDS:-0}" = 1 ] || rm -f "$SB/lib/web-credentials-pending"
EOF

# pinpoint-update stub: records the call and removes the
# marker, as the real program does.
cat > "$SB/bin/pinpoint-update" <<'EOF'
#!/bin/bash
echo "MENU $*" >> "$SB/menu.calls"
rm -f "$SB/lib/update-menu-pending"
EOF
chmod +x "$SB/bin/"*

chk() {
    local ID="$1" NOTE="$2"
    shift 2
    if "$@"; then
        echo "$ID|PASS|$NOTE"
        PASS=$((PASS + 1))
    else
        echo "$ID|FAIL|$NOTE"
        FAIL=$((FAIL + 1))
    fi
}

# Log in once: an interactive shell that sources the hook.
login() {
    rm -f "$SB/menu.calls"
    echo | PATH="$SB/bin:$PATH" bash --norc -i -c 'source "$SB/hook.sh"; declare -F | grep -c pinpoint_login_ || true' \
        > "$SB/out" 2>/dev/null
}

menu_calls() { [ -f "$SB/menu.calls" ] && wc -l < "$SB/menu.calls" || echo 0; }

# H1: fresh install, first login
touch "$SB/lib/web-credentials-pending" "$SB/lib/update-menu-pending"
login
chk H1 "fresh install: credentials shown, then the menu opens with --first-login" \
    bash -c 'grep -q "CREDENTIALS SHOWN" "$SB/out" && grep -qx "MENU --first-login" "$SB/menu.calls"'

login
chk H2 "second login: menu does not open again" \
    bash -c '[ ! -f "$SB/menu.calls" ] && ! grep -q "CREDENTIALS SHOWN" "$SB/out"'

# H3: credentials not confirmed yet, so the menu waits
touch "$SB/lib/web-credentials-pending" "$SB/lib/update-menu-pending"
KEEP_CREDS=1 login
chk H3 "credentials still pending: menu waits" \
    bash -c 'grep -q "CREDENTIALS SHOWN" "$SB/out" && [ ! -f "$SB/menu.calls" ] && [ -f "$SB/lib/update-menu-pending" ]'

login
chk H4 "next login after confirming: menu opens" \
    bash -c 'grep -qx "MENU --first-login" "$SB/menu.calls"'

# H5: existing appliance, no markers at all
rm -f "$SB/lib/"*
login
chk H5 "existing appliance: nothing shown, menu not opened" \
    bash -c '[ ! -f "$SB/menu.calls" ] && ! grep -q "CREDENTIALS" "$SB/out"'

# H6: non-interactive shells are untouched
touch "$SB/lib/update-menu-pending"
rm -f "$SB/menu.calls"
PATH="$SB/bin:$PATH" bash --norc -c 'source "$SB/hook.sh"' > /dev/null 2>&1
chk H6 "non-interactive shell: menu not opened" \
    bash -c '[ ! -f "$SB/menu.calls" ]'

# H7: helper functions do not stay in the login shell
login
chk H7 "hook leaves no pinpoint_login_ functions behind" \
    bash -c '[ "$(tail -n 1 "$SB/out")" = 0 ]'

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
