#!/usr/bin/env bash
# Point pkgs/zed-editor-bin at a different Zed release.
#
# Reads the latest stable release from the GitHub API (prereleases are Zed's
# preview channel, so /releases/latest is the stable one), prefetches the macOS
# .dmg for each supported arch, and rewrites pkgs/zed-editor-bin/sources.json.
#
# Usage:
#   ./scripts/update-zed-editor-bin.sh              # latest stable release
#   ./scripts/update-zed-editor-bin.sh 1.16.1       # a specific version
#   ./scripts/update-zed-editor-bin.sh --force      # re-prefetch current version

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$REPO_DIR/pkgs/zed-editor-bin/sources.json"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

# nix attribute name -> asset name in the release
ARCHES=(
  "aarch64-darwin:Zed-aarch64.dmg"
  "x86_64-darwin:Zed-x86_64.dmg"
)

force=0
version=""
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 1 ;;
    *) version="${arg#v}" ;;
  esac
done

if [[ -z "$version" ]]; then
  echo "Looking up the latest stable Zed release..."
  tag="$(curl -fsSL https://api.github.com/repos/zed-industries/zed/releases/latest | jq -r .tag_name)"
  version="${tag#v}"
fi

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "Could not determine a Zed version" >&2
  exit 1
fi

current="$(jq -r .version "$SOURCES" 2>/dev/null || echo "")"
if [[ "$version" == "$current" && $force -eq 0 ]]; then
  echo -e "${GREEN}Already at ${BOLD}$version${RESET}${GREEN}, nothing to do.${RESET}"
  exit 0
fi

echo -e "Updating ${BOLD}$current${RESET} -> ${BOLD}$version${RESET}"

systems_json="{}"
for entry in "${ARCHES[@]}"; do
  system="${entry%%:*}"
  asset="${entry#*:}"
  url="https://github.com/zed-industries/zed/releases/download/v${version}/${asset}"

  echo -e "  ${YELLOW}prefetching${RESET} $asset"
  hash="$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -r .hash)"

  systems_json="$(jq -n \
    --argjson acc "$systems_json" \
    --arg system "$system" \
    --arg url "$url" \
    --arg hash "$hash" \
    '$acc + {($system): {url: $url, hash: $hash}}')"
done

tmp="$(mktemp)"
jq -n --arg version "$version" --argjson systems "$systems_json" \
  '{version: $version, systems: $systems}' > "$tmp"
mv "$tmp" "$SOURCES"

echo -e "${GREEN}Wrote${RESET} ${SOURCES#"$REPO_DIR"/}"
echo
echo "Verify with:"
echo "  nix build .#zed-editor-bin && ./result/bin/zeditor --version"
