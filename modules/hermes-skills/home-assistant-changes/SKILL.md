---
name: home-assistant-changes
description: Change Home Assistant's configuration through a pull request on jzila/home-assistant.
version: 1.2.0
author: John Zila
platforms: [linux]
metadata:
  hermes:
    tags: [home-assistant, github, pull-request]
    category: devops
---

# Home Assistant changes

Home Assistant's configuration (automations, scripts, scenes, helpers, areas,
labels, device/entity settings, `/config` files) lives in `jzila/home-assistant`.
Change it only through a pull request there, never through Home Assistant's API
or UI. Controlling devices and reading states is fine as usual.

`git` and `gh` are authenticated as the `zila-hermes` app. Hand steps 1–3 to a
subagent with `delegate_task` (it runs on the coding model), passing John's
request and these steps; relay its PR and plan to John, and do step 4 yourself.

1. In `/var/lib/hermes/workspace/home-assistant` (clone it if missing), branch
   from the latest `origin/main`.
2. Follow the README's pattern, and change the smallest set of files. Leave
   `flake.*`, `.github/`, `tools/` and `ssh-gate/` alone unless asked.
3. Push and open the PR. Argo comments the plan within minutes; send John the
   PR link and its summary, calling out anything destroyed or restarted.
4. Once John approves and checks pass, `gh pr merge --merge`, then tell him
   whether the `apply` check on the merge commit passed.
