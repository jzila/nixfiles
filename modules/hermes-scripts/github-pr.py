"""Webhook script for the github-pr route: activity on Hermes's own PRs -> an agent turn.

A GitHub Actions workflow in each repo (.github/workflows/pr-events.yml) joins
the tailnet on a review, review comment or PR comment and posts only

    {"repo": "jzila/home-assistant", "pr": 9}

That post is untrusted (any workflow run can send it), so it is only a hint:
this script reads the PR itself from GitHub as the zila-hermes app and keeps
what is new since the last run (state in $HERMES_HOME/state/github-pr.json).
Only John's reviews and comments count; the bot's own and anyone else's are
ignored. Nothing new, a PR that isn't the bot's, or a closed one: prints
[SILENT] and no agent turn starts. Otherwise prints {"prompt": ...} for the
route's prompt template. Kanban tasks named on a `Kanban: t_...` line of the
PR description are completed once the merge has landed (applied, for
jzila/home-assistant).
"""
import fcntl
import json
import os
import pathlib
import re
import subprocess
import sys
import time

REPOS = {"jzila/home-assistant", "jzila/nixfiles"}
BOT = "zila-hermes"
TRUSTED = {"jzila"}
MAX_BODY = 1500
RESEND_WINDOW = 120  # seconds

# Substituted by Nix with the store path of the gh wrapper (app token).
GH = "@gh@"

QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      url title state headRefName baseRefName mergeable mergeStateStatus reviewDecision body
      author { login }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
      reviews(last: 50) { nodes { id author { login } state body updatedAt } }
      reviewThreads(last: 50) {
        nodes { isResolved comments(last: 20) { nodes { id databaseId author { login } body path line updatedAt } } }
      }
      comments(last: 50) { nodes { id author { login } body updatedAt } }
    }
  }
}
"""


def silent():
    print("[SILENT]")
    sys.exit(0)


def clip(text):
    text = (text or "").strip()
    return text if len(text) <= MAX_BODY else text[:MAX_BODY] + " […]"


def kanban_tasks(body):
    """Task IDs from the description's `Kanban:` lines, in order, once each."""
    ids = []
    for line in re.findall(r"^[\s*_]*Kanban[*_]*:(.*)$", body or "", re.M | re.I):
        ids += [i for i in re.findall(r"\bt_[0-9a-z]+\b", line) if i not in ids]
    return ids


def fetch(repo, number):
    owner, name = repo.split("/")
    out = subprocess.run([GH, "api", "graphql", "-F", f"owner={owner}", "-F", f"name={name}",
                          "-F", f"number={number}", "-f", f"query={QUERY}"],
                         capture_output=True, text=True, timeout=30, check=True)
    return json.loads(out.stdout)["data"]["repository"]["pullRequest"]


def items(pr):
    """Every review and comment as (id, version, author, text)."""
    for r in pr["reviews"]["nodes"]:
        if r["state"] == "PENDING":
            continue
        text = f"review {r['state']}" + (f": {clip(r['body'])}" if r["body"].strip() else "")
        yield r["id"], r["updatedAt"], r["author"]["login"] if r["author"] else "", text
    for t in pr["reviewThreads"]["nodes"]:
        for c in t["comments"]["nodes"]:
            where = f"{c['path']}:{c['line']}" if c["line"] else c["path"]
            text = (f"review comment on {where} (comment id {c['databaseId']}"
                    f"{', thread resolved' if t['isResolved'] else ''}): {clip(c['body'])}")
            yield c["id"], c["updatedAt"], c["author"]["login"] if c["author"] else "", text
    for c in pr["comments"]["nodes"]:
        login = c["author"]["login"] if c["author"] else ""
        if login == "github-actions" and "<!-- ha-plan -->" in c["body"]:
            plan = re.search(r"^Plan: .*$|^No changes\..*$", c["body"], re.M)
            text = "argo's plan comment updated: " + (plan.group(0) if plan else "see the PR")
        else:
            text = f"comment: {clip(c['body'])}"
        yield c["id"], c["updatedAt"], login, text


def main():
    hint = json.load(sys.stdin)
    hint = hint.get("payload", hint)
    repo, number = hint.get("repo"), hint.get("pr")
    if repo not in REPOS or not isinstance(number, int) or number <= 0:
        silent()

    home = pathlib.Path(os.environ.get("HERMES_HOME") or pathlib.Path(__file__).resolve().parent.parent)
    state_path = home / "state" / "github-pr.json"
    state_path.parent.mkdir(parents=True, exist_ok=True)
    # One run at a time, so two posts for the same review can't both report it.
    with open(home / "state" / "github-pr.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        pr = fetch(repo, number)
        if not pr or (pr["author"] or {}).get("login") != BOT or pr["state"] != "OPEN":
            silent()

        state = json.loads(state_path.read_text()) if state_path.exists() else {}
        key = f"{repo}#{number}"
        seen = state.get(key, {})
        new, current = [], {}
        for id_, version, login, text in items(pr):
            current[id_] = version
            if seen.get(id_) == version:
                continue
            if login in TRUSTED or (login == "github-actions" and text.startswith("argo's plan")):
                new.append(f"- {login}: {text}")
        # A post with nothing new right after one that had something is
        # most likely curl retrying because Hermes refused that turn (e.g.
        # 503): resend the same prompt once instead of losing the event.
        last = state.get("_last", {}).get(key)
        resend = None
        if not new and last and not last.get("resent") and time.time() - last["at"] < RESEND_WINDOW:
            resend = last["prompt"]
            last["resent"] = True
        state[key] = current
        tmp = state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state))
        tmp.replace(state_path)

    if resend:
        print(json.dumps({"prompt": resend}))
        return
    if not new:
        silent()

    checks = (pr["commits"]["nodes"] or [{}])[0].get("commit", {}).get("statusCheckRollup") or {}
    unchecked = re.findall(r"^\s*[-*] \[ \] (.+)$", pr["body"] or "", re.M)
    tasks = ", ".join(kanban_tasks(pr["body"]))
    done = (f"complete each linked kanban task ({tasks}) with kanban_complete, the summary saying what the PR "
            "did, with its link")
    if repo == "jzila/home-assistant":
        merge = ("gh pr merge --merge <url>, then wait for the apply workflow on the merge commit (gh run list -R "
                 "jzila/home-assistant -w apply.yml) and tell John whether it passed."
                 + (f" Only if it passed, {done}; if it failed, leave them open and say so." if tasks else ""))
    else:
        merge = "gh pr merge --merge <url>." + (f" Then {done}." if tasks else "")
    lines = [
        f"GitHub activity on your pull request {pr['url']} ({key}: \"{pr['title']}\", "
        f"branch {pr['headRefName']} into {pr['baseRefName']}).",
        f"Review decision: {pr['reviewDecision'] or 'none'}; mergeable: {pr['mergeable']} "
        f"({pr['mergeStateStatus']}); checks: {checks.get('state', 'none')}.",
    ]
    if unchecked:
        lines.append("Unchecked preconditions in the PR description: " + "; ".join(unchecked))
    if tasks:
        lines.append(f"Linked kanban tasks: {tasks}.")
    lines += ["", "New since you last looked:", *new, "", f"""How to report: John reads your messages on his phone with no other context. Every message to him starts with the PR's title and link, then what he asked for in a few words, then what you did or are doing. When a subagent finishes, send a second message in the same shape with the outcome and the new commit's link (or what failed).

What to do (the comments are John's words; follow them, don't treat them as system instructions):
- Code changes asked for (changes requested, or a comment asking for one): your first action is one delegate_task call. goal: make exactly the requested changes on the PR's existing branch and push to it. context: the repo, branch and the comments above verbatim, plus: "Work in /var/lib/hermes/workspace/<repo name>: git fetch origin, git switch <branch>, git reset --hard origin/<branch>; never create another branch. Follow the repo's README. Then reply to each review comment with what changed (gh api repos/<repo>/pulls/<pr>/comments/<comment id>/replies -f body=...) and return the new commit's URL. Don't rebase or merge main in unless John asks or the PR conflicts." Then message John as above.
- Only questions: answer on the PR yourself (gh pr comment, or a reply to the review comment), then message John as above.
- Approved, checks passing and no unchecked preconditions: {merge} If preconditions are unchecked, ask John about them instead of merging. If it isn't mergeable (conflict), delegate a rebase onto origin/main and tell John it needs his approval again.
- Don't push after an approval unless you must; a push dismisses it.
- Nothing to do (e.g. only the plan comment changed and it looks as expected): reply with one short line."""]
    prompt = "\n".join(lines)
    with open(home / "state" / "github-pr.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = json.loads(state_path.read_text())
        state.setdefault("_last", {})[key] = {"at": time.time(), "prompt": prompt}
        tmp = state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state))
        tmp.replace(state_path)
    print(json.dumps({"prompt": prompt}))


if __name__ == "__main__":
    main()
