"""Protocol and validation tests. No subscription calls or credentials required."""
import copy
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer
from server import BridgeError, CanvasBridge, DEFAULTS, Handler, output_schema, validate_response, attach_generated_images


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.id = str(uuid.uuid4())
        self.object = {**DEFAULTS, "id": self.id, "kind": "shape", "shape": "triangle", "propertiesJSON": '{"angleA":49,"angleB":52,"angleC":79}'}
        self.raw = {"message": "Created triangle", "operations": [{"type": "add", "id": self.id, "object": self.object}]}

    def test_normalizes_structured_properties(self):
        result = validate_response(self.raw)
        self.assertEqual(result["operations"][0]["object"]["properties"]["angleC"], 79)
        self.assertNotIn("propertiesJSON", result["operations"][0]["object"])

    def test_rejects_nonfinite_geometry(self):
        self.object["x"] = float("nan")
        with self.assertRaises(BridgeError):
            validate_response(self.raw)

    def test_rejects_negative_size(self):
        self.object["width"] = -1
        with self.assertRaises(BridgeError):
            validate_response(self.raw)

    def test_rejects_missing_update_target(self):
        self.raw["operations"][0]["type"] = "update"
        with self.assertRaises(BridgeError):
            validate_response(self.raw, [])

    def test_update_preserves_id(self):
        self.raw["operations"][0]["type"] = "update"
        result = validate_response(self.raw, [self.id])
        self.assertEqual(result["operations"][0]["id"], self.id)

    def test_update_accepts_swift_uppercase_uuid(self):
        self.raw["operations"][0]["type"] = "update"
        result = validate_response(self.raw, [self.id.upper()])
        self.assertEqual(result["operations"][0]["id"], self.id)

    def test_rejects_unrelated_delete(self):
        with self.assertRaises(BridgeError):
            validate_response({"operations": [{"type": "delete", "id": self.id}]}, [])

    def test_duplicates_get_fresh_ids(self):
        result = validate_response(self.raw, [self.id])
        self.assertNotEqual(result["operations"][0]["id"], self.id)

    def test_rejects_invalid_properties(self):
        self.object["propertiesJSON"] = '{"x":"not numeric"}'
        with self.assertRaises(BridgeError):
            validate_response(self.raw)

    def test_schema_has_no_extra_top_fields(self):
        self.assertFalse(output_schema()["additionalProperties"])

    def test_pdf_insert_uses_known_document_and_one_based_page(self):
        documents = [{"id": self.id, "title": "Original exercises", "pages": 400}]
        raw = {"operations": [{"type": "insertPDF", "documentID": self.id.upper(), "page": 350, "x": -100, "y": None}]}
        result = validate_response(raw, documents=documents)
        self.assertEqual(result["operations"], [{"type": "insertPDF", "documentID": self.id, "page": 350, "x": -100.0}])

    def test_pdf_insert_rejects_unknown_pages_and_excessive_batch(self):
        documents = [{"id": self.id, "title": "Original exercises", "pages": 400}]
        valid = {"type": "insertPDF", "documentID": self.id, "page": 350}
        for invalid in ({**valid, "documentID": "file:///private/book.pdf"}, {**valid, "documentID": str(uuid.uuid4())},
                        {**valid, "page": 0}, {**valid, "page": 401}, {**valid, "page": True}, {**valid, "x": float("inf")}):
            with self.subTest(invalid=invalid), self.assertRaises(BridgeError):
                validate_response({"operations": [self.raw["operations"][0], invalid]}, documents=documents)
        with self.assertRaises(BridgeError):
            validate_response({"operations": [valid] * 5}, documents=documents)


class ImageAttachmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.thread = str(uuid.uuid4())
        self.folder = self.root / self.thread
        self.folder.mkdir()
        self.image = self.folder / "generated.png"
        self.image.write_bytes(b"\x89PNG\r\n\x1a\nexample")
        self.events = json.dumps({"type": "thread.started", "thread_id": self.thread})
    def tearDown(self):
        self.temp.cleanup()
    def test_attaches_only_this_turn_image(self):
        raw = {"operations": [{"object": {"kind": "image", "imagePath": str(self.image)}}]}
        attach_generated_images(raw, self.events, self.root)
        self.assertTrue(raw["operations"][0]["object"]["imageData"])
        self.assertNotIn("imagePath", raw["operations"][0]["object"])
    def test_rejects_another_turn_image(self):
        raw = {"operations": [{"object": {"imagePath": str(self.image)}}]}
        wrong = json.dumps({"type": "thread.started", "thread_id": str(uuid.uuid4())})
        with self.assertRaises(BridgeError):
            attach_generated_images(raw, wrong, self.root)
    def test_rejects_path_escape(self):
        other = self.root / "private.png"
        other.write_bytes(b"\x89PNGprivate")
        raw = {"operations": [{"object": {"imagePath": str(other)}}]}
        with self.assertRaises(BridgeError):
            attach_generated_images(raw, self.events, self.root)
    def test_rejects_symlink(self):
        alias = self.folder / "alias.png"
        alias.symlink_to(self.image)
        raw = {"operations": [{"object": {"imagePath": str(alias)}}]}
        with self.assertRaises(BridgeError):
            attach_generated_images(raw, self.events, self.root)


class FakeAuth:
    def device_login(self):
        return {"verificationUrl": "https://auth.openai.com/codex/device", "userCode": "test-only", "loginId": "id"}


class FakeBridge:
    token = "test-bearer-token"
    auth = FakeAuth()
    def status(self):
        return {"connected": True, "provider": "chatgpt"}
    def generate(self, data):
        return {"message": data["prompt"], "operations": []}
    def disconnect(self):
        self.token = "new-token"
        return {"message": "Disconnected"}


class FakeCatalog:
    def status(self):
        return {"configured": True, "connected": True, "provider": "Databricks"}
    def list_objects(self):
        return {"objects": [{"id": "snapshot", "title": "Test object"}], "truncated": False}
    def save_object(self, obj):
        return {"entry": {"id": "snapshot", "title": obj["title"]}}
    def load_object(self, ident):
        return {"entry": {"id": ident}, "object": {"title": "Test object"}}


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.bridge = FakeBridge()
        self.server.bridge.catalog = FakeCatalog()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:" + str(self.server.server_port)
    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
    def request(self, path, data=None, token="test-bearer-token", headers=None):
        h = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
        h.update(headers or {})
        req = urllib.request.Request(self.url + path, json.dumps(data).encode() if data is not None else None, h)
        return json.load(urllib.request.urlopen(req, timeout=3))
    def test_requires_pairing(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.request("/status", token="wrong")
        self.assertEqual(ctx.exception.code, 401)
    def test_reports_account_status(self):
        self.assertTrue(self.request("/status")["connected"])
    def test_rejects_browser_origins(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.request("/status", headers={"Origin": "https://example.com"})
        self.assertEqual(ctx.exception.code, 403)
    def test_generates_with_authorized_request(self):
        self.assertEqual(self.request("/generate", {"prompt": "Triangle"})["message"], "Triangle")
    def test_device_login_contract(self):
        self.assertIn("userCode", self.request("/auth/start", {}))
    def test_disconnect_revokes_token(self):
        self.request("/disconnect", {})
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.request("/status")
        self.assertEqual(ctx.exception.code, 401)
    def test_unknown_route(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.request("/unknown")
        self.assertEqual(ctx.exception.code, 404)

    def test_cloud_catalog_http_contract(self):
        self.assertTrue(self.request("/catalog/status")["connected"])
        self.assertEqual(self.request("/catalog/objects")["objects"][0]["title"], "Test object")
        self.assertEqual(self.request("/catalog/objects", {"object": {"title": "Saved"}})["entry"]["title"], "Saved")
        self.assertEqual(self.request("/catalog/objects/snapshot")["entry"]["id"], "snapshot")

    def test_cloud_catalog_requires_bearer_for_reads_and_writes(self):
        for path, data in (("/catalog/status", None), ("/catalog/objects", None), ("/catalog/objects/snapshot", None), ("/catalog/objects", {"object": {}})):
            with self.subTest(path=path), self.assertRaises(urllib.error.HTTPError) as ctx:
                self.request(path, data, token="wrong")
            self.assertEqual(ctx.exception.code, 401)


if __name__ == "__main__":
    unittest.main()
