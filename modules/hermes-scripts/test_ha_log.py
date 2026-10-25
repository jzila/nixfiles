"""ha-log.py's device payloads (automation.hermes_ha_unreachable): one task per device."""
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

spec = importlib.util.spec_from_file_location("ha_log", pathlib.Path(__file__).with_name("ha-log.py"))
ha_log = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ha_log)


class DeviceTest(unittest.TestCase):
    def run_payload(self, tasks, **payload):
        calls = []

        def kanban(*args):
            calls.append(args)
            return json.dumps(tasks) if args[0] == "list" else json.dumps({"id": "t1"})

        payload = {"kind": "log", "level": "ERROR", "logger": "pychromecast.socket_client",
                   "message": "Failed to connect", **payload}
        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"HERMES_HOME": home}), \
                mock.patch.object(ha_log, "kanban", kanban), mock.patch("sys.stdin", io.StringIO(json.dumps(payload))), \
                redirect_stdout(io.StringIO()) as out:
            ha_log.main()
        return calls, out.getvalue()

    def test_new_device_task(self):
        calls, out = self.run_payload([], device="Rooftop speaker")
        create = calls[1]
        self.assertEqual(create[1], "HA log: can't reach Rooftop speaker")
        self.assertIn("unreachable for 30+ minutes", create[3])
        self.assertIn("unreachable for 30+ minutes", json.loads(out)["prompt"])

    def test_same_device_other_integration(self):
        calls, _ = self.run_payload([], device="Rooftop speaker")
        task = {"id": "t1", "title": calls[1][1], "status": "todo", "body": calls[1][3]}
        calls, out = self.run_payload([task], device="Rooftop speaker", logger="homeassistant.components.cast",
                                      message="Rooftop speaker timed out")
        self.assertEqual([c[0] for c in calls], ["list", "edit"])
        self.assertIn("- logged 2 times", calls[1][3])
        self.assertEqual(out.strip(), "[SILENT]")

    def test_without_device_unchanged(self):
        calls, _ = self.run_payload([])
        self.assertEqual(calls[1][1], "HA log: pychromecast.socket_client: Failed to connect")


if __name__ == "__main__":
    unittest.main()
