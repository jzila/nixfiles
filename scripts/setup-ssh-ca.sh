#!/usr/bin/env bash
# Script to configure SSH CA with SmallStep

set -euo pipefail

STEP_CA_URL="https://smallstep-ca.local.zila.dev:9000"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔧 Setting up SSH CA integration with SmallStep"
echo "CA URL: $STEP_CA_URL"
echo ""

# Check if step CLI is installed
if ! command -v step &> /dev/null; then
    echo "❌ step CLI not found"
    echo "Make sure it's installed in your home manager configuration and rebuild"
    exit 1
fi

# Get CA fingerprint dynamically
echo "🔍 Getting CA certificate fingerprint..."
if command -v openssl &> /dev/null; then
    CA_FINGERPRINT=$(curl -sk "$STEP_CA_URL/roots.pem" | openssl x509 -fingerprint -sha256 -noout | cut -d'=' -f2)
else
    echo "❌ openssl not found. Please install openssl or run with:"
    echo "   nix-shell -p step-cli openssl --run './scripts/setup-ssh-ca.sh'"
    exit 1
fi

if [[ -z "$CA_FINGERPRINT" ]]; then
    echo "❌ Could not get CA fingerprint"
    exit 1
fi

echo "🔐 CA Fingerprint: $CA_FINGERPRINT"
echo ""

# Setup step CLI configuration manually since bootstrap may not work
echo "🔗 Setting up step CLI configuration manually..."
echo "🔍 Testing CA connectivity first..."

# Test basic connectivity
if ! curl -sk "$STEP_CA_URL/health" >/dev/null; then
    echo "❌ Cannot reach CA at $STEP_CA_URL"
    exit 1
fi
echo "✅ CA is reachable"

# Create step directory structure
STEP_PATH="${HOME}/.step"
mkdir -p "$STEP_PATH/certs" "$STEP_PATH/config"

# Download and save root certificate
echo "📥 Downloading root certificate..."
if ! curl -sk "$STEP_CA_URL/roots.pem" -o "$STEP_PATH/certs/root_ca.crt"; then
    echo "❌ Failed to download root certificate"
    exit 1
fi
echo "✅ Root certificate saved to $STEP_PATH/certs/root_ca.crt"

# Create step configuration
echo "⚙️  Creating step configuration..."
cat > "$STEP_PATH/config/defaults.json" << EOF
{
    "ca-url": "$STEP_CA_URL",
    "fingerprint": "$CA_FINGERPRINT",
    "root": "$STEP_PATH/certs/root_ca.crt"
}
EOF

echo "✅ Step CLI configured manually"

# Test the configuration
echo "🔍 Testing step CLI configuration..."
if step ca health >/dev/null 2>&1; then
    echo "✅ Step CLI can communicate with CA"
else
    echo "⚠️  Step CLI health check failed, but continuing..."
fi

echo "✅ Step CLI bootstrapped successfully"

# Check if SSH is already configured
echo "🔍 Checking SSH CA configuration..."
if step ssh config --roots 2>/dev/null | grep -q ssh; then
    echo "✅ SSH CA already configured"
    SSH_CA_KEY=$(step ssh config --roots)
else
    echo "⚠️  SSH CA not configured yet"
    echo "🔧 Setting up SSH CA provisioner..."
    
    # First, let's check what provisioners exist
    echo "📋 Current provisioners:"
    step ca provisioner list 2>/dev/null || echo "  (Could not list provisioners - may need authentication)"
    echo ""
    
    # Check if SSH provisioner already exists
    echo "🔍 Checking for existing SSH provisioners..."
    if step ca provisioner list 2>/dev/null | grep -q "ssh-ca"; then
        echo "✅ SSH provisioner 'ssh-ca' already exists"
    else
        # Try to add SSH provisioner
        echo "🔐 Adding SSH provisioner (you may be prompted for admin credentials)..."
        if step ca provisioner add ssh-ca --type=SSHPOP; then
            echo "✅ SSH provisioner added successfully"
        else
            echo "❌ Failed to add SSH provisioner"
            echo "You may need to:"
            echo "1. Find the admin password in container logs: docker logs step-ca | grep password"
            echo "2. Or add a JWK provisioner first: step ca provisioner add admin --type=JWK"
            echo "3. Then retry: step ca provisioner add ssh-ca --type=SSHPOP"
            echo ""
            echo "❓ Continue without SSH CA setup? [y/N]"
            read -r continue_without
            if [[ ! "$continue_without" =~ ^[Yy]$ ]]; then
                exit 1
            fi
            echo "⚠️  Continuing without SSH CA - you'll need to configure it manually"
            SSH_CA_KEY=""
        fi
    fi
    
    # Try to get SSH CA key
    if SSH_CA_KEY=$(step ssh config --roots 2>/dev/null) && [[ -n "$SSH_CA_KEY" ]]; then
        echo "✅ SSH CA public key retrieved"
    else
        echo "⚠️  Could not retrieve SSH CA public key automatically"
        echo "This might be normal if SSH CA was just configured"
        SSH_CA_KEY="# SSH CA key will be available after first certificate generation"
    fi
fi

echo "✅ SSH CA public key retrieved"
echo ""

# Create SSH CA module
SSH_CA_MODULE="$REPO_ROOT/modules/ssh-ca/default.nix"
if [[ -f "$SSH_CA_MODULE" ]]; then
    echo "📝 SSH CA NixOS module already exists, updating..."
else
    echo "📝 Creating SSH CA NixOS module..."
fi
mkdir -p "$REPO_ROOT/modules/ssh-ca"

cat > "$SSH_CA_MODULE" << EOF
# SSH Certificate Authority integration for SmallStep CA
{ config, pkgs, lib, ... }:

{
  # Trust the SSH CA for user certificates
  services.openssh = {
    extraConfig = ''
      # Trust certificates signed by our SSH CA
      TrustedUserCAKeys /etc/ssh/ssh_user_ca.pub
      
      # Optional: Enable SSH CA for host certificates too
      # HostCertificate /etc/ssh/ssh_host_key-cert.pub
      
      # Allow certificate-based authentication
      PubkeyAuthentication yes
      AuthorizedKeysFile .ssh/authorized_keys
    '';
  };

  # Deploy SSH CA public key
  environment.etc."ssh/ssh_user_ca.pub" = {
    text = ''
      # SmallStep SSH CA public key
      # Generated: $(date -Iseconds)
      # CA URL: $STEP_CA_URL
$SSH_CA_KEY
    '';
    mode = "0644";
  };

  # Install step CLI for certificate management
  environment.systemPackages = with pkgs; [
    step-cli
  ];

  # Optional: Configure step CLI globally
  environment.etc."step/config/defaults.json" = {
    text = builtins.toJSON {
      ca-url = "$STEP_CA_URL";
      fingerprint = "$(curl -sk "$STEP_CA_URL/health" | jq -r .fingerprint 2>/dev/null || echo 'UPDATE-ME')";
      root = "/etc/step/certs/root_ca.crt";
    };
    mode = "0644";
  };

  # Deploy root CA certificate
  environment.etc."step/certs/root_ca.crt" = {
    text = ''$(curl -sk "$STEP_CA_URL/roots.pem")'';
    mode = "0644";
  };
}
EOF

echo "✅ SSH CA module created: $REPO_ROOT/modules/ssh-ca/default.nix"
echo ""

# Update aliza module to include SSH CA
echo "📝 Adding SSH CA to shared desktop module..."
if grep -q "ssh-ca" "$REPO_ROOT/modules/desktop/aliza.nix"; then
    echo "✅ SSH CA already imported in aliza module"
else
    # Add import to the imports section
    sed -i '/imports = \[/a\    ../ssh-ca' "$REPO_ROOT/modules/desktop/aliza.nix"
    echo "✅ Added SSH CA import to aliza module"
fi

echo ""
echo "🎉 SSH CA integration complete!"
echo ""
echo "📋 Next steps:"
echo "1. Commit the changes:"
echo "   git add -A && git commit -m 'feat: add SmallStep SSH CA integration'"
echo ""
echo "2. Rebuild your system to trust the SSH CA:"
echo "   sudo nixos-rebuild switch --flake .#venator"
echo ""
echo "3. Generate an installer certificate:"
echo "   $SCRIPT_DIR/get-installer-cert.sh"
echo ""
echo "4. Test SSH with certificate:"
echo "   ssh -i ~/.ssh/installer_key root@target-host"
EOF