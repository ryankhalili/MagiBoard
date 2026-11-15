# MagiBoard implementation provenance

Recorded for the MagiBoard v0.2 hackathon prototype, November 15, 2026.

The Swift app, Python companion, object schema, renderer, graph parser, persistence layer, and included example widgets were authored for this project with AI coding assistance. No third-party whiteboard implementation was cloned, forked, vendored, or copied into the app.

## Conceptual inspiration

| Source | Material considered | Product concept |
| --- | --- | --- |
| [Magic Whiteboard](https://github.com/ryankhalili/magic-whiteboard) | Repository overview and the creator's description | Magic Pen, voice requests, and spatial reference areas |
| [Mathlean](https://mathlean.com/) | Public homepage | Visual work with mathematical objects |
| [Excalidraw](https://excalidraw.com/) | Public product concepts | Direct manipulation and whiteboard navigation |
| [OwlLuna](https://github.com/owaisazmal/OwlLuna) | Public repository overview | Native iPad handwriting and local notebooks |
| Notability, Goodnotes, OneNote, and Apple Notes | Product examples named by the creator | Familiar note-taking and Apple Pencil interactions |

These sources informed expected interactions. Their application source was not used as an implementation reference or included as a dependency.

## Frameworks, runtime, and assets

The app uses Apple system frameworks: SwiftUI, UIKit, PencilKit, Core Graphics, PDFKit, WebKit, Speech, AVFoundation, PhotosUI, UniformTypeIdentifiers, Security, and Foundation networking. System fonts and SF Symbols remain Apple assets. No external Swift package or JavaScript whiteboard/math library is bundled.

The companion uses Python's standard library, macOS service-discovery tools, and an externally installed Codex runtime. Codex is not project-owned code. Protocol integration was checked against installed CLI help, the [official app-server documentation](https://learn.chatgpt.com/docs/app-server), and [official authentication documentation](https://learn.chatgpt.com/docs/auth). A generated protocol schema was inspected for integration research and is not shipped as source.

The welcome notebook and example widgets are original project content. Imported PDFs, images, text, retrieved web material, and model-generated content retain their respective provenance and applicable terms. Exporting a notebook does not transfer ownership of those materials.

## Rights and disclosure

[LICENSE](../LICENSE) retains the project's **Copyright (c) 2026 Ryan Khalili. All rights reserved.** notice. No broad open-source license has been selected. The notice covers rights held in original project material and does not relicense external frameworks, runtimes, services, documents, or assets. The MagiBoard product rename preserves this reserved-rights position.

This record describes the development process and dependencies; it does not certify compliance with any event's rules. AI coding assistance and the external Codex runtime should be disclosed wherever the hackathon requires them.
