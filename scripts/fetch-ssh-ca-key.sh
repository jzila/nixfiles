#!/usr/bin/env bash
# Fetch SSH CA public key from SmallStep CA
set -euo pipefail

SSH_CA_FILE="/etc/ssh/ssh_user_ca.pub"
STEP_CA_URL="https://smallstep-ca.local.zila.dev:9000"

# Check if SSH CA key already exists and is recent (less than 24 hours old)
if [[ -f "$SSH_CA_FILE" ]] && [[ $(find "$SSH_CA_FILE" -mtime -1 -print 2>/dev/null) ]]; then
    echo "SSH CA key is recent, skipping fetch"
    exit 0
fi

echo "Fetching SSH CA public key from SmallStep CA..."

# Create temporary step config
TEMP_STEPPATH=$(mktemp -d)
mkdir -p "$TEMP_STEPPATH/certs" "$TEMP_STEPPATH/config"

cleanup() {
    rm -rf "$TEMP_STEPPATH"
}
trap cleanup EXIT

# Download root CA certificate
if ! curl -sk "$STEP_CA_URL/roots.pem" -o "$TEMP_STEPPATH/certs/root_ca.crt"; then
    echo "Failed to download root CA certificate"
    exit 1
fi

# Create step configuration
cat > "$TEMP_STEPPATH/config/defaults.json" << EOF
{
    "ca-url": "$STEP_CA_URL",
    "root": "$TEMP_STEPPATH/certs/root_ca.crt"
}
EOF

# Fetch SSH CA public key
TEMP_SSH_CA=$(mktemp)
{
    echo "# SmallStep SSH CA public key"
    echo "# Fetched at boot time: $(date -Iseconds)"
    echo "# CA URL: $STEP_CA_URL"
    STEPPATH="$TEMP_STEPPATH" step ssh config --roots
} > "$TEMP_SSH_CA"

if [[ -s "$TEMP_SSH_CA" ]] && grep -q "ssh-" "$TEMP_SSH_CA"; then
    # Atomically replace the SSH CA file
    mv "$TEMP_SSH_CA" "$SSH_CA_FILE"
    chmod 644 "$SSH_CA_FILE"
    echo "SSH CA public key updated successfully"
else
    echo "Failed to fetch valid SSH CA public key"
    rm -f "$TEMP_SSH_CA"
    exit 1
fi