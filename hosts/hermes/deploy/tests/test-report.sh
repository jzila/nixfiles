#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub bodies expand when they run
# report.sh (nixos-deploy-report), against hermes's kanban CLI with the board
# in $T/board.json. Run: bash hosts/hermes/deploy/tests/test-report.sh
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

stub hermes 'echo "hermes $*" >>"$T/calls"; [ "$2" = list ] && cat "$T/board.json"; true'

# scenario NAME VERDICT BOARD: the report's first line and the open tasks.
scenario() {
  name=$1
  fresh
  printf '%s\n' "$2" >"$T/report.md"
  printf '%s\n' "$3" >"$T/board.json"
}
rep() { script report.sh "$T/report.md"; }

failed="Failed to deploy $B to hermes at now: x"
task='{"id": "t_1", "title": "hermes deploy: main failed to deploy", "tenant": null, "created_by": "nixos-deploy", "status": "ready", "created_at": 1, "body": "old"}'
other='{"id": "t_2", "title": "hermes deploy: x", "tenant": "hass", "created_by": "nixos-deploy", "status": "ready", "created_at": 1, "body": ""}'
scenario "first failure" "$failed" "[$other]"; rep
expect_rc 0; expect_call "hermes kanban create --created-by nixos-deploy --body-file"; expect_no_call "edit"
scenario "another failure" "$failed" "[$task]"; rep
expect_rc 0; expect_call "hermes kanban edit t_1"; expect_no_call "create"
scenario "same failure" "$failed" "[$(jq -c --arg b "$failed" '.body = $b' <<<"$task")]"; rep
expect_rc 0; expect_no_call "edit"; expect_no_call "create"
scenario "deployed" "Deployed $B to hermes at 2026-10-24T12:00:00-05:00." "[$task, $other]"; rep
expect_rc 0; expect_call "hermes kanban complete t_1 --result Deployed main bbbbbbbbbbbb"; expect_no_call "t_2"
scenario "garbage" nonsense "[]"; rep
expect_rc 1

summary
