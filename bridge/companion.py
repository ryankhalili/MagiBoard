#!/usr/bin/env python3
"""Launch MagiBoard independently of an editor, chat, or open Terminal window."""
from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

from server import BridgeError, CanvasBridge, DEFAULT_STATE_DIR, HERE, find_codex


def read_status(state_dir, timeout=3):
    """Use the private pairing credential internally; never print it."""
    try:
        pair = json.loads((state_dir / "pairing.canvaspair").read_text())
        request = urllib.request.Request(pair["url"].rstrip("/") + "/status",
            headers={"Authorization": "Bearer " + pair["token"]})
        # Local network traffic must not follow a shell's HTTP proxy setting.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=timeout) as response:
            result = json.load(response)
        return result if isinstance(result, dict) else None
    except (OSError, ValueError, KeyError, urllib.error.URLError):
        return None


def managed_pid(state_dir):
    """Verify both command and birth time so stale PID files cannot kill another app."""
    try:
        record = json.loads((state_dir / "process.json").read_text())
        pid = int(record["pid"])
        if pid <= 1:
            return None
        command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=3).stdout.strip()
        birth = process_birth(pid)
        expected = str(HERE / "server.py")
        if command and expected in command and birth and birth == record["birth"]:
            return pid
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
        pass
    return None


def process_birth(pid):
    return subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="], capture_output=True,
        text=True, timeout=3).stdout.strip()


def start(state_dir, args):
    if managed_pid(state_dir) or read_status(state_dir):
        print("MagiBoard Companion is already running. Open MagiBoard on your iPad.")
        return 0
    codex = find_codex(args.codex)
    command = [sys.executable, str(HERE / "server.py"), "--host", "0.0.0.0", "--port", str(args.port),
        "--state-dir", str(state_dir), "--codex", codex]
    if args.model:
        command += ["--model", args.model]
    if args.no_discovery:
        command.append("--no-discovery")
    fd = os.open(state_dir / "companion.log", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.chmod(state_dir / "companion.log", 0o600)
    with os.fdopen(fd, "ab", buffering=0) as log:
        process = subprocess.Popen(command, cwd=HERE, stdin=subprocess.DEVNULL, stdout=log,
            stderr=log, start_new_session=True, close_fds=True)
    CanvasBridge._save_secret(state_dir / "process.json", json.dumps({"pid": process.pid, "birth": process_birth(process.pid)}))
    deadline = time.monotonic() + 18
    while time.monotonic() < deadline:
        if process.poll() is not None:
            print("MagiBoard could not start. Open the private companion.log in its Application Support folder for details.")
            return 1
        status = read_status(state_dir, timeout=2)
        if status:
            print("MagiBoard Companion is running on " + status.get("displayName", "this Mac") + ".")
            print("You can close this window and this chat. Keep the Mac awake and on the same trusted Wi-Fi as your iPad.")
            if not status.get("connected"):
                print("Connect this Mac in the iPad app, then sign in to your ChatGPT account in Account settings.")
            return 0
        time.sleep(0.25)
    print("MagiBoard is starting. Open the iPad app; use the companion status command if the connection is not ready.")
    return 0


def stop(state_dir):
    pid = managed_pid(state_dir)
    if not pid:
        if read_status(state_dir):
            print("A companion started another way is running. Stop it in its original Terminal window, then use Start MagiBoard.")
            return 1
        print("MagiBoard Companion is stopped.")
        return 0
    status = read_status(state_dir)
    if status and status.get("busy"):
        print("A canvas request is still running. Let it finish, then stop the companion.")
        return 1
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 8
    while managed_pid(state_dir) and time.monotonic() < deadline:
        time.sleep(0.15)
    if managed_pid(state_dir):
        print("The companion is still finishing shutdown. Try again shortly.")
        return 1
    (state_dir / "process.json").unlink(missing_ok=True)
    print("MagiBoard Companion stopped. Your account and iPad pairing are preserved.")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Start or stop the independent MagiBoard Mac companion")
    parser.add_argument("action", choices=("start", "stop", "status", "pair"))
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE_DIR)
    parser.add_argument("--port", type=int, default=8247)
    parser.add_argument("--model")
    parser.add_argument("--codex")
    parser.add_argument("--no-discovery", action="store_true")
    args = parser.parse_args()
    state_dir = args.state_dir.expanduser().resolve()
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_fd = os.open(state_dir / "launcher.lock", os.O_WRONLY | os.O_CREAT, 0o600)
    with os.fdopen(lock_fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            if args.action == "start":
                return start(state_dir, args)
            if args.action == "stop":
                return stop(state_dir)
            if args.action == "pair":
                pair = state_dir / "pairing.canvaspair"
                if not pair.is_file():
                    print("Start MagiBoard Companion first.")
                    return 1
                subprocess.run(["/usr/bin/open", "-R", str(pair)], check=True)
                print("Finder has selected your private pairing file. AirDrop it to your iPad, then import it in MagiBoard Account settings.")
                return 0
            status = read_status(state_dir)
            if status:
                print("MagiBoard Companion is running on " + status.get("displayName", "this Mac") + ".")
                print("ChatGPT account connected." if status.get("connected") else "ChatGPT sign-in is needed in Account settings.")
            else:
                print("MagiBoard Companion is not reachable. Run Start MagiBoard on this Mac.")
            return 0 if status else 1
        except (BridgeError, OSError) as error:
            print(str(error), file=sys.stderr)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
