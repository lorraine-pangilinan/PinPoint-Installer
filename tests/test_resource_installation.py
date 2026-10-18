"""Regression checks for installer packaging and web-only upgrades."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ResourceInstallationTest(unittest.TestCase):
    def test_web_upgrade_installs_helper_before_gunicorn_restarts(self):
        text = (ROOT / 'setup/deploy-pinpoint-web.sh').read_text()
        call = 'bash "$SCRIPT_DIR/install-resource-helper.sh"'
        self.assertIn(call, text)
        self.assertLess(text.index(call), text.index('systemctl restart "$SERVICE_NAME"', text.index('# [10/12]')))

    def test_privileges_uses_same_installer(self):
        text = (ROOT / 'setup/configure-pinpoint-privileges.sh').read_text()
        self.assertIn('bash "$SCRIPT_DIR/install-resource-helper.sh"', text)
        self.assertNotIn('RESOURCE_SUDOERS_TMP=', text)

    def test_companions_checked_before_web_upgrade(self):
        text = (ROOT / 'setup/deploy-pinpoint-web.sh').read_text()
        self.assertIn('install-resource-helper.sh pinpoint-apply-resources.py', text)
        self.assertLess(text.index('install-resource-helper.sh pinpoint-apply-resources.py'), text.index('# [2/12]'))

    def test_iso_packages_python_and_shell_companions(self):
        text = (ROOT / 'scripts/build.sh').read_text()
        self.assertIn('cp "$PROJECT/setup/"*.sh "$PINPOINT_DIR/"', text)
        self.assertIn('cp "$PROJECT/setup/pinpoint-apply-resources.py" "$PINPOINT_DIR/"', text)
        self.assertTrue((ROOT / 'setup/install-resource-helper.sh').is_file())


if __name__ == '__main__':
    unittest.main()
