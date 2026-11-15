#!/usr/bin/env python3
"""Build MagiBoard using Xcode; personal signing settings stay outside source control."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parent


def signing_team(root=ROOT):
    team = os.environ.get("MAGIBOARD_TEAM", "").strip()
    if not team:
        config = root / ".local/signing.json"
        if config.is_file():
            try:
                team = str(json.loads(config.read_text()).get("developmentTeam", "")).strip()
            except (OSError, ValueError) as error:
                raise SystemExit("Could not read .local/signing.json. Use a JSON object with developmentTeam.") from error
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise SystemExit("For device builds, set MAGIBOARD_TEAM to your Apple development team ID, or save it as developmentTeam in the ignored .local/signing.json file.")
    return team


def simulator_destination(preferred=None):
    result = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "--json"],
        check=True, capture_output=True, text=True)
    inventory = json.loads(result.stdout).get("devices", {})
    choices = []
    for runtime, devices in inventory.items():
        if ".iOS-" not in runtime:
            continue
        version = tuple(int(part) for part in re.findall(r"\d+", runtime.split(".iOS-")[-1]))
        for device in devices:
            if device.get("isAvailable", True):
                choices.append((device, version))
    if preferred:
        choices = [choice for choice in choices if preferred in (choice[0].get("udid"), choice[0].get("name"))]
    if not choices:
        raise SystemExit("No matching iOS Simulator is available. Install an iOS simulator runtime in Xcode, then try again.")
    # Prefer an iPad for the notebook UI, retaining an already-booted iPad when possible.
    choices.sort(key=lambda choice: ("iPad" in choice[0].get("name", ""),
        choice[0].get("state") == "Booted", choice[1], choice[0].get("name", "")), reverse=True)
    return "platform=iOS Simulator,id=" + choices[0][0]["udid"]


def main():
    parser = argparse.ArgumentParser(description="Build or test the native MagiBoard prototype")
    parser.add_argument("mode", nargs="?", default="simulator", choices=("simulator", "device", "test"))
    parser.add_argument("--simulator", default=os.environ.get("MAGIBOARD_SIMULATOR"),
        help="Simulator name or UDID for tests; default selects an available iPad")
    parser.add_argument("--only-testing", action="append", default=[], metavar="TARGET[/SUITE[/TEST]]")
    parser.add_argument("--skip-testing", action="append", default=[], metavar="TARGET[/SUITE[/TEST]]")
    args = parser.parse_args()
    device = args.mode == "device"
    destination = "generic/platform=iOS" if device else (
        simulator_destination(args.simulator) if args.mode == "test" else "generic/platform=iOS Simulator")
    command = ["xcodebuild", "-project", str(ROOT / "CanvasStudio.xcodeproj"), "-scheme", "CanvasStudio",
        "-configuration", "Debug", "-sdk", "iphoneos" if device else "iphonesimulator",
        "-destination", destination, "-derivedDataPath", str(ROOT / ("build-device" if device else "build"))]
    command += ["-allowProvisioningUpdates", "DEVELOPMENT_TEAM=" + signing_team()] if device else ["CODE_SIGNING_ALLOWED=NO"]
    command += ["-only-testing:" + name for name in args.only_testing]
    command += ["-skip-testing:" + name for name in args.skip_testing]
    subprocess.run(command + ["test" if args.mode == "test" else "build"], check=True)


if __name__ == "__main__":
    main()
