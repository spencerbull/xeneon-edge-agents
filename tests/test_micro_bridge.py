import json
from pathlib import Path
import runpy
import socket
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

MODULE = runpy.run_path(str(Path(__file__).parents[1] / "config/bin/xeneon-micro-bridge"))
Bridge, HerdrOwner = MODULE["Bridge"], MODULE["HerdrOwner"]


def agent(name, state="working", review=False):
    return {"id": name, "status": state, "review_ready": review, "actions": {"open": True}}


class MicroBridgeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.owner = Mock(marker=Path(self.directory.name) / "restore-herdr")
        self.bridge = Bridge("portal", "micro", Path(self.directory.name), self.owner)
        self.portal, self.peer = socket.socketpair()
        self.addCleanup(self.portal.close)
        self.addCleanup(self.peer.close)
        self.addCleanup(self.bridge.selector.close)
        self.bridge.portal = self.portal
        self.snapshot = {"type": "snapshot", "schema_version": 1, "sequence": 7,
                         "backend": {"mode": "t3code"}, "connection": "connected",
                         "agents": [agent("one"), agent("two", "blocked")]}
        self.bridge.portal_event(self.snapshot)
        self.bridge.acknowledged_slots = ["one", "two"]

    def event(self, key, action="press"):
        self.bridge.micro_event({"event": "key", "key": key, "action": action})

    def read(self):
        self.peer.settimeout(0.05)
        return json.loads(self.peer.recv(8192))

    def test_physical_keys_use_current_slot_identity_and_no_action_replay(self):
        self.event("AG01")
        command = self.read()
        self.assertEqual((command["agent_id"], command["sequence"], command["action"]), ("two", 7, "open"))
        self.event("AG00")
        with self.assertRaises(TimeoutError):
            self.read()
        self.bridge.portal_event({"type": "action_result", "request_id": command["request_id"], "ok": False})
        self.assertIsNone(self.bridge.selected)
        self.assertIsNone(self.bridge.pending)

    def test_dial_and_attention_follow_shared_order_after_update(self):
        self.bridge.selected = "one"
        self.event("ENC_CW", "step")
        command = self.read()
        self.assertEqual(command["agent_id"], "two")
        self.bridge.portal_event({"type": "action_result", "request_id": command["request_id"], "ok": True})
        self.assertEqual(self.bridge.selected, "two")
        self.snapshot["agents"] = [agent("third", "done", True), agent("one")]
        self.snapshot["sequence"] = 8
        self.bridge.portal_event(self.snapshot)
        self.bridge.acknowledged_slots = ["third", "one"]
        self.event("ACT08")
        self.assertEqual(self.read()["agent_id"], "third")

    def test_late_events_on_backend_switch_and_stale_roster_do_nothing(self):
        self.snapshot["backend"]["mode"] = "herdr"
        self.event("AG00")
        self.snapshot["backend"]["mode"] = "t3code"
        self.bridge.received = time.monotonic() - 5
        self.event("AG00")
        with self.assertRaises(TimeoutError):
            self.read()

    def test_approval_and_microphone_companion_keys_never_send_text_or_approve(self):
        for key in ("ACT06", "ACT07", "ACT10", "ACT11", "ACT12", "ENC_CLK"):
            self.event(key)
        with self.assertRaises(TimeoutError):
            self.read()

    def test_device_acknowledgement_precedes_claiming_controlled_slots(self):
        self.bridge.lights_request = ("led-1", ["one", "two"])
        self.bridge.ring_request = "ring-1"
        self.assertFalse(self.bridge.status_path.exists())
        self.bridge.micro_event({"id": "led-1", "ok": True})
        self.assertFalse(self.bridge.status_path.exists())
        self.bridge.micro_event({"id": "ring-1", "ok": True})
        status = json.loads(self.bridge.status_path.read_text())
        self.assertEqual(status["slots"], ["one", "two"])
        self.assertTrue(status["controlled"])
        self.assertEqual(self.bridge.status_path.stat().st_mode & 0o777, 0o600)
        self.bridge.release()
        self.assertFalse(self.bridge.status_path.exists())
        self.owner.restore.assert_called_once()

    def test_failed_lights_never_claim_control(self):
        self.bridge.lights_request = ("led-1", ["one"])
        with self.assertRaises(RuntimeError):
            self.bridge.micro_event({"id": "led-1", "ok": False})
        self.assertFalse(self.bridge.status_path.exists())

    def test_retargeted_slots_cannot_act_until_both_lighting_frames_are_acknowledged(self):
        self.snapshot["agents"][0] = agent("new")
        self.event("AG00")
        with self.assertRaises(TimeoutError):
            self.read()
        self.bridge.ring_request = "ring-error"
        with self.assertRaises(RuntimeError):
            self.bridge.micro_event({"id": "ring-error", "ok": False})
        self.assertFalse(self.bridge.status_path.exists())

    def test_empty_and_removed_slots_are_cleared(self):
        frame = MODULE["lights"]([agent("one", "blocked")])
        self.assertEqual(len(frame), 6)
        self.assertNotEqual(frame[0]["color"], 0)
        self.assertTrue(all(slot["color"] == 0 for slot in frame[1:]))

    def test_service_restoration_marker_survives_stop_failure(self):
        owner = HerdrOwner(Path(self.directory.name), manage=True)
        owner.command = Mock(side_effect=[0, 1])
        with self.assertRaises(RuntimeError):
            owner.acquire()
        self.assertTrue(owner.marker.exists())
        owner.command = Mock(return_value=0)
        owner.restore()
        owner.command.assert_called_once_with("start", "herdr-bridge.service")
        self.assertFalse(owner.marker.exists())

    def test_shared_per_device_lock_prevents_a_second_integration(self):
        hub = Path(self.directory.name) / "microd.sock"
        first = HerdrOwner(Path(self.directory.name), micro_path=hub)
        second = HerdrOwner(Path(self.directory.name), micro_path=hub)
        first.command = second.command = Mock(return_value=3)
        with patch("pathlib.Path.iterdir", return_value=[]):
            first.acquire()
            self.assertTrue(hub.with_suffix(".integration.lock").exists())
            with self.assertRaises(BlockingIOError):
                second.acquire()
            first.restore()
            second.acquire()
            second.restore()

    def test_no_implicit_takeover_or_start_of_previously_inactive_service(self):
        owner = HerdrOwner(Path(self.directory.name))
        owner.command = Mock(return_value=0)
        with self.assertRaises(RuntimeError):
            owner.acquire()
        self.assertFalse(owner.marker.exists())
        owner.restore()
        owner.command.assert_called_once_with("is-active", "--quiet", "herdr-bridge.service")


if __name__ == "__main__":
    unittest.main()
