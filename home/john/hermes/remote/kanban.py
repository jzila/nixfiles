"""`hermes kanban` on the remote dashboard: upstream's parser, each subcommand mapped onto generated
API operations; a subcommand or flag the API has no equivalent for exits as not available remotely."""

import argparse
import json
import sys
from types import SimpleNamespace

from hermes_cli.kanban import _parse_duration, _parse_workspace_flag
from hermes_cli.kanban_output import _fmt_task_line, _fmt_ts
from hermes_cli.kanban_parser import build_parser


def T(*words):
    return ("kanban", *words)


def task_list(run, a):
    board = run(T("board", "get"), board=a.board, tenant=a.tenant, include_archived=a.archived,
                workflow_template_id=a.workflow_template_id, current_step_key=a.current_step_key)
    tasks = sorted((t for c in board["columns"] for t in c["tasks"]), key=lambda t: (-t["priority"], t["created_at"]))
    tasks = [t for t in tasks if a.status in (None, t["status"]) and a.assignee in (None, t["assignee"])
             and (a.all or (t["status"] != "done" or a.status == "done") and t["priority"] >= 0)]
    if a.json:
        return tasks
    print("\n".join(_fmt_task_line(SimpleNamespace(**t)) for t in tasks) or "(no matching tasks)")


def show(run, a):
    d = run(T("tasks", "get"), task_id=a.task_id, board=a.board, run_state_type=a.state_type, run_state_name=a.state_name)
    if a.json:
        return d
    t = d["task"]
    print(f"Task {t['id']}: {t['title']}")
    for f in ("status", "assignee", "priority", "tenant", "workspace_kind", "branch_name", "model_override"):
        if t.get(f) not in (None, ""):
            print(f"  {f + ':':<16}{t[f]}")
    for title, text in (("Body", t["body"]), ("Result", t["result"] or t["latest_summary"])):
        if text:
            print(f"\n{title}:\n{text}")
    for title, rows, line in (
            ("Comments", d["comments"], lambda c: f"[{_fmt_ts(c['created_at'])}] {c['author']}: {c['body']}"),
            ("Events", d["events"][-20:], lambda e: f"[{_fmt_ts(e['created_at'])}] {e['kind']} {e['payload'] or ''}"),
            ("Runs", d["runs"], lambda r: f"#{r['id']} {r['outcome'] or r['status']} @{r['profile'] or '-'}  "
                                          f"{_fmt_ts(r['started_at'])}  {(r['summary'] or '').partition(chr(10))[0][:160]}")):
        if rows:
            print(f"\n{title} ({len(rows)}):\n" + "\n".join("  " + line(r) for r in rows))


def create(run, a):
    if a.body_file:
        a.body = sys.stdin.read() if a.body_file == "-" else open(a.body_file).read()
    kind, path = _parse_workspace_flag(a.workspace)
    return run(T("tasks", "create"), board=a.board, title=a.title, body=a.body, assignee=a.assignee,
               parents=a.parent, workspace_kind=kind, workspace_path=path, project_id=a.project, tenant=a.tenant,
               priority=a.priority, triage=a.triage, idempotency_key=a.idempotency_key,
               max_runtime_seconds=_parse_duration(a.max_runtime), skills=a.skills or None, goal_mode=a.goal_mode,
               goal_max_turns=a.goal_max_turns, model_override=a.model_override, provider_override=a.provider_override)


def move(status):
    """PATCH each task to `status`; a reason blocks with it, or is a comment before re-opening."""
    def go(run, a):
        reason = " ".join(a.reason) if isinstance(a.reason, list) else a.reason
        out = []
        for tid in [a.task_id, *(a.ids or [])] if "task_id" in a else a.task_ids:
            if reason and status == "ready":
                run(T("tasks", "comments"), board=a.board, task_id=tid, body=reason, author="user")
            out.append(run(T("tasks", "patch"), board=a.board, task_id=tid, status=status,
                           block_reason=None if status == "ready" else reason or None))
        return out
    return go


def archive(run, a):
    out = [run(T("tasks", "bulk"), board=a.board, ids=a.task_ids, archive=True)] if a.task_ids else []
    return out + [run(T("tasks", "delete"), board=a.board, task_id=tid) for tid in a.purge_ids or ()]


def unassigned(profile):
    return "" if profile == "none" else profile


def call(key, **fields):
    """A subcommand that is one operation: each field is a constant or a function of the args."""
    return lambda run, a: run(T(*key), board=a.board, **{k: v(a) if callable(v) else v for k, v in fields.items()})


# subcommand: (handler, its flags with no API equivalent)
COMMANDS = {
    "create": (create, ("branch", "created_by", "max_retries", "completion_contract", "initial_status")),
    "list": (task_list, ("mine", "session", "sort")),
    "show": (show, ()),
    "assign": (call(("tasks", "patch"), task_id=lambda a: a.task_id, assignee=lambda a: unassigned(a.profile)), ()),
    "set-model": (call(("tasks", "patch"), task_id=lambda a: a.task_id, provider_override=lambda a: a.provider,
                       model_override=lambda a: None if a.model in (None, "none") else a.model,
                       clear_model_override=lambda a: a.model in (None, "none")), ()),
    "reclaim": (call(("tasks", "reclaim"), task_id=lambda a: a.task_id, reason=lambda a: a.reason), ()),
    "reassign": (call(("tasks", "reassign"), task_id=lambda a: a.task_id, profile=lambda a: unassigned(a.profile),
                      reclaim_first=lambda a: a.reclaim, reason=lambda a: a.reason), ()),
    "diagnostics": (call(("diagnostics", "get"), severity=lambda a: a.severity, task_id=lambda a: a.task), ()),
    "link": (call(("links", "create"), parent_id=lambda a: a.parent_id, child_id=lambda a: a.child_id), ()),
    "unlink": (call(("links", "delete"), parent_id=lambda a: a.parent_id, child_id=lambda a: a.child_id), ()),
    "comment": (call(("tasks", "comments"), task_id=lambda a: a.task_id, author=lambda a: a.author or "user",
                     body=lambda a: " ".join(a.text)[:a.max_len]), ()),
    "attach": (call(("tasks", "attachments", "create"), task_id=lambda a: a.task_id, uploaded_by=lambda a: a.author,
                    file=lambda a: (a.name or a.path.rsplit("/", 1)[-1], a.content_type, open(a.path, "rb").read())), ()),
    "attachments": (call(("tasks", "attachments", "get"), task_id=lambda a: a.task_id), ()),
    "attach-rm": (call(("attachments", "delete"), attachment_id=lambda a: a.attachment_id), ()),
    # The API completes over a live claim either way, so --force changes nothing.
    "complete": (call(("tasks", "bulk"), ids=lambda a: a.task_ids, status="done", result=lambda a: a.result,
                      summary=lambda a: a.summary, metadata=lambda a: a.metadata and json.loads(a.metadata)), ()),
    "edit": (call(("tasks", "patch"), task_id=lambda a: a.task_id, title=lambda a: a.title, body=lambda a: a.body,
                  priority=lambda a: a.priority), ("result", "summary", "metadata")),
    "block": (move("blocked"), ("kind",)),
    "schedule": (move("scheduled"), ()),
    "unblock": (move("ready"), ()),
    "request-review": (call(("tasks", "patch"), task_id=lambda a: a.task_id, status="review",
                            summary=lambda a: a.summary, assignee=lambda a: a.reviewer,
                            metadata=lambda a: a.metadata and json.loads(a.metadata)), ()),
    "reopen-review": (move("ready"), ()),
    "promote": (move("ready"), ("reason", "dry_run")),
    "archive": (archive, ()),
    "dispatch": (call(("dispatch",), dry_run=lambda a: a.dry_run, max=lambda a: a.max), ("failure_limit",)),
    "stats": (call(("stats", "get")), ()),
    "log": (lambda run, a: print(run(T("tasks", "log", "get"), task_id=a.task_id, board=a.board, tail=a.tail)["content"],
                                 end=""), ()),
    "runs": (lambda run, a: run(T("tasks", "get"), task_id=a.task_id, board=a.board, run_state_type=a.state_type,
                                run_state_name=a.state_name)["runs"], ()),
    "assignees": (call(("assignees", "get")), ()),
    "specify": (call(("tasks", "specify"), task_id=lambda a: a.task_id, author=lambda a: a.author), ("all_triage", "tenant")),
    "decompose": (call(("tasks", "decompose"), task_id=lambda a: a.task_id, author=lambda a: a.author),
                  ("all_triage", "tenant")),
}
BOARDS = {
    "list": (call(("boards", "list"), include_archived=lambda a: a.all), ()),
    "create": (call(("boards", "create"), slug=lambda a: a.slug, name=lambda a: a.name, icon=lambda a: a.icon,
                    description=lambda a: a.description, color=lambda a: a.color, switch=lambda a: a.switch,
                    default_workdir=lambda a: a.default_workdir), ()),
    "rm": (call(("boards", "delete"), slug=lambda a: a.slug, delete=lambda a: a.delete), ()),
    "switch": (call(("boards", "switch"), slug=lambda a: a.slug), ()),
    "show": (lambda run, a: print(run(T("boards", "list"))["current"]), ()),
    "rename": (call(("boards", "patch"), slug=lambda a: a.slug, name=lambda a: a.name), ()),
    "set-default-workdir": (call(("boards", "patch"), slug=lambda a: a.slug, default_workdir=lambda a: a.path or ""), ()),
}


def subcommands(parser):
    return next(a for a in parser._actions if isinstance(a, argparse._SubParsersAction))


def bind(parser, name, handler, unsupported, run):
    def go(a):
        for dest in unsupported:
            if getattr(a, dest) not in (None, False, [], parser.get_default(dest)):
                flag = next((x.option_strings or [x.dest])[0] for x in parser._actions if x.dest == dest)
                sys.exit(f"hermes kanban {name} {flag}: not available remotely")
        return handler(run, a)
    parser.set_defaults(_run=go)


def register(sub, run):
    """Add `kanban` to `sub`; returns its subcommands, for the generated operations to join."""
    kanban = build_parser(sub)
    actions = subcommands(kanban)
    actions.choices["list"].add_argument("--all", action="store_true", help="Include done and priority < 0 tasks")
    # Boards come second so that their group keeps its help over the "not available" default.
    for parser, table, prefix in ((kanban, COMMANDS, ""), (actions.choices["boards"], BOARDS, "boards ")):
        parser.set_defaults(_run=lambda a, p=parser: p.print_help())
        choices = subcommands(parser).choices
        for name, p in choices.items():
            p.set_defaults(_run=lambda a, n=prefix + name: sys.exit(f"hermes kanban {n}: not available remotely"))
        for name, (handler, unsupported) in table.items():
            bind(choices[name], prefix + name, handler, unsupported, run)
    return actions
