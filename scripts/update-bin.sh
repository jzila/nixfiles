#!/usr/bin/env bash
# Bump a pkgs/<pkg>/sources.json to a newer upstream release.
#
# Each package that this script knows how to update carries its own metadata
# in an "update" block inside pkgs/<pkg>/sources.json, right next to the
# version/systems data the Nix derivation reads. The Nix side ignores that
# block entirely. See any pkgs/*/sources.json for the shape, or the kata-bin
# one for a template-driven example:
#
#   "update": {
#     "repo": "kenn-io/kata",
#     "asset": "kata_${version}_homebrew_${arch}.tar.gz",
#     "arches": {"aarch64-darwin": "darwin_arm64", "x86_64-darwin": "darwin_amd64",
#                "aarch64-linux": "linux_arm64", "x86_64-linux": "linux_amd64"},
#     "verify": "kata version"
#   }
#
# "asset" is a template filled in with ${version} and ${arch}, resolved per
# system via "arches". Packages whose asset names don't embed a version (or
# only ship some systems) use a per-system literal map instead:
#
#   "update": {
#     "repo": "zed-industries/zed",
#     "assets": {"aarch64-darwin": "Zed-aarch64.dmg", "x86_64-darwin": "Zed-x86_64.dmg"},
#     "verify": "zeditor --version"
#   }
#
# Reads the requested (or latest) release from the GitHub API, prefetches one
# asset per system with `nix store prefetch-file`, and rewrites sources.json.
#
# Usage:
#   ./scripts/update-bin.sh <pkg> [version] [--force]   # one package
#   ./scripts/update-bin.sh --all [--force]              # every package with an "update" block
#
# Examples:
#   ./scripts/update-bin.sh kata-bin              # latest release
#   ./scripts/update-bin.sh kata-bin 0.17.3       # a specific version
#   ./scripts/update-bin.sh kata-bin --force      # re-prefetch the current version
#   ./scripts/update-bin.sh --all                 # bump everything that's behind

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

usage() {
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
}

all=0
force=0
pkg=""
version=""

for arg in "$@"; do
  case "$arg" in
    --all) all=1 ;;
    --force) force=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 1 ;;
    *)
      if [[ -z "$pkg" ]]; then
        pkg="$arg"
      else
        version="${arg#v}"
      fi
      ;;
  esac
done

if [[ $all -eq 1 && -n "$pkg" ]]; then
  echo "--all cannot be combined with a package name" >&2
  exit 1
fi

if [[ $all -eq 0 && -z "$pkg" ]]; then
  usage
  exit 1
fi

# Update one package. $3 (label) prefixes output with the package name, which
# --all needs to disambiguate and a single-package invocation doesn't.
update_one() {
  local pkg="$1" version="$2" label="$3"
  local sources="$REPO_DIR/pkgs/$pkg/sources.json"
  local prefix=""
  [[ "$label" -eq 1 ]] && prefix="$pkg: "

  if [[ ! -f "$sources" ]]; then
    echo "no such package: $pkg (missing pkgs/$pkg/sources.json)" >&2
    return 1
  fi

  local repo asset verify
  repo="$(jq -r '.update.repo // empty' "$sources")"
  if [[ -z "$repo" ]]; then
    echo "${prefix}pkgs/$pkg/sources.json has no update block, skipping" >&2
    return 1
  fi
  asset="$(jq -r '.update.asset // empty' "$sources")"
  verify="$(jq -r '.update.verify // empty' "$sources")"

  if [[ -z "$version" ]]; then
    echo "${prefix}Looking up the latest $pkg release..."
    local tag
    tag="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name)"
    version="${tag#v}"
  fi

  if [[ -z "$version" || "$version" == "null" ]]; then
    echo "${prefix}Could not determine a version for $pkg" >&2
    return 1
  fi

  local current
  current="$(jq -r '.version // empty' "$sources")"
  if [[ "$version" == "$current" && $force -eq 0 ]]; then
    echo -e "${prefix}${GREEN}Already at ${BOLD}$version${RESET}${GREEN}, nothing to do.${RESET}"
    return 0
  fi

  echo -e "${prefix}Updating ${BOLD}$current${RESET} -> ${BOLD}$version${RESET}"

  # Enumerate the systems this package targets: a per-system literal asset
  # map if given, else every system named in the template's arch map.
  local -a systems=()
  local using_assets=0
  if jq -e '.update.assets' "$sources" >/dev/null 2>&1; then
    using_assets=1
    mapfile -t systems < <(jq -r '.update.assets | keys_unsorted[]' "$sources")
  else
    mapfile -t systems < <(jq -r '.update.arches | keys_unsorted[]' "$sources")
  fi

  local systems_json="{}"
  local system name arch url hash
  for system in "${systems[@]}"; do
    if [[ "$using_assets" -eq 1 ]]; then
      name="$(jq -r --arg s "$system" '.update.assets[$s]' "$sources")"
    else
      arch="$(jq -r --arg s "$system" '.update.arches[$s]' "$sources")"
      name="${asset//\$\{version\}/$version}"
      name="${name//\$\{arch\}/$arch}"
    fi
    url="https://github.com/$repo/releases/download/v${version}/${name}"

    echo -e "  ${YELLOW}prefetching${RESET} $name"
    hash="$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -r .hash)"

    systems_json="$(jq -n \
      --argjson acc "$systems_json" \
      --arg system "$system" \
      --arg url "$url" \
      --arg hash "$hash" \
      '$acc + {($system): {url: $url, hash: $hash}}')"
  done

  local update_json tmp
  update_json="$(jq -c '.update' "$sources")"
  tmp="$(mktemp)"
  jq -n --arg version "$version" --argjson systems "$systems_json" --argjson update "$update_json" \
    '{version: $version, systems: $systems, update: $update}' > "$tmp"
  mv "$tmp" "$sources"

  echo -e "  ${GREEN}Wrote${RESET} pkgs/$pkg/sources.json"
  if [[ -n "$verify" ]]; then
    echo "  Verify with:"
    echo "    nix build .#$pkg && ./result/bin/$verify"
  fi
}

if [[ $all -eq 1 ]]; then
  status=0
  for dir in "$REPO_DIR"/pkgs/*/; do
    name="$(basename "$dir")"
    [[ -f "$dir/sources.json" ]] || continue
    jq -e '.update' "$dir/sources.json" >/dev/null 2>&1 || continue
    update_one "$name" "" 1 || status=1
  done
  exit $status
else
  update_one "$pkg" "$version" 0
fi
