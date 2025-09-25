#!/usr/bin/env bash
# Generate SSH certificate for netboot installer access

set -euo pipefail

STEP_CA_URL="https://smallstep-ca.local.zila.dev:9000"
CERT_DURATION="${CERT_DURATION:-1h}"
CERT_PRINCIPALS="root,installer"
SSH_KEY_PATH="$HOME/.ssh/installer_key"

echo "🔐 Generating SSH certificate for installer access"
echo "CA URL: $STEP_CA_URL"
echo "Duration: $CERT_DURATION"
echo "Principals: $CERT_PRINCIPALS"
echo ""

# Check if step CLI is available
if ! command -v step &> /dev/null; then
    echo "❌ step CLI not found"
    echo "Make sure it's installed in your home manager configuration and rebuild"
    exit 1
fi

# Check if step is configured
if [[ ! -f "$HOME/.step/config/defaults.json" ]]; then
    echo "⚠️  Step CLI not configured. Bootstrapping..."
    step ca bootstrap --ca-url "$STEP_CA_URL"
fi

# Generate SSH key pair if it doesn't exist
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "🔑 Generating SSH key pair for installer..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "installer@$(hostname)"
    echo "✅ SSH key pair generated: $SSH_KEY_PATH"
fi

# Generate SSH certificate
echo "📋 Requesting SSH certificate..."
if step ssh certificate \
    --provisioner "ssh-ca" \
    --sign \
    --principal "$CERT_PRINCIPALS" \
    --not-after "$CERT_DURATION" \
    installer \
    "$SSH_KEY_PATH.pub"; then
    
    echo "✅ SSH certificate generated successfully!"
    echo ""
    echo "📁 Files created:"
    echo "  Private key: $SSH_KEY_PATH"
    echo "  Public key:  $SSH_KEY_PATH.pub" 
    echo "  Certificate: $SSH_KEY_PATH-cert.pub"
    echo ""
    
    # Show certificate details
    echo "📋 Certificate details:"
    ssh-keygen -L -f "$SSH_KEY_PATH-cert.pub"
    echo ""
    
    echo "🚀 Usage:"
    echo "  ssh -i $SSH_KEY_PATH root@framework-ip"
    echo "  ssh -i $SSH_KEY_PATH installer@framework-ip"
    echo ""
    echo "⏰ Certificate expires in: $CERT_DURATION"
    
else
    echo "❌ Failed to generate SSH certificate"
    echo ""
    echo "Possible issues:"
    echo "1. SSH CA not configured in SmallStep"
    echo "2. Admin provisioner not available"
    echo "3. Network connectivity issues"
    echo ""
    echo "To configure SSH CA:"
    echo "  step ca provisioner add admin --type=OIDC"
    echo "  step ssh config --roots"
    exit 1
fi