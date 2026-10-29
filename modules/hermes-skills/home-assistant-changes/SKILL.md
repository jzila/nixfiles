---
name: home-assistant-changes
description: Read Home Assistant's state through the read-only proxy (ha-get); change anything only through a pull request on jzila/home-assistant.
version: 1.5.0
author: John Zila
platforms: [linux]
metadata:
  hermes:
    tags: [home-assistant, github, pull-request]
    category: devops
---

# Home Assistant changes

## Reading: `ha-get`, read-only

You can read Home Assistant, nothing more. `ha-get` sends a GET through a
read-only proxy outside your container, which adds the token (you never have
one, and can't reach Home Assistant any other way):

```sh
ha-get /api/states                     # all entities
ha-get /api/states/sun.sun             # one entity
ha-get /api/components                 # loaded integrations
ha-get '/api/history/period/2026-10-29T00:00:00%2B00:00?filter_entity_id=sun.sun'
ha-get '/api/logbook/2026-10-29T00:00:00%2B00:00?entity=sun.sun'
ha-get /api/config                     # also /api/, /api/services, /api/events, /api/calendars[/<entity>]
```

Only those endpoints, GET only. Everything else is refused (403/405) on
purpose: service calls, POSTs, the WebSocket API, templates, add-ons, auth.
A 503 means no token is installed yet: tell John. Never try another way
around it, and never ask for the proxy to be widened (no issue, task or PR
for that): it stays read-only by design.

## Changing: a pull request

Nothing changes Home Assistant live: not devices, not services, not
configuration. Its configuration (automations, scripts, scenes, helpers,
areas, labels, device/entity settings, `/config` files) changes only through a
pull request on `jzila/home-assistant`, which John approves; anything you'd
want to do live becomes such a PR, or a suggestion to John.

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
