# nixos-deploy-request: the deploy job's one step (.github/workflows/ci.yml),
# in the nixfiles runner's container. Asks the VM to deploy main (run.sh),
# streams the deploy's log into the job, and passes if this commit, or a
# later one on main, is deployed. Runs under writeShellApplication.
dir=${NIXOS_DEPLOY_RUN_DIR:-/run/nixos-deploy}
repo=${GITHUB_REPOSITORY:?}
sha=${GITHUB_SHA:?}
token="$GITHUB_RUN_ID.${GITHUB_RUN_ATTEMPT:-1}"
poll=${NIXOS_DEPLOY_POLL:-2}

echo "$token" >"$dir/request/next"
until [ "$(head -n 1 "$dir/result/log" 2>/dev/null)" = "request $token" ]; do sleep "$poll"; done
tail -n +2 -f "$dir/result/log" &
tail=$!
until [ "$(cut -d ' ' -f 1 "$dir/result/status" 2>/dev/null)" = "$token" ]; do sleep "$poll"; done
sleep 1
kill "$tail"
read -r _ rc deployed <"$dir/result/status"

if [ "$deployed" = "$sha" ]; then
  echo "::notice::Deployed $sha to hermes."
  exit 0
fi
# Main moved on while this waited: a later commit deployed is this one too.
if [ -n "$deployed" ] && [ "$rc" = 0 ] &&
  [ "$(curl -fsS --max-time 30 "https://api.github.com/repos/$repo/compare/$sha...$deployed" | jq -r .status)" = ahead ]; then
  echo "::notice::Deployed $deployed, which includes $sha."
  exit 0
fi
echo "::error::$sha is not deployed (nixos-deploy exited $rc; deployed: ${deployed:-nothing}). See the log above."
exit 1
