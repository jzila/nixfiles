#!/usr/bin/env bash
# Wrapper around darwin-rebuild switch that detects manual macOS settings
# changes and aborts if the rebuild would override them.
#
# Evaluates the flake to find exactly which system.defaults keys nix-darwin
# will write, then compares those against live values. If any differ, it means
# you changed something in System Settings that the rebuild would revert.
#
# Usage:
#   ./scripts/darwin-switch.sh              # check + rebuild
#   ./scripts/darwin-switch.sh --diff       # show what would be overridden

set -euo pipefail

FLAKE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST="macbook"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

# Map nix-darwin system.defaults domain names to macOS defaults domains
declare -A DOMAIN_MAP=(
  [dock]="com.apple.dock"
  [finder]="com.apple.finder"
  [NSGlobalDomain]="NSGlobalDomain"
  [screencapture]="com.apple.screencapture"
  [screensaver]="com.apple.screensaver"
  [trackpad]="com.apple.AppleMultitouchTrackpad"
  [magicmouse]="com.apple.driver.AppleBluetoothMultitouch.mouse"
  [loginwindow]="com.apple.loginwindow"
  [spaces]="com.apple.spaces"
  [WindowManager]="com.apple.WindowManager"
  [menuExtraClock]="com.apple.menuextra.clock"
  [controlcenter]="com.apple.controlcenter"
  [universalaccess]="com.apple.universalaccess"
  [hitoolbox]="com.apple.HIToolbox"
  [".GlobalPreferences"]="Apple Global Domain"
  [SoftwareUpdate]="com.apple.SoftwareUpdate"
  [smb]="com.apple.desktopservices"
  [iCal]="com.apple.iCal"
  [ActivityMonitor]="com.apple.ActivityMonitor"
  [LaunchServices]="com.apple.LaunchServices"
)

# Domains to check (only the ones likely to have user-facing settings)
DOMAINS=(dock finder NSGlobalDomain screencapture trackpad loginwindow spaces WindowManager menuExtraClock controlcenter universalaccess)

normalize_nix_value() {
  local val="$1"
  case "$val" in
    true)  echo "1" ;;
    false) echo "0" ;;
    *)     echo "$val" ;;
  esac
}

compute_diff() {
  local has_changes=false
  local diff_lines=()

  echo -e "Evaluating nix config..." >&2

  for nix_domain in "${DOMAINS[@]}"; do
    local mac_domain="${DOMAIN_MAP[$nix_domain]:-}"
    if [[ -z "$mac_domain" ]]; then
      continue
    fi

    # Get non-null keys from nix eval
    local nix_keys
    nix_keys=$(nix eval ".#darwinConfigurations.${HOST}.config.system.defaults.${nix_domain}" --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k, v in sorted(d.items()):
    if v is not None:
        print(f'{k}\t{json.dumps(v)}')
" 2>/dev/null) || continue

    while IFS=$'\t' read -r key nix_json_value; do
      [[ -z "$key" ]] && continue

      # Parse the JSON value to a plain string for comparison
      # json.dumps gives us true/false (lowercase), then normalize to 1/0
      local nix_value
      nix_value=$(python3 -c "
import json
v = json.loads('$nix_json_value')
if isinstance(v, bool):
    print(1 if v else 0)
elif isinstance(v, (int, float)):
    print(v)
else:
    print(v)
" 2>/dev/null) || nix_value="$nix_json_value"

      local live_value
      live_value=$(defaults read "$mac_domain" "$key" 2>/dev/null) || live_value="<unset>"

      if [[ "$live_value" != "$nix_value" ]]; then
        has_changes=true
        diff_lines+=("  ${BOLD}${nix_domain}.${key}${RESET}: ${YELLOW}${live_value}${RESET} (live) → ${GREEN}${nix_value}${RESET} (nix)")
      fi
    done <<< "$nix_keys"
  done

  if $has_changes; then
    echo -e "${YELLOW}These settings have been manually changed and will be reverted by rebuild:${RESET}"
    echo ""
    for line in "${diff_lines[@]}"; do
      echo -e "$line"
    done
    return 1
  else
    echo -e "${GREEN}All nix-managed defaults match live system. No settings will be overridden.${RESET}"
    return 0
  fi
}

# Parse args
ACTION="switch"
EXTRA_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --diff) ACTION="diff" ;;
    *)      EXTRA_ARGS+=("$arg") ;;
  esac
done

case "$ACTION" in
  diff)
    compute_diff || true
    ;;
  switch)
    if compute_diff; then
      exec sudo darwin-rebuild switch --flake "$FLAKE_DIR#${HOST}" "${EXTRA_ARGS[@]}"
    else
      echo ""
      echo -e "Update your nix config in ${BOLD}modules/darwin/base.nix${RESET} to match, then re-run."
      echo -e "Or run ${BOLD}sudo darwin-rebuild switch --flake .#${HOST}${RESET} directly to override."
      exit 1
    fi
    ;;
esac
