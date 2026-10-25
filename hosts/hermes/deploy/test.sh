#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # `ok` never fails; stub bodies expand at run time
# Tests deploy.sh and report.sh against stubs of git, curl, nix, nix-env,
# systemctl, systemd-run and hermes. Run: bash hosts/hermes/deploy/test.sh
# (also the flake check hermes-deploy). Needs bash, jq, coreutils, util-linux.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export T

A=$(printf 'a%.0s' {1..40}) # deployed
B=$(printf 'b%.0s' {1..40}) # main
C=$(printf 'c%.0s' {1..40}) # main, later

stub() { printf '#!%s\n%s\n' "$(command -v bash)" "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
stub git 'echo "git $*" >>"$T/calls"; [ -e "$T/offline" ] && exit 128; printf "%s\trefs/heads/main\n" "$(cat "$T/main")"'
# curl: github.com reachability, or the API (-o FILE -w %{http_code} ... URL).
stub curl '
url=${!#} out=
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
case $url in
  https://github.com) [ -e "$T/offline" ] && exit 6; exit 0 ;;
  */api/version) [ -e "$T/ollama-down" ] && exit 7; exit 0 ;;
  http://127.0.0.1:8644/) [ -e "$T/webhook-down" ] && { printf 000; exit 7; }; printf 404; exit 0 ;;
  */check-runs*) echo "api checks" >>"$T/calls"; f=checks ;;
  */compare/*) echo "api compare" >>"$T/calls"; f=compare ;;
esac
cp "$T/$f.json" "$out"; printf %s "$(cat "$T/$f.status" 2>/dev/null || echo 200)"'
stub nix 'echo "nix $*" >>"$T/calls"; [ -e "$T/build-fails" ] && exit 1; echo "$T/sys-$(cat "$T/build")"'
stub nix-env 'echo "nix-env $*" >>"$T/calls"'
stub systemd-run 'echo "systemd-run $1" >>"$T/calls"; while [[ $1 == -* ]]; do shift; done; exec "$@"'
# systemctl: units listed in $T/inactive are down, in $T/failed failed, in
# $T/condfail skipped by their start condition.
stub systemctl '
case $1 in
  list-units) cat "$T/failed" 2>/dev/null || true ;;
  show)
    u=${!#}
    case $3 in
      MainPID) cat "$T/mainpid" ;;
      ConditionResult) if grep -qx "$u" "$T/condfail" 2>/dev/null; then echo no; else echo yes; fi ;;
      *) echo loaded ;;
    esac ;;
  is-active) u=${!#}; if grep -qx "$u" "$T/inactive" 2>/dev/null; then echo inactive; exit 3; fi; echo active ;;
esac'
# inside: Hermes's container (nixos-container run hermes --), logged and run here.
stub inside 'echo "inside $*" >>"$T/calls"; shift; exec "$@"'
stub hermes 'echo "hermes $*" >>"$T/calls"; [ "$2" = list ] && cat "$T/board.json"; true'
# The extra health check (hermes-health): fails while $T/sick exists.
stub check '[ -e "$T/sick" ] && { echo "Signal is disconnected"; exit 1; }; exit 0'

# Systems: switching makes $T/current point at it, and applies $T/on-<name>.
for s in old new; do
  mkdir -p "$T/sys-$s/bin"
  printf '#!%s\nln -sfn "%s" "$T/current"\n[ -e "$T/on-%s" ] && . "$T/on-%s"\nexit 0\n' \
    "$(command -v bash)" "$T/sys-$s" "$s" "$s" >"$T/sys-$s/bin/switch-to-configuration"
  chmod +x "$T/sys-$s/bin/switch-to-configuration"
done

checks() { # status conclusion sha
  jq -n --arg s "$1" --arg c "$2" --arg sha "$3" \
    '{check_runs: [{id: 1, head_sha: $sha, status: $s, conclusion: $c, app: {id: 15368}}]}' >"$T/checks.json"
}
reset() {
  rm -rf "$T/state" "$T/calls" "$T/inactive" "$T/failed" "$T/offline" "$T/build-fails" "$T/on-new" \
    "$T/on-old" "$T/pause" "$T/pause2" "$T/checks.status" "$T/compare.status" "$T/sick" "$T/condfail"
  mkdir -p "$T/state"
  ln -sfn "$T/sys-old" "$T/current"
  echo "$A" >"$T/state/deployed"
  echo "$T/sys-old" >"$T/state/system"
  echo "$B" >"$T/main"
  echo new >"$T/build"
  checks completed success "$B"
  echo '{"status": "ahead"}' >"$T/compare.json"
  touch "$T/calls"
}
run() {
  rc=0
  out=$(env PATH="$T/bin:$PATH" NIXOS_DEPLOY_STATE="$T/state" NIXOS_DEPLOY_PAUSE="$T/pause $T/pause2" \
    NIXOS_DEPLOY_CURRENT="$T/current" NIXOS_DEPLOY_PROFILE="$T/profile" \
    NIXOS_DEPLOY_UNITS="hermes-agent.service nginx.service" NIXOS_DEPLOY_CHECK="$T/bin/check" \
    NIXOS_DEPLOY_HEALTH_TIMEOUT=0 NIXOS_DEPLOY_POLL=0 "$@" \
    bash -o errexit -o nounset -o pipefail "$here/deploy.sh" 2>&1) || rc=$?
}

pass=0 failures=0
ok() { pass=$((pass + 1)); }
no() { failures=$((failures + 1)); echo "FAIL [$name]: $*"; printf '    %s\n' "$out"; }
expect_rc() { [ "$rc" = "$1" ] && ok || no "exit $rc, expected $1"; }
expect_state() { [ "$(cat "$T/state/$1" 2>/dev/null)" = "$2" ] && ok || no "$1 is '$(cat "$T/state/$1" 2>/dev/null)', expected '$2'"; }
expect_call() { grep -q -- "$1" "$T/calls" && ok || no "no call matching '$1'"; }
expect_no_call() { ! grep -q -- "$1" "$T/calls" && ok || no "unexpected call matching '$1'"; }
expect_report() { head -n 1 "$T/state/report.md" 2>/dev/null | grep -q -- "$1" && ok || no "report doesn't start with '$1'"; }
expect_current() { [ "$(readlink "$T/current")" = "$T/sys-$1" ] && ok || no "current is $(readlink "$T/current"), expected sys-$1"; }

name="up to date"; reset; echo "$B" >"$T/state/deployed"; run
expect_rc 0; expect_no_call "api"; expect_no_call "^nix "

name="paused"; reset; touch "$T/pause"; run
expect_rc 0; expect_no_call "git"

name="second pause file"; reset; touch "$T/pause2"; run
expect_rc 0; expect_no_call "git"

name="booted into another generation"; reset; echo "$B" >"$T/state/deployed"; echo "$T/sys-new" >"$T/state/system"; run
expect_rc 0; expect_no_call "api compare"; expect_call "nix build.*rev=$B"; expect_call "systemd-run --unit=nixos-deploy-switch"
expect_current new; expect_state deployed "$B"; expect_state system "$T/sys-new"

name="github unreachable"; reset; touch "$T/offline"; run
expect_rc 0; expect_no_call "api"

name="CI pending"; reset; checks in_progress null "$B"; run
expect_rc 0; expect_no_call "^nix "; expect_state deployed "$A"

name="CI failed"; reset; checks completed failure "$B"; run
expect_rc 0; expect_no_call "^nix "

name="CI run for another commit"; reset; checks completed success "$C"; run
expect_rc 0; expect_no_call "^nix "

name="API rate limited"; reset; echo 403 >"$T/checks.status"; run
expect_rc 0; expect_no_call "^nix "; [ ! -e "$T/state/attempt" ] && ok || no "attempt recorded"

name="not a descendant"; reset; echo '{"status": "diverged"}' >"$T/compare.json"; run
expect_rc 1; expect_no_call "^nix "; expect_report "Failed to deploy $B"; expect_state attempt "$B 3"
run; expect_rc 0; expect_no_call "^nix "

name="first deploy onto main's system"; reset; rm "$T/state/deployed"; echo old >"$T/build"; run
expect_rc 0; expect_no_call "api compare"; expect_no_call "nix-env"; expect_state deployed "$B"; expect_report "Deployed $B"

name="healthy switch"; reset; run
expect_rc 0; expect_call "nix build.*rev=$B#nixosConfigurations.hermes"; expect_call "nix-env -p $T/profile --set $T/sys-new"
expect_call "systemd-run --unit=nixos-deploy-switch"; expect_no_call "nixos-deploy-rollback"
expect_current new; expect_state deployed "$B"; expect_state system "$T/sys-new"; expect_report "Deployed $B"

name="pre-existing failed unit"; reset; echo "foo.service loaded failed failed Foo" >"$T/failed"; run
expect_rc 0; expect_current new; expect_state deployed "$B"

name="unit skipped by its condition"; reset; echo nginx.service >"$T/condfail"; echo 'echo nginx.service >"$T/inactive"' >"$T/on-new"; run
expect_rc 0; expect_current new; expect_state deployed "$B"

name="key unit down after switch"; reset; echo 'echo hermes-agent.service >"$T/inactive"' >"$T/on-new"
echo 'rm -f "$T/inactive"' >"$T/on-old"; run
expect_rc 1; expect_call "nix-env -p $T/profile --set $T/sys-old"; expect_call "systemd-run --unit=nixos-deploy-rollback"
expect_current old; expect_state deployed "$A"; expect_state attempt "$B 3"
expect_report "Failed to deploy $B .*hermes-agent.service is inactive"
grep -q "Rolled back to $T/sys-old .*; healthy" "$T/state/report.md" && ok || no "report lacks the rollback"
: >"$T/calls"; run; expect_rc 0; expect_no_call "^nix "
name="main moves after a failure"; rm "$T/on-new"; echo "$C" >"$T/main"; checks completed success "$C"; run
expect_rc 0; expect_state deployed "$C"; [ ! -e "$T/state/attempt" ] && ok || no "attempt kept"

name="new failed unit after switch"; reset; echo 'echo "bar.service loaded failed failed Bar" >"$T/failed"' >"$T/on-new"
echo 'rm -f "$T/failed"' >"$T/on-old"; run
expect_rc 1; expect_current old; expect_report "bar.service failed"

name="hermes unhealthy after switch"; reset; echo 'touch "$T/sick"' >"$T/on-new"; echo 'rm -f "$T/sick"' >"$T/on-old"; run
expect_rc 1; expect_current old; expect_state system "$T/sys-old"; expect_report "Failed to deploy $B .*Signal is disconnected"

name="no network after switch"; reset; echo 'touch "$T/offline"' >"$T/on-new"; echo 'rm -f "$T/offline"' >"$T/on-old"; run
expect_rc 1; expect_current old; expect_report "github.com is unreachable"

name="rollback still unhealthy"; reset; echo 'touch "$T/offline"' >"$T/on-new"; rm -f "$T/on-old"; run
expect_rc 1; expect_current old; grep -q "STILL UNHEALTHY" "$T/state/report.md" && ok || no "report hides it"

name="broken activation"; reset; printf 'exit 1\n' >"$T/on-new"; rm -f "$T/on-old"; run
expect_rc 1; expect_current old; expect_report "switch-to-configuration exited 1"

name="units failed to start but healthy"; reset; printf 'exit 4\n' >"$T/on-new"; run
expect_rc 0; expect_current new; expect_state deployed "$B"

name="build fails 3 times"; reset; touch "$T/build-fails"; run; expect_rc 1; expect_state attempt "$B 1"
[ ! -e "$T/state/report.md" ] && ok || no "reported a first build failure"
run; run; expect_state attempt "$B 3"; expect_report "Failed to deploy $B .*build failed 3 times"
: >"$T/calls"; run; expect_rc 0; expect_no_call "^nix "

name="dry run"; reset; run NIXOS_DEPLOY_DRY_RUN=1
expect_rc 0; expect_call "^nix build"; expect_no_call "nix-env"; expect_no_call "systemd-run"; expect_current old

# report.sh
board() { printf '%s\n' "$1" >"$T/board.json"; }
rep() {
  rc=0
  out=$(env PATH="$T/bin:$PATH" bash -o errexit -o nounset -o pipefail "$here/report.sh" "$T/state/report.md" 2>&1) || rc=$?
}
task='{"id": "t_1", "title": "hermes deploy: main failed to deploy", "tenant": null, "created_by": "nixos-deploy", "status": "ready", "created_at": 1, "body": "old"}'
other='{"id": "t_2", "title": "hermes deploy: x", "tenant": "hass", "created_by": "nixos-deploy", "status": "ready", "created_at": 1, "body": ""}'

name="report: first failure"; : >"$T/calls"; printf 'Failed to deploy %s to hermes at now: x\n' "$B" >"$T/state/report.md"; board "[$other]"; rep
expect_rc 0; expect_call "hermes kanban create --created-by nixos-deploy --body-file"; expect_no_call "edit"
name="report: another failure"; : >"$T/calls"; board "[$task]"; rep
expect_rc 0; expect_call "hermes kanban edit t_1"; expect_no_call "create"
name="report: same failure"; : >"$T/calls"; board "[$(jq -c --rawfile b "$T/state/report.md" '.body = ($b | rtrimstr("\n"))' <<<"$task")]"; rep
expect_rc 0; expect_no_call "edit"; expect_no_call "create"
name="report: deployed"; : >"$T/calls"; printf 'Deployed %s to hermes at 2026-10-24T12:00:00-05:00.\n' "$B" >"$T/state/report.md"; board "[$task, $other]"; rep
expect_rc 0; expect_call "hermes kanban complete t_1 --result Deployed main bbbbbbbbbbbb"; expect_no_call "t_2"
name="report: garbage"; echo nonsense >"$T/state/report.md"; rep
expect_rc 1

# health.sh
gw() { # gateway_state signal_state [pid]
  jq -n --arg g "$1" --arg s "$2" --argjson pid "${3:-42}" \
    '{pid: $pid, gateway_state: $g, platforms: {webhook: {state: "connected"}, signal: {state: $s}}}' >"$T/gw.json"
}
health() {
  rc=0
  out=$(env PATH="$T/bin:$PATH" HERMES_HEALTH_STATE="$T/gw.json" HERMES_HEALTH_SIGNAL="$T/accounts.json" "$@" \
    bash -o errexit -o nounset -o pipefail "$here/health.sh" 2>&1) || rc=$?
}
hreset() {
  rm -f "$T/ollama-down" "$T/webhook-down" "$T/accounts.json" "$T/inactive" "$T/condfail"
  : >"$T/calls"
  echo 42 >"$T/mainpid"
  gw running connected
}
expect_out() { grep -q -- "$1" <<<"$out" && ok || no "output lacks '$1'"; }

name="health: fresh VM, no Signal account"; hreset; gw running disconnected; health
expect_rc 0
name="health: healthy with an account"; hreset; echo '{"accounts": [{"number": "x"}]}' >"$T/accounts.json"; health
expect_rc 0
name="health: Signal down"; hreset; echo '{"accounts": [{"number": "x"}]}' >"$T/accounts.json"; gw running disconnected; health
expect_rc 1; expect_out "Signal is disconnected"
name="health: gateway not running"; hreset; echo 0 >"$T/mainpid"; health
expect_rc 1; expect_out "gateway isn't running"
name="health: stale state file"; hreset; gw running connected 7; health
expect_rc 1; expect_out "hasn't written its state"
name="health: gateway stopping"; hreset; gw stopping connected; health
expect_rc 1; expect_out "gateway is stopping"
name="health: no receiver, no ollama"; hreset; touch "$T/webhook-down" "$T/ollama-down"; health
expect_rc 1; expect_out "nothing listens at http://127.0.0.1:8644/; ollama on argo is unreachable"

name="health: signal-cli down"; hreset; echo signal-cli.service >"$T/inactive"; health
expect_rc 1; expect_out "signal-cli.service is inactive"
name="health: nginx waiting for its certificate"; hreset; echo nginx.service >"$T/condfail"; health
expect_rc 0
name="health: nginx down with its certificate"; hreset; echo nginx.service >"$T/inactive"; health
expect_rc 1; expect_out "nginx.service is inactive"
name="health: checks inside the container"; hreset; health HERMES_HEALTH_IN="$T/bin/inside --" HERMES_HEALTH_CURL=curl
expect_rc 0; expect_call "inside -- systemctl show -P MainPID hermes-agent.service"
expect_call "inside -- systemctl is-active --quiet signal-cli.service"
expect_call "inside -- curl -s --max-time 10"; expect_call "inside -- curl -fs --max-time 10"
name="health: ollama unreachable from inside"; hreset; touch "$T/ollama-down"; health HERMES_HEALTH_IN="$T/bin/inside --"
expect_rc 1; expect_out "ollama on argo is unreachable"

echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
