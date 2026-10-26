---
name: nixfiles-changes
description: Change argo, your own setup or John's other machines through a pull request on jzila/nixfiles.
version: 1.0.0
author: John Zila
platforms: [linux]
metadata:
  hermes:
    tags: [nixos, github, pull-request]
    category: devops
---

# nixfiles changes

argo, your own setup (container, tools, skills, webhook scripts) and John's
other machines change only through a pull request on `jzila/nixfiles`, never
by editing files or running commands on the machines.

You don't write the change. Your first and only action now is one
`delegate_task` call:

- `goal`: John's request, verbatim.
- `context`: "Follow /var/lib/hermes/.hermes/skills/devops/nixfiles-changes/references/make-pr.md exactly. Return the PR URL, what the change does, and its risk."
  If the work comes from kanban tasks, add "Kanban: <task IDs>".

Don't read the repository, search files or run commands first. When the
subagent returns, send John the PR link, a summary and the risk.

After John approves and checks pass: `gh pr merge --merge <PR>`, then complete
the PR's kanban tasks (its `Kanban:` line) with the PR link.
