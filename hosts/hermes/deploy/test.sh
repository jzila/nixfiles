#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub bodies and switch hooks expand when they run
# The deploy scripts' decisions, against stubs: what gets deployed, when it
# rolls back, what lands on the board, and what the deploy job reports.
# Run: bash hosts/hermes/deploy/test.sh (also the flake check hermes-deploy).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export T PATH="$T/bin:$PATH"
mkdir "$T/bin"
A=$(printf 'a%.0s' {1..40}) B=$(printf 'b%.0s' {1..40}) C=$(printf 'c%.0s' {1..40})

stub() { printf '#!%s\n%s\n' "$(command -v bash)" "$2" >"$T/bin/$1"; chmod +x "$T/bin/$1"; }
stub git 'printf "%s\trefs/heads/main\n" "$(cat "$T/main")"'
stub curl 'url=${!#} o=
while [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; shift; done
case $url in
  http://127.0.0.1:8644/) printf 404; exit 0 ;; https://github.com | */api/version) exit 0 ;;
  */check-runs*) f=checks ;; */compare/*) f=compare ;;
esac
if [ -n "$o" ]; then cp "$T/$f.json" "$o"; printf 200; else cat "$T/$f.json"; fi'
stub nix 'echo "nix $*" >>"$T/calls"; [ -e "$T/build-fails" ] && exit 1; echo "$T/sys-new"'
stub nix-env :
stub systemd-run 'while [[ $1 == -* ]]; do shift; done; exec "$@"'
stub systemctl 'case $1 in
  list-units) cat "$T/failed" 2>/dev/null || true ;;
  show) if [ "$3" != ConditionResult ]; then echo loaded; elif grep -qxs "${!#}" "$T/condfail"; then echo no; else echo yes; fi ;;
  is-active) ! grep -qxs "${!#}" "$T/inactive" ;;
  restart) echo "systemctl $*" >>"$T/calls" ;;
esac'
stub check '! [ -e "$T/sick" ] || { echo "Signal is disconnected"; exit 1; }'
stub hermes 'echo "hermes $*" >>"$T/calls"; [ "$2" = list ] && cat "$T/board.json"; true'

pass=0 failures=0
expect() { # WHAT COMMAND...: COMMAND checks WHAT
  if "${@:2}"; then pass=$((pass + 1)); else failures=$((failures + 1)); printf 'FAIL [%s]: expected %s\n%s\n' "$name" "$1" "$out"; fi
}
no() { ! "$@"; }
called() { grep -qs -- "$1" "$T/calls"; }
run() { rc=0; out=$(bash -o errexit -o nounset -o pipefail "$here/$1" "${@:2}" 2>&1) || rc=$?; }
fresh() { name=$1; find "$T" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +; touch "$T/calls"; }

# deploy.sh. $A is deployed (sys-old), main is $B with green CI, and the build
# gives sys-new. Switching to a system points $T/current at it and runs
# $T/on-<system>.
export NIXOS_DEPLOY_STATE="$T/state" NIXOS_DEPLOY_PAUSE="$T/paused" NIXOS_DEPLOY_CURRENT="$T/current" \
  NIXOS_DEPLOY_PROFILE="$T/profile" NIXOS_DEPLOY_UNITS=hermes-agent.service NIXOS_DEPLOY_CHECK="$T/bin/check" \
  NIXOS_DEPLOY_HEALTH_TIMEOUT=0 NIXOS_DEPLOY_POLL=0
ci() { jq -n --arg s "$1" --arg c "$2" --arg sha "$3" \
  '{check_runs: [{id: 1, head_sha: $sha, status: $s, conclusion: $c, app: {id: 15368}}]}' >"$T/checks.json"; }
given() {
  fresh "$1"
  for s in old new; do
    mkdir -p "$T/sys-$s/bin"
    printf '#!/bin/sh\nln -sfn %s "$T/current"\n[ ! -e "$T/on-%s" ] || . "$T/on-%s"\n' "$T/sys-$s" "$s" "$s" \
      >"$T/sys-$s/bin/switch-to-configuration"
    chmod +x "$T/sys-$s/bin/switch-to-configuration"
  done
  mkdir "$T/state"; echo "$A" >"$T/state/deployed"; echo "$T/sys-old" >"$T/state/system"
  ln -s "$T/sys-old" "$T/current"; echo "$B" >"$T/main"; ci completed success "$B"
  echo '{"status": "ahead"}' >"$T/compare.json"
}
deployed() { [ "$(cat "$T/state/deployed")" = "$1" ] && [ "$(readlink "$T/current")" = "$T/sys-$2" ]; }
reported() { head -n 1 "$T/state/report.md" | grep -q -- "$1"; }

given "healthy switch; some units failed to start (exit 4)"; printf 'exit 4\n' >"$T/on-new"; run deploy.sh
expect "$B deployed" deployed "$B" new; expect "a report" reported "Deployed $B"
given "already deployed"; echo "$B" >"$T/state/deployed"; run deploy.sh
expect "no build" no called "nix build"
given "booted into an older generation"; echo "$B" >"$T/state/deployed"; echo "$T/sys-new" >"$T/state/system"; run deploy.sh
expect "the deployed system again" deployed "$B" new
given "paused"; touch "$T/paused"; run deploy.sh
expect "no build" no called "nix build"
given "CI still running"; ci in_progress null "$B"; run deploy.sh
expect "no build" no called "nix build"
given "CI green, but for another commit"; ci completed success "$C"; run deploy.sh
expect "no build" no called "nix build"
given "main rewound or force-pushed"; echo '{"status": "diverged"}' >"$T/compare.json"; run deploy.sh
expect "no build" no called "nix build"; expect "a failure report" reported "Failed to deploy $B"
given "failed units that were failed before, a unit waiting on its condition"
echo "foo.service loaded failed failed Foo" >"$T/failed"; echo hermes-agent.service >"$T/condfail"
echo 'echo hermes-agent.service >"$T/inactive"' >"$T/on-new"; run deploy.sh
expect "$B deployed" deployed "$B" new

given "unhealthy after the switch"; echo 'touch "$T/sick"' >"$T/on-new"; echo 'rm "$T/sick"' >"$T/on-old"; run deploy.sh
expect "exit 1" [ "$rc" = 1 ]; expect "a rollback" deployed "$A" old
expect "the reason reported" reported "Failed to deploy $B .*Signal is disconnected"
: >"$T/calls"; run deploy.sh
expect "no retry" no called "nix build"
name="main moves on after a failure"; rm "$T/on-new"; echo "$C" >"$T/main"; ci completed success "$C"; run deploy.sh
expect "$C deployed" deployed "$C" new
given "still unhealthy after the rollback"; echo 'touch "$T/sick"' >"$T/on-new"; run deploy.sh
expect "it reported" grep -q "STILL UNHEALTHY" "$T/state/report.md"
given "build fails"; touch "$T/build-fails"; run deploy.sh
expect "a quiet first failure" no test -e "$T/state/report.md"
run deploy.sh; run deploy.sh; expect "a report on the third" reported "build failed 3 times"
: >"$T/calls"; run deploy.sh; expect "no fourth try" no called "nix build"

# report.sh: one open task per failure, refreshed or completed; others' tasks
# are left alone.
board() { fresh "$1"; printf '%s\n' "$2" >"$T/report.md"; printf '%s\n' "$3" >"$T/board.json"; }
failed="Failed to deploy $B to hermes at now: x"
task='{"id": "t_1", "title": "hermes deploy: main failed to deploy", "tenant": null, "created_by": "nixos-deploy", "status": "ready", "created_at": 1, "body": "old"}'
other='{"id": "t_2", "title": "hermes deploy: x", "tenant": "hass", "created_by": "nixos-deploy", "status": "ready", "created_at": 1, "body": ""}'
board "first failure" "$failed" "[$other]"; run report.sh "$T/report.md"
expect "a new task" called "kanban create"
board "same failure again" "$failed" "[$(jq -c --arg b "$failed" '.body = $b' <<<"$task")]"; run report.sh "$T/report.md"
expect "the task left alone" no called "kanban \(create\|edit\)"
board "deployed" "Deployed $B to hermes at now." "[$task, $other]"; run report.sh "$T/report.md"
expect "the task completed" called "complete t_1"; expect "the other tenant's left alone" no called "t_2"

# health.sh: Signal counts only once an account exists; a unit waiting on its
# condition isn't down.
gw() { jq -n --arg s "$1" '{pid: 42, gateway_state: "running", platforms: {webhook: {state: "connected"}, signal: {state: $s}}}' >"$T/gw.json"; }
stub systemctl 'case $1 in show) [ "$3" = MainPID ] && echo 42 || echo no ;; is-active) false ;; esac'
export HERMES_HEALTH_STATE="$T/gw.json" HERMES_HEALTH_SIGNAL="$T/accounts.json" HERMES_HEALTH_UNITS=nginx.service
fresh "fresh VM, no Signal account; nginx waiting for its certificate"; gw disconnected; run health.sh
expect "healthy" [ "$rc" = 0 ]
fresh "Signal down"; gw disconnected; echo '{"accounts": [{"number": "x"}]}' >"$T/accounts.json"; run health.sh
expect "unhealthy" grep -q "Signal is disconnected" <<<"$out"

# request.sh with run.sh: the job reports the deploy's verdict, and the runner's
# container is restarted onto its new system after the job, not during it.
stub nixos-deploy 'echo deploying; [ ! -s "$T/deploys" ] || cp "$T/deploys" "$T/state/deployed"; exit "$(cat "$T/deploy-rc")"'
stub nixos-container 'echo /nix/store/runner-old'
stub systemctl 'case $1 in is-active) true ;; restart) echo "systemctl $*" >>"$T/calls" ;; esac'
export NIXOS_DEPLOY_RUN_DIR="$T/run" NIXOS_DEPLOY_POLL=0.1 NIXOS_DEPLOY_SETTLE=0 NIXOS_DEPLOY_RUNNER=nixfiles \
  NIXOS_DEPLOY_CONTAINERS="$T/conf" GITHUB_REPOSITORY=jzila/nixfiles GITHUB_RUN_ID=7
job() { # NAME DEPLOYS RC: a job for $B, and the deploy it starts
  fresh "$1"; mkdir -p "$T/run/request" "$T/run/result" "$T/state" "$T/conf"
  echo "$A" >"$T/state/deployed"; echo "$2" >"$T/deploys"; echo "$3" >"$T/deploy-rc"
  echo "SYSTEM_PATH=/nix/store/runner-new" >"$T/conf/nixfiles.conf"; echo '{"status": "ahead"}' >"$T/compare.json"
  (GITHUB_SHA=$B run request.sh; echo "$out" >"$T/job.out"; exit "$rc") &
  local j=$!
  until [ -e "$T/run/request/next" ]; do sleep 0.1; done
  run run.sh
  rc=0; wait "$j" || rc=$?; out=$(cat "$T/job.out")
}
job "deployed" "$B" 0
expect "a green job" [ "$rc" = 0 ]; expect "the deploy's log" grep -q deploying <<<"$out"
expect "a restart after the job" called "restart container@nixfiles"
job "deploy failed" "" 1
expect "a red job" [ "$rc" = 1 ]
job "a later commit deployed" "$C" 0
expect "a green job" [ "$rc" = 0 ]
stub nixos-container 'touch "$T/run/request/next"; echo /nix/store/runner-old'
job "another job waiting" "$B" 0
expect "no restart under the next job" no called "restart"

echo "$pass passed, $failures failed"
[ "$failures" -eq 0 ]
