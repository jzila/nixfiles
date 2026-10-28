#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub bodies expand when they run
# The deploy job: request.sh (in the runner's container) with run.sh (the
# VM's nixos-deploy.service). Run: bash hosts/hermes/deploy/tests/test-job.sh
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# nixos-deploy: prints a line, deploys $T/deploys (if any), exits $T/deploy-rc.
stub nixos-deploy 'echo "nixos-deploy" >>"$T/calls"; echo "deploying"
[ -s "$T/deploys" ] && cp "$T/deploys" "$T/state/deployed"; exit "$(cat "$T/deploy-rc")"'
# nixos-container: the runner container's running system.
stub nixos-container 'cat "$T/container-system"'

# A new case: $A deployed, the deploy succeeds without deploying anything,
# and the runner's container already runs its configured system.
scenario() {
  name=$1
  fresh
  mkdir -p "$T/run/request" "$T/run/result" "$T/state" "$T/conf"
  echo "$A" >"$T/state/deployed"
  echo 0 >"$T/deploy-rc"
  echo "SYSTEM_PATH=/nix/store/runner-new " >"$T/conf/nixfiles.conf"
  echo /nix/store/runner-new >"$T/container-system"
  echo '{"status": "ahead"}' >"$T/compare.json"
}
export NIXOS_DEPLOY_RUN_DIR="$T/run" NIXOS_DEPLOY_STATE="$T/state" NIXOS_DEPLOY_POLL=0.1 NIXOS_DEPLOY_SETTLE=0 \
  NIXOS_DEPLOY_RUNNER=nixfiles NIXOS_DEPLOY_CONTAINERS="$T/conf" GITHUB_REPOSITORY=jzila/nixfiles GITHUB_RUN_ID=7
# job SHA: a job for that commit and the deploy it starts. $out and $rc are
# the job's; the deploy's output is in $T/run.out.
job() {
  (GITHUB_SHA=$1 script request.sh; echo "$out" >"$T/job.out"; exit "$rc") &
  local j=$!
  until [ -e "$T/run/request/next" ]; do sleep 0.1; done
  script run.sh; echo "$out" >"$T/run.out"
  rc=0; wait "$j" || rc=$?
  out=$(cat "$T/job.out")
}

scenario "deployed"; echo "$B" >"$T/deploys"; job "$B"
expect_rc 0; expect_out "deploying"; expect_out "::notice::Deployed $B"
expect_absent "$T/run/request/next"; expect_no_call "systemctl restart"
scenario "deploy failed"; echo 1 >"$T/deploy-rc"; job "$B"
expect_rc 1; expect_out "::error::$B is not deployed (nixos-deploy exited 1; deployed: $A)"
scenario "paused (nothing deployed)"; echo '{"status": "behind"}' >"$T/compare.json"; job "$B"
expect_rc 1; expect_out "::error::$B is not deployed"
scenario "a later commit deployed"; echo "$C" >"$T/deploys"; job "$B"
expect_rc 0; expect_out "::notice::Deployed $C, which includes $B"
scenario "runner container restarted after its job"; echo "$B" >"$T/deploys"
echo /nix/store/runner-old >"$T/container-system"; job "$B"
expect_rc 0; expect_call "systemctl restart container@nixfiles"
expect_in "$T/run.out" "restarting container@nixfiles onto /nix/store/runner-new"
scenario "runner container kept while another job waits"; echo "$B" >"$T/deploys"
echo /nix/store/runner-old >"$T/container-system"
# Another job asks while the deploy checks the container.
stub nixos-container 'touch "$T/run/request/next"; cat "$T/container-system"'
job "$B"
expect_rc 0; expect_no_call "systemctl restart"

summary
