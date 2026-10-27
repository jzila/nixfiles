# Making a nixfiles PR

`git` and `gh` are authenticated as the `zila-hermes` app.

1. Workspace: `/var/lib/hermes/workspace/nixfiles` (if missing,
   `gh repo clone jzila/nixfiles` there). Discard leftovers from earlier work
   (`git reset --hard && git clean -fd`), `git fetch origin`, then
   `git switch -c <branch> origin/main`. Never branch from another branch.
2. Read `AGENTS.md` and follow it, except that this clone needs no worktree.
   Match the style of the files around the change and change the smallest set
   of files. Never edit `.github/`.
3. You can't build: CI checks the PR (`Build NixOS` for each host).
4. Commit, push, `gh pr create`, then watch `gh pr checks` and fix what fails. argo is John's daily driver: a merged
   change reaches it only when John rebuilds argo. The Hermes VM (`hosts/hermes/`
   and the modules it imports, yours included) deploys main to itself as soon as
   CI passes on the merge. Either way the description says what could break and
   how he would notice. If the context names kanban tasks, it also gets the line
   `Kanban: t_xxxxxxxx` (comma-separated IDs). Return the PR URL, a summary
   and the risk.
