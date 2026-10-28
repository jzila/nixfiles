# nixos-deploy-run: nixos-deploy.service's main process. Runs nixos-deploy for
# the job that asked (request.sh, in the nixfiles runner's container) and
# hands that job the log and the verdict. Two directories, bound into the
# container:
#
#   request/next   the job's token, written by the job; taken by this script
#                  (the path unit starts the service while one is waiting)
#   result/log     "request <token>", then nixos-deploy's output
#   result/status  "<token> <exit code> <deployed commit>", once it's done
#
# Then, unless another request came in meanwhile, the runner's own container,
# which the switch leaves alone (its job is the one waiting here), is
# restarted onto its new system. Runs under writeShellApplication.
dir=${NIXOS_DEPLOY_RUN_DIR:-/run/nixos-deploy}
state=${NIXOS_DEPLOY_STATE:-/var/lib/nixos-deploy}
runner=${NIXOS_DEPLOY_RUNNER:-}
settle=${NIXOS_DEPLOY_SETTLE:-30}
containers=${NIXOS_DEPLOY_CONTAINERS:-/etc/nixos-containers}

token=$(cat "$dir/request/next" 2>/dev/null || true)
rm -f "$dir/request/next"
echo "request $token" >"$dir/result/log"
rc=0
nixos-deploy 2>&1 | tee -a "$dir/result/log" || rc=$?
printf '%s %s %s\n' "$token" "$rc" "$(cat "$state/deployed" 2>/dev/null || true)" >"$dir/result/.status"
mv -f "$dir/result/.status" "$dir/result/status"

if [ -n "$runner" ] && systemctl is-active -q "container@$runner"; then
  # Time for the job to read its verdict and finish.
  sleep "$settle"
  want=$(sed -n 's/^SYSTEM_PATH=//p' "$containers/$runner.conf" | tr -d '[:space:]')
  have=$(nixos-container run "$runner" -- readlink -f /run/current-system || true)
  if [ "$want" != "$have" ] && ! [ -e "$dir/request/next" ]; then
    echo "restarting container@$runner onto $want"
    systemctl restart "container@$runner"
  fi
fi
exit "$rc"
