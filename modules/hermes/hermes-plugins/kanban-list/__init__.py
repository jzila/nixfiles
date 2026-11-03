"""kanban_list hides tasks with priority < 0 (filed Home Assistant log errors) unless include_low_priority.

A plugin rather than a patch: patching Hermes's Python changes the venv its icons are rendered with,
so the VM rebuilds the whole web frontend from source (and ran out of memory doing it).
"""

from __future__ import annotations

import copy
import json

from tools.kanban_tools import KANBAN_LIST_DEFAULT_LIMIT, KANBAN_LIST_MAX_LIMIT, _kanban_handler, _parse_bool_arg
from tools.registry import registry

FLAG = "include_low_priority"


def register(ctx) -> None:
    builtin = registry.get_entry("kanban_list")
    schema = copy.deepcopy(builtin.schema)
    schema["description"] += " Hides tasks with priority < 0 unless include_low_priority."
    schema["parameters"]["properties"][FLAG] = {"type": "boolean", "description": "Include tasks with priority < 0."}

    @_kanban_handler("kanban_list")
    def handler(args: dict, **kw) -> str:
        args = dict(args)
        if _parse_bool_arg(args, FLAG):
            args.pop(FLAG)
            return builtin.handler(args, **kw)
        args.pop(FLAG, None)
        try:
            limit = KANBAN_LIST_DEFAULT_LIMIT if args.get("limit") is None else int(args["limit"])
        except (TypeError, ValueError):
            limit = None
        if limit is None or not 1 <= limit <= KANBAN_LIST_MAX_LIMIT:
            return builtin.handler(args, **kw)  # it reports the bad limit
        result = json.loads(builtin.handler({**args, "limit": KANBAN_LIST_MAX_LIMIT}, **kw))
        if "tasks" not in result:
            return json.dumps(result)
        tasks = [t for t in result["tasks"] if t["priority"] >= 0]
        truncated = len(tasks) > limit or result["truncated"]
        return json.dumps({
            **result, "tasks": tasks[:limit], "count": min(len(tasks), limit), "limit": limit,
            "truncated": truncated,
            "next_limit": min(limit * 2, KANBAN_LIST_MAX_LIMIT) if truncated and limit < KANBAN_LIST_MAX_LIMIT else None})

    ctx.register_tool(
        name="kanban_list", toolset=builtin.toolset, schema=schema, handler=handler, check_fn=builtin.check_fn,
        emoji=builtin.emoji, override=True)
