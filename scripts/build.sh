#!/bin/bash

set -e

PROJECT="$HOME/PinPoint-Installer"
ISO_DIR="$PROJECT/extracted-iso"
BUILD_DIR="$PROJECT/build"

PINPOINT_DIR="$ISO_DIR/pinpoint"
AUTOINSTALL_DIR="$ISO_DIR/nocloud"

echo "=========================================="
echo " PinPoint Installer Build Script"
echo "=========================================="

echo "[0/4] Staging latest installer files..."

mkdir -p "$PINPOINT_DIR"

# Installation scripts
cp "$PROJECT/scripts/install-packages.sh" "$PINPOINT_DIR/"
cp "$PROJECT/scripts/install-nagios-core.sh" "$PINPOINT_DIR/"
cp "$PROJECT/scripts/install-nagios-plugins.sh" "$PINPOINT_DIR/"
cp "$PROJECT/scripts/configure-snmp.sh" "$PINPOINT_DIR/"
cp "$PROJECT/scripts/configure-nagios.sh" "$PINPOINT_DIR/"

# First boot
cp "$PROJECT/firstboot/pinpoint-firstboot.sh" "$PINPOINT_DIR/"

# Autoinstall files
cp "$PROJECT/autoinstall/user-data" "$AUTOINSTALL_DIR/"
cp "$PROJECT/autoinstall/meta-data" "$AUTOINSTALL_DIR/"

echo "[1/3] Updating md5sum.txt..."

cd "$ISO_DIR"

rm -f md5sum.txt

find . -type f ! -name "md5sum.txt" -print0 \
| sort -z \
| xargs -0 md5sum > md5sum.txt

echo "[2/3] Creating build directory..."

mkdir -p "$BUILD_DIR"

echo "[3/3] Building ISO..."

xorriso -as mkisofs \
-r \
-V "PINPOINT_SERVER" \
-o "$BUILD_DIR/PinPoint-Installer-v1.iso" \
-J -l \
-b boot/grub/i386-pc/eltorito.img \
-c boot.catalog \
-no-emul-boot \
-boot-load-size 4 \
-boot-info-table \
--grub2-boot-info \
-eltorito-alt-boot \
-e EFI/boot/bootx64.efi \
-no-emul-boot \
-isohybrid-gpt-basdat \
"$ISO_DIR"

echo
echo "=========================================="
echo " Build Complete!"
echo "=========================================="
echo
echo "ISO created at:"
echo "$BUILD_DIR/PinPoint-Installer-v1.iso"
