#!/usr/bin/env bash
# Script to remotely scan hardware and update argo configuration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOST_CONFIG_DIR="$REPO_ROOT/hosts/argo"
HARDWARE_CONFIG_FILE="$HOST_CONFIG_DIR/hardware-configuration.nix"

# Default values
REMOTE_HOST=""
SSH_USER="root"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

usage() {
    echo "Usage: $0 <remote_host> [ssh_user]"
    echo ""
    echo "Arguments:"
    echo "  remote_host    IP address or hostname of the netbooted Framework Desktop"
    echo "  ssh_user       SSH username (default: root)"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.100"
    echo "  $0 framework.local installer"
    echo ""
    echo "This script will:"
    echo "  1. SSH into the netbooted system"
    echo "  2. Run nixos-generate-config --show-hardware-config"
    echo "  3. Update $HARDWARE_CONFIG_FILE"
    echo "  4. Commit the changes to git"
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

REMOTE_HOST="$1"
if [[ $# -ge 2 ]]; then
    SSH_USER="$2"
fi

echo "🔍 Scanning hardware on remote host: $REMOTE_HOST"
echo "👤 SSH user: $SSH_USER"
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

# Generate hardware configuration
echo "🛠️  Running hardware scan on remote system..."
TEMP_HARDWARE_CONFIG=$(mktemp)

if ! ssh $SSH_OPTIONS "$SSH_USER@$REMOTE_HOST" "nixos-generate-config --show-hardware-config" > "$TEMP_HARDWARE_CONFIG" 2>/dev/null; then
    echo "❌ Failed to generate hardware configuration"
    rm -f "$TEMP_HARDWARE_CONFIG"
    exit 1
fi

# Validate the generated config
if [[ ! -s "$TEMP_HARDWARE_CONFIG" ]]; then
    echo "❌ Generated hardware configuration is empty"
    rm -f "$TEMP_HARDWARE_CONFIG"
    exit 1
fi

# Check if it looks like a valid NixOS hardware config
if ! grep -q "boot.initrd.availableKernelModules" "$TEMP_HARDWARE_CONFIG"; then
    echo "❌ Generated file doesn't look like a valid hardware configuration"
    echo "Content preview:"
    head -10 "$TEMP_HARDWARE_CONFIG"
    rm -f "$TEMP_HARDWARE_CONFIG"
    exit 1
fi

echo "✅ Hardware configuration generated successfully"
echo ""

# Show a preview of the generated config
echo "📋 Hardware configuration preview:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
head -20 "$TEMP_HARDWARE_CONFIG"
echo "..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Ask for confirmation
echo "❓ Replace $HARDWARE_CONFIG_FILE with this configuration? [y/N]"
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "❌ Aborted by user"
    rm -f "$TEMP_HARDWARE_CONFIG"
    exit 1
fi

# Backup existing hardware config
if [[ -f "$HARDWARE_CONFIG_FILE" ]]; then
    BACKUP_FILE="${HARDWARE_CONFIG_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$HARDWARE_CONFIG_FILE" "$BACKUP_FILE"
    echo "💾 Backed up existing config to: $BACKUP_FILE"
fi

# Replace the hardware configuration
cp "$TEMP_HARDWARE_CONFIG" "$HARDWARE_CONFIG_FILE"
rm -f "$TEMP_HARDWARE_CONFIG"

echo "✅ Updated $HARDWARE_CONFIG_FILE"
echo ""

# Change to repo root for git operations
cd "$REPO_ROOT"

# Check if there are changes to commit
if git diff --quiet "$HARDWARE_CONFIG_FILE"; then
    echo "ℹ️  No changes to hardware configuration"
    exit 0
fi

echo "📊 Changes made to hardware configuration:"
git diff "$HARDWARE_CONFIG_FILE"
echo ""

# Commit the changes
echo "💾 Committing hardware configuration changes..."
git add "$HARDWARE_CONFIG_FILE"
git commit -m "$(cat <<EOF
feat: update argo hardware configuration from remote scan

Hardware scanned from: $SSH_USER@$REMOTE_HOST
Timestamp: $(date -Iseconds)

🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"

echo "✅ Hardware configuration updated and committed!"
echo ""
echo "🚀 Next steps:"
echo "  1. Review the changes: git show HEAD"
echo "  2. Test the build: nix build .#nixosConfigurations.argo.config.system.build.toplevel"
echo "  3. Install NixOS: ./scripts/install-remote-nixos.sh $REMOTE_HOST"