# hermes-health: is Hermes working? nixos-deploy's extra health check after a
# switch (NIXOS_DEPLOY_CHECK). Prints each problem and fails if there is one.
# Runs under writeShellApplication (errexit, nounset, pipefail).
#   HERMES_HEALTH_IN        command prefix that runs a command in Hermes's
#                           container ("nixos-container run hermes --"); empty
#                           runs it here
#   HERMES_HEALTH_CURL      curl, as a path the container can run
#   HERMES_HEALTH_UNITS     units in the container that must be active (unless
#                           their start condition is false)
#   HERMES_HEALTH_STATE     Hermes's gateway_state.json (the shared state)
#   HERMES_HEALTH_SIGNAL    signal-cli's accounts.json
#   HERMES_HEALTH_WEBHOOK   the webhook receiver's URL, in the container
#   HERMES_HEALTH_OLLAMA    ollama's version URL, on argo (set by deploy.nix)
read -ra sandbox <<<"${HERMES_HEALTH_IN:-}"
curl=${HERMES_HEALTH_CURL:-curl}
units=${HERMES_HEALTH_UNITS:-signal-cli.service nginx.service}
gw=${HERMES_HEALTH_STATE:-/var/lib/hermes/.hermes/gateway_state.json}
accounts=${HERMES_HEALTH_SIGNAL:-/var/lib/signal-cli/data/accounts.json}
webhook=${HERMES_HEALTH_WEBHOOK:-http://127.0.0.1:8644/}
ollama=${HERMES_HEALTH_OLLAMA:-http://192.168.1.237:11434/api/version}

p=()
pid=$("${sandbox[@]}" systemctl show -P MainPID hermes-agent.service)
if [ "${pid:-0}" = 0 ]; then
  p+=("the gateway isn't running")
elif ! jq -e --argjson pid "$pid" '.pid == $pid' "$gw" >/dev/null 2>&1; then
  p+=("the gateway (pid $pid) hasn't written its state yet")
else
  [ "$(jq -r .gateway_state "$gw")" = running ] || p+=("the gateway is $(jq -r .gateway_state "$gw")")
  [ "$(jq -r .platforms.webhook.state "$gw")" = connected ] ||
    p+=("the webhook platform is $(jq -r .platforms.webhook.state "$gw")")
  # Only once a Signal account is registered (not in a fresh VM).
  if jq -e '.accounts | length > 0' "$accounts" >/dev/null 2>&1; then
    [ "$(jq -r .platforms.signal.state "$gw")" = connected ] ||
      p+=("Signal is $(jq -r .platforms.signal.state "$gw")")
  fi
fi
for u in $units; do
  [ "$("${sandbox[@]}" systemctl show -P ConditionResult "$u")" = no ] && continue
  "${sandbox[@]}" systemctl is-active --quiet "$u" >/dev/null ||
    p+=("$u is $("${sandbox[@]}" systemctl is-active "$u" || true)")
done
code=$("${sandbox[@]}" "$curl" -s --max-time 10 -o /dev/null -w '%{http_code}' "$webhook" || true)
[ "${code:-000}" != 000 ] || p+=("nothing listens at $webhook")
"${sandbox[@]}" "$curl" -fs --max-time 10 -o /dev/null "$ollama" || p+=("ollama on argo is unreachable")

if [ ${#p[@]} -gt 0 ]; then
  out=$(printf '%s; ' "${p[@]}")
  echo "${out%; }"
  exit 1
fi
