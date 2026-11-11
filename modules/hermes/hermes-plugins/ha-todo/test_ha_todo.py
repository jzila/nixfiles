"""Loaded by the pinned Hermes, against a stand-in egress gateway."""
import json
import os
import pathlib
import shutil
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

calls = []


class Gateway(BaseHTTPRequestHandler):
    def do_GET(self):
        self.reply(200, [{"entity_id": "todo.grocery", "state": "2", "attributes": {"friendly_name": "Grocery"}},
                         {"entity_id": "sun.sun", "state": "above_horizon", "attributes": {}}])

    def do_POST(self):
        calls.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
        if "remove_completed" in self.path:
            return self.reply(403, "Refused by Hermes's egress gateway")
        self.reply(200, {"service_response": {"todo.grocery": {"items": [{"summary": "milk"}]}}}
                   if self.path.endswith("?return_response") else [])

    def reply(self, code, body):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(body.encode() if isinstance(body, str) else json.dumps(body).encode())

    def log_message(self, *a):
        pass


class TodoTest(unittest.TestCase):
    def test_toolset(self):
        server = HTTPServer(("127.0.0.1", 0), Gateway)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        home = pathlib.Path(os.environ["HERMES_HOME"])
        shutil.copytree(pathlib.Path(__file__).parent, home / "plugins/ha-todo")
        (home / "config.yaml").write_text(json.dumps({"plugins": {
            "enabled": ["ha-todo"], "entries": {"ha-todo": {"settings": {"url": f"http://127.0.0.1:{server.server_port}"}}}}}))

        from hermes_cli.plugins import discover_plugins
        from model_tools import get_tool_definitions
        from tools.registry import registry
        discover_plugins()
        tools = get_tool_definitions(["ha-todo", "no_mcp"], quiet_mode=True, skip_tool_search_assembly=True)
        names = {t["function"]["name"] for t in tools}
        self.assertIn("ha_todo_update_item", names)
        self.assertNotIn("terminal", names)

        run = lambda name, **args: json.loads(registry.dispatch(name, args))
        self.assertEqual(run("ha_todo_lists"), [{"entity_id": "todo.grocery", "name": "Grocery", "open": "2"}])
        self.assertEqual(run("ha_todo_get_items", entity_id="todo.grocery"), {"items": [{"summary": "milk"}]})
        run("ha_todo_add_item", entity_id="todo.grocery", item="eggs", due="2026-11-08")
        self.assertEqual(calls[-1], ("/api/services/todo/add_item",
                                     {"entity_id": "todo.grocery", "item": "eggs", "due_date": "2026-11-08"}))
        self.assertEqual(run("ha_todo_remove_completed_items", entity_id="todo.grocery"),
                         {"error": "403: Refused by Hermes's egress gateway"})
