#!/bin/bash

##################################################
# PinPoint Installer Test Runner
# Module : update-mail-tests.sh
# Purpose: Update-notice email on a real appliance
#          (plan 10.1 and 14). Sends the queued
#          notices through /bin/mail and msmtp, the
#          transport the Nagios alerts use, to a
#          local test mail server that requires
#          STARTTLS and a login, like a real relay.
#
# Usage: sudo PINPOINT_MODULE_DIR=/root/pinpoint-phase45 ./update-mail-tests.sh
#
# Needs: Phases 4 and 5 installed, network for apt
# and the catalog. Installs python3-aiosmtpd and
# trusts a throw-away certificate for "localhost"
# while it runs; both are removed at the end, and
# /etc/msmtprc and updater.conf are put back.
# Run it on a staging VM you can restore from a
# snapshot. Output: one line per case, "ID|STATUS|note",
# then a summary. Also in /root/update-mail-output.txt.
##################################################

set -u

OUT="/root/update-mail-output.txt"
WORK="/root/pinpoint-mailtest"
SINK_DIR="$WORK/received"
PROGRAM="/usr/local/sbin/pinpoint-update"
EXEC="/usr/local/sbin/pinpoint-update-exec"
HELPER="/usr/local/sbin/pinpoint-apply-smtp"
DB="/var/lib/pinpoint/updates/updates.db"
CONF="/etc/pinpoint/updates/updater.conf"
MSMTP_CFG="/etc/msmtprc"
CA_FILE="/usr/local/share/ca-certificates/pinpoint-mailtest.crt"
NAGIOS_CFG="/usr/local/nagios/etc/nagios.cfg"
SINK_UNIT="pinpoint-mailtest-sink"
PORT=2587
TO="${MAIL_TEST_TO:-adminraine@gmail.com}"
SENDER="pinpoint-alerts@mailtest.lan"
PASSWORD="mt-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
WRONG="wrong-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

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

sql_write() {
    python3 -c 'import sqlite3, sys
con = sqlite3.connect(sys.argv[1], timeout=10)
with con:
    con.execute(sys.argv[2])' "$DB" "$1"
}

received() { find "$SINK_DIR" -name '*.json' | wc -l; }

# Queue one test notice through the program's own code, so the audit chain stays intact.
queue() {
    python3 - "$1" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader('pu', '/usr/local/sbin/pinpoint-update')
spec = importlib.util.spec_from_loader('pu', loader)
pu = importlib.util.module_from_spec(spec)
loader.exec_module(pu)
store = pu.Store()
print(pu.queue_notice(store, 'mailtest', pu.subject('Mail test %s' % sys.argv[1]),
                      'Mail test notice %s.\n' % sys.argv[1], 'mailtest', sys.argv[1]))
PY
}

notice() { sql "SELECT IFNULL(sent_at, 'pending'), attempts FROM notice WHERE txn_id = '$1'" | sed 's/^20[^|]*|/sent|/'; }

discover() { "$PROGRAM" discover --quiet >> "$WORK/discover.log" 2>&1; }

set_notify() {
    sed -i '/^notify_to *=/d' "$CONF"
    [ -n "$1" ] && echo "notify_to = $1" >> "$CONF"
    return 0
}

apply_smtp() {
    printf '{"host": "localhost", "port": %d, "tls": "starttls", "username": "pinpoint", "password": "%s", "sender": "%s"}' \
        "$PORT" "$1" "$SENDER" | "$HELPER"
}

sink_start() {
    systemctl reset-failed "$SINK_UNIT" > /dev/null 2>&1
    # The password goes in a file: systemd logs a unit's command line.
    (umask 077; printf '%s' "$PASSWORD" > "$WORK/sink-password")
    systemd-run --quiet --unit="$SINK_UNIT" /usr/bin/python3 "$WORK/sink.py" "$SINK_DIR" "$PORT" \
        "$WORK/cert.pem" "$WORK/key.pem" "$WORK/sink-password"
    for _ in $(seq 1 30); do
        (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2> /dev/null && return 0
        sleep 0.5
    done
    return 1
}

sink_stop() { systemctl stop "$SINK_UNIT" > /dev/null 2>&1; systemctl reset-failed "$SINK_UNIT" > /dev/null 2>&1; }

##################################################
# Setup
##################################################

mkdir -p "$WORK" "$SINK_DIR"
rm -f "$SINK_DIR"/* "$WORK/discover.log"
cp -p "$CONF" "$WORK/updater.conf.before"
cp -p "$MSMTP_CFG" "$WORK/msmtprc.before"

cat > "$WORK/sink.py" <<'PY'
#!/usr/bin/python3
# Test mail server: STARTTLS required, then AUTH required. Saves each message.
import json, ssl, sys, time, uuid
from pathlib import Path
from aiosmtpd.controller import Controller
from aiosmtpd.smtp import AuthResult

out, port, cert, key = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
password = Path(sys.argv[5]).read_text()


def check_login(server, session, envelope, mechanism, auth_data):
    ok = getattr(auth_data, 'login', b'') == b'pinpoint' and getattr(auth_data, 'password', b'') == password.encode()
    # handled=False: the server answers 535 itself, as a real relay does (the default stays silent).
    return AuthResult(success=ok, handled=False)


class Save:
    async def handle_DATA(self, server, session, envelope):
        name = '%d-%s' % (time.time_ns(), uuid.uuid4().hex[:6])
        (out / (name + '.eml')).write_bytes(envelope.original_content or envelope.content)
        (out / (name + '.json')).write_text(json.dumps({
            'mail_from': envelope.mail_from, 'rcpt_tos': envelope.rcpt_tos,
            'tls': session.ssl is not None, 'authenticated': bool(session.authenticated)}))
        return '250 OK saved'


context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
context.load_cert_chain(cert, key)
controller = Controller(Save(), hostname='127.0.0.1', port=port, tls_context=context, require_starttls=True,
                        authenticator=check_login, auth_required=True, auth_require_tls=True)
controller.start()
while True:
    time.sleep(3600)
PY

DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3-aiosmtpd > "$WORK/apt.log" 2>&1
check M00a "python3-aiosmtpd installed" python3 -c 'import aiosmtpd'

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" > /dev/null 2>&1
cp "$WORK/cert.pem" "$CA_FILE"
update-ca-certificates > /dev/null 2>&1
check M00b "Test certificate trusted" grep -q "$(sed -n 2p "$WORK/cert.pem")" /etc/ssl/certs/ca-certificates.crt
check M00c "Test mail server listening on 127.0.0.1:$PORT" sink_start

AUDIT_START="$(sql "SELECT IFNULL(MAX(seq), 0) FROM audit")"
# A rerun starts from the same state as the first run: the real notices unsent, no test notices.
sql_write "DELETE FROM notice WHERE manifest_id = 'mailtest'"
sql_write "UPDATE notice SET sent_at = NULL, attempts = 0, last_error = NULL"

PENDING_REAL="$(sql "SELECT COUNT(*) FROM notice WHERE sent_at IS NULL AND IFNULL(manifest_id, '') != 'mailtest'")"
echo "Real notices pending at start: $PENDING_REAL" | tee -a "$OUT"
sql "SELECT kind, IFNULL(txn_id, manifest_id), attempts FROM notice WHERE sent_at IS NULL" | tee -a "$OUT"

##################################################
# M01-M02: transport
##################################################

check M01a "Helper accepts the relay settings" apply_smtp "$PASSWORD"
is M01b "msmtprc is root:nagios 640" "$(stat -c '%U:%G %a' "$MSMTP_CFG")" "root:nagios 640"

BEFORE="$(received)"
printf 'Baseline from the Nagios user.\n' | sudo -u nagios /usr/bin/mail -s "M02 baseline" "$TO" > "$WORK/M02.txt" 2>&1
is M02a "The nagios user can send through /bin/mail (alert path)" "$(received)" "$((BEFORE + 1))"
LAST="$(ls -t "$SINK_DIR"/*.json 2> /dev/null | head -n 1)"
check M02b "Delivered over STARTTLS with a login" \
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d["tls"] and d["authenticated"]))' "$LAST"

##################################################
# M03-M04: no real recipient means nothing is sent
##################################################

set_notify ""
BEFORE="$(received)"
discover
is M03a "No notify_to and no system_users: nothing sent" "$(received)" "$BEFORE"
is M03b "Notices stay pending, no attempt counted" \
    "$(sql "SELECT COUNT(*) FROM notice WHERE sent_at IS NULL AND attempts = 0 AND IFNULL(manifest_id, '') != 'mailtest'")" \
    "$PENDING_REAL"

set_notify "ops@example.com, root@localhost"
discover
is M04 "Placeholder addresses only: nothing sent" "$(received)" "$BEFORE"

##################################################
# M05-M07: the queued notices are sent once
##################################################

set_notify "$TO"
AUDIT_BEFORE="$(sql "SELECT COUNT(*) FROM audit WHERE event = 'notice.sent'")"
discover
is M05a "Every pending notice sent ($PENDING_REAL)" "$(received)" "$((BEFORE + PENDING_REAL))"
is M05b "None left pending" \
    "$(sql "SELECT COUNT(*) FROM notice WHERE sent_at IS NULL AND IFNULL(manifest_id, '') != 'mailtest'")" 0
is M05c "One notice.sent audit row each" \
    "$(sql "SELECT COUNT(*) FROM audit WHERE event = 'notice.sent'")" "$((AUDIT_BEFORE + PENDING_REAL))"

python3 - "$SINK_DIR" "$TO" "$SENDER" "$(hostname)" > "$WORK/M06.txt" 2>&1 <<'PY'
import email, json, sys
from email import policy
from pathlib import Path
out, to, sender, host = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
bad = 0
for meta in sorted(out.glob('*.json')):
    msg = email.message_from_bytes(meta.with_suffix('.eml').read_bytes(), policy=policy.default)
    if msg['Subject'] == 'M02 baseline':
        continue
    d = json.loads(meta.read_text())
    ok = (d['rcpt_tos'] == [to] and msg['Subject'].startswith('[PinPoint %s] ' % host)
          and sender in (msg['From'] or ''))
    print('%s | %s | %s | %s' % ('ok' if ok else 'BAD', d['rcpt_tos'], msg['From'], msg['Subject']))
    bad += not ok
sys.exit(bad)
PY
check M06 "Each mail: one recipient, From is the relay sender, subject [PinPoint host]" test "$?" -eq 0

check M07 "The succeeded notice carries the transaction details" \
    bash -c "grep -l 'Nagios update installed' '$SINK_DIR'/*.eml | xargs grep -l 'Result:      succeeded' | xargs grep -q 'Transaction: txn'"

BEFORE="$(received)"
discover
"$EXEC" run-due >> "$WORK/discover.log" 2>&1
is M08 "Run again (discover and run-due): nothing sent twice" "$(received)" "$BEFORE"

##################################################
# M09-M11: relay down, then back
##################################################

queue M10 > /dev/null
sink_stop
discover
is M09a "Relay down: notice still pending after one attempt" "$(notice M10)" "pending|1"
check M09b "Relay down: the reason is recorded" \
    test -n "$(sql "SELECT last_error FROM notice WHERE txn_id = 'M10'")"
is M09c "Relay down: a notice.failed audit row" \
    "$(sql "SELECT COUNT(*) FROM audit WHERE event = 'notice.failed' AND txn_id = 'M10' AND seq > $AUDIT_START")" 1
sql "SELECT last_error FROM notice WHERE txn_id = 'M10'" > "$WORK/M09-error.txt"

sink_start
BEFORE="$(received)"
"$EXEC" run-due >> "$WORK/discover.log" 2>&1
is M10a "Relay back: run-due (5-minute timer) retries and sends it" "$(notice M10)" "sent|2"
is M10b "One mail for it" "$(received)" "$((BEFORE + 1))"

##################################################
# M11: wrong password
##################################################

apply_smtp "$WRONG" > /dev/null
queue M11 > /dev/null
BEFORE="$(received)"
discover
is M11a "Wrong password: not delivered, still pending" "$(notice M11)" "pending|1"
is M11b "Wrong password: nothing reached the server" "$(received)" "$BEFORE"
sql "SELECT last_error FROM notice WHERE txn_id = 'M11'" > "$WORK/M11-error.txt"
check M11c "The error mentions authentication" grep -qi 'auth' "$WORK/M11-error.txt"
no_password_leak() {
    ! { sql "SELECT IFNULL(last_error, '') FROM notice"; sql "SELECT detail_json FROM audit"
        journalctl --since '-30 min' --no-pager 2> /dev/null; cat /var/log/mail.log 2> /dev/null; } \
        | grep -q -e "$WRONG" -e "$PASSWORD"
}
check M11d "No password in the notice table, audit log, journal or mail log" no_password_leak
apply_smtp "$PASSWORD" > /dev/null
discover
is M11e "Right password again: sent" "$(notice M11)" "sent|2"

##################################################
# M12: attempt limit
##################################################

queue M12 > /dev/null
sql_write "UPDATE notice SET attempts = 9 WHERE txn_id = 'M12'"
sink_stop
discover
is M12a "Tenth failure counted" "$(notice M12)" "pending|10"
sink_start
BEFORE="$(received)"
discover
is M12b "After 10 attempts it is not tried again" "$(notice M12)" "pending|10"
is M12c "And nothing is sent" "$(received)" "$BEFORE"

##################################################
# M13: several notify_to addresses in one mail
##################################################

SECOND="second.admin@mailtest.lan"
set_notify "$TO, $SECOND"
queue M13 > /dev/null
discover
LAST="$(ls -t "$SINK_DIR"/*.json | head -n 1)"
is M13 "Two notify_to addresses: one mail to both" \
    "$(python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1]))["rcpt_tos"])))' "$LAST")" \
    "$(printf '%s\n' "$TO" "$SECOND" | sort | paste -sd,)"

##################################################
# M14: recipients from the Nagios system_users group
##################################################

set_notify ""
# The appliance lists cfg_file lines (no cfg_dir), so add one for the test file and put nagios.cfg back after.
TEST_CFG="/usr/local/nagios/etc/objects/pinpoint-mailtest.cfg"
cp -p "$NAGIOS_CFG" "$WORK/nagios.cfg.before"
echo "cfg_file=$TEST_CFG" >> "$NAGIOS_CFG"
cat > "$TEST_CFG" <<EOF
# Temporary, written by update-mail-tests.sh
define contact {
    contact_name                  mailtest-real
    use                           generic-contact
    email                         $TO
}
define contact {
    contact_name                  mailtest-placeholder
    use                           generic-contact
    email                         someone@example.com
}
define contactgroup {
    contactgroup_name             system_users
    members                       mailtest-real,mailtest-placeholder
}
EOF
chown nagios:nagios "$TEST_CFG"
if /usr/local/nagios/bin/nagios -v "$NAGIOS_CFG" > "$WORK/M14-verify.txt" 2>&1; then
    systemctl restart nagios
    for _ in $(seq 1 30); do
        grep -q 'mailtest-placeholder' /usr/local/nagios/var/objects.cache 2> /dev/null && break
        sleep 1
    done
    queue M14 > /dev/null
    discover
    LAST="$(ls -t "$SINK_DIR"/*.json | head -n 1)"
    is M14a "system_users: sent" "$(notice M14)" "sent|1"
    is M14b "system_users: only the real address, not example.com" \
        "$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["rcpt_tos"]))' "$LAST")" "$TO"
else
    record M14a FAIL "Test contacts rejected by nagios -v (see $WORK/M14-verify.txt)"
fi
cp -p "$WORK/nagios.cfg.before" "$NAGIOS_CFG"
rm -f "$TEST_CFG"
systemctl restart nagios
check M14c "Nagios running again without the test contacts" \
    bash -c "systemctl is-active --quiet nagios && sleep 3 && ! grep -q mailtest-real /usr/local/nagios/var/objects.cache"

##################################################
# M15: one sender at a time
##################################################

set_notify "$TO"
queue M15 > /dev/null
flock -x /var/lib/pinpoint/updates/notices.lock "$PROGRAM" discover --quiet >> "$WORK/discover.log" 2>&1
is M15a "While another process holds the notices lock: left to it" "$(notice M15)" "pending|0"
discover
is M15b "Lock released: sent by the next run" "$(notice M15)" "sent|1"
check M15c "Every test notice delivered exactly once" python3 - "$SINK_DIR" <<'PY'
import collections, email, sys
from email import policy
from pathlib import Path
# Subject and body: two rolled-back transactions of one update set share a subject, not a body.
mails = [email.message_from_bytes(p.read_bytes(), policy=policy.default) for p in Path(sys.argv[1]).glob('*.eml')]
seen = collections.Counter((m['Subject'], m.get_content()) for m in mails)
dup = {s[0]: n for s, n in seen.items() if n > 1}
print(dup)
sys.exit(1 if dup else 0)
PY

##################################################
# Cleanup
##################################################

sink_stop
rm -f "$CA_FILE" "$WORK/sink-password" "$WORK/key.pem"
update-ca-certificates --fresh > /dev/null 2>&1
cp -p "$WORK/updater.conf.before" "$CONF"
cp -p "$WORK/msmtprc.before" "$MSMTP_CFG"
chown root:nagios "$MSMTP_CFG"
chmod 640 "$MSMTP_CFG"
DEBIAN_FRONTEND=noninteractive apt-get remove -y -q python3-aiosmtpd >> "$WORK/apt.log" 2>&1
check Z1 "Test certificate no longer trusted" bash -c "! grep -q '$(sed -n 2p "$WORK/cert.pem")' /etc/ssl/certs/ca-certificates.crt"
check Z2 "msmtprc and updater.conf restored" \
    bash -c "cmp -s '$WORK/msmtprc.before' '$MSMTP_CFG' && cmp -s '$WORK/updater.conf.before' '$CONF'"
check Z3 "Audit chain intact" bash -c "'$PROGRAM' audit --verify | tail -n 1 | grep -q intact"

echo "Notices at the end (kind | id | state | attempts):" | tee -a "$OUT"
sql "SELECT kind, IFNULL(txn_id, manifest_id), IFNULL(sent_at, 'pending'), attempts FROM notice ORDER BY created_at" | tee -a "$OUT"
echo "SUMMARY: PASS $PASS, FAIL $FAIL" | tee -a "$OUT"
[ "$FAIL" -eq 0 ]
