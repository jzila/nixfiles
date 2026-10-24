# Making a nixfiles PR

`git` and `gh` are authenticated as the `zila-hermes` app.

1. Workspace: `/var/lib/hermes/workspace/nixfiles` (if missing,
   `gh repo clone jzila/nixfiles` there). Discard leftovers from earlier work
   (`git reset --hard && git clean -fd`), `git fetch origin`, then
   `git switch -c <branch> origin/main`. Never branch from another branch.
2. Read `AGENTS.md` and follow it, except that this clone needs no worktree.
   Match the style of the files around the change and change the smallest set
   of files. Never edit `.github/`.
3. If `nix` is on PATH, run
   `nix build --no-link .#nixosConfigurations.argo.config.system.build.toplevel`
   (and the same for any other host you changed) and fix any failure.
   Otherwise CI checks it.
4. Commit, push, `gh pr create`. argo is John's daily driver: a merged
   change reaches it only when John rebuilds argo, so the description says
   what could break and how he would notice. If the context names kanban tasks, it also gets the line
   `Kanban: t_xxxxxxxx` (comma-separated IDs). Return the PR URL, a summary
   and the risk.
