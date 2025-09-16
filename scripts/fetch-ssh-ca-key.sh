#!/usr/bin/env bash
# Fetch SSH CA public key from SmallStep CA
set -euo pipefail

SSH_CA_FILE="/etc/ssh/ssh_user_ca.pub"
# STEP_CA_URL may be provided via environment; default to lab URL
: "${STEP_CA_URL:=https://smallstep-ca.local.zila.dev:9000}"

# Check if SSH CA key already exists and is recent (less than 24 hours old)
if [[ -f "$SSH_CA_FILE" ]] && [[ $(find "$SSH_CA_FILE" -mtime -1 -print 2>/dev/null) ]]; then
    echo "SSH CA key is recent, skipping fetch"
    exit 0
fi

echo "Fetching SSH CA public key from SmallStep CA at: $STEP_CA_URL"

# Create temporary step config
TEMP_STEPPATH=$(mktemp -d)
mkdir -p "$TEMP_STEPPATH/certs" "$TEMP_STEPPATH/config"

cleanup() {
    rm -rf "$TEMP_STEPPATH"
}
trap cleanup EXIT

# Download root CA certificate with simple retry to tolerate slow network bringup
attempts=10
delay=2
for i in $(seq 1 $attempts); do
  if curl -sk --connect-timeout 3 --max-time 6 "$STEP_CA_URL/roots.pem" -o "$TEMP_STEPPATH/certs/root_ca.crt"; then
    break
  fi
  echo "Attempt $i/$attempts: waiting for CA at $STEP_CA_URL ..."
  sleep $delay
done
if [ ! -s "$TEMP_STEPPATH/certs/root_ca.crt" ]; then
  echo "Failed to download root CA certificate from $STEP_CA_URL"
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
    STEPPATH="$TEMP_STEPPATH" step ssh config --roots 2>&1
} > "$TEMP_SSH_CA" || true

# Extract valid SSH public key lines from the output (supports ed25519, ecdsa, sk-ssh, rsa)
TEMP_KEYS=$(mktemp)
grep -E '^(ssh-|ecdsa-|sk-ssh-|ssh-rsa)' "$TEMP_SSH_CA" > "$TEMP_KEYS" || true

if [[ -s "$TEMP_KEYS" ]]; then
    # Assemble final TrustedUserCAKeys file with comment + keys only
    {
      echo "# SmallStep SSH CA public key"
      echo "# Fetched at boot time: $(date -Iseconds)"
      echo "# CA URL: $STEP_CA_URL"
      cat "$TEMP_KEYS"
    } > "$SSH_CA_FILE"
    chmod 644 "$SSH_CA_FILE"
    echo "SSH CA public key updated successfully"
    rm -f "$TEMP_SSH_CA" "$TEMP_KEYS"
else
    echo "Failed to fetch valid SSH CA public key; output was:"
    echo "-----"
    sed -n '1,120p' "$TEMP_SSH_CA" || true
    echo "-----"
    rm -f "$TEMP_SSH_CA" "$TEMP_KEYS"
    exit 1
fi
