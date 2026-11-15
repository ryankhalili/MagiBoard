# MagiBoard · v0.4.0

A native iPad whiteboard for handwriting, interactive objects, and an AI assistant that works where you point. Built for MadHacks with original Swift and Python code; no whiteboard application's source was copied or forked.

## What you can do

- Write with Apple Pencil using PencilKit pens, pencil, highlighter, and eraser. The lasso selects handwriting and objects together; selected ink highlights its actual stroke silhouette, including pressure and erased gaps. Copy, paste, duplicate, delete, move, pan, zoom, and undo.
- Optionally turn closed pen or pencil strokes into clean circles, rectangles, or triangles when you lift the Pencil. Recognition preserves the drawn orientation; Undo restores the original ink.
- Organize notebooks in the sliding library sidebar. Add named page regions, choose blank/dotted/ruled/grid paper, and collapse the drawing toolbar.
- Create editable geometry, graphs, text, images, and bare mathematical expressions. The native equation editor previews fractions, scripts, roots, integrals, sums, Greek letters, and more as you type, with a math keyboard accessory and clear syntax errors.
- Plot explicit functions with named coefficients, scientific notation, automatic vertical fitting, readable tick labels, and visible expression errors. Advanced phase portraits, differential-equation simulations, and 3D requests use original interactive widgets rather than the native single-function plotter; generated mathematical content still needs checking.
- Build interactive HTML objects with sliders, number fields, switches, and choices. While **Interact** is enabled, an object can create, duplicate, or update real canvas objects through a bounded document API—for example, a coin that duplicates onto the whiteboard.
- Focus Magic Pen on a point or rectangle and type a request. Up to four tasks can run while you keep writing or move elsewhere; each keeps its original reference and appears in the task list. Leaving Magic Pen does not cancel submitted work. In voice mode, speak a request, hear the reply, and continue hands-free; selecting a new reference lets you start another request while previous work continues.
- Browse 16 original starter objects and local/cloud libraries with search, kind filters, previews, and grid/list views. Save a reusable local object, share an editable `.magiboardobject` package, or explicitly save a version to Databricks through the configured Mac companion.
- Search imported PDF references, locate and crop original exercises through bookmarks, problem labels, and PDF text geometry, or place complete pages on the canvas, and write over them. Import images and export a region as PNG/PDF or a complete editable notebook.

Settings are organized into Account, Voice & Magic, Canvas, Storage, and About. Drawing works without an AI connection; a small, explicitly labeled offline command set demonstrates common geometry edits and example objects.

The Thinking level setting forwards Fast, Balanced, Deep, or Very deep to each new agent request. Fast uses the existing low-effort default; higher levels can take longer. Ordinary canvas requests skip full-text PDF retrieval.

## Build the iPad app

Requirements: macOS with Xcode, an iPadOS 18-or-later SDK and device, or an iPad simulator. Development used Xcode 27.2. Physical-device installation needs your own Apple development signing settings.

1. Open `CanvasStudio.xcodeproj` and select the **CanvasStudio** scheme.
2. Select an iPad simulator, or choose your development team and connected iPad under Signing & Capabilities.
3. Run the app. For a physical iPad, enable Developer Mode and trust the development account if iPadOS asks.

Command-line build, from this directory:

```sh
python3 build.py simulator
python3 build.py device
```

The app is named **MagiBoard**. The project, bundle identity, `.canvasstudio` notebook extension, and existing storage locations retain their earlier names for compatibility with saved notebooks and pairing.

## Connect your ChatGPT subscription

1. Install Codex on the Mac and sign in with ChatGPT.
2. Double-click **Start MagiBoard.command** in `bridge/`, or run:

   ```sh
   python3 bridge/companion.py start
   ```

3. Use **Pair iPad.command** in `bridge/` to reveal the private pairing file. Transfer it to the iPad, then choose **Settings → Account → Connect Mac companion** to import it.
4. Allow Local Network access and check the connection. If needed, **Sign in with ChatGPT** opens the official device-code sign-in flow.

Keep both devices on the same trusted network and keep the Mac awake. The companion runs independently in the background: it does not use the development chat and does not need that chat or its Terminal window to stay open. It does not automatically restart after a Mac reboot. Use **Stop MagiBoard.command** to stop it. Nearby Mac discovery is available in Advanced connection; discovery never replaces secure pairing.

ChatGPT credentials remain managed by Codex on the Mac. The iPad stores a separate pairing token in Keychain. AI requests share the prompt, structured canvas context, a focused screenshot, and relevant PDF excerpts with the companion. Hosted web search and image generation depend on the connected account and runtime. See the [companion guide](bridge/README.md) for details.

The optional **Databricks** tab in Object catalog uses a configured Unity Catalog volume through the Mac companion. Each Save uploads one immutable object version; Load creates an independent local copy. Notebooks and handwriting are not uploaded automatically. Setup, authentication, and the distinction from experimental SQL charts are documented in the [Databricks guide](bridge/DATABRICKS.md).

## Voice

Choose **Settings → Voice & Magic → Voice provider**. Automatic uses GPT Realtime when the Mac companion has an API key configured; Apple speech remains available explicitly. Start Voice in Magic Pen, point to a reference, and speak naturally. Simple native edits run directly; images, research, PDF exercises, and custom widgets become independent canvas tasks. New spoken turns capture their own reference, so changing focus does not redirect earlier work.

**GPT Realtime uses the OpenAI API and API credits**, separately from the ChatGPT subscription used for background canvas agents. The permanent key stays on the Mac; the paired iPad receives a short-lived credential and streams audio directly to OpenAI. Stop closes the audio connection; backgrounding, audio interruptions, ten minutes of use, or ninety seconds of inactivity also end it. Submitted canvas jobs continue independently. Dictation and the Apple voice provider use native recognition and synthesis. See [voice setup and findings](bridge/VOICE_NOTES.md).

## Test

In Xcode, choose an available iPad simulator and run **Product → Test**. The XCTest targets cover document transactions, persistence, equation parsing/layout, widget actions, concurrent agent work, camera/ink coordinates, voice lifecycle, and native UI interactions.

```sh
cd bridge
python3 -m unittest discover -p 'test_*.py' -v
```

Standalone model, store, and PDF checks are also available in `Tests/`. See [validation scope](docs/VALIDATION.md) for the evidence and remaining physical-device checks.

## Prototype limits

- The expanding canvas has practical limits: 2,000 objects and 40 MB of ink per notebook. Imported PDFs support files up to 1 GB without a page-count cap; search uses embedded text, not OCR. Large or complex documents can take longer to search or render.
- Interactive objects run isolated, network-blocked HTML/JavaScript. Their typed canvas actions are validated, undoable, and available only in interaction mode. They do not provide arbitrary native code, Python, shell access, or a persistent backend. Transient widget state may reset on reload; exports are static.
- The original equation typesetter supports a documented [LaTeX subset](docs/ARCHITECTURE.md#equations), not full TeX. Matrices, cases/aligned environments, custom macros, and packages are unsupported. Handwriting conversion requires an explicit visual AI request. GIF imports are static; HTML objects can animate.
- Concurrent tasks preserve unrelated edits and ink. A task that tries to change an object edited since its request is rejected and must be retried; this is not automatic collaborative merging.
- AI needs the paired Mac and internet. Voice quality, echo cancellation, interruption behavior, and Pencil feel still need hands-on device testing. Realtime API access requires a valid configured key; expired keys produce a connection error, and Apple speech remains selectable.
- The Databricks catalog needs separate Mac-side setup and stores object snapshots only. Notebook cloud sync, collaboration, SQL data charts, in-app API-key provisioning, standalone iPad Codex execution, and an extension marketplace are not implemented. The companion's authenticated local HTTP transport is intended for a trusted network.

## Source and rights

The app uses Apple system frameworks without third-party whiteboard or math libraries. The companion uses Python's standard library, an externally installed Codex runtime, and an optional external Databricks CLI. [Provenance](docs/PROVENANCE.md) records the conceptual inspiration and AI coding assistance; [architecture](docs/ARCHITECTURE.md) describes the implementation boundaries.

[LICENSE](LICENSE) reserves rights in the original project source. No open-source license is granted. Apple frameworks, Codex, imported documents, and generated or retrieved material retain their applicable rights and terms.
