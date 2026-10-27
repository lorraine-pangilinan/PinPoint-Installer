#!/bin/bash

##################################################
# PinPoint Installer Library
# Module : baseline-artifacts.sh
# Purpose: Read the bundled baseline manifest and
#          download artifacts that match its SHA-256.
#
# Sourced by install-nagios-core.sh,
# install-nagios-plugins.sh and configure-nagios.sh.
# Callers set LOG before sourcing.
#
# The manifest is manifests/pp-mon-baseline-1.json next
# to this file (in /root/pinpoint/ on an appliance, in
# setup/ in the repository). BASELINE_MANIFEST
# overrides it, for tests.
##################################################

BASELINE_MANIFEST="${BASELINE_MANIFEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manifests/pp-mon-baseline-1.json}"

# Print one field of a component, for example:
#   baseline_field nagios-core version
#   baseline_field nagios-core artifact.sha256
baseline_field() {
    python3 - "$BASELINE_MANIFEST" "$1" "$2" <<'EOF'
import json, sys

path, component, field = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    value = json.load(f)["components"][component]
for key in field.split("."):
    value = value[key]
if not isinstance(value, str) or not value or "\n" in value:
    raise SystemExit("bad value for %s %s" % (component, field))
print(value)
EOF
}

# Succeeds if FILE exists and its SHA-256 is EXPECTED.
sha256_matches() {
    local FILE="$1" EXPECTED="$2" ACTUAL

    [ -f "$FILE" ] || return 1
    ACTUAL="$(sha256sum "$FILE" | cut -d ' ' -f 1)"
    [ "$ACTUAL" = "$EXPECTED" ]
}

# Make sure the current directory holds the component's
# archive with the manifest's SHA-256. A cached copy is
# reused only if it matches; otherwise it is downloaded
# again. Exits the calling script if no matching copy
# can be obtained.
fetch_verified_artifact() {
    local COMPONENT="$1" URL FILE SHA

    if [ ! -f "$BASELINE_MANIFEST" ]; then
        echo "✗ Baseline manifest not found: $BASELINE_MANIFEST" | tee -a "$LOG"
        exit 1
    fi

    URL="$(baseline_field "$COMPONENT" artifact.url)" || exit 1
    FILE="$(baseline_field "$COMPONENT" artifact.file)" || exit 1
    SHA="$(baseline_field "$COMPONENT" artifact.sha256)" || exit 1

    case "$URL" in
        https://*) ;;
        *)
            echo "✗ $COMPONENT: manifest URL is not HTTPS." | tee -a "$LOG"
            exit 1
            ;;
    esac

    if sha256_matches "$FILE" "$SHA"; then
        echo "✓ $FILE already present; SHA-256 matches the baseline." | tee -a "$LOG"
        return 0
    fi

    if [ -f "$FILE" ]; then
        echo "  Cached $FILE does not match the baseline; downloading again." | tee -a "$LOG"
    fi

    rm -f "$FILE" "$FILE.part"
    if ! wget -q -O "$FILE.part" "$URL"; then
        rm -f "$FILE.part"
        echo "✗ Could not download $URL" | tee -a "$LOG"
        exit 1
    fi

    if ! sha256_matches "$FILE.part" "$SHA"; then
        echo "✗ $FILE does not match the baseline SHA-256." | tee -a "$LOG"
        echo "  Expected: $SHA" | tee -a "$LOG"
        echo "  Got:      $(sha256sum "$FILE.part" | cut -d ' ' -f 1)" | tee -a "$LOG"
        echo "  The download was deleted. Nothing was installed from it." | tee -a "$LOG"
        rm -f "$FILE.part"
        exit 1
    fi

    mv "$FILE.part" "$FILE"
    echo "✓ $FILE downloaded; SHA-256 matches the baseline." | tee -a "$LOG"
}
