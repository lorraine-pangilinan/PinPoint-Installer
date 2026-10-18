#!/bin/bash
# Shared fresh-install / web-upgrade dependency. Run only from trusted installer
# files as root. This does not change resource.cfg or restart any service.
set -euo pipefail

fail() { echo "ERROR: $1" >&2; exit 1; }
[ "$EUID" -eq 0 ] || fail "Run install-resource-helper.sh as root."
[ "$#" -eq 0 ] || fail "This installer takes no arguments."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/pinpoint-apply-resources.py"
HELPER="/usr/local/sbin/pinpoint-apply-resources"
SUDOERS="/etc/sudoers.d/pinpoint-apply-resources"
[ -f "$SOURCE" ] || fail "Resource helper source is missing; copy the complete setup directory."
id pinpoint >/dev/null 2>&1 || fail "The pinpoint service account is missing."
for TOOL in install visudo sudo python3; do
    command -v "$TOOL" >/dev/null || fail "Required tool $TOOL is missing."
done

# Validate the narrow rule before replacing either installed file. Empty quotes
# explicitly prohibit command arguments; this grants no shell or generic sudo.
RULE="$(mktemp)"
trap 'rm -f "$RULE"' EXIT
cat > "$RULE" <<EOF
# Managed by PinPoint Installer. Fixed resource destination, managed block only.
pinpoint ALL=(root) NOPASSWD: $HELPER ""
EOF
visudo -cf "$RULE" >/dev/null || fail "Generated resource sudoers rule is invalid."
install -d -o root -g root -m 0755 /usr/local/sbin /etc/sudoers.d
install -o root -g root -m 0755 "$SOURCE" "$HELPER"
install -o root -g root -m 0440 "$RULE" "$SUDOERS"
# Check the effective sudo policy without running a resource write.
sudo -l -U pinpoint -- "$HELPER" >/dev/null 2>&1 \
    || fail "Installed resource helper is not allowed by sudo policy."
echo "Restricted Nagios resource helper and exact sudo rule installed."
