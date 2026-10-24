# Making a Home Assistant PR

`git` and `gh` are authenticated as the `zila-hermes` app.

1. Workspace: `/var/lib/hermes/workspace/home-assistant` (if missing,
   `gh repo clone jzila/home-assistant` there). Discard leftovers from earlier
   work (`git reset --hard && git clean -fd`), `git fetch origin`, then
   `git switch -c <branch> origin/main`. Never branch from another branch.
2. Read `README.md` and follow its pattern. Change the smallest set of files.
   Leave `flake.*`, `.github/`, `tools/` and `ssh-gate/` alone.
3. Commit, push, `gh pr create`. If the context names kanban tasks, the
   description gets the line `Kanban: t_xxxxxxxx` (comma-separated IDs). Wait
   for argo's plan comment (`<!-- ha-plan -->`, a few minutes) and return the
   PR URL and the plan summary.
