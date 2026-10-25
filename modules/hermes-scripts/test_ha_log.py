"""Tests for ha-log.py: python3 -m unittest test_ha_log (from this directory).

Fixtures are the errors Home Assistant logged on 2026-10-24 when two TVs, the
receiver and the rooftop speaker dropped off the network.
"""
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("ha_log", pathlib.Path(__file__).with_name("ha-log.py"))
ha_log = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ha_log)

CAST = "pychromecast.socket_client"
LINKPLAY_EXC = ("File \"/usr/local/lib/python3.14/site-packages/linkplay/utils.py\", line 67, in session_call_api\n"
                " raise LinkPlayRequestException(\n"
                "linkplay.exceptions.LinkPlayRequestException: error requesting data from "
                "'https://192.168.1.142/httpapi.asp?command=getNewAudioOutputHardwareMode'")
DLNA_MESSAGE = ("Exception in SSDP callback <bound method DmsDeviceSource.async_ssdp_callback of "
                "<homeassistant.components.dlna_dms.dms.DmsDeviceSource object at 0x26b63d5d9a0>>: "
                "(SsdpServiceInfo(ssdp_usn='uuid:00000001-0000-1010-8000-94db5632d40b::upnp:rootdevice', "
                "ssdp_st='upnp:rootdevice', upnp={'deviceType': 'urn:schemas-upnp-org:device:MediaServer:1', "
                "'friendlyName': 'Sony Receiver', 'manufacturer': 'Sony Cor")

# (logger, message, exception)
ROOFTOP = [
    ("homeassistant.helpers.entity", "Update for select.rooftop_speaker_audio_output_hardware_mode fails", LINKPLAY_EXC),
    (CAST, "[Rooftop speaker(192.168.1.142):8009] Failed to connect to service "
           "HostServiceInfo(host='192.168.1.142', port=8009), retrying in 5.0s", None),
]
OLED83 = [
    ("homeassistant.components.webostv",
     "Error fetching LG webOS TV OLED83G5WUA data: Device LG webOS TV OLED83G5WUA is unavailable", None),
    (CAST, "[[LG] webOS TV OLED83G5WUA(192.168.1.108):8009] Error reading from socket: "
           "[Errno 104] Connection reset by peer", None),
    (CAST, "[[LG] webOS TV OLED83G5WUA(192.168.1.108):8009] Failed to connect to service MDNSServiceInfo("
           "name='OLED83G5WUA.BUSYLJR-95c0ed6dccd848848d5e58a6dbdd5ff1._googlecast._tcp.local.'), retrying in 5.0s", None),
]
SONY = [
    ("homeassistant.util.logging", DLNA_MESSAGE, None),
    (CAST, "[Sony Receiver(192.168.1.88):8009] Failed to connect to service MDNSServiceInfo("
           "name='C4A-91732e84ea901a5d8268331d8354de8e._googlecast._tcp.local.'), retrying in 5.0s", None),
    (CAST, "[Sony Receiver(192.168.1.88):8009] Failed to connect to service "
           "HostServiceInfo(host='192.168.1.88', port=8009), retrying in 5.0s", None),
]
NOT_DEVICES = [
    ("homeassistant.helpers.template", "Template variable warning: No first item, sequence was empty. "
     "when rendering '{%- set only = none -%}", None),
    ("homeassistant.components.automation.front_door_open", "Door Status: Already running", None),
    ("homeassistant.components.automation.foo", "Error executing script. Timeout for light.kitchen", None),
    ("homeassistant.components.template", "TemplateError('ZeroDivisionError: division by zero') "
     "while processing template for sensor.power", None),
]


def device(name, ip=None, sleeps=False, entities=2, down=0, down_since=None):
    return {"name": name, "ip": ip, "sleeps": sleeps, "entities": entities, "down": down, "down_since": down_since}


SNAPSHOT = [
    device("Rooftop speaker", entities=2),
    device("Rooftop speaker", ip="192.168.1.142", entities=4),
    device("Sony Receiver"), device("Sony Receiver", entities=1),
    device("[LG] webOS TV OLED83G5WUA"), device("LG webOS TV OLED83G5WUA", entities=1),
    device("LG webOS TV OLED65B6P", entities=1, down=1, down_since=1000),
    device("ZilaVilla UDM", ip="192.168.1.1", entities=11),
]


class Board:
    """A fake hass kanban board, driven through the same argv as the hermes CLI."""

    def __init__(self):
        self.tasks = {}

    def __call__(self, cmd, *args):
        if cmd == "list":
            return json.dumps(list(self.tasks.values()))
        if cmd == "create":
            tid = f"t_{len(self.tasks):04d}"
            self.tasks[tid] = {"id": tid, "title": args[0], "body": args[args.index("--body") + 1], "status": "todo"}
            return json.dumps({"id": tid})
        if cmd == "edit":
            self.tasks[args[0]]["body"] = args[2]
            return ""
        if cmd == "complete":
            self.tasks[args[0]].update(status="done", result=args[2])
            return ""
        raise AssertionError(cmd)

    def open(self):
        return [t for t in self.tasks.values() if t["status"] != "done"]


class Classifier(unittest.TestCase):
    def test_reachability_errors_name_their_device(self):
        for logger, message, exc in ROOFTOP + OLED83 + SONY:
            with self.subTest(message=message[:60]):
                self.assertIsNotNone(ha_log.reachability(logger, message, exc))

    def test_other_errors_are_not_device_errors(self):
        for logger, message, exc in NOT_DEVICES:
            with self.subTest(message=message[:60]):
                self.assertIsNone(ha_log.reachability(logger, message, exc))

    def test_identity(self):
        ident = ha_log.reachability(*OLED83[1])
        self.assertEqual(ident["names"], ["[LG] webOS TV OLED83G5WUA"])
        self.assertEqual(ident["hosts"], ["192.168.1.108"])
        ident = ha_log.reachability(*ROOFTOP[0])
        self.assertEqual(ident["hosts"], ["192.168.1.142"])
        self.assertEqual(ident["entities"], ["select.rooftop_speaker_audio_output_hardware_mode"])
        self.assertEqual(ha_log.reachability(*SONY[0])["names"], ["Sony Receiver"])
        self.assertEqual(ha_log.reachability(*OLED83[0])["names"], ["LG webOS TV OLED83G5WUA"])

    def test_add_on_network_is_not_a_device_address(self):
        ident = ha_log.reachability(
            "music_assistant_client.connection",
            "Failed to connect to ws://d5369777-music-assistant:8094/ws: Cannot connect to host "
            "d5369777-music-assistant:8094 ssl:False [Connect call failed ('172.30.32.1', 8094)]", None)
        self.assertEqual(ident["hosts"], ["d5369777-music-assistant"])


class Grouping(unittest.TestCase):
    def key(self, row, devices=SNAPSHOT, aliases=None):
        name, display, _ = ha_log.resolve(ha_log.reachability(*row), devices, aliases or {})
        return ha_log.device_key(name, display)

    def test_one_key_per_device_whichever_integration(self):
        for rows in (ROOFTOP, OLED83, SONY):
            self.assertEqual(len({self.key(r) for r in rows}), 1, rows[0][1])
        self.assertEqual(len({self.key(rows[0]) for rows in (ROOFTOP, OLED83, SONY)}), 3)

    def test_address_only_message_by_configuration_url(self):
        row = ("linkplay", "error requesting data from 'https://192.168.1.142/httpapi.asp?command=getStatusEx'", None)
        self.assertEqual(self.key(row), self.key(ROOFTOP[1]))

    def test_address_only_message_by_earlier_alias(self):
        row = ("songpal", "Unable to connect to http://192.168.1.88:10000/sony", None)
        self.assertNotEqual(self.key(row), self.key(SONY[1]))
        self.assertEqual(self.key(row, aliases={"192.168.1.88": "Sony Receiver"}), self.key(SONY[1]))

    def test_entity_only_message_by_device_name(self):
        row = ("homeassistant.helpers.entity", "Update for media_player.rooftop_speaker_3 fails",
               "aiohttp.client_exceptions.ClientConnectorError: Cannot connect to host")
        self.assertEqual(self.key(row), self.key(ROOFTOP[1]))

    def test_without_snapshot_names_still_group(self):
        self.assertEqual(len({self.key(r, devices=[]) for r in OLED83}), 1)


class Webhook(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.board = Board()
        self.now = 1_792_887_000.0
        for patch in (mock.patch.object(ha_log, "kanban", self.board),
                      mock.patch.object(ha_log.time, "time", lambda: self.now),
                      mock.patch.dict("os.environ", {"HERMES_HOME": self.home.name})):
            patch.start()
            self.addCleanup(patch.stop)

    def post(self, payload):
        out = io.StringIO()
        with mock.patch("sys.stdin", io.StringIO(json.dumps(payload))), mock.patch("sys.stdout", out):
            ha_log.main()
        out = out.getvalue().strip()
        return None if out == "[SILENT]" else json.loads(out)["prompt"]

    def log(self, row):
        logger, message, exc = row
        return self.post({"kind": "log", "level": "ERROR", "logger": logger, "source": "x.py:1",
                          "message": message, "exception": exc, "count": 1,
                          "first_occurred": "2026-10-24T19:10:38-05:00", "last_occurred": "2026-10-24T19:10:38-05:00"})

    def snapshot(self, devices):
        return self.post({"kind": "devices", "devices": devices})

    def test_evening_of_2026_10_24_one_task_per_device_no_turn_yet(self):
        self.snapshot(SNAPSHOT)
        for row in ROOFTOP + OLED83 + SONY:
            self.assertIsNone(self.log(row))
            self.now += 30
        self.assertEqual(sorted(t["title"] for t in self.board.open()), [
            "HA log: can't reach LG webOS TV OLED83G5WUA", "HA log: can't reach Rooftop speaker",
            "HA log: can't reach Sony Receiver"])
        sony = next(t for t in self.board.open() if "Sony" in t["title"])
        self.assertIn("logged 3 times", sony["body"])
        self.assertIn("pychromecast.socket_client", sony["body"])

    def test_device_back_after_defer_is_completed_without_a_turn(self):
        self.snapshot(SNAPSHOT)
        down = [dict(d, down=d["entities"], down_since=int(self.now)) if "Rooftop" in d["name"] else d for d in SNAPSHOT]
        self.snapshot(down)
        for row in ROOFTOP:
            self.log(row)
        self.now += ha_log.DEFER - 60
        self.assertIsNone(self.snapshot(SNAPSHOT))
        self.assertEqual(len(self.board.open()), 1)
        self.now += 120
        self.assertIsNone(self.snapshot(SNAPSHOT))
        self.assertEqual(self.board.open(), [])
        self.assertIn("Transient", next(iter(self.board.tasks.values()))["result"])

    def test_device_still_down_after_defer_gets_one_turn(self):
        for row in OLED83 + SONY:
            self.log(row)
        down = [dict(d, down=d["entities"], down_since=int(self.now)) if "OLED83" in d["name"] or "Sony" in d["name"]
                else d for d in SNAPSHOT]
        self.now += ha_log.DEFER + 10
        prompt = self.snapshot(down)
        self.assertIn("can't reach 2 devices (automatic alert)", prompt)
        self.assertIn("LG webOS TV OLED83G5WUA", prompt)
        self.assertIn("Sony Receiver", prompt)
        self.assertIn("sleeps", prompt)
        self.assertEqual(len(self.board.open()), 2)
        self.now += 300
        self.assertIsNone(self.snapshot(down))  # once
        self.assertIsNone(self.log(OLED83[1]))  # and further errors just count
        self.assertEqual(len(self.board.open()), 2)
        state = json.loads(pathlib.Path(self.home.name, "state", "ha-log.json").read_text())
        self.assertEqual(len(state["turns"]), 1)

    def test_still_logging_is_not_back(self):
        self.log(ROOFTOP[1])
        self.now += ha_log.DEFER - 60
        self.snapshot(SNAPSHOT)  # snapshots keep coming every 5 minutes
        self.now += 70
        self.log(ROOFTOP[0])
        self.assertIn("still logging errors", self.snapshot(SNAPSHOT))

    def test_unknown_device_is_triaged(self):
        self.log(("songpal", "Unable to connect to http://192.168.1.200:10000/sony", None))
        self.now += ha_log.DEFER + 10
        self.assertIn("not found among Home Assistant's devices", self.snapshot(SNAPSHOT))

    def test_rate_limited_check_waits_for_next_snapshot(self):
        self.snapshot(SNAPSHOT)
        for i in range(ha_log.MAX_TURNS):
            self.assertIsNotNone(self.log(("homeassistant.components.foo", f"Problem {chr(65 + i)}", None)))
        self.log(SONY[1])
        down = [dict(d, down=1, down_since=int(self.now)) if "Sony" in d["name"] else d for d in SNAPSHOT]
        self.now += ha_log.DEFER + 10
        self.assertIsNone(self.snapshot(down))
        self.now += ha_log.RATE_WINDOW
        self.assertIn("Sony Receiver", self.snapshot(down))

    def test_sleeping_devices_are_dropped(self):
        sleepy = [dict(d, sleeps=True) if "OLED83" in d["name"] or "Sony" in d["name"] else d for d in SNAPSHOT]
        self.snapshot(sleepy)
        for row in OLED83 + SONY:
            self.assertIsNone(self.log(row))
        self.assertEqual(self.board.tasks, {})
        self.log(ROOFTOP[1])  # the rooftop speaker isn't one
        self.assertEqual(len(self.board.open()), 1)

    def test_labelled_while_waiting_completes_silently(self):
        self.log(SONY[1])
        self.now += ha_log.DEFER + 10
        sleepy = [dict(d, sleeps=True, down=1, down_since=int(self.now)) if "Sony" in d["name"] else d for d in SNAPSHOT]
        self.assertIsNone(self.snapshot(sleepy))
        self.assertEqual(self.board.open(), [])

    def test_no_snapshot_triages_unchecked_on_next_error(self):
        self.log(SONY[1])
        self.now += ha_log.DEFER + 10
        prompt = self.log(SONY[2])
        self.assertIn("couldn't be checked", prompt)

    def test_completed_task_starts_a_new_episode(self):
        self.snapshot(SNAPSHOT)
        self.log(SONY[1])
        for t in self.board.open():
            self.board("complete", t["id"], "--result", "by hand")
        self.log(SONY[1])
        self.assertEqual(len(self.board.open()), 1)
        self.assertIn("logged 1 times", self.board.open()[0]["body"])

    def test_other_errors_still_get_a_turn_at_once(self):
        prompt = self.log(NOT_DEVICES[3])
        self.assertIn("logged a new problem", prompt)
        self.assertIsNone(self.log(NOT_DEVICES[3]))
        self.assertIn("logged 2 times", self.board.open()[0]["body"])

    def test_snapshot_is_validated(self):
        devices = ha_log.parse_devices({"devices": [
            {"name": "Ok`$(x)", "ip": "1.2.3.4; rm", "sleeps": "yes", "entities": "3", "down": -1, "down_since": "x"},
            "junk", {"name": ""}]})
        self.assertEqual(devices, [device("Ok(x)", entities=3)])


if __name__ == "__main__":
    unittest.main()
