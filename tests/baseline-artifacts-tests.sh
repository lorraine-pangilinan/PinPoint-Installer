#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : baseline-artifacts-tests.sh
# Purpose: Check setup/baseline-artifacts.sh: the
#          baseline manifest is read correctly and
#          only archives with the manifest's SHA-256
#          are accepted.
#
# Usage: bash tests/baseline-artifacts-tests.sh
#
# Runs on any machine with bash, python3 and
# sha256sum. Nothing is downloaded: wget is replaced
# by a stub that serves files from a temporary folder.
# Output: one line per case, "ID|STATUS|note", then a
# summary.
##################################################

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/setup/baseline-artifacts.sh"
REAL_MANIFEST="$REPO/setup/manifests/pp-mon-baseline-1.json"

PASS=0
FAIL=0

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

chk() {
    local ID="$1" NOTE="$2"
    shift 2
    if "$@" >> "$SB/case.log" 2>&1; then
        echo "$ID|PASS|$NOTE"
        PASS=$((PASS + 1))
    else
        echo "$ID|FAIL|$NOTE"
        FAIL=$((FAIL + 1))
    fi
}

# Fake upstream: GOOD is what the manifest expects, BAD is a
# tampered archive with a different digest.
mkdir -p "$SB/upstream" "$SB/bin" "$SB/work"
printf 'good archive\n' > "$SB/upstream/good"
printf 'tampered archive\n' > "$SB/upstream/bad"
GOOD_SHA="$(sha256sum "$SB/upstream/good" | cut -d ' ' -f 1)"

# wget stub: "wget -q -O FILE URL" copies upstream/$SERVE to
# FILE and counts calls.
cat > "$SB/bin/wget" <<'EOF'
#!/bin/bash
echo x >> "$SB/wget.calls"
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -O) OUT="$2"; shift 2 ;;
        *) shift ;;
    esac
done
cp "$SB/upstream/$SERVE" "$OUT"
EOF
chmod +x "$SB/bin/wget"

make_manifest() {
    cat > "$SB/manifest.json" <<EOF
{"schema_version": 1, "components": {"demo": {"version": "9.9.9",
 "artifact": {"url": "$1", "file": "demo.tar.gz", "sha256": "$GOOD_SHA"}}}}
EOF
}

# Run fetch_verified_artifact in a subshell, as the install
# modules do, and record its exit code.
fetch() {
    (
        export SB SERVE="$1"
        PATH="$SB/bin:$PATH"
        LOG="$SB/fetch.log"
        BASELINE_MANIFEST="$SB/manifest.json"
        cd "$SB/work"
        source "$LIB"
        fetch_verified_artifact demo
    )
}

calls() { [ -f "$SB/wget.calls" ] && wc -l < "$SB/wget.calls" || echo 0; }

# The cases below run in "bash -c", so they need these.
export -f fetch calls
export SB LIB

# --- Manifest in the repository ---
chk B1 "baseline manifest is valid JSON with schema_version 1" \
    python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["schema_version"]==1' "$REAL_MANIFEST"

chk B2 "every component has https URL, file name and 64-hex SHA-256" \
    python3 - "$REAL_MANIFEST" <<'EOF'
import json, re, sys
m = json.load(open(sys.argv[1]))
assert set(m["components"]) == {"nagios-core", "nagios-plugins", "check-ncpa"}
for c in m["components"].values():
    a = c["artifact"]
    assert a["url"].startswith("https://"), a
    assert re.fullmatch(r"[A-Za-z0-9._-]+", a["file"]), a
    assert re.fullmatch(r"[0-9a-f]{64}", a["sha256"]), a
EOF

chk B3 "baseline_field reads the Nagios Core version (4.5.11)" \
    bash -c 'BASELINE_MANIFEST="$1"; LOG=/dev/null; source "$2"; [ "$(baseline_field nagios-core version)" = 4.5.11 ]' _ "$REAL_MANIFEST" "$LIB"

chk B4 "baseline_field fails for a missing field" \
    bash -c '! (BASELINE_MANIFEST="$1"; LOG=/dev/null; source "$2"; baseline_field nagios-core nosuchfield)' _ "$REAL_MANIFEST" "$LIB"

# --- Download and verification ---
make_manifest "https://example.invalid/demo.tar.gz"

rm -f "$SB/wget.calls" "$SB/work/"*
chk D1 "matching download is accepted and kept" \
    bash -c 'fetch good && [ -f "$1/work/demo.tar.gz" ] && [ ! -e "$1/work/demo.tar.gz.part" ]' _ "$SB"

chk D2 "matching cached archive is reused without downloading" \
    bash -c 'BEFORE=$(calls); fetch bad && [ "$(calls)" = "$BEFORE" ]'

printf 'stale\n' > "$SB/work/demo.tar.gz"
chk D3 "mismatching cached archive is downloaded again and replaced" \
    bash -c 'fetch good && [ "$(sha256sum "$SB/work/demo.tar.gz" | cut -d " " -f 1)" = "$1" ]' _ "$GOOD_SHA"

rm -f "$SB/work/"*
chk D4 "tampered download fails and leaves no archive behind" \
    bash -c '! fetch bad && [ ! -e "$SB/work/demo.tar.gz" ] && [ ! -e "$SB/work/demo.tar.gz.part" ]'

chk D5 "failure message names the expected and actual digests" \
    bash -c 'grep -q "Expected: $1" "$SB/fetch.log" && grep -q "Got:" "$SB/fetch.log"' _ "$GOOD_SHA"

make_manifest "http://example.invalid/demo.tar.gz"
rm -f "$SB/work/"*
chk D6 "non-HTTPS manifest URL is refused before downloading" \
    bash -c 'BEFORE=$(calls); ! fetch good && [ "$(calls)" = "$BEFORE" ]'

chk D7 "missing manifest stops the install" \
    bash -c '! (export SERVE=good; PATH="$SB/bin:$PATH"; LOG="$SB/fetch.log"; BASELINE_MANIFEST="$SB/none.json"; cd "$SB/work"; source "$LIB"; fetch_verified_artifact demo)'

# --- Install modules no longer hard-code versions or download directly ---
chk M1 "install modules and configure-nagios.sh contain no version literals" \
    bash -c '! grep -nE "4\.5\.11|2\.4\.12" "$1"/setup/install-nagios-core.sh "$1"/setup/install-nagios-plugins.sh "$1"/setup/configure-nagios.sh' _ "$REPO"

chk M2 "install modules call wget only through fetch_verified_artifact" \
    bash -c '! grep -n "wget" "$1"/setup/install-nagios-core.sh "$1"/setup/install-nagios-plugins.sh' _ "$REPO"

chk M3 "build.sh copies the manifest onto the ISO" \
    grep -q 'setup/manifests/' "$REPO/scripts/build.sh"

echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
