# MagiBoard v0.3 architecture

The native app owns each notebook. Drawing and object rendering share a world-coordinate system; the Mac companion returns proposed edits that the app validates and applies as one undoable transaction.

## Documents and persistence

`Models.swift` defines the version-one Codable document schema. A notebook has an ID, title, timestamp, object array, and PencilKit drawing bytes. The portable `.canvasstudio` file is JSON, with embedded images and ink encoded as base64. The legacy extension and storage names remain stable across the MagiBoard rename.

| Object fields | Purpose |
| --- | --- |
| `id`, `kind`, `title` | Identity, renderer, and readable label |
| `x`, `y`, `width`, `height` | World-coordinate placement |
| `color`, `shape`, `pattern`, `text` | Visual and mathematical content |
| `properties` | Exposed numeric parameters |
| `propertySpecs` | Optional labels, control types, ranges, steps, units, and choices for those parameters |
| `code` | Self-contained interactive HTML/CSS/JavaScript |
| `imageData` | Embedded raster content |

Supported kinds are `text`, `shape`, `graph`, `image`, `widget`, `latex`, and `frame`. Page regions use frame objects, so they share ordinary selection, editing, export, and persistence behavior.

`NotebookValidation` checks schema version, identifiers, geometry, content bounds, and triangle angles. `NotebookStore` provides gesture checkpoints, undo/redo, debounced atomic saves, import isolation, and reusable catalog objects. Failed saves preserve in-memory work and prevent switching away from it. Catalog insertion assigns a new object ID.

`ObjectPropertySpec` describes a `number`, `slider`, `toggle`, or `choice` control whose key maps to a value in `properties`. Toggle values are numeric zero/one; choice options have labels and numeric values. Missing descriptors decode as an empty array, keeping older notebooks compatible. Undeclared numeric properties remain editable through fallback controls.

An editable `.magiboardobject` package holds one validated object, including its behavior, embedded image, and control descriptors. Import saves a fresh copy in the local catalog. This is separate from the complete `.canvasstudio` notebook format.

Settings are separate from notebooks. Pairing secrets are excluded from JSON and stored in Keychain. The PDF library is also separate; PDF pages placed on the canvas become embedded image objects and travel with notebook exports.

## Native UI and drawing

SwiftUI supplies the notebook ribbon, sliding library sidebar, inspector, and categorized Settings screens. UIKit hosts a PencilKit canvas over a Core Graphics object surface. PencilKit handles pressure-sensitive ink, erasing, and native ink selection. Object selection is a separate tool.

The camera supports panning, zooming, and expanding content extents. A rebased native ink origin maps negative world coordinates into PencilKit's positive content space. Saved ink, canvas objects, crop exports, and AI references remain in world coordinates. Dragging, resizing, and reference gestures use the same mapping. Magic Pen uses one-finger or Pencil gestures for reference selection and two fingers for navigation. The canvas ignores keyboard safe-area changes so an editor does not rescale the camera.

`ObjectRenderer.swift` draws native shapes, graphs, text, equations, images, and frames. Graph expressions use a dedicated parser, not arbitrary native evaluation. Triangle geometry follows the exposed angles. Optional shape recognition uses geometric heuristics on closed strokes. Long text, graph expressions, and equations open native editor sheets; the inspector shows the selected object's title and declared controls.

`CanvasExporter` uses the Magic Pen rectangle, selected-object bounds, or viewport as its crop. It composites objects and ink into a bounded PNG or one-page PDF. Interactive objects contribute cached static snapshots.

## Equations

`EquationParser` and `EquationRenderer` are original Swift implementations. The parser produces a bounded syntax tree; the renderer measures baselines, ascenders, and descenders using UIKit/CoreText and draws text, rules, radicals, and accents directly into the shared canvas/export context. Fractions have stacked numerators and denominators; scripts have separate baselines; sums and limits can place their bounds above and below. Equation objects draw bare math, with no decorative title or card.

`EquationEditor` pairs a native text view with a live preview and a scrolling math accessory. Its insertion buttons respect the caret or selection. Parse errors identify the command or group and its character position, and invalid drafts cannot be saved. The editor can fit the object's dimensions to the expression. The canvas also exposes errors on imported unsupported expressions instead of silently interpreting them as different mathematics.

Supported syntax includes:

- Groups, superscripts/subscripts, optional outer `$…$`, `$$…$$`, `\(…\)`, or `\[…\]`, and explicit `\\` line breaks.
- `\frac`, `\dfrac`, `\tfrac`, `\binom`, `\sqrt`, indexed roots, and scalable `\left`/`\right` delimiters.
- `\sum`, `\prod`, `\int`, `\iint`, `\iiint`, `\oint`, `\lim`, `\limsup`, `\liminf`, and operator `\limits`/`\nolimits`.
- Greek letters, common relation/arithmetic/arrow symbols, and named functions such as `\sin`, `\cos`, `\tan`, `\log`, `\ln`, and `\exp`.
- `\text`, `\operatorname`, `\mathrm`, `\mathbf`, `\boldsymbol`, `\mathit`, `\mathtt`; hats, bars, vectors, dots, tildes, and common spacing commands.

This is an expression typesetter, not a TeX engine. Matrices, aligned/cases environments, custom macros, packages, and document layout are unsupported. `\dfrac` and `\tfrac` currently share the same fraction layout. The parser limits each expression to 8,192 characters, 2,048 elements, and 64 levels of nesting. A bounded layout cache avoids reparsing unchanged expressions during drawing.

## Interactive objects

`CanvasWidgetView` runs a nonpersistent `WKWebView` containing an origin-isolated iframe with `sandbox="allow-scripts"`. A restrictive Content Security Policy blocks external connections and external resource loading. A narrow native message bridge accepts typed document operations only while the user has enabled **Interact**, by button or double-tap. Outside that mode, gestures manipulate the object as part of the whiteboard.

The widget receives numeric parameters as `window.canvasProperties`; `window.properties` and `window.objectProperties` are aliases. `window.canvasObject` supplies its ID, kind, title, world bounds, and numeric properties. Metadata changes dispatch `canvaspropertieschange` and `canvasobjectchange` events without reloading unchanged source. Source changes reload the isolated document. Widgets are transparent by default; a card can be requested explicitly.

| JavaScript API | Document action |
| --- | --- |
| `canvasHost.create(object)` | Create an independent canvas object with a fresh ID |
| `canvasHost.duplicate(id, {dx, dy})` | Duplicate an existing object at an offset in world coordinates |
| `canvasHost.update(id, patch)` | Change supported fields or numeric properties of an existing object |
| `canvasHost.batch(operations)` | Apply up to 24 actions as one validated, undoable transaction |

The Promise-based API returns object summaries; batches also return IDs. Requests are bounded by size and mutation rate, source identity is checked, and every proposed object passes the same native validation boundary as an AI edit. A rejected batch makes no partial document changes. The sample coin uses this API to create a real neighboring object, so its duplicates persist, export, and participate in selection and undo.

Widgets do not receive filesystem, shell, Python, native-plugin, or backend access. Browser animation and transient JavaScript state are not automatically persisted; document changes made through the host API are. Further robustness work is needed for expensive or poorly authored JavaScript.

## Agent boundary

`ConnectionClient` captures a prompt, structured objects, selected IDs, a spatial reference, optional JPEG context, and bounded PDF excerpts for each task. Existing raster bytes are omitted from the textual object list and restored for updates that omit replacement image data. Up to four tasks can run concurrently. Pending regions stay attached to their captured coordinates, while the task list offers cancellation, status, and result focus. Completion does not steal the current tool, selection, or draft reference.

`NotebookStore.applyAgentResponse` merges a response into the current notebook. Additions and changes to untouched objects can coexist with newer ink and unrelated edits. Updates or deletions are rejected if their target differs from the task's snapshot; a task for another notebook is also rejected. Conflicts fail the complete response and preserve user edits. An in-progress gesture gets a checkpoint boundary around an arriving agent transaction, keeping their undo entries distinct. This is optimistic conflict detection, not collaborative field-by-field merging.

The Python companion starts its own ephemeral Codex turn. It is independent of the chat used to develop the app. Host execution tools, connected apps, plugins, browser control, hooks, memory, and delegation are disabled for generation. Hosted web search and image generation can remain available to the connected account. Widget source is returned as data and is not executed on the Mac.

Responses contain `message` and `operations` with `add`, `update`, or `delete` types. The companion validates the response, and the native app validates it again before atomic application. Updates and deletions must identify existing objects. Canceled native tasks discard their responses; canceling a request does not guarantee immediate termination of work already running in the Mac runtime.

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

## Databricks object catalog

`CloudObjectCatalog` uses authenticated companion endpoints to list, save, and load object snapshots in a configured Databricks Unity Catalog volume. The Mac's external Databricks CLI manages OAuth credentials; the iPad uses only its existing companion pairing token. Each explicit Save creates a unique immutable version with metadata, schema version, object data, and a content checksum. Load validates the object and inserts a fresh local copy. The native UI lives beside the local object catalog.

The implementation uses the Databricks Files API, not SQL execution. A fresh checkout has no workspace configuration. The companion does not provision resources on startup, upload notebooks automatically, or provide live collaborative synchronization. Live development validation saved, listed, and loaded an original synthetic object while the SQL warehouse remained stopped. The separately included SQL chart adapter is disabled and not wired to the app. See [Databricks setup and boundaries](../bridge/DATABRICKS.md).

Future extensions can add broader math environments, persistent widget runtime state, OCR retrieval, explicitly scoped remote execution, and notebook cloud synchronization. Cloud collaboration, API-key settings, and a plugin marketplace are not included.
