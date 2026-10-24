# nixos-deploy: switch this system (the hermes microVM) to jzila/nixfiles main
# once CI has built it. One round per run, started by nixos-deploy.timer; see
# hosts/hermes/deploy.nix. Runs under writeShellApplication (errexit, nounset,
# pipefail).
#
# Everything is overridable from the environment so a dry run (and the tests in
# test.sh) can run it unprivileged:
#   NIXOS_DEPLOY_DRY_RUN=1   do everything but switch and roll back
#   NIXOS_DEPLOY_STATE       state dir (deployed, system, attempt, report.md, lock)
#   NIXOS_DEPLOY_PAUSE       kill switches: no deploy while any of these exists
#   NIXOS_DEPLOY_UNITS       units that must be active after a switch
#   NIXOS_DEPLOY_CHECK       a further health check: prints problems, fails
repo=${NIXOS_DEPLOY_REPO:-jzila/nixfiles}
host=${NIXOS_DEPLOY_HOST:-hermes}
state=${NIXOS_DEPLOY_STATE:-/var/lib/nixos-deploy}
pause=${NIXOS_DEPLOY_PAUSE:-/var/lib/nixos-deploy/paused}
current=${NIXOS_DEPLOY_CURRENT:-/run/current-system}
profile=${NIXOS_DEPLOY_PROFILE:-/nix/var/nix/profiles/system}
units=${NIXOS_DEPLOY_UNITS:-}
extra_check=${NIXOS_DEPLOY_CHECK:-}
health_timeout=${NIXOS_DEPLOY_HEALTH_TIMEOUT:-300}
poll=${NIXOS_DEPLOY_POLL:-10}
dry=${NIXOS_DEPLOY_DRY_RUN:-}

check="Build NixOS ($host)"
# GitHub Actions' app id: a check run of the same name from any other app
# doesn't count.
actions_app=15368
# A build that fails this many times for one commit isn't retried until main
# moves; a failed switch or a refused commit isn't retried at all.
build_tries=3

log() { echo "$*"; }
short() { echo "${1:0:12}"; }

mkdir -p "$state"
exec 9>"$state/lock"
if ! flock -n 9; then
  log "another run holds $state/lock"
  exit 0
fi

for p in $pause; do
  if [ -e "$p" ]; then
    log "paused: $p exists"
    exit 0
  fi
done

# Unauthenticated GET from the public API. Prints the HTTP status; the body
# goes to $body. Rate limits and outages surface as a non-200 status.
body=$(mktemp)
trap 'rm -f "$body"' EXIT
gh_api() {
  curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/$repo/$1" || echo 000
}

# Writes the verdict for nixos-deploy-report (the kanban board), atomically.
report() {
  local tmp
  tmp=$(mktemp "$state/.report.XXXXXX")
  printf '%s\n' "$@" >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$state/report.md"
  log "report: $1"
}

# Records the commit as failed (not retried until main moves) and files it.
fail() {
  echo "$main $build_tries" >"$state/attempt"
  report "Failed to deploy $main to $host at $(date -Is): $1" "" "${@:2}" "" \
    "Not retried until main moves. Logs: journalctl -u nixos-deploy -u nixos-deploy-switch -u nixos-deploy-rollback"
  exit 1
}

main=$(timeout 60 git ls-remote "https://github.com/$repo" refs/heads/main | cut -f1) || true
if ! [[ $main =~ ^[0-9a-f]{40}$ ]]; then
  log "couldn't read main from github.com; trying again next round"
  exit 0
fi

deployed=$(cat "$state/deployed" 2>/dev/null || true)
system=$(cat "$state/system" 2>/dev/null || true)
tried='' tries=0
if [ -s "$state/attempt" ]; then
  read -r tried tries <"$state/attempt"
fi
# Deployed and running. After a restart the VM runs what argo built for it
# until this round switches it back to the deployed commit.
if [ "$main" = "$deployed" ] && [ "$(readlink -f "$current")" = "$system" ]; then
  log "main $(short "$main") is deployed"
  exit 0
fi
if [ "$main" = "$tried" ] && [ "$tries" -ge "$build_tries" ]; then
  log "main $(short "$main") failed before; waiting for main to move"
  exit 0
fi
[ "$main" = "$tried" ] || tries=0

# CI: the newest "Build NixOS (<host>)" run on this exact commit must have
# succeeded. Pending (or not started) waits; red waits for a fix or a re-run.
status=$(gh_api "commits/$main/check-runs?check_name=$(jq -rn --arg c "$check" '$c | @uri')&app_id=$actions_app&filter=latest")
if [ "$status" != 200 ]; then
  log "GitHub API returned $status for check runs; trying again next round"
  exit 0
fi
ci=$(jq -r --arg sha "$main" --argjson app "$actions_app" '
  [.check_runs[] | select(.head_sha == $sha and .app.id == $app)] | max_by(.id)
  | if . == null then "missing" elif .status != "completed" then .status else .conclusion end' "$body")
if [ "$ci" != success ]; then
  log "main $(short "$main"): \"$check\" is $ci; waiting"
  exit 0
fi

# History: main only moves forward from what this deployed (see the module
# header). Skipped before the first deploy, when nothing is recorded, and when
# main is the deployed commit, to be switched to again.
if [ -n "$deployed" ] && [ "$main" != "$deployed" ]; then
  status=$(gh_api "compare/$deployed...$main?per_page=1")
  case $status in
    200) relation=$(jq -r .status "$body") ;;
    404) relation="unrelated (deployed commit not found)" ;;
    *)
      log "GitHub API returned $status for compare; trying again next round"
      exit 0
      ;;
  esac
  if [ "$relation" != ahead ]; then
    fail "main is not a descendant of the deployed $deployed (GitHub says: $relation)" \
      "Main's history was rewritten, or the deployed commit was dropped from it. Review main, then" \
      "remove $state/deployed so the next round deploys main as a first deploy."
  fi
fi

# Build the pinned commit, never a branch name.
flake="git+https://github.com/$repo?ref=refs/heads/main&rev=$main"
log "building $(short "$main") ($flake)"
if ! out=$(timeout 4h nix build --no-link --print-out-paths --option accept-flake-config false \
  "$flake#nixosConfigurations.$host.config.system.build.toplevel"); then
  tries=$((tries + 1))
  echo "$main $tries" >"$state/attempt"
  if [ "$tries" -ge "$build_tries" ]; then
    fail "the build failed $tries times" "The running system is unchanged."
  fi
  log "build failed (try $tries of $build_tries); trying again next round"
  exit 1
fi
prev=$(readlink -f "$current")
log "built $out"

succeed() {
  echo "$main" >"$state/deployed"
  readlink -f "$out" >"$state/system"
  rm -f "$state/attempt"
  report "Deployed $main to $host at $(date -Is)." "" "$1"
  exit 0
}

# Same system (the first deploy onto a VM already running main, or a commit
# that doesn't touch the VM): record it, nothing to switch.
if [ "$(readlink -f "$out")" = "$prev" ]; then
  log "main $(short "$main") is the running system; nothing to switch"
  succeed "Already running $out."
fi

failed_units() {
  systemctl list-units --failed --plain --no-legend --full | awk '{print $1}' | sort -u
}

# Healthy: the key units that still exist (and whose start conditions hold)
# are active, no unit failed that wasn't failed before the switch, github.com
# is reachable (DNS, routing, TLS), and the extra check passes. Leaves the
# problems in $problems.
problems=''
healthy() {
  local u p=() out
  for u in $units; do
    [ "$(systemctl show -P LoadState "$u")" = loaded ] || continue
    [ "$(systemctl show -P ConditionResult "$u")" = no ] && continue
    systemctl is-active --quiet "$u" || p+=("$u is $(systemctl is-active "$u" || true)")
  done
  for u in $(comm -13 <(echo "$failed_before") <(failed_units)); do
    p+=("$u failed")
  done
  curl -fsS --max-time 10 -o /dev/null https://github.com || p+=("github.com is unreachable")
  if [ -n "$extra_check" ] && ! out=$("$extra_check" 2>&1); then
    p+=("${out:-$extra_check failed}")
  fi
  problems=$(printf '%s; ' "${p[@]}")
  [ ${#p[@]} -eq 0 ]
}
wait_healthy() {
  local deadline=$((SECONDS + health_timeout))
  until healthy; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "unhealthy after ${health_timeout}s: $problems"
      return 1
    fi
    sleep "$poll"
  done
}

# Switch in a transient unit of its own, so that nothing the switch does to
# this unit (stopping it, if a commit drops this module) can cut it short.
switch_to() {
  local name=$1 system=$2
  nix-env -p "$profile" --set "$system"
  systemd-run --unit="$name" --collect --wait --quiet --service-type=exec \
    "$system/bin/switch-to-configuration" switch
}

failed_before=$(failed_units)
if [ -n "$dry" ]; then
  log "dry run: would switch from $prev to $out; checking the running system's health instead"
  if wait_healthy; then log "dry run: healthy"; else log "dry run: unhealthy: $problems"; fi
  succeed "Dry run: switch skipped."
fi

log "switching to $out (from $prev)"
rc=0
switch_to nixos-deploy-switch "$out" || rc=$?
# 4: some units failed to (re)start. The health check decides whether that
# matters; anything else is a broken activation.
if { [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ]; } && wait_healthy; then
  succeed "Switched to $out (switch-to-configuration exited $rc); healthy."
fi
if [ "$rc" -eq 0 ] || [ "$rc" -eq 4 ]; then
  why="unhealthy after the switch: $problems"
else
  why="switch-to-configuration exited $rc"
fi

log "rolling back to $prev: $why"
rrc=0
switch_to nixos-deploy-rollback "$prev" || rrc=$?
if wait_healthy; then
  after="Rolled back to $prev (switch-to-configuration exited $rrc); healthy."
else
  after="Rolled back to $prev (switch-to-configuration exited $rrc); STILL UNHEALTHY: $problems"
fi
fail "$why" "$after"
