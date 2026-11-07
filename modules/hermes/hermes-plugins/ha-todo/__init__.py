"""The `ha-todo` toolset: Home Assistant's to-do lists, for chat users who mustn't get a shell.

Calls go to the host's egress gateway (settings.url), which holds the token and allowlists these services.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request

from tools.registry import tool_error, tool_result

LIST = {"entity_id": {"type": "string", "description": "A list's entity_id from ha_todo_lists."}}
ITEM = {"item": {"type": "string", "description": "The item's summary (or, for an existing one, uid)."}}
DETAILS = {"description": {"type": "string"}, "due": {"type": "string", "description": "YYYY-MM-DD or ISO datetime."}}
STATUS = {"status": {"type": "string", "enum": ["needs_action", "completed"]}}


def register(ctx) -> None:
    url = ctx.get_config("url")

    def request(path, body=None):
        req = urllib.request.Request(url + path, None if body is None else json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)

    def tool(name, description, properties, run, required=("entity_id",)):
        def handler(args, **kw):
            try:
                return tool_result(run(dict(args)))
            except urllib.error.HTTPError as e:
                with e:
                    return tool_error(f"{e.code}: {e.read().decode(errors='replace').strip()}")
            except OSError as e:
                return tool_error(str(e))

        ctx.register_tool(name=name, toolset="ha-todo", handler=handler, emoji="📝", schema={
            "name": name, "description": description,
            "parameters": {"type": "object", "properties": properties, "required": list(required)}})

    def service(name, query=""):
        def run(args):
            if due := args.pop("due", None):
                args["due_date" if len(due) == 10 else "due_datetime"] = due
            result = request(f"/api/services/todo/{name}{query}", args)
            return result["service_response"][args["entity_id"]] if query else {"ok": True}
        return run

    tool("ha_todo_lists", "The household's Home Assistant to-do lists, with their open item counts.", {},
         lambda _: [{"entity_id": s["entity_id"], "name": s["attributes"].get("friendly_name"), "open": s["state"]}
                    for s in request("/api/states") if s["entity_id"].startswith("todo.")], required=())
    tool("ha_todo_get_items", "Items on a to-do list.", {**LIST, **STATUS}, service("get_items", "?return_response"))
    tool("ha_todo_add_item", "Add an item to a to-do list.", {**LIST, **ITEM, **DETAILS}, service("add_item"),
         required=("entity_id", "item"))
    tool("ha_todo_update_item", "Change an item: rename, complete or reopen (status), description, due.",
         {**LIST, **ITEM, "rename": {"type": "string"}, **STATUS, **DETAILS}, service("update_item"),
         required=("entity_id", "item"))
    tool("ha_todo_remove_item", "Remove an item from a to-do list.", {**LIST, **ITEM}, service("remove_item"),
         required=("entity_id", "item"))
    tool("ha_todo_remove_completed_items", "Remove every completed item from a to-do list.", LIST,
         service("remove_completed_items"))
