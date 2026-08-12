#!/bin/bash

##################################################
# PinPoint ISO Build Script
##################################################

set -e

PROJECT="$HOME/PinPoint-Installer"

ISO_DIR="$PROJECT/extracted-iso"
BUILD_DIR="$PROJECT/build"

PINPOINT_DIR="$ISO_DIR/pinpoint"
AUTOINSTALL_DIR="$ISO_DIR/nocloud"

echo "=========================================="
echo "      PinPoint ISO Build Script"
echo "=========================================="
echo

##################################################
# Stage Latest Files
##################################################

echo "[0/4] Staging latest installer files..."

rm -rf "$PINPOINT_DIR"
mkdir -p "$PINPOINT_DIR"

echo "Copying setup modules..."

cp "$PROJECT/setup/"*.sh "$PINPOINT_DIR/"

echo "Copying first boot files..."

cp "$PROJECT/firstboot/"* "$PINPOINT_DIR/"

echo "Copying autoinstall configuration..."

cp "$PROJECT/autoinstall/user-data" "$AUTOINSTALL_DIR/"
cp "$PROJECT/autoinstall/meta-data" "$AUTOINSTALL_DIR/"

echo "✓ Latest installer files staged."

##################################################
# Update md5sum
##################################################

echo
echo "[1/4] Updating md5sum.txt..."

cd "$ISO_DIR"

rm -f md5sum.txt

find . -type f \
    ! -name "md5sum.txt" \
    ! -name "boot.catalog" \
    ! -path "./boot/grub/i386-pc/eltorito.img" \
    -print0 \
| sort -z \
| xargs -0 md5sum > md5sum.txt

echo "✓ md5sum.txt updated."

##################################################
# Create Build Directory
##################################################

echo
echo "[2/4] Preparing build directory..."

mkdir -p "$BUILD_DIR"

echo "✓ Build directory ready."

##################################################
# Build ISO
##################################################

echo
echo "[3/4] Building ISO..."

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

echo "✓ ISO successfully created."

##################################################
# Finish
##################################################

echo
echo "=========================================="
echo "         Build Complete!"
echo "=========================================="
echo
echo "ISO Location:"
echo "$BUILD_DIR/PinPoint-Installer-v1.iso"
echo
