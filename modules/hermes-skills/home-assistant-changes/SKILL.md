---
name: home-assistant-changes
description: Change Home Assistant's configuration by opening a pull request on jzila/home-assistant, report argo's plan, and merge once John approves.
version: 1.0.0
author: John Zila
platforms: [linux]
metadata:
  hermes:
    tags: [home-assistant, github, pull-request]
    category: devops
---

# Home Assistant changes

Home Assistant's configuration is declared in git: the private repo
`jzila/home-assistant`. Argo plans every pull request against live Home
Assistant and posts the plan as a PR comment; a merge to `main` is applied
automatically. **Every configuration change goes through a pull request.** Never
change Home Assistant's configuration through its API or UI yourself.
Turning things on or off, running scripts or reading states are not
configuration changes and stay as they are.

## When to use

John asks for a change to automations, scripts, scenes, helpers (`input_*`),
floors, areas, labels, device or entity names/areas/labels, or the YAML files
Home Assistant reads from `/config`.

## Access

You act as the GitHub App `zila-hermes`. `git` and `gh` are already
authenticated (a token from the host, refreshed every 30 minutes). You can push
branches, open and comment on PRs, read checks, and merge a PR **after John
approves it**. You cannot change workflows (`.github/`), and `main` only accepts
PRs.

## Steps

1. **Checkout.** Keep a clone at `/var/lib/hermes/workspace/home-assistant`
   (`git clone https://github.com/jzila/home-assistant.git` if missing). For each
   change, start a branch from the latest main:
   `git fetch origin && git switch -c hermes/<short-slug> origin/main`.
2. **Read the README first.** The pattern matters:
   - every resource is an HCL `resource` or `module` block under `tofu/`, one
     module per directory; YAML is only the body of an automation, script or
     scene, next to its `.tf`;
   - a fact is written once: things that belong to a feature (e.g. the shade
     zones in `tofu/features/shades/zones.tf`) are changed there, never as a
     separate resource;
   - `config/` mirrors files in `/config`; only paths in `config/manifest.yaml`
     are used.
3. **Edit** the smallest set of files that makes the change. Match the
   surrounding style. Don't touch `flake.nix`, `flake.lock`, `.github/`, `tools/`
   or `ssh-gate/` unless John asked for exactly that: argo won't plan such PRs.
4. **Commit** with a plain, descriptive message (what and why), push the branch,
   and open the PR with `gh pr create --fill` or a short body explaining the
   change.
5. **Wait for the plan.** Argo's `plan` check runs within a few minutes and posts
   a comment starting with `<!-- ha-plan -->`
   (`gh pr view <n> --comments`). Report to John: the PR link, the plan summary
   (`Plan: X to add, Y to change, Z to destroy`, or "No changes"), and anything
   surprising (destroys, a restart in the `config/` section, an unrelated
   change). If the plan fails, read it, fix the branch, push, and report again.
6. **Merge after approval only.** When John has approved
   (`gh pr view <n> --json reviewDecision` is `APPROVED`) and the checks pass,
   merge with `gh pr merge <n> --merge`. Never push to the branch after John
   approves: a new push needs a new approval. If he asks for changes, push them
   and go back to step 5.
7. **Confirm the apply.** The merge starts the `apply` check on the merge commit
   (`gh api repos/jzila/home-assistant/commits/<sha>/check-runs`). Tell John
   whether it succeeded; if it failed, say so with the check's name and URL.

## Don't

- Don't change Home Assistant configuration any other way, even to "fix it
  quickly".
- Don't merge without John's approval, and don't ask anyone else to approve.
- Don't put secrets in the repo: Home Assistant's `secrets.yaml`, tokens or keys
  never belong there.
