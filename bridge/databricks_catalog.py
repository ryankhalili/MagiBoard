"""Explicit immutable object snapshots in a configured Databricks volume.

Authentication stays in the official CLI. No SQL, warehouse management, resource
provisioning, automatic upload, overwrite, or deletion is exposed by this module.
"""
from __future__ import annotations

import base64
from datetime import datetime, timezone
import hashlib
import hmac
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import threading
import uuid


MAX_OBJECT_BYTES = 12 * 1024 * 1024
MAX_METADATA_BYTES = 2 * 1024 * 1024
SUFFIX = ".magiboard-object.json"
KINDS = {"text", "shape", "graph", "image", "widget", "latex", "frame"}


class CatalogError(Exception):
    pass


def object_bytes(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def make_entry(obj, snapshot_id=None, now=None):
    title = str(obj.get("title") or {"latex": "Equation", "widget": "Interactive object"}.get(obj["kind"], obj["kind"].capitalize()))
    title = "".join(char for char in title if char.isprintable()).encode("utf-8")[:64].decode("utf-8", errors="ignore") or "Object"
    moment = (now or datetime.now(timezone.utc)).astimezone(timezone.utc).replace(microsecond=0)
    entry = {"id": str(snapshot_id or uuid.uuid4()), "title": title, "kind": obj["kind"],
        "createdAt": moment.isoformat().replace("+00:00", "Z"), "schemaVersion": 1}
    encoded_title = base64.urlsafe_b64encode(title.encode()).decode().rstrip("=")
    filename = "~".join([moment.strftime("%Y%m%dT%H%M%SZ"), entry["kind"], encoded_title, entry["id"]]) + SUFFIX
    return entry, filename


def parse_filename(filename):
    if not isinstance(filename, str) or PurePosixPath(filename).name != filename or not filename.endswith(SUFFIX):
        return None
    parts = filename[:-len(SUFFIX)].split("~")
    if len(parts) != 4:
        return None
    stamp, kind, title, ident = parts
    try:
        if kind not in KINDS or not re.fullmatch(r"[A-Za-z0-9_-]{1,88}", title) or str(uuid.UUID(ident)) != ident:
            return None
        moment = datetime.strptime(stamp, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        decoded = base64.b64decode(title + "=" * (-len(title) % 4), altchars=b"-_", validate=True).decode("utf-8")
        if not decoded or not all(char.isprintable() for char in decoded):
            return None
        return {"id": ident, "title": decoded, "kind": kind,
            "createdAt": moment.isoformat().replace("+00:00", "Z"), "schemaVersion": 1}
    except (ValueError, UnicodeDecodeError):
        return None


class DatabricksCatalog:
    def __init__(self, state_dir, validate_object):
        self.state_dir = Path(state_dir)
        self.validate_object = validate_object
        self.profile = self.volume = self.cli = None
        config_path = self.state_dir / "databricks.json"
        if not config_path.exists():
            return
        try:
            config = json.loads(config_path.read_text())
            if not config.get("enabled", False):
                return
            profile, volume = config.get("profile", ""), config.get("volume", "")
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", profile):
                return
            if not re.fullmatch(r"/Volumes/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+", volume):
                return
            binary = shutil.which("databricks") or str(Path.home() / ".local/bin/databricks")
            if not Path(binary).is_file():
                return
            self.profile, self.volume, self.cli = profile, volume, binary
        except (OSError, ValueError, TypeError, AttributeError):
            pass

    @property
    def configured(self):
        return bool(self.cli and self.profile and self.volume)

    def _run(self, args, *, raw=False):
        if not self.configured:
            raise CatalogError("Configure Databricks on the Mac companion before using the cloud catalog.")
        limit = MAX_OBJECT_BYTES if raw else MAX_METADATA_BYTES
        command = [self.cli, *args, "--profile", self.profile]
        if not raw:
            command += ["--output", "json"]
        try:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            timer = threading.Timer(60, process.kill)
            timer.start()
            try:
                output = process.stdout.read(limit + 1)
                if len(output) > limit:
                    process.kill()
                    raise CatalogError("The cloud catalog item is too large.")
                if process.wait(timeout=5):
                    raise CatalogError("Databricks could not complete the catalog request. Check the Mac sign-in and volume permissions.")
            finally:
                timer.cancel()
                if process.poll() is None:
                    process.kill()
                process.wait()
                process.stdout.close()
            return output if raw else json.loads(output or b"{}")
        except (OSError, ValueError, subprocess.TimeoutExpired):
            raise CatalogError("The cloud catalog is unavailable. Check the Mac companion's Databricks connection.") from None

    def status(self):
        result = {"configured": self.configured, "connected": False, "provider": "Databricks",
            "message": "Cloud catalog is not configured on this Mac."}
        if self.configured:
            try:
                self._run(["volumes", "read", ".".join(self.volume.split("/")[2:])])
                result.update(connected=True, message="Cloud object catalog is connected.")
            except CatalogError as error:
                result["message"] = str(error)
        return result

    def _entries(self):
        if not self.configured:
            raise CatalogError("Configure Databricks on the Mac companion before using the cloud catalog.")
        response = self._run(["api", "get", "/api/2.0/fs/directories" + self.volume + "/objects?page_size=200"])
        if not isinstance(response, dict):
            raise CatalogError("The cloud catalog returned unreadable metadata.")
        entries = []
        for record in response.get("contents", []):
            if not isinstance(record, dict) or record.get("is_directory"):
                continue
            filename = PurePosixPath(str(record.get("path", record.get("name", "")))).name
            entry = parse_filename(filename)
            if entry:
                entries.append((entry, filename))
        entries.sort(key=lambda value: (value[0]["createdAt"], value[0]["id"]), reverse=True)
        return entries, bool(response.get("next_page_token"))

    def list_objects(self):
        entries, truncated = self._entries()
        return {"objects": [entry for entry, _ in entries], "truncated": truncated}

    def save_object(self, obj):
        if not self.configured:
            raise CatalogError("Configure Databricks on the Mac companion before using the cloud catalog.")
        obj = self.validate_object(obj)
        encoded_object = object_bytes(obj)
        if len(encoded_object) > MAX_OBJECT_BYTES - 2048:
            raise CatalogError("This object is too large for the cloud catalog.")
        entry, filename = make_entry(obj)
        package = {"format": "magiboard-object", "schemaVersion": 1, "entry": entry, "object": obj,
            "sha256": hashlib.sha256(encoded_object).hexdigest()}
        with tempfile.TemporaryDirectory(prefix="catalog-save-", dir=self.state_dir) as folder:
            path = Path(folder) / "object.json"
            path.write_bytes(object_bytes(package))
            # Unique snapshot filename; no --overwrite flag, even for a collision.
            self._run(["fs", "cp", str(path), "dbfs:" + self.volume + "/objects/" + filename], raw=True)
        return {"entry": entry}

    def load_object(self, ident):
        try:
            ident = str(uuid.UUID(ident))
        except (ValueError, TypeError):
            raise CatalogError("Choose a valid cloud catalog item.")
        entries, _ = self._entries()
        match = next(((entry, filename) for entry, filename in entries if entry["id"] == ident), None)
        if not match:
            raise CatalogError("That cloud catalog item could not be found in the current listing.")
        entry, filename = match
        data = self._run(["fs", "cat", "dbfs:" + self.volume + "/objects/" + filename], raw=True)
        try:
            package = json.loads(data)
            obj = package.get("object")
            if package.get("format") != "magiboard-object" or package.get("schemaVersion") != 1 or package.get("entry") != entry:
                raise ValueError()
            digest = hashlib.sha256(object_bytes(obj)).hexdigest()
            if not hmac.compare_digest(digest, str(package.get("sha256", ""))):
                raise ValueError()
            obj = self.validate_object(obj)
        except (ValueError, TypeError, AttributeError):
            raise CatalogError("The cloud object is damaged or uses an unsupported format.") from None
        return {"entry": entry, "object": obj}
