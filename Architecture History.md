# PinPoint Installer Architectures

## Architecture v1 (Fully Automated)

Boot ISO
↓
Ubuntu Autoinstall
↓
late-commands
↓
Install Nagios
Install SNMP
Install PinPoint

Issues

- User couldn’t specify language
- User couldn’t specify timezone
- User couldn’t specify keyboard
- Credentials were hardcoded

---

## Architecture v2 (Customizable)

Boot ISO
↓
Interactive Ubuntu Installer
↓
Administrator specifies:

- Language
- Keyboard
- Timezone
- Username
- Password
- Hostname

↓
Ubuntu Installation

↓
PinPoint Installer Wizard

↓
Install Packages

↓
Install Nagios

↓
Install Plugins

↓
Install SNMP

↓
Install Apache

↓
Install Web Interface

↓
Ready for the network
