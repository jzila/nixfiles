#!/usr/bin/env bash
# Script for complete remote NixOS installation workflow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default values
REMOTE_HOST=""
SSH_USER="root"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
TARGET_HOST="argo"
SKIP_PARTITIONING="false"

usage() {
    echo "Usage: $0 <remote_host> [options]"
    echo ""
    echo "Arguments:"
    echo "  remote_host         IP address or hostname of the netbooted Framework Desktop"
    echo ""
    echo "Options:"
    echo "  -u, --user USER     SSH username (default: root)"
    echo "  -t, --target HOST   Target host configuration (default: argo)"
    echo "  -s, --skip-partition Skip automatic partitioning"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.100"
    echo "  $0 framework.local --user installer"
    echo "  $0 192.168.1.100 --skip-partition"
    echo ""
    echo "This script will:"
    echo "  1. Test SSH connectivity"
    echo "  2. Optionally partition the disk automatically"
    echo "  3. Copy the nixfiles repository to the remote system"
    echo "  4. Run nixos-install with the specified configuration"
    echo "  5. Set up user password"
    echo "  6. Provide post-installation instructions"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user)
            SSH_USER="$2"
            shift 2
            ;;
        -t|--target)
            TARGET_HOST="$2"
            shift 2
            ;;
        -s|--skip-partition)
            SKIP_PARTITIONING="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "❌ Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [[ -z "$REMOTE_HOST" ]]; then
                REMOTE_HOST="$1"
            else
                echo "❌ Too many arguments"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$REMOTE_HOST" ]]; then
    usage
    exit 1
fi

echo "🚀 Starting NixOS installation on Framework Desktop"
echo "🎯 Target host: $TARGET_HOST"
echo "🖥️  Remote system: $SSH_USER@$REMOTE_HOST"
echo "💽 Skip partitioning: $SKIP_PARTITIONING"
echo ""

# Test SSH connectivity
echo "🔌 Testing SSH connectivity..."
if ! ssh $SSH_OPTIONS "$SSH_USER@$REMOTE_HOST" "echo 'SSH connection successful'" 2>/dev/null; then
    echo "❌ Failed to connect to $SSH_USER@$REMOTE_HOST"
    echo ""
    echo "Make sure:"
    echo "  - The Framework Desktop has booted from network"
    echo "  - SSH is enabled and running"
    echo "  - Your SSH key is authorized"
    echo "  - The IP address is correct"
    exit 1
fi
echo "✅ SSH connection successful"
echo ""

# Check available disks
echo "💽 Checking available disks..."
AVAILABLE_DISKS=$(ssh $SSH_OPTIONS "$SSH_USER@$REMOTE_HOST" "lsblk -d -n -o NAME,SIZE,TYPE | grep disk" || true)

if [[ -z "$AVAILABLE_DISKS" ]]; then
    echo "❌ No disks found on remote system"
    exit 1
fi

echo "Available disks:"
echo "$AVAILABLE_DISKS"
echo ""

# Automatic partitioning (if not skipped)
if [[ "$SKIP_PARTITIONING" != "true" ]]; then
    # Get the first disk
    FIRST_DISK=$(echo "$AVAILABLE_DISKS" | head -1 | awk '{print $1}')
    
    echo "❓ Automatically partition /dev/$FIRST_DISK? This will DESTROY ALL DATA! [y/N]"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "⚠️  DESTROYING ALL DATA on /dev/$FIRST_DISK in 5 seconds..."
        echo "Press Ctrl+C to abort!"
        sleep 5
        
        echo "🗂️  Partitioning /dev/$FIRST_DISK..."
        ssh $SSH_OPTIONS "$SSH_USER@$REMOTE_HOST" bash << EOF
set -euo pipefail

# Unmount any existing partitions
umount /dev/${FIRST_DISK}* 2>/dev/null || true

# Create GPT partition table
parted /dev/$FIRST_DISK --script -- mklabel gpt

# Create EFI boot partition (512MB)
parted /dev/$FIRST_DISK --script -- mkpart ESP fat32 1MiB 512MiB
parted /dev/$FIRST_DISK --script -- set 1 esp on

# Create root partition (remaining space)
parted /dev/$FIRST_DISK --script -- mkpart primary ext4 512MiB 100%

# Wait for kernel to recognize partitions
sleep 2

# Format EFI partition
mkfs.fat -F 32 -n boot /dev/${FIRST_DISK}1

# Format root partition  
mkfs.ext4 -L nixos /dev/${FIRST_DISK}2

echo "✅ Partitioning complete"
EOF
        echo "✅ Disk partitioned successfully"
    else
        echo "⚠️  Skipping automatic partitioning"
        echo "Make sure you have:"
        echo "  - A mounted root filesystem at /mnt"
        echo "  - A mounted EFI partition at /mnt/boot"
    fi
else
    echo "⚠️  Skipping automatic partitioning (--skip-partition)"
    echo "Make sure you have manually prepared:"
    echo "  - A mounted root filesystem at /mnt"  
    echo "  - A mounted EFI partition at /mnt/boot"
fi

echo ""
echo "❓ Continue with NixOS installation? [y/N]"
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "❌ Installation aborted by user"
    exit 1
fi

# Mount filesystems (if partitioning was done)
if [[ "$SKIP_PARTITIONING" != "true" ]] && [[ -n "${FIRST_DISK:-}" ]]; then
    echo "🗂️  Mounting filesystems..."
    ssh $SSH_OPTIONS "$SSH_USER@$REMOTE_HOST" bash << EOF
set -euo pipefail

# Mount root filesystem
mount /dev/${FIRST_DISK}2 /mnt

# Create boot directory and mount EFI partition
mkdir -p /mnt/boot
mount /dev/${FIRST_DISK}1 /mnt/boot

echo "✅ Filesystems mounted"
df -h /mnt /mnt/boot
EOF
fi

# Copy nixfiles to remote system
echo "📦 Copying nixfiles repository to remote system..."
TEMP_NIXFILES="/tmp/nixfiles-$(date +%s)"

# Create a clean copy of the repository
git clone "$REPO_ROOT" "$TEMP_NIXFILES"
cd "$TEMP_NIXFILES"

# Copy to remote system
rsync -av --exclude='.git' --exclude='result*' -e "ssh $SSH_OPTIONS" \
    ./ "$SSH_USER@$REMOTE_HOST:/tmp/nixfiles/"

# Cleanup local temp copy
rm -rf "$TEMP_NIXFILES"
cd "$REPO_ROOT"

echo "✅ Repository copied to remote system"
echo ""

# Install NixOS
echo "🔧 Installing NixOS with configuration: $TARGET_HOST"
ssh $SSH_OPTIONS "$SSH_USER@$REMOTE_HOST" bash << EOF
set -euo pipefail

cd /tmp/nixfiles

echo "Building NixOS configuration..."
nix build .#nixosConfigurations.$TARGET_HOST.config.system.build.toplevel

echo "Installing NixOS..."
nixos-install --flake .#$TARGET_HOST --no-root-passwd

echo "✅ NixOS installation complete"
EOF

echo "✅ NixOS installation completed successfully!"
echo ""

# Set up user password
echo "🔐 Setting up user password for john..."
echo "❓ Set password for user 'john'? [Y/n]"
read -r set_password
if [[ ! "$set_password" =~ ^[Nn]$ ]]; then
    ssh $SSH_OPTIONS "$SSH_USER@$REMOTE_HOST" "nixos-enter --root /mnt -c 'passwd john'"
    echo "✅ Password set for user john"
fi

echo ""
echo "🎉 Installation complete! Framework Desktop is ready."
echo ""
echo "📋 Post-installation steps:"
echo "  1. Remove netboot media and reboot:"
echo "     ssh $SSH_USER@$REMOTE_HOST 'reboot'"
echo ""
echo "  2. After reboot, the system should boot into NixOS"
echo "     Login as: john"
echo ""  
echo "  3. To make changes, edit the nixfiles and rebuild:"
echo "     sudo nixos-rebuild switch --flake /path/to/nixfiles#$TARGET_HOST"
echo ""
echo "  4. Consider setting up remote access:"
echo "     - Configure SSH keys"
echo "     - Set up Tailscale (already configured)"
echo "     - Configure firewall rules as needed"
echo ""
echo "🚀 Your Framework Desktop is now running NixOS!"