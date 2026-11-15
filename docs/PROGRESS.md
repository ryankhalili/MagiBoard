# MagiBoard development checkpoints

## Shipped — v0.3 interaction and object refinement

Implemented:

- Magic Pen is a normal mutually exclusive tool. Leaving it clears the draft reference; submitted tasks keep their own regions. First-use instructions explain two-finger navigation.
- Up to four independent AI tasks preserve handwriting, tool selection, and new references. Stale object edits are rejected atomically.
- Stable tool transitions, explicit object copy/paste/duplicate/delete and Select All, and keyboard-safe canvas positioning.
- Bare equations, an original math typesetter, a live native LaTeX editor, and a math insertion accessory.
- Interactive objects can create, duplicate, and update real parent-canvas objects through a validated, undoable API.
- Labeled numeric controls, sliders, toggles, and choices; portable object packages for sharing and a versioned Databricks catalog.
- Repaired photo/file insertion, centered ribbon tabs, and an original book-based app icon.

The signed v0.3 build is installed and launched on the connected iPad, preserving existing notebooks and pairing. All 45 native unit tests, 14 native UI regressions, and 61 Python tests passed across the full and targeted verification runs.

The verified companion/catalog checkpoint was pushed as `5589507`, followed by the native v0.3 release checkpoint. Actual subscription-backed concurrent generation, equation transcription, authenticated cloud save/list/load, and unauthorized-request rejection were checked. Only a synthetic demo object was uploaded during validation; no SQL warehouse was started.

## In progress — v0.3.1 physical-device feedback

- Repair shape recognition timing so completing a shape never removes the following stroke. Improve circles, rectangles, and triangles while retaining drawing orientation.
- Replace the confusing native Insert Space menu with visible mixed ink/object selection actions. Extend lasso selection to handwriting and objects together.
- Keep submitted voice jobs autonomous when leaving Magic Pen; a new reference can start a separate voice request.
- Add searchable starter/local/cloud catalogs with grid/list views, previews, and clearer Databricks save actions.
- Expose the actual per-request thinking level (the existing default was already low).
- Align the bottom controls, remove idle tool-description text, and make selected page regions draggable.
- Remove the 300-page PDF cutoff, move large-book operations off the UI thread, and verify search/printout beyond page 300.

The shape suite passed all 20 checks; mixed selection passed 10 unit checks plus ink/object clipboard UI checks. Broader integration and the new PDF/catalog checks remain in progress before the next install and release.

## Shipped — v0.2

Native iPad app and independent Mac companion published. The release passed 29 native tests and 43 Python tests. The user confirmed dictation and spoken canvas actions work on the physical iPad.

## Remaining prototype boundaries

- The equation engine supports an explicit subset of LaTeX, not complete TeX.
- Widgets use isolated HTML/JavaScript and a structured document API, not arbitrary native or Python execution. Previously saved widget source keeps its authored behavior.
- Community sharing uses object packages and a workspace catalog; there is no public marketplace or live notebook collaboration.
- The Mac companion is still needed for subscription-backed AI. Voice uses native recognition and speech synthesis around text-agent turns.
- Longer physical Pencil/audio, large-notebook, accessibility, and weak-network testing remains.

Credentials, notebook data, pairing files, and local runtime configuration remain outside version control. Only completed, verified checkpoints are described as shipped.
