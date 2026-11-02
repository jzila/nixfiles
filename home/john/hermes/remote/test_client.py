import contextlib
import io
import json
import unittest
from unittest import mock

import client

BOARD = {"columns": [{"name": s, "tasks": [
    {"id": f"t_{s}{p}", "title": s, "status": s, "priority": p, "created_at": 0, "assignee": None, "tenant": None}
    for p in (1, -1)]} for s in ("ready", "done")]}


class Client(unittest.TestCase):
    def requests(self, argv, reply=None):
        sent = []
        with mock.patch.object(client, "call", lambda *r: sent.append(r) or reply), \
                contextlib.redirect_stdout(io.StringIO()) as out:
            client.main(argv)
        return sent, out.getvalue()

    def test_commands_map_to_requests(self):
        cases = [
            (["kanban", "api", "tasks", "patch", "t_1", "--status", "done", "--priority", "2"],
             ("PATCH", "/api/plugins/kanban/tasks/t_1", {}, {"status": "done", "priority": 2})),
            (["kanban", "api", "tasks", "get", "t 1", "--board", "b"],
             ("GET", "/api/plugins/kanban/tasks/t%201", {"board": "b"}, None)),
            (["cron", "jobs", "pause", "j1"], ("POST", "/api/cron/jobs/j1/pause", {}, None)),
            (["sessions", "list", "--limit", "3"], ("GET", "/api/sessions", {"limit": 3}, None)),
            (["kanban", "--board", "b", "complete", "t_1", "t_2", "--result", "ok"],
             ("POST", "/api/plugins/kanban/tasks/bulk", {"board": "b"}, {"ids": ["t_1", "t_2"], "status": "done", "result": "ok"})),
            (["kanban", "assign", "t_1", "none"], ("PATCH", "/api/plugins/kanban/tasks/t_1", {}, {"assignee": ""})),
            (["kanban", "unlink", "a", "b"], ("DELETE", "/api/plugins/kanban/links", {"parent_id": "a", "child_id": "b"}, None)),
        ]
        for argv, want in cases:
            with self.subTest(argv=argv):
                self.assertEqual(self.requests(argv)[0], [want])

    def test_kanban_list_hides_done_and_negative_priority_unless_all(self):
        for argv, ids in ((["kanban", "ls"], ["t_ready1"]),
                          (["kanban", "list", "--status", "done"], ["t_done1"]),
                          (["kanban", "list", "--all"], ["t_ready1", "t_done1", "t_ready-1", "t_done-1"])):
            with self.subTest(argv=argv):
                _, out = self.requests([*argv, "--json"], BOARD)
                self.assertEqual([t["id"] for t in json.loads(out)], ids)

    def test_unavailable_remotely(self):
        for argv in (["kanban", "swarm", "g", "--verifier", "v", "--synthesizer", "s"],
                     ["kanban", "boards", "export"], ["kanban", "list", "--mine"], ["kanban", "block", "t", "--kind", "transient"]):
            with self.subTest(argv=argv):
                with self.assertRaises(SystemExit) as e:
                    self.requests(argv)
                self.assertIn("not available remotely", str(e.exception.code))


if __name__ == "__main__":
    unittest.main()
