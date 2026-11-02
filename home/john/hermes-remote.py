"""`hermes` on argo (hermes.nix): Hermes on the hermes VM, through its dashboard.

`login`: the dashboard's native-app sign-in (RFC 8252, through its OIDC provider) with a loopback
redirect; the tokens go to a 0600 file and are refreshed when near expiry or rejected.
`<namespace> …` (kanban, cron, sessions, …): a CLI generated from the dashboard's OpenAPI spec, one
command per operation, named from its path and method (`kanban tasks get <id>`). `kanban` also takes
Hermes's own `hermes kanban` subcommands (its parser), mapped onto those operations, since Hermes's
CLI only works on the VM's databases; a generated name they shadow is under `api kanban …`, the
plain generated tree. Anything else is the TUI, attached with a single-use WebSocket ticket.
"""

import argparse
import base64
import hashlib
import http.server
import json
import mimetypes
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path
from types import SimpleNamespace

from hermes_cli import kanban as k, kanban_db as kb, kanban_parser
from hermes_cli.kanban_output import _fmt_task_line

BASE = os.environ["HERMES_REMOTE_URL"]
STATE = Path(os.environ["HERMES_REMOTE_STATE"])
TOKENS, SPEC = STATE / "tokens.json", STATE / "openapi.json"
VERBS = {"get": "get", "post": "create", "put": "set", "patch": "patch", "delete": "delete"}
BOARD = None


def multipart(fields, boundary):
    out = b""
    for name, value in fields.items():
        head = ""
        if isinstance(value, tuple):
            filename, ctype, value = value
            head = f'; filename="{filename}"\r\nContent-Type: {ctype}'
        elif not isinstance(value, bytes):
            value = str(value).encode()
        out += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"{head}\r\n\r\n'.encode() + value + b"\r\n"
    return out + f"--{boundary}--\r\n".encode()


def request(method, path, body=None, bearer=None, form=None):
    headers, data = {}, None
    if form is not None:
        boundary = secrets.token_hex(16)
        data, headers["Content-Type"] = multipart(form, boundary), f"multipart/form-data; boundary={boundary}"
    elif body is not None:
        data, headers["Content-Type"] = json.dumps(body).encode(), "application/json"
    if bearer:
        headers["Authorization"] = f"Bearer {bearer}"
    with urllib.request.urlopen(urllib.request.Request(BASE + path, data, headers, method=method), timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if r.headers.get_content_type() == "application/json" else raw


def save(tokens):
    TOKENS.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(TOKENS, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(tokens, f)


def refresh(tokens):
    tokens = request("POST", "/auth/native/refresh",
                     {"refresh_token": tokens["refresh_token"], "provider": tokens["provider"]})
    save(tokens)
    return tokens


def authed(method, path, **kw):
    try:
        tokens = json.loads(TOKENS.read_text())
    except FileNotFoundError:
        sys.exit("Not signed in: run `hermes login`.")
    try:
        if tokens["expires_at"] < time.time() + 60:
            tokens = refresh(tokens)
        try:
            return request(method, path, bearer=tokens["access_token"], **kw)
        except urllib.error.HTTPError as e:
            if e.code != 401:
                raise
            return request(method, path, bearer=refresh(tokens)["access_token"], **kw)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            sys.exit("Session expired: run `hermes login`.")
        sys.exit(f"Hermes: HTTP {e.code}: {e.read().decode(errors='replace')[:500]}")


def login(_):
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    reply = {}

    class Callback(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            reply.update(urllib.parse.parse_qsl(urllib.parse.urlsplit(self.path).query))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Signed in to Hermes; you can close this tab.")

        def log_message(self, *_):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Callback)
    url = BASE + "/auth/native/authorize?" + urllib.parse.urlencode({
        "provider": "self-hosted", "code_challenge": challenge, "code_challenge_method": "S256",
        "redirect_uri": f"http://127.0.0.1:{server.server_port}/callback", "state": state})
    print(f"Sign in at {url}", file=sys.stderr)
    webbrowser.open(url)
    while not reply:
        server.handle_request()
    if reply.get("state") != state or "code" not in reply:
        sys.exit(f"Sign-in failed: {reply.get('error', 'no code')}")
    save(request("POST", "/auth/native/token", {"code": reply["code"], "code_verifier": verifier}))
    print("Signed in.", file=sys.stderr)


def ticket(_=None):
    return authed("POST", "/api/auth/ws-ticket")["ticket"]


def tui(argv):
    os.environ["HERMES_TUI_GATEWAY_URL"] = f"wss://{urllib.parse.urlsplit(BASE).netloc}/api/ws?ticket={ticket()}"
    os.execv(os.environ["HERMES_REMOTE_TUI"], ["hermes", "--tui", *argv])


def shorten(spec):
    """Names each operation `<namespace> <path words…> <verb>` in place of FastAPI's operationId."""
    paths = {p: ops for p, ops in spec["paths"].items() if p.startswith("/api/")}
    names = {}
    for path, ops in paths.items():
        methods = ops.keys() & VERBS.keys()
        for m in methods:
            words = [s for s in path.removeprefix("/api/").removeprefix("plugins/").split("/") if s[0] != "{"]
            verb = "list" if m == "get" and any(p.startswith(path + "/{") for p in paths) else VERBS[m]
            if m == "post" and len(methods) == 1 and len(words) > 1:
                verb = words.pop()  # an action, e.g. tasks/{task_id}/reclaim
            names[path, m] = (*words, verb)
    groups = {n[:i] for n in names.values() for i in range(1, len(n))}
    seen = set()
    for (path, m), n in names.items():
        n = (*n, VERBS[m]) if n in groups else n
        n = (*n[:-1], f"{n[-1]}-{m}") if n in seen else n
        seen.add(n)
        paths[path][m]["operationId"] = " ".join(n)
    return {**spec, "paths": paths}


def load_spec():
    """The rewritten spec, cached for a day: its version is always 0.0.0 and it has no ETag."""
    try:
        if SPEC.stat().st_mtime > time.time() - 86400:
            return json.loads(SPEC.read_text())
    except FileNotFoundError:
        pass
    spec = shorten(authed("GET", "/openapi.json"))
    SPEC.with_suffix(".tmp").write_text(json.dumps(spec))
    SPEC.with_suffix(".tmp").replace(SPEC)
    return spec


def resolve(schema):
    if "$ref" in schema:
        return resolve(SPEC_DATA["components"]["schemas"][schema["$ref"].rsplit("/", 1)[1]])
    alts = [s for s in schema.get("anyOf", []) if s.get("type") != "null"]
    return {**schema, **resolve(alts[0])} if len(alts) == 1 else schema


def fields(op):
    """(location, name, schema, required) of each path/query parameter, then each body property."""
    for p in op.get("parameters", []):
        if p["in"] in ("path", "query"):
            yield p["in"], p["name"], {"description": p.get("description"), **resolve(p.get("schema", {}))}, p.get("required", False)
    for ctype, loc in (("application/json", "body"), ("multipart/form-data", "form")):
        if schema := op.get("requestBody", {}).get("content", {}).get(ctype, {}).get("schema"):
            schema = resolve(schema)
            for name, prop in schema.get("properties", {}).items():
                yield loc, name, resolve(prop), name in schema.get("required", ())


def upload(path, name=None, ctype=None):
    path = Path(path).expanduser()
    return name or path.name, ctype or mimetypes.guess_type(path.name)[0] or "application/octet-stream", path.read_bytes()


def kind(schema):
    if schema.get("format") == "binary":
        return upload
    return {"integer": int, "number": float, "string": str}.get(schema.get("type"), json.loads)


def esc(text):
    return text and text.replace("%", "%%")


def subs(parser):
    return next((a for a in parser._actions if isinstance(a, argparse._SubParsersAction)), None)


def tree(action, ops):
    """Adds each operation under its name's words, skipping one whose name an upstream command has."""
    for name, (method, path, op) in ops.items():
        *group, leaf = name.split()
        at = action
        for word in group:
            if word not in at.choices:
                at.add_parser(word, help="").add_subparsers(metavar="command", required=True)
            if not (at := subs(at.choices[word])):
                break
        if not at or leaf in at.choices:
            continue
        p = at.add_parser(leaf, help=esc(op.get("summary")), description=esc(op.get("description")))
        taken = set()
        for loc, field, schema, required in sorted(fields(op), key=lambda f: f[0] == "query"):
            dest, help, metavar = f"{loc}:{field}", esc(schema.get("description")), field.upper()
            if loc == "path":
                p.add_argument(dest, metavar=field, type=kind(schema), help=help)
                continue
            flag = "--" + field.replace("_", "-")
            flag = f"--{loc}-{flag[2:]}" if flag in taken else flag
            taken.add(flag)
            if schema.get("type") == "boolean":
                # A default-true flag needs its --no- form; a false one may itself be named no_….
                p.add_argument(flag, dest=dest, help=help, **{"action": argparse.BooleanOptionalAction}
                               if schema.get("default") else {"action": "store_const", "const": True})
            elif schema.get("type") == "array":
                p.add_argument(flag, dest=dest, help=help, metavar=metavar, action="append", type=kind(resolve(schema.get("items", {}))))
            else:
                p.add_argument(flag, dest=dest, help=help, metavar=metavar, required=required, type=kind(schema))
        if "application/json" in op.get("requestBody", {}).get("content", {}):
            p.add_argument("--json-body", type=json.loads, help="the whole request body as JSON; flags override its fields")
        p.set_defaults(run=run_op, op=(method, path, op))


def send(op, parts):
    method, path, o = op
    if BOARD and any(p["name"] == "board" for p in o.get("parameters", [])):
        parts["query"].setdefault("board", BOARD)
    path = path.format(**{n: urllib.parse.quote(str(v), safe="") for n, v in parts["path"].items()})
    query = urllib.parse.urlencode({n: str(v).lower() if isinstance(v, bool) else v for n, v in parts["query"].items()}, doseq=True)
    content = o.get("requestBody", {}).get("content", {})
    return authed(method.upper(), path + (query and "?" + query),
                  body=parts["body"] if "application/json" in content else None,
                  form=parts["form"] if "multipart/form-data" in content else None)


def run_op(a):
    parts = {"path": {}, "query": {}, "body": getattr(a, "json_body", None) or {}, "form": {}}
    for dest, value in vars(a).items():
        loc, _, name = dest.partition(":")
        if name and value is not None:
            parts[loc][name] = value
    return send(a.op, parts)


def call(name, **kw):
    """Runs the operation `name`, each keyword going to the path, body or query field it names."""
    op = OPS[name]
    locs = {field: loc for loc, field, *_ in fields(op[2])}
    parts = {"path": {}, "query": {}, "body": {}, "form": {}}
    for field, value in kw.items():
        if value is not None:
            parts[locs[field]][field] = value
    return send(op, parts)


def author(a=None):
    # Hermes's default is the local profile, "default" here; the person at argo is who's writing.
    return getattr(a, "author", None) or os.environ.get("USER", "user")


def kanban_list(a):
    assignee = a.assignee or (author() if a.mine else None)
    board = call("kanban board get", include_archived=a.archived or a.status == "archived", tenant=a.tenant,
                 workflow_template_id=a.workflow_template_id, current_step_key=a.current_step_key)
    ts = [t for c in board["columns"] for t in c["tasks"]
          if assignee in (None, t["assignee"]) and a.session in (None, t["session_id"])
          and (t["status"] == a.status if a.status else a.all or (t["status"] != "done" and t["priority"] >= 0))]
    for term in reversed(kb.VALID_SORT_ORDERS[a.sort or "priority"].split(",")):
        col, order = term.split()[:2]
        desc = order == "DESC"
        ts.sort(key=lambda t: ((t[col] is None) != desc, t[col] if t[col] is not None else 0), reverse=desc)
    return ts if a.json else "\n".join(_fmt_task_line(SimpleNamespace(**t)) for t in ts) or "(no matching tasks)"


def kanban_show(a):
    d = call("kanban tasks get", task_id=a.task_id, run_state_type=a.state_type, run_state_name=a.state_name)
    if a.json:
        return d
    t = d["task"]
    return "\n".join([
        f"Task {t['id']}: {t['title']}",
        *(f"  {f + ':':<11}{t[f]}" for f in ("status", "assignee", "priority", "tenant") if t[f] not in (None, "")),
        *(f"  {f + ':':<11}{', '.join(d['links'][f])}" for f in ("parents", "children") if d["links"][f]),
        *(["", t["body"]] if t["body"] else []),
        *(["", "Summary:", t["latest_summary"]] if t.get("latest_summary") else []),
        *(["", f"Comments ({len(d['comments'])}):"] if d["comments"] else []),
        *(f"  {k._fmt_ts(c['created_at'])} {c['author']}: {c['body']}" for c in d["comments"])])


def kanban_create(a):
    workspace_kind, workspace_path = k._parse_workspace_flag(a.workspace)
    body = sys.stdin.read() if a.body_file == "-" else Path(a.body_file).read_text() if a.body_file else a.body
    r = call("kanban tasks create", title=a.title, body=body, assignee=a.assignee, parents=a.parent,
             workspace_kind=workspace_kind, workspace_path=workspace_path, project_id=a.project, tenant=a.tenant,
             priority=a.priority, triage=a.triage, idempotency_key=a.idempotency_key,
             max_runtime_seconds=k._parse_duration(a.max_runtime), skills=a.skills or None,
             model_override=a.model_override, provider_override=a.provider_override, goal_mode=a.goal_mode,
             goal_max_turns=a.goal_max_turns)
    if r.get("warning"):
        print(r["warning"], file=sys.stderr)
    return r if a.json else r["task"]["id"]


def each(ids, done, status, prefix=None, reason=None, **patch):
    """Hermes's bulk verbs: an optional `PREFIX: reason` comment, then the status change, per task."""
    for tid in ids:
        if reason:
            call("kanban tasks comments", task_id=tid, body=f"{prefix}: {reason}", author=author())
        call("kanban tasks patch", task_id=tid, status=status, **patch)
        print(f"{done} {tid}" + (f": {reason}" if reason else ""))


def kanban_comment(a):
    body = " ".join(a.text).strip()
    call("kanban tasks comments", task_id=a.task_id, body=body[:a.max_len] if a.max_len else body, author=author(a))
    return f"Comment added to {a.task_id}"


def kanban_archive(a):
    if bool(a.task_ids) == bool(a.purge_ids):
        sys.exit("hermes kanban archive: give task_ids to archive, or --rm archived task_ids")
    for tid in a.purge_ids or []:
        if call("kanban tasks get", task_id=tid)["task"]["status"] != "archived":
            sys.exit(f"cannot delete {tid} (must already be archived)")
        call("kanban tasks delete", task_id=tid)
        print(f"Deleted {tid}")
    return a.task_ids and call("kanban tasks bulk", ids=a.task_ids, archive=True)


def kanban_tail(a):
    last = 0
    while True:
        for e in call("kanban tasks get", task_id=a.task_id)["events"]:
            if e["id"] > last:
                last = e["id"]
                print(k._fmt_ts(e["created_at"]), e["kind"], json.dumps(e["payload"]) if e["payload"] else "", flush=True)
        time.sleep(a.interval)


def triage(a):
    if a.task_id or not a.all_triage:
        return [a.task_id or sys.exit("give a task_id or --all")]
    return [t["id"] for c in call("kanban board get", tenant=a.tenant)["columns"] if c["name"] == "triage" for t in c["tasks"]]


def ids(a):
    return [a.task_id, *(a.ids or [])]


def metadata(a):
    return json.loads(a.metadata) if a.metadata else None


def model(a):
    if a.model in (None, "none"):
        return {"clear_model_override": True}
    return {"model_override": a.model, "provider_override": a.provider}


KANBAN = {
    "boards list": lambda a: call("kanban boards list", include_archived=a.all),
    "boards create": lambda a: call("kanban boards create", slug=a.slug, name=a.name, description=a.description,
                                    icon=a.icon, color=a.color, switch=a.switch, default_workdir=a.default_workdir),
    "boards rm": lambda a: call("kanban boards delete", slug=a.slug, delete=a.delete),
    "boards switch": lambda a: call("kanban boards switch", slug=a.slug),
    "boards show": lambda a: call("kanban boards list")["current"],
    "boards rename": lambda a: call("kanban boards patch", slug=a.slug, name=a.name),
    "boards set-default-workdir": lambda a: call("kanban boards patch", slug=a.slug, default_workdir=a.path or ""),
    "create": kanban_create,
    "list": kanban_list,
    "show": kanban_show,
    # Hermes's 'none' unassigns; the API's is "".
    "assign": lambda a: call("kanban tasks patch", task_id=a.task_id, assignee="" if a.profile == "none" else a.profile),
    "set-model": lambda a: call("kanban tasks patch", task_id=a.task_id, **model(a)),
    "reclaim": lambda a: call("kanban tasks reclaim", task_id=a.task_id, reason=a.reason),
    "reassign": lambda a: call("kanban tasks reassign", task_id=a.task_id, profile="" if a.profile == "none" else a.profile,
                               reclaim_first=a.reclaim, reason=a.reason),
    "diagnostics": lambda a: [d for d in call("kanban diagnostics get", severity=a.severity)["diagnostics"]
                              if a.task in (None, d["task_id"])],
    "link": lambda a: call("kanban links create", parent_id=a.parent_id, child_id=a.child_id),
    "unlink": lambda a: call("kanban links delete", parent_id=a.parent_id, child_id=a.child_id),
    "comment": kanban_comment,
    "attach": lambda a: call("kanban tasks attachments create", task_id=a.task_id, uploaded_by=author(a),
                             file=upload(a.path, a.name, a.content_type)),
    "attachments": lambda a: call("kanban tasks attachments get", task_id=a.task_id),
    "attach-rm": lambda a: call("kanban attachments delete", attachment_id=a.attachment_id),
    # The API always overrides a live claim, as --force does.
    "complete": lambda a: call("kanban tasks bulk", ids=a.task_ids, status="done", result=a.result, summary=a.summary,
                               metadata=metadata(a)),
    "edit": lambda a: call("kanban tasks patch", task_id=a.task_id, title=a.title, body=a.body, priority=a.priority),
    "block": lambda a: each(ids(a), "Blocked", "blocked", "BLOCKED", k._joined_words(a.reason),
                            block_reason=k._joined_words(a.reason)),
    "schedule": lambda a: each(ids(a), "Scheduled", "scheduled", "SCHEDULED", k._joined_words(a.reason),
                               block_reason=k._joined_words(a.reason)),
    "unblock": lambda a: each(a.task_ids, "Unblocked", "ready", "UNBLOCK", a.reason),
    "request-review": lambda a: call("kanban tasks patch", task_id=a.task_id, status="review", summary=a.summary,
                                     metadata=metadata(a), assignee=a.reviewer),
    "reopen-review": lambda a: each(a.task_ids, "Reopened", "ready", "CHANGES REQUESTED", a.reason),
    "promote": lambda a: each(ids(a), "Promoted", "ready"),
    "archive": kanban_archive,
    "tail": kanban_tail,
    "dispatch": lambda a: call("kanban dispatch", dry_run=a.dry_run, max=a.max),
    "stats": lambda a: call("kanban stats get"),
    "log": lambda a: call("kanban tasks log get", task_id=a.task_id, tail=a.tail)["content"],
    "runs": lambda a: call("kanban tasks get", task_id=a.task_id, run_state_type=a.state_type,
                           run_state_name=a.state_name)["runs"],
    "assignees": lambda a: call("kanban assignees get"),
    "specify": lambda a: [call("kanban tasks specify", task_id=t, author=author(a)) for t in triage(a)],
    "decompose": lambda a: [call("kanban tasks decompose", task_id=t, author=author(a)) for t in triage(a)],
}
# Options the API has no field for; the rest of these commands work.
UNSUPPORTED = {"create": ("branch", "created_by", "max_retries", "completion_contract", "initial_status"),
               "edit": ("result", "summary", "metadata"), "block": ("kind",), "promote": ("reason", "dry_run"),
               "dispatch": ("failure_limit",)}


def remote(name, parser):
    def run(a):
        for dest in UNSUPPORTED.get(name, ()):
            if getattr(a, dest) not in (None, False, [], parser.get_default(dest)):
                sys.exit(f"hermes kanban {name}: {dest} is not available remotely")
        if name not in KANBAN:
            sys.exit(f"hermes kanban {name}: not available remotely")
        return KANBAN[name](a)
    return run


def overlay(top):
    kanban = kanban_parser.build_parser(top)
    subs(kanban).choices["list"].add_argument("--all", action="store_true", help="also done and priority < 0 tasks")

    def walk(parser):
        if action := subs(parser):
            parser.set_defaults(run=lambda a: parser.print_help())
            for child in set(action.choices.values()):
                walk(child)
        else:
            parser.set_defaults(run=remote(parser.prog.removeprefix(kanban.prog).strip(), parser))
    walk(kanban)


def main(argv):
    global SPEC_DATA, OPS, BOARD
    first = argv[0] if argv else ""
    if first not in ("login", "ticket"):
        if not first or first.startswith("-"):
            return tui(argv)
        SPEC_DATA = load_spec()
        OPS = {op["operationId"]: (m, p, op) for p, ops in SPEC_DATA["paths"].items()
               for m, op in ops.items() if m in VERBS}
        namespaces = {name.split()[0] for name in OPS}
        if first != "api" and first not in namespaces:
            return tui(argv)
    parser = argparse.ArgumentParser(prog="hermes", description=__doc__.split("\n\n")[0])
    top = parser.add_subparsers(metavar="command", required=True)
    top.add_parser("login", help="sign in to the dashboard").set_defaults(run=login)
    top.add_parser("ticket", help="print a single-use TUI WebSocket ticket").set_defaults(run=ticket)
    if first not in ("login", "ticket"):
        if first == "api":
            want = set(argv[1:2]) & namespaces or namespaces
            tree(top.add_parser("api", help="every operation, as generated").add_subparsers(metavar="namespace", required=True),
                 {n: op for n, op in OPS.items() if n.split()[0] in want})
        else:
            if first == "kanban":
                overlay(top)
            tree(top, {n: op for n, op in OPS.items() if n.split()[0] == first})
    a = parser.parse_args(argv)
    BOARD = getattr(a, "board", None)
    result = a.run(a)
    if isinstance(result, bytes):
        sys.stdout.buffer.write(result)
    elif isinstance(result, str):
        print(result)
    elif result is not None:
        print(json.dumps(result, indent=2, ensure_ascii=False))


try:
    main(sys.argv[1:])
except KeyboardInterrupt:
    sys.exit(130)
