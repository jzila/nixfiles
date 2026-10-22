---
name: home-assistant-changes
description: Change Home Assistant's configuration through a pull request on jzila/home-assistant.
version: 1.3.0
author: John Zila
platforms: [linux]
metadata:
  hermes:
    tags: [home-assistant, github, pull-request]
    category: devops
---

# Home Assistant changes

Home Assistant's configuration (automations, scripts, scenes, helpers, areas,
labels, device/entity settings, `/config` files) changes only through a pull
request on `jzila/home-assistant`, never through Home Assistant's API or UI.
Controlling devices and reading states is fine as usual.

You don't write the change. Your first and only action now is one
`delegate_task` call:

- `goal`: John's request, verbatim.
- `context`: "Follow /var/lib/hermes/.hermes/skills/devops/home-assistant-changes/references/make-pr.md exactly. Return the PR URL and the plan summary from argo's PR comment."

Don't read the repository, search files or run commands first. When the
subagent returns, send John the PR link and plan, calling out anything
destroyed or restarted.

After John approves and checks pass: `gh pr merge --merge <PR>`, then tell him
whether the `apply` check on the merge commit passed.
