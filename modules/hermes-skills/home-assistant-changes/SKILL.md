---
name: home-assistant-changes
description: Read Home Assistant (ha-get), edit to-do list items (ha-call); change anything else only through a pull request on jzila/home-assistant.
version: 1.7.0
author: John Zila
platforms: [linux]
metadata:
  hermes:
    tags: [home-assistant, github, pull-request]
    category: devops
---

# Home Assistant changes

## Reading: `ha-get`

```sh
ha-get /api/states                     # all entities
ha-get /api/states/sun.sun             # one entity
ha-get /api/components                 # loaded integrations
ha-get '/api/history/period/2026-10-29T00:00:00%2B00:00?filter_entity_id=sun.sun'
ha-get '/api/logbook/2026-10-29T00:00:00%2B00:00?entity=sun.sun'
ha-get /api/config                     # also /api/, /api/services, /api/events, /api/calendars[/<entity>]
```

## To-do items: `ha-call`

List items are data: edit them live when asked, no PR.

```sh
ha-call todo.get_items entity_id=todo.groceries
ha-call todo.add_item entity_id=todo.groceries item="paper towels"
ha-call todo.update_item entity_id=todo.groceries item="paper towels" status=completed
ha-call todo.remove_item entity_id=todo.groceries item="paper towels"
```

Anything else is refused (403); never work around it or ask to widen it. 503
means no token: tell John.

## Changing: a pull request

Nothing else changes Home Assistant live, lists themselves included. Its
configuration (automations, scripts, scenes, helpers, areas, labels,
device/entity settings, `/config` files) changes only through a pull request
on `jzila/home-assistant`, which John approves; anything you'd want to do live
becomes such a PR, or a suggestion to John.

You don't write the change. Your first and only action now is one
`delegate_task` call:

- `goal`: John's request, verbatim.
- `context`: "Follow /var/lib/hermes/.hermes/skills/devops/home-assistant-changes/references/make-pr.md exactly. Return the PR URL and the plan summary from argo's PR comment."
  If the work comes from kanban tasks, add "Kanban: <task IDs>".

Don't read the repository, search files or run commands first. When the
subagent returns, send John the PR link and plan, calling out anything
destroyed or restarted.

After John approves and checks pass: `gh pr merge --merge <PR>`, then tell him
whether the `apply` check on the merge commit passed. If it did, complete the
PR's kanban tasks (its `Kanban:` line) with the PR link.
