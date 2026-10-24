# nixos-deploy-report: reconcile nixos-deploy's verdict with the kanban board,
# like ha-drift-report: one open, untenanted "argo deploy:" task by
# nixos-deploy, its body refreshed by a later failure, completed by the next
# deploy. Runs as hermes, never as root. Runs under writeShellApplication.
report=$1
title="argo deploy: main failed to deploy"
verdict=$(head -n 1 "$report")
open=$(hermes kanban list --json | jq -c '[.[]
  | select(.tenant == null and .created_by == "nixos-deploy" and (.title | startswith("argo deploy:")))
  | select(.status != "done" and .status != "archived")]')

if [[ $verdict =~ ^Failed\ to\ deploy\ [0-9a-f]{40}\  ]]; then
  task=$(jq -c 'max_by(.created_at) // empty' <<<"$open")
  if [ -z "$task" ]; then
    # No --idempotency-key: it would also match an earlier, completed task.
    hermes kanban create --created-by nixos-deploy --body-file "$report" "$title"
  elif [ "$(jq -r .body <<<"$task")" != "$(cat "$report")" ]; then
    hermes kanban edit "$(jq -r .id <<<"$task")" --body "$(cat "$report")"
  fi
elif [[ $verdict =~ ^Deployed\ ([0-9a-f]{40})\ to\ ([^\ ]+)\ at\ ([^\ ]+)\.$ ]]; then
  result="Deployed main ${BASH_REMATCH[1]:0:12} to ${BASH_REMATCH[2]} at ${BASH_REMATCH[3]}."
  for id in $(jq -r '.[].id' <<<"$open"); do
    hermes kanban complete "$id" --result "$result"
  done
else
  echo "nixos-deploy-report: unrecognised verdict: $verdict" >&2
  exit 1
fi
