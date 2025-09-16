#!/usr/bin/env bash

set -euo pipefail

# Build netboot files for Framework Desktop (argo)
# Usage: ./scripts/build-netboot.sh [output-dir]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${1:-$REPO_DIR/netboot-files}"

echo "Building netboot files for argo..."
cd "$REPO_DIR"

# Clean previous builds
rm -f kernel netboot-script result

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Build components directly to output directory
echo "Building kernel..."
nix build .#nixosConfigurations.argo-netboot.config.system.build.kernel -o "$OUTPUT_DIR/kernel"

echo "Building initrd with embedded squashfs..."
nix build .#nixosConfigurations.argo-netboot.config.system.build.netbootRamdisk -o "$OUTPUT_DIR/result"

echo "Building iPXE scripts (classic + EFI variant)..."
# Classic script from nixos netboot module (for reference)
nix build .#nixosConfigurations.argo-netboot.config.system.build.netbootIpxeScript -o "$OUTPUT_DIR/netboot-script-classic"
# EFI-friendly script we generate (imgargs + boot vmlinuz)
nix build .#nixosConfigurations.argo-netboot.config.system.build.netbootIpxeScriptEfi -o "$OUTPUT_DIR/netboot-script-efi"

# Copy files from symlinks to actual files
echo "Copying files in $OUTPUT_DIR..."
cp "$OUTPUT_DIR/kernel/bzImage" "$OUTPUT_DIR/"
cp "$OUTPUT_DIR/result/initrd" "$OUTPUT_DIR/"

# Handle iPXE outputs which may be files or directories
if [ -d "$OUTPUT_DIR/netboot-script-efi" ]; then
  cp "$OUTPUT_DIR/netboot-script-efi/netboot-efi.ipxe" "$OUTPUT_DIR/netboot-efi.ipxe"
else
  cp "$OUTPUT_DIR/netboot-script-efi" "$OUTPUT_DIR/netboot-efi.ipxe"
fi

if [ -d "$OUTPUT_DIR/netboot-script-classic" ]; then
  cp "$OUTPUT_DIR/netboot-script-classic/netboot.ipxe" "$OUTPUT_DIR/netboot-classic.ipxe"
else
  cp "$OUTPUT_DIR/netboot-script-classic" "$OUTPUT_DIR/netboot-classic.ipxe"
fi

# Fix permissions to allow overwriting on future runs
chmod 644 "$OUTPUT_DIR/bzImage"
chmod 644 "$OUTPUT_DIR/initrd"
chmod 644 "$OUTPUT_DIR/netboot-efi.ipxe"
chmod 644 "$OUTPUT_DIR/netboot-classic.ipxe"

# Clean up build symlinks
rm -f "$OUTPUT_DIR/kernel" "$OUTPUT_DIR/result" "$OUTPUT_DIR/netboot-script-classic" "$OUTPUT_DIR/netboot-script-efi"

# Copy to TrueNAS mount point if available
TRUENAS_TARGET="${TRUENAS_TARGET:-/run/user/1000/kio-fuse-AyJqdB/smb/john@truenas/zila-family/netboot/assets/custom/aliza-nixos/}"
if [ -d "$(dirname "$TRUENAS_TARGET")" ]; then
    echo ""
    echo "Copying files to TrueNAS..."
    mkdir -p "$TRUENAS_TARGET"
    cp "$OUTPUT_DIR/bzImage" "$TRUENAS_TARGET/"
    cp "$OUTPUT_DIR/initrd" "$TRUENAS_TARGET/"
    # Prefer the EFI-friendly iPXE script as the default
    cp "$OUTPUT_DIR/netboot-efi.ipxe" "$TRUENAS_TARGET/netboot.ipxe"
    cp "$OUTPUT_DIR/netboot-classic.ipxe" "$TRUENAS_TARGET/"
    echo "Files copied to TrueNAS: $TRUENAS_TARGET"
else
    echo ""
    echo "TrueNAS mount not available at: $TRUENAS_TARGET"
    echo "Manual copy required."
fi

# Show file sizes
echo ""
echo "Netboot files created:"
ls -lah "$OUTPUT_DIR"

echo ""
echo "Total size:"
du -sh "$OUTPUT_DIR"

echo ""
echo "Files ready for deployment!"
