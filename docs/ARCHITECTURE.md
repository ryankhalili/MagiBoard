# MagiBoard v0.2 architecture

The native app owns each notebook. Drawing and object rendering share a world-coordinate system; the Mac companion returns proposed edits that the app validates and applies as one undoable transaction.

## Documents and persistence

`Models.swift` defines the version-one Codable document schema. A notebook has an ID, title, timestamp, object array, and PencilKit drawing bytes. The portable `.canvasstudio` file is JSON, with embedded images and ink encoded as base64. The legacy extension and storage names remain stable across the MagiBoard rename.

| Object fields | Purpose |
| --- | --- |
| `id`, `kind`, `title` | Identity, renderer, and readable label |
| `x`, `y`, `width`, `height` | World-coordinate placement |
| `color`, `shape`, `pattern`, `text` | Visual and mathematical content |
| `properties` | Exposed numeric parameters |
| `code` | Self-contained interactive HTML/CSS/JavaScript |
| `imageData` | Embedded raster content |

Supported kinds are `text`, `shape`, `graph`, `image`, `widget`, `latex`, and `frame`. Page regions use frame objects, so they share ordinary selection, editing, export, and persistence behavior.

`NotebookValidation` checks schema version, identifiers, geometry, content bounds, and triangle angles. `NotebookStore` provides gesture checkpoints, undo/redo, debounced atomic saves, import isolation, and reusable catalog objects. Failed saves preserve in-memory work and prevent switching away from it. Catalog insertion assigns a new object ID.

Settings are separate from notebooks. Pairing secrets are excluded from JSON and stored in Keychain. The PDF library is also separate; PDF pages placed on the canvas become embedded image objects and travel with notebook exports.

## Native UI and drawing

SwiftUI supplies the notebook ribbon, sliding library sidebar, inspector, and categorized Settings screens. UIKit hosts a PencilKit canvas over a Core Graphics object surface. PencilKit handles pressure-sensitive ink, erasing, and native ink selection. Object selection is a separate tool.

The camera supports panning, zooming, and expanding content extents. A rebased native ink origin maps negative world coordinates into PencilKit's positive content space. Saved ink, canvas objects, crop exports, and AI references remain in world coordinates. Dragging, resizing, and reference gestures use the same mapping.

`ObjectRenderer.swift` draws native shapes, graphs, text, equations, images, and frames. Graph expressions use a dedicated parser, not arbitrary native evaluation. Triangle geometry follows the exposed angles. Equation rendering supports a limited notation subset rather than a full TeX engine. Optional shape recognition uses geometric heuristics on closed strokes.

`CanvasExporter` uses the Magic Pen rectangle, selected-object bounds, or viewport as its crop. It composites objects and ink into a bounded PNG or one-page PDF. Interactive objects contribute cached static snapshots.

## Interactive objects

`CanvasWidgetView` runs a nonpersistent `WKWebView` containing an origin-isolated iframe with `sandbox="allow-scripts"`. A restrictive Content Security Policy blocks external connections, scripts, media, and forms. There is no native message bridge.

The widget receives numeric parameters as `window.canvasProperties`; `window.properties` and `window.objectProperties` are aliases. Changing source, dimensions, or parameters reloads it. Double-tapping enters interaction mode. Browser APIs can animate and respond to touch, but incidental JavaScript state is not automatically persisted.

Widgets do not receive filesystem, shell, Python, native-plugin, or backend access. Further robustness work is needed for expensive or poorly authored JavaScript.

## Agent boundary

`ConnectionClient` sends a prompt, structured objects, selected IDs, a spatial reference, optional JPEG context, and bounded PDF excerpts. Existing raster bytes are omitted from the textual object list. The client checks that the notebook has not changed before applying the response.

The Python companion starts its own ephemeral Codex turn. It is independent of the chat used to develop the app. Host execution tools, connected apps, plugins, browser control, hooks, memory, and delegation are disabled for generation. Hosted web search and image generation can remain available to the connected account. Widget source is returned as data and is not executed on the Mac.

Responses contain `message` and `operations` with `add`, `update`, or `delete` types. The companion validates the response, and the native app validates it again before atomic application. Updates and deletions must identify existing objects. Stale or canceled responses cannot silently overwrite newer canvas edits.

Generated images are accepted only from the generated-image directory belonging to the exact Codex turn identified by its trusted event stream. The companion rejects path escapes, symlinks, invalid signatures, and oversized assets before embedding image bytes.

`LocalAssistant` is a small deterministic offline command parser. Its responses are labeled as offline commands, not AI output.

## Companion, pairing, and transport

`bridge/companion.py` provides independent background start, status, pairing, and stop operations. It does not install a login item or automatically restart after reboot. Codex account status and device-code sign-in use the official app-server account interface. Credentials remain with Codex on the Mac, and changing that account changes the shared Mac sign-in.

A private `.canvaspair` file contains the local address and separate bearer token. HTTP endpoints require that token and reject browser-origin requests. Disconnecting the iPad rotates pairing without logging the Mac out of Codex.

Bonjour advertises `_magiboard._tcp.` with a friendly name and protocol version. It never advertises a token. Discovery can update an already paired address; a new device still needs the private pairing file.

The prototype uses authenticated HTTP on a trusted local network. Remote hosting, transport-security deployment, and standalone iPad subscription execution are outside this release.

## Voice conversation

`VoiceInput` manages Apple speech recognition, microphone permissions, audio capture, language selection, silence detection, interruption handling, and on-device recognition with service fallback. Session identities reject late permission results and canceled recognition callbacks.

`ConversationVoice` coordinates a turn-based loop:

1. Listen and transcribe an utterance.
2. Send its text through the normal canvas-agent request.
3. Apply validated edits and receive a text reply.
4. Speak the reply with system speech synthesis, then resume listening.

Listening pauses during the agent turn and spoken reply to avoid treating playback as a command. Stopping, backgrounding, interruption, and errors invalidate the current session. The interface can remain hands-free across successful turns, with a visible stop control.

This is native recognition and synthesis around a text agent. It is not OpenAI realtime audio streaming. The tested runtime rejected subscription-only realtime audio with an API-key requirement; the separate API-backed route is not configured. See [the recorded probe](../bridge/VOICE_NOTES.md).

## PDF references and extension boundaries

`PDFLibrary` preserves imported PDFs, indexes embedded text, ranks matching excerpts, and rasterizes pages for annotation. Scanned documents without embedded text are not locally OCR-indexed. Agents receive bounded text context rather than unrestricted filesystem access.

Future extensions can add typed property descriptors, persistent widget state, richer math typesetting, OCR retrieval, explicitly scoped remote execution, or Databricks-backed storage. These are extension opportunities, not current capabilities. Cloud collaboration, API-key settings, and a plugin marketplace are not included.
