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

echo "Building initrd..."
nix build .#nixosConfigurations.argo-netboot.config.system.build.netbootRamdisk -o "$OUTPUT_DIR/result"

echo "Building squashfs store..."
nix build .#nixosConfigurations.argo-netboot.config.system.build.squashfsStore -o "$OUTPUT_DIR/squashfs"

echo "Building iPXE script..."
nix build .#nixosConfigurations.argo-netboot.config.system.build.netbootIpxeScript -o "$OUTPUT_DIR/netboot-script"

# Copy files from symlinks to actual files
echo "Copying files in $OUTPUT_DIR..."
cp "$OUTPUT_DIR/kernel/bzImage" "$OUTPUT_DIR/"
cp "$OUTPUT_DIR/result/initrd" "$OUTPUT_DIR/"
cp "$OUTPUT_DIR/squashfs" "$OUTPUT_DIR/nix-store.squashfs"
cp "$OUTPUT_DIR/netboot-script/netboot.ipxe" "$OUTPUT_DIR/"

# Clean up build symlinks
rm -f "$OUTPUT_DIR/kernel" "$OUTPUT_DIR/result" "$OUTPUT_DIR/squashfs" "$OUTPUT_DIR/netboot-script"

# Copy to TrueNAS mount point if available
TRUENAS_TARGET="${TRUENAS_TARGET:-/run/user/1000/kio-fuse-AyJqdB/smb/john@truenas/zila-family/netboot/assets/custom/aliza-nixos/}"
if [ -d "$(dirname "$TRUENAS_TARGET")" ]; then
    echo ""
    echo "Copying files to TrueNAS..."
    mkdir -p "$TRUENAS_TARGET"
    cp "$OUTPUT_DIR/bzImage" "$TRUENAS_TARGET/"
    cp "$OUTPUT_DIR/initrd" "$TRUENAS_TARGET/"
    cp "$OUTPUT_DIR/netboot.ipxe" "$TRUENAS_TARGET/"
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