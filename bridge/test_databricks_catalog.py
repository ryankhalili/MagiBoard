"""Cloud object validation and immutable snapshots; no network calls."""
import base64
import json
from pathlib import Path
import tempfile
import unittest
import uuid

from databricks_catalog import CatalogError, DatabricksCatalog, make_entry, parse_filename
from server import DEFAULTS, validate_catalog_object


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.catalog = DatabricksCatalog(self.temp.name, validate_catalog_object)
        self.catalog.cli, self.catalog.profile, self.catalog.volume = "fake", "TEST", "/Volumes/test/schema/catalog"
        self.files, self.calls = {}, []
        self.object = {**DEFAULTS, "id": str(uuid.uuid4()), "kind": "widget", "title": "A useful coin 🪙",
            "code": "<button>Coin</button>", "properties": {"speed": 1},
            "propertySpecs": [{"key": "speed", "label": "Speed", "control": "slider", "min": 0, "max": 5, "step": 0.1}]}
        self.catalog._run = self.run_cli

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, args, *, raw=False):
        self.calls.append(args)
        if args[:2] == ["fs", "cp"]:
            self.assertNotIn(args[3], self.files)
            self.files[args[3]] = Path(args[2]).read_bytes()
            return b""
        if args[:2] == ["fs", "cat"]:
            return self.files[args[2]]
        if args[:2] == ["api", "get"]:
            return {"contents": [{"path": path.removeprefix("dbfs:"), "is_directory": False} for path in self.files]}
        raise AssertionError("Unexpected cloud action")

    def test_save_list_load_preserves_editable_object_and_specs(self):
        entry = self.catalog.save_object(self.object)["entry"]
        listing = self.catalog.list_objects()["objects"]
        self.assertEqual(listing, [entry])
        loaded = self.catalog.load_object(entry["id"])
        self.assertEqual(loaded["object"]["code"], self.object["code"])
        self.assertEqual(loaded["object"]["properties"], {"speed": 1})
        self.assertEqual(loaded["object"]["propertySpecs"][0]["label"], "Speed")
        self.assertEqual(loaded["object"]["id"], self.object["id"])

    def test_repeated_save_creates_immutable_versions(self):
        first = self.catalog.save_object(self.object)["entry"]
        self.object["properties"]["speed"] = 2
        second = self.catalog.save_object(self.object)["entry"]
        self.assertNotEqual(first["id"], second["id"])
        self.assertEqual(len(self.files), 2)
        self.assertEqual(self.catalog.load_object(first["id"])["object"]["properties"]["speed"], 1)
        self.assertTrue(all("--overwrite" not in args for args in self.calls))

    def test_list_reads_only_bounded_metadata(self):
        self.catalog.save_object(self.object)
        self.calls.clear()
        self.catalog.list_objects()
        self.assertEqual(len(self.calls), 1)
        self.assertIn("page_size=200", self.calls[0][2])
        self.assertEqual(self.calls[0][:2], ["api", "get"])

    def test_corrupt_object_is_rejected_before_import(self):
        entry = self.catalog.save_object(self.object)["entry"]
        key = next(iter(self.files))
        package = json.loads(self.files[key])
        package["object"]["code"] = "changed"
        self.files[key] = json.dumps(package).encode()
        with self.assertRaisesRegex(CatalogError, "damaged"):
            self.catalog.load_object(entry["id"])

    def test_invalid_id_cannot_escape_volume(self):
        with self.assertRaises(CatalogError):
            self.catalog.load_object("../../other-volume/private")
        self.assertEqual(self.calls, [])

    def test_bad_image_never_uploads(self):
        self.object["imageData"] = base64.b64encode(b"not an image").decode()
        with self.assertRaises(CatalogError):
            self.catalog.save_object(self.object)
        self.assertEqual(self.files, {})

    def test_unconfigured_catalog_has_no_automatic_setup(self):
        catalog = DatabricksCatalog(self.temp.name, validate_catalog_object)
        self.assertFalse(catalog.status()["configured"])
        with self.assertRaises(CatalogError):
            catalog.list_objects()
        with self.assertRaises(CatalogError):
            catalog.save_object(self.object)

    def test_filename_preserves_unicode_metadata_without_paths(self):
        entry, filename = make_entry(self.object)
        self.assertEqual(parse_filename(filename), entry)
        self.assertNotIn("/", filename)
        self.assertIsNone(parse_filename("../" + filename))
        self.assertIsNone(parse_filename("arbitrary.json"))

    def test_valid_large_native_content_and_alpha_color_are_lossless(self):
        self.object.update(title="A" * 300, text="x" * 50000, code="<script>" + " " * 120000 + "</script>", color="#2563EB80", width=12000)
        self.object["properties"]["largeValue"] = 2_000_000
        entry = self.catalog.save_object(self.object)["entry"]
        loaded = self.catalog.load_object(entry["id"])["object"]
        for key in ("title", "text", "code", "color", "width", "properties"):
            self.assertEqual(loaded[key], self.object[key], key)

    def test_oversized_source_is_rejected_instead_of_truncated(self):
        self.object["code"] = "x" * 524289
        with self.assertRaises(CatalogError):
            self.catalog.save_object(self.object)
        self.assertEqual(self.files, {})


if __name__ == "__main__":
    unittest.main()
