#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub bodies and switch hooks expand when they run
# deploy.sh (nixos-deploy). Run: bash hosts/hermes/deploy/tests/test-deploy.sh
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

stub git 'echo "git $*" >>"$T/calls"; [ -e "$T/offline" ] && exit 128; printf "%s\trefs/heads/main\n" "$(cat "$T/main")"'
stub nix 'echo "nix $*" >>"$T/calls"; [ -e "$T/build-fails" ] && exit 1; echo "$T/sys-$(cat "$T/build")"'
stub nix-env 'echo "nix-env $*" >>"$T/calls"'
stub systemd-run 'echo "systemd-run $1" >>"$T/calls"; while [[ $1 == -* ]]; do shift; done; exec "$@"'
# The extra health check (hermes-health): fails while $T/sick exists.
stub check '[ -e "$T/sick" ] && { echo "Signal is disconnected"; exit 1; }; exit 0'

checks() { # status conclusion sha
  jq -n --arg s "$1" --arg c "$2" --arg sha "$3" '{check_runs: [{id: 1, head_sha: $sha, status: $s, conclusion: $c, app: {id: 15368}}]}' >"$T/checks.json"; }
# A new case: $A deployed (system sys-old), main at $B, CI green, $B a
# descendant, and the build gives sys-new. Switching to a system makes
# $T/current point at it and runs $T/on-<system>, if any.
scenario() {
  name=$1
  fresh
  for s in old new; do
    mkdir -p "$T/sys-$s/bin"
    printf '#!%s\nln -sfn "%s" "$T/current"\n[ -e "$T/on-%s" ] && . "$T/on-%s"\nexit 0\n' \
      "$(command -v bash)" "$T/sys-$s" "$s" "$s" >"$T/sys-$s/bin/switch-to-configuration"
    chmod +x "$T/sys-$s/bin/switch-to-configuration"
  done
  mkdir -p "$T/state"
  ln -sfn "$T/sys-old" "$T/current"
  echo "$A" >"$T/state/deployed"
  echo "$T/sys-old" >"$T/state/system"
  echo "$B" >"$T/main"
  echo new >"$T/build"
  checks completed success "$B"
  echo '{"status": "ahead"}' >"$T/compare.json"
}
run() {
  NIXOS_DEPLOY_STATE="$T/state" NIXOS_DEPLOY_PAUSE="$T/pause $T/pause2" NIXOS_DEPLOY_CURRENT="$T/current" \
    NIXOS_DEPLOY_PROFILE="$T/profile" NIXOS_DEPLOY_UNITS="hermes-agent.service nginx.service" \
    NIXOS_DEPLOY_CHECK="$T/bin/check" NIXOS_DEPLOY_HEALTH_TIMEOUT=0 NIXOS_DEPLOY_POLL=0 script deploy.sh
}
state() { cat "$T/state/$1" 2>/dev/null; }
expect_state() { expect "$1 is '$(state "$1")', expected '$2'" [ "$(state "$1")" = "$2" ]; }
expect_report() { expect "report doesn't start with '$1'" grep -q -- "$1" <<<"$(state report.md | head -n 1)"; }
expect_current() { expect "current is $(readlink "$T/current"), expected sys-$1" [ "$(readlink "$T/current")" = "$T/sys-$1" ]; }

# Nothing to do
scenario "up to date"; echo "$B" >"$T/state/deployed"; run
expect_rc 0; expect_no_call "api"; expect_no_call "^nix "
scenario "paused"; touch "$T/pause"; run
expect_rc 0; expect_no_call "git"
scenario "second pause file"; touch "$T/pause2"; run
expect_rc 0; expect_no_call "git"
scenario "github unreachable"; touch "$T/offline"; run
expect_rc 0; expect_no_call "api"
scenario "CI pending"; checks in_progress null "$B"; run
expect_rc 0; expect_no_call "^nix "; expect_state deployed "$A"
scenario "CI failed"; checks completed failure "$B"; run
expect_rc 0; expect_no_call "^nix "
scenario "CI run for another commit"; checks completed success "$C"; run
expect_rc 0; expect_no_call "^nix "
scenario "API rate limited"; echo 403 >"$T/checks.status"; run
expect_rc 0; expect_no_call "^nix "; expect_absent "$T/state/attempt"
scenario "not a descendant"; echo '{"status": "diverged"}' >"$T/compare.json"; run
expect_rc 1; expect_no_call "^nix "; expect_report "Failed to deploy $B"; expect_state attempt "$B 3"
run
expect_rc 0; expect_no_call "^nix "

# Deploys
scenario "booted into another generation"; echo "$B" >"$T/state/deployed"; echo "$T/sys-new" >"$T/state/system"; run
expect_rc 0; expect_no_call "api compare"; expect_call "nix build.*rev=$B"; expect_call "systemd-run --unit=nixos-deploy-switch"
expect_current new; expect_state deployed "$B"; expect_state system "$T/sys-new"
scenario "first deploy onto main's system"; rm "$T/state/deployed"; echo old >"$T/build"; run
expect_rc 0; expect_no_call "api compare"; expect_no_call "nix-env"; expect_state deployed "$B"; expect_report "Deployed $B"
scenario "healthy switch"; run
expect_rc 0; expect_call "nix build.*rev=$B#nixosConfigurations.hermes"; expect_call "nix-env -p $T/profile --set $T/sys-new"
expect_call "systemd-run --unit=nixos-deploy-switch"; expect_no_call "nixos-deploy-rollback"
expect_current new; expect_state deployed "$B"; expect_state system "$T/sys-new"; expect_report "Deployed $B"
scenario "pre-existing failed unit"; echo "foo.service loaded failed failed Foo" >"$T/failed"; run
expect_rc 0; expect_current new; expect_state deployed "$B"
scenario "unit skipped by its condition"; echo nginx.service >"$T/condfail"; echo 'echo nginx.service >"$T/inactive"' >"$T/on-new"; run
expect_rc 0; expect_current new; expect_state deployed "$B"
scenario "units failed to start but healthy"; printf 'exit 4\n' >"$T/on-new"; run
expect_rc 0; expect_current new; expect_state deployed "$B"
scenario "dry run"; NIXOS_DEPLOY_DRY_RUN=1 run
expect_rc 0; expect_call "^nix build"; expect_no_call "nix-env"; expect_no_call "systemd-run"; expect_current old

# Unhealthy after the switch: rolled back
scenario "key unit down after switch"
echo 'echo hermes-agent.service >"$T/inactive"' >"$T/on-new"; echo 'rm -f "$T/inactive"' >"$T/on-old"; run
expect_rc 1; expect_call "nix-env -p $T/profile --set $T/sys-old"; expect_call "systemd-run --unit=nixos-deploy-rollback"
expect_current old; expect_state deployed "$A"; expect_state attempt "$B 3"
expect_report "Failed to deploy $B .*hermes-agent.service is inactive"
expect_in "$T/state/report.md" "Rolled back to $T/sys-old .*; healthy"
: >"$T/calls"; run
expect_rc 0; expect_no_call "^nix "
name="main moves after a failure"; rm "$T/on-new"; echo "$C" >"$T/main"; checks completed success "$C"; run
expect_rc 0; expect_state deployed "$C"; expect_absent "$T/state/attempt"
scenario "new failed unit after switch"
echo 'echo "bar.service loaded failed failed Bar" >"$T/failed"' >"$T/on-new"; echo 'rm -f "$T/failed"' >"$T/on-old"; run
expect_rc 1; expect_current old; expect_report "bar.service failed"
scenario "hermes unhealthy after switch"; echo 'touch "$T/sick"' >"$T/on-new"; echo 'rm -f "$T/sick"' >"$T/on-old"; run
expect_rc 1; expect_current old; expect_state system "$T/sys-old"; expect_report "Failed to deploy $B .*Signal is disconnected"
scenario "no network after switch"; echo 'touch "$T/offline"' >"$T/on-new"; echo 'rm -f "$T/offline"' >"$T/on-old"; run
expect_rc 1; expect_current old; expect_report "github.com is unreachable"
scenario "rollback still unhealthy"; echo 'touch "$T/offline"' >"$T/on-new"; run
expect_rc 1; expect_current old; expect_in "$T/state/report.md" "STILL UNHEALTHY"
scenario "broken activation"; printf 'exit 1\n' >"$T/on-new"; run
expect_rc 1; expect_current old; expect_report "switch-to-configuration exited 1"

# Build failures
scenario "build fails 3 times"; touch "$T/build-fails"; run
expect_rc 1; expect_state attempt "$B 1"; expect_absent "$T/state/report.md"
run; run
expect_state attempt "$B 3"; expect_report "Failed to deploy $B .*build failed 3 times"
: >"$T/calls"; run
expect_rc 0; expect_no_call "^nix "

summary
