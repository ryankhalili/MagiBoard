"""Concurrent request isolation and inspector control validation, without model calls."""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

from server import BridgeError, CanvasBridge, DEFAULTS, GenerationSlots, validate_property_specs


class PropertyControlTests(unittest.TestCase):
    def test_slider_preserves_exposed_range_and_label(self):
        specs = validate_property_specs([{"key": "gravity", "label": "Gravity", "control": "slider",
            "min": 0, "max": 30, "step": 0.1, "unit": "m/s²"}], {"gravity": 9.81})
        self.assertEqual(specs[0]["min"], 0)
        self.assertEqual(specs[0]["label"], "Gravity")
        self.assertEqual(specs[0]["choices"], [])

    def test_unknown_property_and_duplicate_controls_are_rejected(self):
        with self.assertRaises(BridgeError):
            validate_property_specs([{"key": "missing"}], {})
        with self.assertRaises(BridgeError):
            validate_property_specs([{"key": "a"}, {"key": "a"}], {"a": 1})

    def test_slider_without_valid_bounds_is_rejected(self):
        for limits in ({}, {"min": 1, "max": 0, "step": 1}, {"min": 0, "max": 3, "step": 0}):
            with self.subTest(limits=limits), self.assertRaises(BridgeError):
                validate_property_specs([{"key": "a", "control": "slider", **limits}], {"a": 1})

    def test_choice_and_toggle_values_match_their_controls(self):
        choice = {"key": "mode", "control": "choice", "choices": [{"label": "Slow", "value": 0}, {"label": "Fast", "value": 1}]}
        self.assertEqual(validate_property_specs([choice], {"mode": 1})[0]["choices"][1]["label"], "Fast")
        with self.assertRaises(BridgeError):
            validate_property_specs([choice], {"mode": 2})
        with self.assertRaises(BridgeError):
            validate_property_specs([{"key": "enabled", "control": "toggle"}], {"enabled": 0.5})


class ConcurrentGenerationTests(unittest.TestCase):
    def make_bridge(self, folder):
        bridge = CanvasBridge.__new__(CanvasBridge)
        bridge.state_dir = Path(folder)
        bridge.codex = "fake-codex"
        bridge.model = None
        bridge.busy = GenerationSlots(4)
        return bridge

    def test_four_turns_are_isolated_and_fifth_is_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            bridge = self.make_bridge(folder)
            entered, release = threading.Event(), threading.Event()
            lock = threading.Lock()
            contexts, directories, efforts = [], [], []
            def run(command, **kwargs):
                context = json.loads(kwargs["input"].split("\n\nCanvas request:\n")[1])
                with lock:
                    contexts.append(context)
                    directories.append(kwargs["cwd"])
                    efforts.append((context["prompt"], next(value for value in command if value.startswith("model_reasoning_effort="))))
                    if len(contexts) == 4:
                        entered.set()
                self.assertTrue(release.wait(5))
                ident = str(uuid.uuid4())
                obj = {**DEFAULTS, "id": ident, "kind": "text", "text": context["prompt"], "x": context["reference"]["x"]}
                result = {"message": context["prompt"], "operations": [{"type": "add", "id": ident, "object": obj}]}
                (kwargs["cwd"] / "response.json").write_text(json.dumps(result))
                return subprocess.CompletedProcess(command, 0, "", "")
            levels = ["low", "medium", "high", "xhigh"]
            requests = [{"prompt": "request " + str(index), "objects": [], "reference": {"x": index * 100}, "reasoningEffort": levels[index]} for index in range(4)]
            with patch("server.subprocess.run", side_effect=run), concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                futures = [pool.submit(bridge.generate, request) for request in requests]
                try:
                    self.assertTrue(entered.wait(5))
                    self.assertEqual(bridge.busy.active, 4)
                    with self.assertRaisesRegex(BridgeError, "Four canvas requests"):
                        bridge.generate({"prompt": "fifth", "objects": []})
                    requests[0]["reference"]["x"] = -999
                finally:
                    release.set()
                results = [future.result(timeout=5) for future in futures]
            self.assertEqual([result["operations"][0]["object"]["x"] for result in results], [0, 100, 200, 300])
            self.assertEqual([result["message"] for result in results], ["request " + str(index) for index in range(4)])
            self.assertEqual(len(set(directories)), 4)
            self.assertEqual(dict(efforts), {"request " + str(index): f'model_reasoning_effort="{level}"' for index, level in enumerate(levels)})
            self.assertEqual(bridge.busy.active, 0)

    def test_missing_effort_uses_real_low_cli_override(self):
        with tempfile.TemporaryDirectory() as folder:
            bridge = self.make_bridge(folder)
            def run(command, **kwargs):
                overrides = [command[index + 1] for index, value in enumerate(command[:-1]) if value == "-c"]
                self.assertEqual([value for value in overrides if value.startswith("model_reasoning_effort=")], ['model_reasoning_effort="low"'])
                (kwargs["cwd"] / "response.json").write_text(json.dumps({"message": "Done", "operations": []}))
                return subprocess.CompletedProcess(command, 0, "", "")
            with patch("server.subprocess.run", side_effect=run) as execute:
                bridge.generate({"prompt": "test", "objects": []})
                execute.assert_called_once()

    def test_invalid_effort_rejected_before_running_codex(self):
        with tempfile.TemporaryDirectory() as folder:
            bridge = self.make_bridge(folder)
            for value in (None, 1, [], "", "HIGH", "ultra", 'low"\n[shell_environment_policy]\ninherit="all'):
                with self.subTest(value=value), patch("server.subprocess.run") as execute:
                    with self.assertRaisesRegex(BridgeError, "thinking level"):
                        bridge.generate({"prompt": "test", "objects": [], "reasoningEffort": value})
                    execute.assert_not_called()
                    self.assertEqual(bridge.busy.active, 0)

    def test_timeout_releases_slot(self):
        with tempfile.TemporaryDirectory() as folder:
            bridge = self.make_bridge(folder)
            with patch("server.subprocess.run", side_effect=subprocess.TimeoutExpired("codex", 390)):
                with self.assertRaisesRegex(BridgeError, "took too long"):
                    bridge.generate({"prompt": "test", "objects": []})
            self.assertEqual(bridge.busy.active, 0)


if __name__ == "__main__":
    unittest.main()
