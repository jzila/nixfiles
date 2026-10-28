#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub bodies expand when they run
# health.sh (hermes-health), against stubs of systemctl, curl and the
# container's command prefix, with the gateway's state in $T/gw.json.
# Run: bash hosts/hermes/deploy/tests/test-health.sh
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# inside: Hermes's container (nixos-container run hermes --), logged and run here.
stub inside 'echo "inside $*" >>"$T/calls"; shift; exec "$@"'

gw() { # gateway_state signal_state [pid]
  jq -n --arg g "$1" --arg s "$2" --argjson pid "${3:-42}" \
    '{pid: $pid, gateway_state: $g, platforms: {webhook: {state: "connected"}, signal: {state: $s}}}' >"$T/gw.json"
}
signal_account() { echo '{"accounts": [{"number": "x"}]}' >"$T/accounts.json"; }
# A new case: the gateway (pid 42) running, everything connected, no Signal
# account yet.
scenario() {
  name=$1
  fresh
  echo 42 >"$T/mainpid"
  gw running connected
}
health() { script health.sh HERMES_HEALTH_STATE="$T/gw.json" HERMES_HEALTH_SIGNAL="$T/accounts.json" "$@"; }

scenario "fresh VM, no Signal account"; gw running disconnected; health
expect_rc 0

scenario "healthy with an account"; signal_account; health
expect_rc 0

scenario "Signal down"; signal_account; gw running disconnected; health
expect_rc 1; expect_out "Signal is disconnected"

scenario "gateway not running"; echo 0 >"$T/mainpid"; health
expect_rc 1; expect_out "gateway isn't running"

scenario "stale state file"; gw running connected 7; health
expect_rc 1; expect_out "hasn't written its state"

scenario "gateway stopping"; gw stopping connected; health
expect_rc 1; expect_out "gateway is stopping"

scenario "no receiver, no ollama"; touch "$T/webhook-down" "$T/ollama-down"; health
expect_rc 1; expect_out "nothing listens at http://127.0.0.1:8644/; ollama on argo is unreachable"

scenario "signal-cli down"; echo signal-cli.service >"$T/inactive"; health
expect_rc 1; expect_out "signal-cli.service is inactive"

scenario "nginx waiting for its certificate"; echo nginx.service >"$T/condfail"; health
expect_rc 0

scenario "nginx down with its certificate"; echo nginx.service >"$T/inactive"; health
expect_rc 1; expect_out "nginx.service is inactive"

scenario "checks inside the container"; health HERMES_HEALTH_IN="$T/bin/inside --" HERMES_HEALTH_CURL=curl
expect_rc 0; expect_call "inside -- systemctl show -P MainPID hermes-agent.service"
expect_call "inside -- systemctl is-active --quiet signal-cli.service"
expect_call "inside -- curl -s --max-time 10"; expect_call "inside -- curl -fs --max-time 10"

scenario "ollama unreachable from inside"; touch "$T/ollama-down"; health HERMES_HEALTH_IN="$T/bin/inside --"
expect_rc 1; expect_out "ollama on argo is unreachable"

summary
