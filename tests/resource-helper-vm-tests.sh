#!/bin/bash
# Installed integration checks. Run only on a disposable Pinpoint appliance:
# sudo bash tests/resource-helper-vm-tests.sh
# Installs the helper, applies current application config, leaves repair installed.
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo 'Run as root on a disposable appliance.' >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$HERE/../setup"
APP=/opt/pinpoint/Network-Diagnosis-System/server
BACKUP="$(mktemp -d /var/backups/pinpoint-resource-test.XXXXXX)"
chmod 700 "$BACKUP"
for FILE in /usr/local/nagios/etc/resource.cfg /usr/local/nagios/etc/objects/hosts.cfg; do
    cp -p "$FILE" "$BACKUP/$(basename "$FILE")"
done
for FILE in /usr/local/sbin/pinpoint-apply-resources /etc/sudoers.d/pinpoint-apply-resources; do
    if [ -e "$FILE" ]; then cp -p "$FILE" "$BACKUP/$(basename "$FILE").$(stat -c %a "$FILE")"; fi
done
bash "$SETUP/install-resource-helper.sh"
bash "$SETUP/install-resource-helper.sh"
[ "$(stat -c '%U:%G %a' /usr/local/sbin/pinpoint-apply-resources)" = 'root:root 755' ]
[ "$(stat -c '%U:%G %a' /etc/sudoers.d/pinpoint-apply-resources)" = 'root:root 440' ]
visudo -cf /etc/sudoers.d/pinpoint-apply-resources
visudo -c > "$BACKUP/sudoers-validation.log" 2>&1
if runuser -u pinpoint -- sudo -n /usr/local/sbin/pinpoint-apply-resources unexpected > "$BACKUP/extra-argument.log" 2>&1; then
    echo 'FAIL: extra arguments allowed' >&2; exit 1
fi
if printf '{"resource_path":"/etc/sudoers","outside_digest":"bad","block":null}' \
    | runuser -u pinpoint -- sudo -n /usr/local/sbin/pinpoint-apply-resources > "$BACKUP/invalid-request.log" 2>&1; then
    echo 'FAIL: invalid request accepted' >&2; exit 1
fi
# Missing companion must fail without changing either installed dependency.
sha256sum /usr/local/sbin/pinpoint-apply-resources /etc/sudoers.d/pinpoint-apply-resources > "$BACKUP/installed.sha256"
mkdir "$BACKUP/incomplete"
cp "$SETUP/install-resource-helper.sh" "$BACKUP/incomplete/"
if bash "$BACKUP/incomplete/install-resource-helper.sh" > "$BACKUP/missing-source.log" 2>&1; then
    echo 'FAIL: missing helper source accepted' >&2; exit 1
fi
sha256sum -c "$BACKUP/installed.sha256"
set -a
source /etc/pinpoint/pinpoint.env
set +a
export PINPOINT_SCHEDULER=0
cd "$APP"
runuser -u pinpoint --preserve-environment -- /opt/pinpoint/venv/bin/python - <<'PY'
from app import app
from app.network_discovery.create_host_cfg import regenerate_and_apply_config_status
with app.app_context():
    status, _message = regenerate_and_apply_config_status()
    print('Application config status:', status)
    if status not in ('applied', 'unchanged'):
        raise SystemExit('FAIL: current configuration could not be generated/applied')
PY
/usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg > "$BACKUP/nagios-validation.log" 2>&1
sed -n '/Total Warnings:/p; /Total Errors:/p' "$BACKUP/nagios-validation.log"
[ "$(stat -c '%U:%G %a' /usr/local/nagios/etc/resource.cfg)" = 'nagios:nagios 660' ]
systemctl is-active nagios pinpoint-gunicorn
echo "PASS: installed resource helper checks. Private backups: $BACKUP"
