#!/usr/bin/env bash
# Script to build and serve NixOS netboot image for argo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NETBOOT_DIR="/tmp/nixfiles-netboot"
HTTP_PORT="${NETBOOT_PORT:-8080}"

echo "🚀 Building and serving NixOS netboot image for argo..."

# Change to repo root
cd "$REPO_ROOT"

# Build the netboot image
echo "📦 Building netboot image..."
nix build .#nixosConfigurations.argo-netboot.config.system.build.netbootRamdisk

if [[ ! -d "result" ]]; then
    echo "❌ Build failed - no result directory found"
    exit 1
fi

# Prepare netboot directory
echo "📁 Preparing netboot files..."
rm -rf "$NETBOOT_DIR"
mkdir -p "$NETBOOT_DIR"

# Copy kernel and initrd
cp result/bzImage "$NETBOOT_DIR/"
cp result/initrd "$NETBOOT_DIR/"

# Create boot configuration files for different boot methods
echo "📝 Creating boot configuration files..."

# Create iPXE boot script
cat > "$NETBOOT_DIR/boot.ipxe" << EOF
#!ipxe
echo Loading NixOS installer for Framework Desktop (argo)...
kernel bzImage init=/nix/store/*/init console=tty0
initrd initrd
boot
EOF

# Create GRUB network boot config
cat > "$NETBOOT_DIR/grub.cfg" << EOF
menuentry "NixOS Installer - Framework Desktop (argo)" {
    linux bzImage init=/nix/store/*/init console=tty0
    initrd initrd
}
EOF

# Get local IP address
LOCAL_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')

# Create simple index.html with boot instructions
cat > "$NETBOOT_DIR/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>NixOS Netboot Server</title>
    <style>
        body { font-family: monospace; margin: 40px; background: #1e1e1e; color: #d4d4d4; }
        .container { max-width: 800px; }
        .file { background: #2d2d30; padding: 10px; margin: 10px 0; border-radius: 4px; }
        .command { background: #264f78; padding: 10px; margin: 10px 0; border-radius: 4px; }
        a { color: #4fc3f7; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 NixOS Netboot Server for Framework Desktop (argo)</h1>
        
        <h2>Available Files:</h2>
        <div class="file">
            <a href="bzImage">bzImage</a> - Linux kernel
        </div>
        <div class="file">
            <a href="initrd">initrd</a> - Initial ramdisk with NixOS installer
        </div>
        <div class="file">
            <a href="boot.ipxe">boot.ipxe</a> - iPXE boot script
        </div>
        <div class="file">
            <a href="grub.cfg">grub.cfg</a> - GRUB network boot config
        </div>
        
        <h2>Boot Instructions:</h2>
        <h3>UEFI HTTP Boot (Recommended for Framework):</h3>
        <div class="command">
            1. Enter BIOS (F2 during boot)<br>
            2. Enable Network Boot<br>
            3. Set HTTP Boot URL: <strong>http://$LOCAL_IP:$HTTP_PORT/boot.ipxe</strong><br>
            4. Save and reboot
        </div>
        
        <h3>Manual PXE Configuration:</h3>
        <div class="command">
            Kernel: http://$LOCAL_IP:$HTTP_PORT/bzImage<br>
            Initrd: http://$LOCAL_IP:$HTTP_PORT/initrd<br>
            Kernel args: init=/nix/store/*/init console=tty0
        </div>
        
        <h2>After Boot:</h2>
        <div class="command">
            SSH to the installer:<br>
            ssh root@&lt;framework-ip&gt;<br>
            ssh installer@&lt;framework-ip&gt;
        </div>
    </div>
</body>
</html>
EOF

echo "✅ Netboot files ready in: $NETBOOT_DIR"
echo ""
echo "🌐 Starting HTTP server on port $HTTP_PORT..."
echo "📍 Server URL: http://$LOCAL_IP:$HTTP_PORT"
echo "🖥️  Management interface: http://$LOCAL_IP:$HTTP_PORT"
echo ""
echo "📋 Framework BIOS Setup:"
echo "   1. Press F2 during boot to enter BIOS"
echo "   2. Enable Network Boot"
echo "   3. Set HTTP Boot URL: http://$LOCAL_IP:$HTTP_PORT/boot.ipxe"
echo "   4. Save and reboot"
echo ""
echo "🛑 Press Ctrl+C to stop the server"
echo ""

# Start HTTP server
cd "$NETBOOT_DIR"
exec python3 -m http.server "$HTTP_PORT"