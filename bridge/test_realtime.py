"""Voice credential isolation and protocol checks; no live API calls."""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock
import urllib.error
import urllib.request

from realtime import ENDPOINT, MODEL, MAX_RESPONSE, NoRedirect, RealtimeBootstrap, RealtimeError, voice_session


class RealtimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.key = "sk-" + "testOnlyNonCredential" * 3
        self.keyfile = self.root / "private-key"
        self.keyfile.write_text(self.key)
        self.keyfile.chmod(0o600)
        self.config = self.root / "realtime.json"
        self.config.write_text(json.dumps({"enabled": True, "keyFile": str(self.keyfile)}))
        self.opener = Mock()
        self.bridge = RealtimeBootstrap(self.root, opener=self.opener, clock=lambda: 1000)
        self.response({"value": "ek_testOnlyEphemeral", "expires_at": 1060,
            "session": {"private": "must never return"}})

    def tearDown(self):
        self.temp.cleanup()

    def response(self, value):
        self.opener.open.return_value = io.BytesIO(json.dumps(value).encode())

    def test_only_ephemeral_token_crosses_boundary_and_fixed_session_reaches_api(self):
        result = self.bridge.create_session({})
        self.assertEqual(result, {"token": "ek_testOnlyEphemeral", "model": MODEL, "expiresAt": 1060})
        request = self.opener.open.call_args.args[0]
        self.assertEqual(request.full_url, ENDPOINT)
        self.assertEqual(request.get_header("Authorization"), "Bearer " + self.key)
        body = json.loads(request.data)
        self.assertEqual(body["expires_after"], {"anchor": "created_at", "seconds": 60})
        self.assertEqual(body["session"]["model"], MODEL)
        self.assertEqual(body["session"]["audio"]["input"]["format"], {"type": "audio/pcm", "rate": 24000})
        self.assertEqual(body["session"]["audio"]["input"]["transcription"]["model"], "gpt-4o-mini-transcribe")
        self.assertEqual(body["session"]["audio"]["output"]["format"]["rate"], 24000)
        self.assertTrue(body["session"]["audio"]["input"]["turn_detection"]["interrupt_response"])
        self.assertNotIn(self.key, json.dumps(result))
        self.assertEqual(self.opener.open.call_args.kwargs["timeout"], 20)

    def test_status_returns_no_key_path_and_does_not_call_api(self):
        status = self.bridge.status()
        self.assertEqual(status, {"realtimeAvailable": True, "realtimeModel": MODEL})
        self.assertNotIn(str(self.keyfile), json.dumps(status))
        self.assertNotIn(self.key, json.dumps(status))
        self.opener.open.assert_not_called()

    def test_missing_disabled_or_malformed_config_cannot_start_voice(self):
        for value in ({"enabled": False, "keyFile": str(self.keyfile)}, [], {"enabled": True, "keyFile": "relative"}):
            self.config.write_text(json.dumps(value))
            self.assertFalse(self.bridge.status()["realtimeAvailable"])
            with self.assertRaises(RealtimeError):
                self.bridge.create_session({})
        self.config.unlink()
        self.assertFalse(self.bridge.status()["realtimeAvailable"])
        self.opener.open.assert_not_called()

    def test_key_file_requires_one_bounded_key(self):
        for value in ("", self.key + "\nother", "not-a-key", "x" * 16385):
            self.keyfile.write_text(value)
            with self.assertRaises(RealtimeError):
                self.bridge.create_session({})
        self.opener.open.assert_not_called()

    def test_client_cannot_override_model_endpoint_instructions_or_tools(self):
        for value in ({"model": "other"}, {"endpoint": "https://example.com"}, {"session": {}}, {"tools": []}, []):
            with self.subTest(value=value), self.assertRaises(RealtimeError):
                self.bridge.create_session(value)
        self.opener.open.assert_not_called()

    def test_rejects_expired_malformed_or_oversized_response(self):
        for result in ({"value": "ek_x", "expires_at": 999}, {"value": "ek_x", "expires_at": 99999},
                       {"value": "ek_x", "expires_at": True}, {"value": "", "expires_at": 1060}, [],
                       {"value": "x" * MAX_RESPONSE, "expires_at": 1060}):
            self.response(result)
            with self.subTest(result=str(result)[:80]), self.assertRaises(RealtimeError):
                self.bridge.create_session({})

    def test_provider_errors_are_sanitized_and_slot_released(self):
        for code in (400, 401, 403, 429, 500):
            self.opener.open.side_effect = urllib.error.HTTPError(ENDPOINT, code, self.key, {}, io.BytesIO(self.key.encode()))
            with self.assertRaises(RealtimeError) as context:
                self.bridge.create_session({})
            self.assertNotIn(self.key, str(context.exception))
        self.opener.open.side_effect = None
        self.response({"value": "ek_test", "expires_at": 1060})
        self.assertEqual(self.bridge.create_session({})["token"], "ek_test")

    def test_bounded_concurrency_and_no_redirect(self):
        self.bridge.slots.acquire()
        self.bridge.slots.acquire()
        with self.assertRaises(RealtimeError):
            self.bridge.create_session({})
        self.opener.open.assert_not_called()
        self.assertIsNone(NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://example.com"))

    def test_tools_use_bounded_native_edit_contract_and_distinct_queued_jobs(self):
        tools = {item["name"]: item for item in voice_session()["tools"]}
        self.assertEqual(set(tools), {"edit_canvas", "submit_canvas_task"})
        edits = tools["edit_canvas"]["parameters"]
        self.assertFalse(edits["additionalProperties"])
        self.assertEqual(set(edits["required"]), {"referenceID", "message", "operations"})
        self.assertEqual(edits["properties"]["operations"]["maxItems"], 24)
        operation = edits["properties"]["operations"]["items"]
        self.assertEqual(set(operation["required"]), set(operation["properties"]))
        self.assertNotIn("widget", operation["properties"]["kind"]["enum"])
        self.assertEqual(operation["properties"]["color"]["pattern"], "^#[0-9A-Fa-f]{6}$")
        self.assertEqual(tools["submit_canvas_task"]["parameters"]["properties"]["prompt"]["maxLength"], 16000)


if __name__ == "__main__":
    unittest.main()
