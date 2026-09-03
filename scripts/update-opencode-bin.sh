#!/usr/bin/env bash
# Point pkgs/opencode-bin at a different opencode release.
#
# Reads the latest release from the GitHub API, prefetches the release archive
# for each supported platform, and rewrites pkgs/opencode-bin/sources.json.
#
# Usage:
#   ./scripts/update-opencode-bin.sh              # latest release
#   ./scripts/update-opencode-bin.sh 1.18.27      # a specific version
#   ./scripts/update-opencode-bin.sh --force      # re-prefetch current version

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCES="$REPO_DIR/pkgs/opencode-bin/sources.json"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

# nix attribute name -> asset name in the release. The x64 builds come in a
# baseline flavour too, for CPUs without AVX2; none of these hosts need it.
ARCHES=(
  "aarch64-darwin:opencode-darwin-arm64.zip"
  "x86_64-darwin:opencode-darwin-x64.zip"
  "aarch64-linux:opencode-linux-arm64.tar.gz"
  "x86_64-linux:opencode-linux-x64.tar.gz"
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
  echo "Looking up the latest opencode release..."
  tag="$(curl -fsSL https://api.github.com/repos/anomalyco/opencode/releases/latest | jq -r .tag_name)"
  version="${tag#v}"
fi

if [[ -z "$version" || "$version" == "null" ]]; then
  echo "Could not determine an opencode version" >&2
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
  url="https://github.com/anomalyco/opencode/releases/download/v${version}/${asset}"

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
echo "  nix build .#opencode-bin && ./result/bin/opencode --version"
