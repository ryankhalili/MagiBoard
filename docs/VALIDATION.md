# MagiBoard v0.4.0 validation scope

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

The final **v0.4.0** run passed **97 native unit tests** and the new voice-provider Settings UI test. The existing Settings persistence/AI-disable UI test passed in the preceding run. All **77 companion tests** passed. Native additions cover stroke-shaped selection pixels/masks, three concurrent voice tasks with immutable references, tool-result continuation snapshots, Realtime tool deduplication/barge-in state, PCM conversion and playback truncation, spatial PDF question crops/continuations/ambiguity, expression parameters, power precedence, axis fitting, and ticks. An initial PDF test caught a fractional-size bitmap edge that prevented blank-paper trimming; integer raster sizing fixed it and the complete unit suite passed afterward. An interrupted simulator launch was rerun successfully in isolation; the entire UI inventory was not rerun for this release.

Live Realtime checks used the explicitly supplied API key through the configured Mac file. Credential minting succeeded with both fixed tools; an ephemeral credential connected using native `URLSessionWebSocketTask`. Text requests produced a direct triangle edit and a separate queued-image tool call (without executing an image generation). A short synthesized speech stream produced a valid circle edit and an input transcript. No user's microphone was captured for these probes. A subscription-backed advanced-plot request produced an original Canvas widget with numerical Runge–Kutta integration and vector arrows. API access and these payload checks do not establish mathematical correctness for arbitrary generated plots or physical iPad audio quality.

Production PDF extraction was exercised against eight exercises in the actual uploaded textbook, including multi-page questions; the original question 2.2 crop was visually verified to retain its equation and final note while excluding adjacent questions. Only synthetic PDFs are committed. Ambiguous exercise endings return an error and offer an explicit whole-page alternative. The signed device build succeeded and was installed; physical microphone/echo/route-change checks remain below.

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

For **v0.3.1**, all **70 native unit tests** passed: 7 independent-task/image checks, 21 renderer/shape/camera checks, 7 equation checks, 13 store/schema/starter checks, 10 mixed-selection checks, 6 voice lifecycle checks, 4 cloud catalog/package checks, and 2 PDF library checks. All **65 Python companion tests** passed. Targeted UI runs verified mixed ink/object copy/paste/duplicate/undo, catalog search/filter/grid/list/preview/insertion, matching bottom-control geometry, handwriting, hand/finger panning, and Magic Pen reference retention through two-finger zoom and tool changes. The final run included all 70 unit tests and the three navigation/drawing UI regressions; it passed without failures. The entire 17-method UI inventory was not rerun as one suite against the final source revision.

New native checks cover shape recognition boundaries and orientation, keeping later strokes when recognition completes, deferring native drawing mutations through zoom settlement, autonomous voice jobs with callback isolation, and mixed-selection rollback and clipboard validation. PDF tests import and search a synthetic 400-page document, render page 350, and route an actual captured-library `insertPDF` response through `ConnectionClient` into one undoable image insertion. The signed v0.3.1 device build succeeded and was installed and launched on the connected iPad.

## Live integration evidence

Live checks on November 15, 2026 used the Mac's existing ChatGPT sign-in without an API key. They retrieved account status, generated the requested triangle with 49°, 52°, and 79° angles, created a tappable coin widget, and returned a generated raster image with image bytes attached.

The v0.3 live checks also ran two independent requests concurrently with different reference regions, generated editable bare equations and exposed graph controls, and transcribed a fraction through the running companion's authenticated HTTP endpoint. Databricks managed-volume save/list/load preserved a synthetic object's identity and geometry. Only an original synthetic demo object was uploaded during these checks; user notebooks were not uploaded, and the SQL warehouse remained stopped.

The v0.3.1 companion accepted a live medium-effort request and a separate page-350 printout request against synthetic captured PDF metadata. The latter returned a validated `insertPDF` operation in approximately 6.2 seconds; native tests separately verify rendering and insertion from the actual 400-page file. This timing is one observed run, not a latency guarantee. Databricks status/list/load remained available after the final companion restart, with the SQL warehouse still stopped.

The final v0.3.1 build adds chapter-aware retrieval, bringing the passing native unit suite to **71 tests**. The new test covers separate chapter/Problems bookmarks, bare exercise labels, continuation pages, and the heading-text fallback without bookmarks. The production retrieval method was also checked against the user's actual 571-page textbook: chapter 2, problem 2 returns PDF page 161, verified visually against the printed page. A live request using that retrieved context returned exactly the correct original-page insertion in 5.6 seconds. No textbook files or extracted text are included in this repository. All 65 companion tests passed again after clarifying PDF file pages versus printed labels in the agent instructions.

The independent background launcher was exercised with isolated temporary state: start, duplicate-start prevention, authenticated status, private runtime-file permissions, and graceful stop. Bonjour registration and resolution were also verified on macOS.

A separate realtime-audio probe exposed an account/runtime limit: startup was rejected with **“realtime conversation requires API key auth.”** No microphone audio was captured by that probe. MagiBoard therefore uses native recognition, Codex text requests, and native synthesis. [Voice findings](../bridge/VOICE_NOTES.md) record the exact scope of that result.

## Physical-device checks still needed

- Sustained Apple Pencil writing, pressure, palm rejection, tool switching, and long-session memory use.
- Microphone and speech permission flows, recognition accuracy, spoken replies, silence timing, and Bluetooth/headset changes.
- Conversation latency and recovery from interrupted audio, failed requests, weak Wi-Fi, sleep, and app backgrounding.
- Large notebooks, extended widget execution, full accessibility navigation, and broader device/orientation coverage.

Simulator and state-machine tests cannot substitute for these checks. Device-code authentication follows the official protocol; the existing account was not replaced merely to exercise sign-in during development.
