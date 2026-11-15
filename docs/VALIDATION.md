# MagiBoard v0.3 validation scope

MagiBoard is a development prototype. Native simulator and signed-device builds have been produced during development, and the app has been installed and launched on an iPad Pro. Automated coverage verifies important document, rendering, connection, and lifecycle behavior; it does not establish production readiness or physical Pencil and microphone performance.

## Run the suites

Open `CanvasStudio.xcodeproj`, choose the **CanvasStudio** scheme and an available iPad simulator, then run **Product → Test**. Use the test report from that run for the current result; this document intentionally contains no machine-specific simulator identifiers or private build paths.

Companion tests run from the project directory:

```sh
cd bridge
python3 -m unittest discover -p 'test_*.py' -v
```

The standalone checks in `Tests/ModelTests.swift`, `Tests/StoreTests.swift`, and `Tests/PDFLibraryChecks.swift` have their own entry points and are excluded from the XCTest targets.

## Coverage

| Area | Checks |
| --- | --- |
| Documents | Transaction rollback, undo/redo, grouped ink edits, failed-save recovery, import isolation, serialization, secret exclusion |
| Geometry and rendering | Exact triangle angles, graph expression parsing, crop exports with actual ink, portrait/landscape framing |
| Equations | Fraction/script baselines, roots and limits, parser bounds and errors, bare rendering, live editor templates and saved source |
| Interactive objects | Validated canvas-wide creation/duplication, atomic batches, mutation limits, explicit Interact/Done, undo |
| Concurrent tasks | Out-of-order completion, captured reference isolation, handwriting preservation, stale-update rejection, independent cancellation, gesture/agent undo boundaries |
| Catalog and imports | Property-control value validation, legacy compatibility, oriented/downsampled image imports, portable object packages, explicit cloud save/load |
| Canvas navigation | Negative-coordinate writing, native-origin rebasing, stable world positions, existing-ink compatibility, camera/undo behavior |
| Native UI | Drawing, Hand navigation, object selection and movement, graph editing, offline Magic Pen, toolbar/page controls, categorized Settings |
| Voice lifecycle | Late permission responses, cancellation, exactly-once utterance delivery, blank speech, duplicate turns, playback completion, inactive startup |
| PDF library | Preservation of original bytes, text search, natural query matching, page insertion, raster bounds, reload |
| Companion | Bearer enforcement, origin rejection, token rotation, device-login shape, object validation, generated-image path confinement, executable discovery, process lifecycle |
| Discovery and capabilities | Secret-free Bonjour metadata, real service registration/resolution, native speech capability reporting |

The earlier v0.2 release passed 29 native XCTest checks and 43 Python tests. Three additional delayed-network simulator checks verified that stale account status and login responses cannot restore a disconnected session. The user confirmed dictation and spoken canvas actions on the physical iPad after that release.

For v0.3, all **45 native unit tests** passed: 5 independent-task/image checks, 12 renderer/widget/camera checks, 7 equation checks, 11 store/schema checks, 6 voice lifecycle checks, and 4 cloud catalog/package checks. All **14 native UI regressions** passed across the full and targeted runs, for **59 native checks** total. The pinch test uses a gesture large enough to pass UIKit’s recognition threshold; the equation editor test uses the native Select All menu to avoid unreliable synthetic hardware-key selection. All **61 Python tests** passed. The signed device build succeeded and was installed and launched on the connected iPad with saved notebooks and pairing preserved.

The standalone suites previously passed 12 model checks, 10 store checks, and 8 PDF checks. Physical microphone and Apple Pencil experience still require the hands-on checks below.

## Live integration evidence

Live checks on November 15, 2026 used the Mac's existing ChatGPT sign-in without an API key. They retrieved account status, generated the requested triangle with 49°, 52°, and 79° angles, created a tappable coin widget, and returned a generated raster image with image bytes attached.

The v0.3 live checks also ran two independent requests concurrently with different reference regions, generated editable bare equations and exposed graph controls, and transcribed a fraction through the running companion's authenticated HTTP endpoint. Databricks managed-volume save/list/load preserved a synthetic object's identity and geometry. Only an original synthetic demo object was uploaded during these checks; user notebooks were not uploaded, and the SQL warehouse remained stopped.

The independent background launcher was exercised with isolated temporary state: start, duplicate-start prevention, authenticated status, private runtime-file permissions, and graceful stop. Bonjour registration and resolution were also verified on macOS.

A separate realtime-audio probe exposed an account/runtime limit: startup was rejected with **“realtime conversation requires API key auth.”** No microphone audio was captured by that probe. MagiBoard therefore uses native recognition, Codex text requests, and native synthesis. [Voice findings](../bridge/VOICE_NOTES.md) record the exact scope of that result.

## Physical-device checks still needed

- Sustained Apple Pencil writing, pressure, palm rejection, tool switching, and long-session memory use.
- Microphone and speech permission flows, recognition accuracy, spoken replies, silence timing, and Bluetooth/headset changes.
- Conversation latency and recovery from interrupted audio, failed requests, weak Wi-Fi, sleep, and app backgrounding.
- Large notebooks, extended widget execution, full accessibility navigation, and broader device/orientation coverage.

Simulator and state-machine tests cannot substitute for these checks. Device-code authentication follows the official protocol; the existing account was not replaced merely to exercise sign-in during development.
