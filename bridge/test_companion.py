"""Companion discovery, secret separation, and safe lifecycle checks."""
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from companion import managed_pid
from server import BonjourAdvertisement, BridgeError, CanvasBridge, HERE, find_codex


class CompanionTests(unittest.TestCase):
    def test_explicit_codex_must_be_executable(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / "codex"
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o600)
            with self.assertRaises(BridgeError):
                find_codex(str(binary))
            binary.chmod(0o700)
            self.assertEqual(find_codex(str(binary)), str(binary.resolve()))

    def test_bonjour_contains_no_pairing_credential(self):
        with patch("server.subprocess.Popen") as popen:
            service = BonjourAdvertisement("Demo Mac", 8247)
            self.assertTrue(service.start())
            args = popen.call_args.args[0]
            self.assertEqual(args[2:6], ["Demo Mac", "_magiboard._tcp", "local.", "8247"])
            self.assertEqual(args[6:], ["version=1", "displayName=Demo Mac"])

    def test_status_distinguishes_native_voice_from_realtime_audio(self):
        bridge = CanvasBridge.__new__(CanvasBridge)
        bridge.realtime = Mock()
        bridge.realtime.status.return_value = {"realtimeAvailable": False, "realtimeModel": None}
        bridge.auth = Mock()
        bridge.auth.status.return_value = {"connected": True, "provider": "chatgpt"}
        bridge.display_name = "Demo Mac"
        bridge.busy = Mock()
        bridge.busy.locked.return_value = False
        result = bridge.status()
        self.assertEqual(result["displayName"], "Demo Mac")
        self.assertEqual(result["voiceTransport"], "native_speech_text")
        self.assertFalse(result["subscriptionRealtimeAudio"])
        self.assertNotIn("token", result)

    def test_managed_pid_rejects_reused_pid(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "process.json").write_text(json.dumps({"pid": 12345, "birth": "old"}))
            process = Mock(stdout="python3 " + str(HERE / "server.py"))
            with patch("companion.subprocess.run", return_value=process), patch("companion.process_birth", return_value="new"):
                self.assertIsNone(managed_pid(root))

    def test_managed_pid_rejects_other_program(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "process.json").write_text(json.dumps({"pid": 12345, "birth": "same"}))
            with patch("companion.subprocess.run", return_value=Mock(stdout="unrelated-app")), patch("companion.process_birth", return_value="same"):
                self.assertIsNone(managed_pid(root))

    def test_managed_pid_accepts_matching_program_and_birth(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "process.json").write_text(json.dumps({"pid": 12345, "birth": "same"}))
            process = Mock(stdout="python3 " + str(HERE / "server.py"))
            with patch("companion.subprocess.run", return_value=process), patch("companion.process_birth", return_value="same"):
                self.assertEqual(managed_pid(root), 12345)


if __name__ == "__main__":
    unittest.main()
