import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

private let accent = Color(red: 0.29, green: 0.29, blue: 0.88)
private let swatches = ["#243449", "#2563EB", "#16A34A", "#EF4444", "#8B5CF6", "#F59E0B"]

extension Color {
    init(studioHex: String) {
        let clean = studioHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(clean.prefix(6), radix: 16) ?? 0x243449
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct StudioView: View {
    @ObservedObject var store: NotebookStore
    @ObservedObject var library: PDFLibrary
    @StateObject private var agent = ConnectionClient()
    @StateObject private var voice = VoiceInput()
    @StateObject private var conversation = ConversationVoice()
    @State private var ribbonTab = "Draw"
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var showCatalog = false
    @State private var showReferences = false
    @State private var showInspector = true
    private var showMagic: Bool { store.tool == .magic }
    @State private var showJobs = false
    @State private var showPhotos = false
    @State private var importError: String?
    @State private var voiceRequestID: UUID?
    @State private var showImport = false
    @State private var prompt = ""
    @State private var shareURL: URL?
    @State private var photoItem: PhotosPickerItem?
    @State private var showHelp = false
    @State private var consumedMagicHold = false
    @State private var renameNotebook = false
    @State private var titleDraft = ""
    @FocusState private var promptFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View { lifecycleWorkspace }

    private var canvasWorkspace: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            NativeCanvas(store: store) {
                promptFocused = false
                if store.settings.voiceMode && !conversation.active { startConversation() }
            }.ignoresSafeArea(.keyboard).ignoresSafeArea(edges: .bottom)
            VStack(spacing: 0) {
                topBar
                if !store.settings.toolbarCollapsed { ribbonBar }
                ZStack(alignment: .topLeading) {
                    if store.tool == .magic {
                        Label("Tap or drag to focus · Two fingers to move and zoom", systemImage: "scope")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                            .padding(.horizontal, 14).padding(.vertical, 9).background(.regularMaterial, in: Capsule())
                    }
                    if !store.selectedIDs.isEmpty && store.tool == .select {
                        selectionActions
                    }
                    if !store.selectedIDs.isEmpty && showInspector && store.tool == .select {
                        HStack {
                            Spacer()
                            ObjectInspector(store: store) { showInspector = false }
                                .frame(width: 276).transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }.padding(.horizontal, 20).padding(.top, 12)
                Spacer(minLength: 8)
                bottomBar.padding(.horizontal, 20).padding(.bottom, 16)
            }
        }
        .tint(accent)
        .alert("Notebook name", isPresented: $renameNotebook) {
            TextField("Name", text: $titleDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { store.notebook.title = title; store.save() }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showMagic)
        .animation(.easeInOut(duration: 0.18), value: store.selectedIDs)
    }

    private var presentedWorkspace: some View {
        canvasWorkspace
        .sheet(isPresented: $showSettings) { StudioSettingsView(store: store, agent: agent) }
         .overlay(alignment: .topLeading) {
            if showLibrary {
                HStack(spacing: 0) {
                    NotebookSidebar(store: store, onClose: { showLibrary = false }, onCatalog: { showLibrary = false; showCatalog = true }, onReferences: { showLibrary = false; showReferences = true })
                        .frame(width: 300)
                        .background(Color(uiColor: .systemBackground))
                        .overlay(alignment: .trailing) { Divider() }
                        .shadow(color: .black.opacity(0.06), radius: 16, x: 5)
                    Color.black.opacity(0.07).contentShape(Rectangle()).onTapGesture { withAnimation { showLibrary = false } }
                }
                .padding(.top, headerHeight + (store.settings.toolbarCollapsed ? 0 : 65))
                .transition(.move(edge: .leading))
            }
        }
        .sheet(isPresented: $showCatalog) { ObjectCatalogView(store: store, agent: agent) }
        .sheet(isPresented: $showReferences) { ReferenceLibraryView(store: store, library: library) }
        .sheet(isPresented: $showHelp) { helpSheet }
        .sheet(item: Binding(get: { shareURL.map(ShareFile.init) }, set: { shareURL = $0?.url })) { file in
            ActivitySheet(url: file.url)
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.pdf, .image, .json, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { importFile(url) }
            if case .failure(let error) = result { store.status = error.localizedDescription }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images, preferredItemEncoding: .compatible)
        .alert("Could not insert image", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
    }

    private var inputWorkspace: some View {
        presentedWorkspace
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw NotebookError.invalid("The photo could not be downloaded. Try saving it to Files and importing it.") }
                    insertImage(data, title: "Photo")
                } catch { importError = error.localizedDescription }
                photoItem = nil
            }
        }
         .onChange(of: voice.transcript) { _, text in if !text.isEmpty { prompt = text } }
    }

    private var lifecycleWorkspace: some View {
        inputWorkspace
        .onChange(of: store.settings.aiEnabled) { _, enabled in if !enabled { stopConversation(); voice.stop(); agent.cancel() } }
        .onChange(of: store.notebook.id) { _, _ in stopConversation(); voice.stop(); agent.cancel() }
        .onChange(of: showSettings) { _, open in if open { stopConversation(); voice.stop() } }
        .onChange(of: showCatalog) { _, open in if open { stopConversation(); voice.stop() } }
        .onChange(of: showReferences) { _, open in if open { stopConversation(); voice.stop() } }
        .onChange(of: showImport) { _, open in if open { stopConversation(); voice.stop() } }
        .onChange(of: showPhotos) { _, open in if open { stopConversation(); voice.stop() } }
        .onChange(of: ribbonTab) { _, _ in store.settings.toolbarCollapsed = false }
        .onChange(of: store.tool) { old, tool in
            if old == .magic && tool != .magic { store.reference = nil; stopConversation(); voice.stop(); promptFocused = false }
            if tool == .magic { store.selectedIDs = [] }
            if tool == .select { showInspector = true }
        }
        .onChange(of: store.selectedIDs) { _, ids in if !ids.isEmpty { showInspector = true } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.save(); voice.stop(); stopConversation() }
        }
        .task { if !store.settings.bridgeURL.isEmpty { await agent.check(store.settings) } }
        .background(shortcuts)
    }

    private var headerHeight: CGFloat { store.settings.compactHeader ? 34 : 50 }
    private var topBar: some View {
        ZStack {
            HStack(spacing: 14) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showLibrary.toggle() } } label: {
                    Image(systemName: "books.vertical").font(.system(size: 21, weight: .medium)).foregroundStyle(accent)
                }.accessibilityLabel("Notebooks").accessibilityIdentifier("notebooks")
                Button { titleDraft = store.notebook.title; renameNotebook = true } label: {
                    Text(store.notebook.title).font(.system(size: store.settings.compactHeader ? 13 : 15, weight: .semibold)).lineLimit(1)
                }.frame(maxWidth: 200, alignment: .leading).accessibilityLabel("Rename notebook")
                Spacer()
                exportMenu
                Button { showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 19)) }
                    .accessibilityLabel("Settings").accessibilityIdentifier("settings")
                Button { withAnimation(.easeInOut(duration: 0.2)) { store.settings.toolbarCollapsed.toggle() } } label: {
                    Image(systemName: "rectangle.bottomhalf.inset.filled").font(.system(size: 17)).foregroundStyle(store.settings.toolbarCollapsed ? .secondary : accent)
                }.accessibilityLabel(store.settings.toolbarCollapsed ? "Show ribbon" : "Hide ribbon").accessibilityIdentifier("toggleToolbar")
                Button { withAnimation(.easeInOut(duration: 0.2)) { store.settings.compactHeader.toggle() } } label: {
                    Image(systemName: store.settings.compactHeader ? "chevron.down" : "chevron.up").font(.system(size: 13, weight: .semibold))
                }.accessibilityLabel(store.settings.compactHeader ? "Expand title bar" : "Compact title bar").accessibilityIdentifier("toggleHeader")
            }
            HStack(spacing: 6) {
                ForEach(["Home", "Draw", "Insert", "View"], id: \.self) { tab in
                    Button { ribbonTab = tab } label: {
                        Text(tab).font(.system(size: 14, weight: ribbonTab == tab ? .semibold : .regular))
                            .foregroundStyle(ribbonTab == tab ? accent : Color.primary)
                            .padding(.horizontal, 12).frame(height: headerHeight)
                            .overlay(alignment: .bottom) { if ribbonTab == tab { Capsule().fill(accent).frame(height: 2).padding(.horizontal, 10) } }
                    }.accessibilityIdentifier("tab_\(tab.lowercased())")
                }
            }
        }.foregroundStyle(.primary).padding(.horizontal, 24).frame(height: headerHeight)
            .background(Color(uiColor: .systemBackground)).overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private var insertMenu: some View {
        Menu {
            Button("Text", systemImage: "textformat") { addObject("text") }
            Button("Equation", systemImage: "function") { addObject("latex") }
            Button("Graph", systemImage: "chart.xyaxis.line") { addObject("graph") }
            Menu("Shape", systemImage: "square.on.circle") {
                Button("Triangle") { addObject("shape", shape: "triangle") }
                Button("Circle") { addObject("shape", shape: "circle") }
                Button("Rectangle") { addObject("shape", shape: "rectangle") }
                Button("Arrow") { addObject("shape", shape: "arrow") }
            }
            Button("Named region", systemImage: "rectangle.dashed") { addObject("frame") }
            Button("Interactive object", systemImage: "curlybraces") { addObject("widget") }
            Divider()
            Button("Photo library", systemImage: "photo") { showPhotos = true }
            Button("Import file…", systemImage: "square.and.arrow.down") { showImport = true }
            Button("Object catalog", systemImage: "square.grid.2x2") { showCatalog = true }
            Button("PDF reference library", systemImage: "books.vertical") { showReferences = true }
        } label: { ribbonLabel("Insert", "plus") }.accessibilityIdentifier("insert")
    }
    private var exportMenu: some View {
        Menu {
            Button("Image of focused area", systemImage: "photo") { shareURL = CanvasExporter.export(store: store, asPDF: false) }
            Button("PDF of focused area", systemImage: "doc.richtext") { shareURL = CanvasExporter.export(store: store, asPDF: true) }
            Button("Editable notebook", systemImage: "square.stack.3d.up") { shareURL = store.exportNotebook() }
        } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 19)) }.accessibilityLabel("Export")
    }
    private var historyButtons: some View {
        Group {
            Button { store.undo() } label: { ribbonLabel("Undo", "arrow.uturn.backward") }.disabled(!store.canUndo).accessibilityIdentifier("undo")
            Button { store.redo() } label: { ribbonLabel("Redo", "arrow.uturn.forward") }.disabled(!store.canRedo).accessibilityLabel("Redo")
        }
    }
    private func ribbonLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 18, weight: .regular))
            Text(title).font(.system(size: 10, weight: .medium))
        }.frame(minWidth: 42, minHeight: 49)
    }
    private var ribbonBar: some View {
        Group {
            if ribbonTab == "Draw" { toolBar }
            else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        if ribbonTab == "Home" {
                            historyButtons
                            Divider().frame(height: 30)
                            Button {
                                store.tool = .select
                                store.selectedIDs = Set(store.notebook.objects.map(\.id))
                            } label: { ribbonLabel("All objects", "square.dashed.inset.filled") }
                                .disabled(store.notebook.objects.isEmpty).accessibilityIdentifier("selectAllObjects")
                            Button { NotificationCenter.default.post(name: .canvasCopySelection, object: nil) } label: { ribbonLabel("Copy", "doc.on.doc") }.disabled(store.selectedIDs.isEmpty)
                            Button { NotificationCenter.default.post(name: .canvasPasteSelection, object: nil) } label: { ribbonLabel("Paste", "doc.on.clipboard") }
                            Button { NotificationCenter.default.post(name: .canvasDuplicateSelection, object: nil) } label: { ribbonLabel("Duplicate", "plus.square.on.square") }.disabled(store.selectedIDs.isEmpty)
                            Button { NotificationCenter.default.post(name: .canvasDeleteSelection, object: nil) } label: { ribbonLabel("Delete", "trash") }.disabled(store.selectedIDs.isEmpty)
                            Divider().frame(height: 30)
                            insertMenu
                            Button { showCatalog = true } label: { ribbonLabel("Catalog", "square.grid.2x2") }
                        } else if ribbonTab == "Insert" {
                            insertMenu
                            Button { addObject("text") } label: { ribbonLabel("Text", "textformat") }
                            Button { addObject("graph") } label: { ribbonLabel("Graph", "chart.xyaxis.line") }
                            Button { addObject("latex") } label: { ribbonLabel("Equation", "function") }
                            Button { addObject("widget") } label: { ribbonLabel("Interactive", "curlybraces") }
                            Divider().frame(height: 30)
                            Button { showPhotos = true } label: { ribbonLabel("Photo", "photo") }
                            Button { showImport = true } label: { ribbonLabel("File", "doc.badge.plus") }
                            Button { showReferences = true } label: { ribbonLabel("PDF library", "books.vertical") }
                            Button { addPage(landscape: false) } label: { ribbonLabel("New page", "doc") }
                        } else {
                            Button { withAnimation { showLibrary.toggle() } } label: { ribbonLabel("Navigation", "sidebar.left") }
                            Button { NotificationCenter.default.post(name: .canvasFitContent, object: nil) } label: { ribbonLabel("Fit canvas", "arrow.up.left.and.arrow.down.right") }
                            Button { NotificationCenter.default.post(name: .canvasResetCamera, object: nil) } label: { ribbonLabel("100%", "1.magnifyingglass") }
                            pageSetupMenu
                            Button { showInspector.toggle() } label: { ribbonLabel("Properties", "slider.horizontal.3") }
                            Button { store.settings.darkMode.toggle() } label: { ribbonLabel("Appearance", store.settings.darkMode ? "moon" : "sun.max") }
                            Button { store.settings.compactHeader.toggle() } label: { ribbonLabel("Compact", "arrow.up.to.line.compact") }
                            Button { showHelp = true } label: { ribbonLabel("Help", "questionmark.circle") }
                        }
                    }.foregroundStyle(.primary).padding(.horizontal, 22).padding(.vertical, 8)
                }.frame(height: 65).background(Color(uiColor: .secondarySystemBackground).opacity(0.82))
                    .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                historyButtons
                Divider().frame(height: 30).padding(.horizontal, 4)
                ForEach([CanvasTool.pen, .pencil, .highlighter, .eraser, .lasso, .select, .hand]) { tool in
                    Button { store.tool = tool; if tool == .select { showInspector = true } } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tool.icon).font(.system(size: 18, weight: .medium))
                            Text(shortLabel(tool)).font(.system(size: 10, weight: .medium))
                        }.frame(width: 48, height: 52)
                            .foregroundStyle(store.tool == tool ? accent : Color.primary.opacity(0.72))
                            .background(store.tool == tool ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.accessibilityLabel(tool.label).accessibilityIdentifier("tool_\(tool.rawValue)")
                }
                Divider().frame(height: 32).padding(.horizontal, 3)
                Menu {
                    ForEach([1.0, 3, 6, 12, 20], id: \.self) { size in
                        Button("\(Int(size)) pt") { store.lineWidth = size }
                    }
                } label: {
                    VStack(spacing: 5) {
                        Circle().fill(Color(studioHex: store.colorHex)).frame(width: min(18, store.lineWidth + 4), height: min(18, store.lineWidth + 4)).frame(height: 20)
                        Text("\(Int(store.lineWidth)) pt").font(.system(size: 10, weight: .medium))
                    }.frame(width: 36, height: 52)
                }.accessibilityLabel("Stroke width")
                ForEach(swatches.prefix(5), id: \.self) { hex in
                    Button { store.colorHex = hex } label: {
                        Circle().fill(Color(studioHex: hex)).frame(width: 20, height: 20)
                            .padding(4).overlay(Circle().stroke(store.colorHex == hex ? Color(studioHex: hex) : .clear, lineWidth: 1.5))
                    }.accessibilityLabel("Ink \(hex)")
                }
                Divider().frame(height: 32).padding(.horizontal, 5)
                insertMenu
                pageSetupMenu
            }.padding(.horizontal, 20).padding(.vertical, 6)
        }
        .frame(height: 65).background(Color(uiColor: .secondarySystemBackground).opacity(0.82))
        .overlay(alignment: .bottom) { Divider() }
    }
    private var pageSetupMenu: some View {
        Menu {
                    Section("Paper") {
                        ForEach(["blank", "dots", "ruled", "grid"], id: \.self) { style in
                            Button {
                                store.settings.paperStyle = style; store.settings.showGrid = style != "blank"
                            } label: {
                                if store.settings.paperStyle == style { Label(style.capitalized, systemImage: "checkmark") }
                                else { Text(style.capitalized) }
                            }
                        }
                    }
                    Section("Pages on the canvas") {
                        Button("Insert A4 page", systemImage: "doc") { addPage(landscape: false) }
                        Button("Insert landscape page", systemImage: "rectangle") { addPage(landscape: true) }
                        Button("Fit all content", systemImage: "arrow.up.left.and.arrow.down.right") {
                            NotificationCenter.default.post(name: .canvasFitContent, object: nil)
                        }
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "doc.badge.gearshape").font(.system(size: 18))
                        Text("Page setup").font(.system(size: 10, weight: .medium))
                    }.frame(width: 70, height: 52)
                }.foregroundStyle(.secondary).accessibilityIdentifier("pageSetup").accessibilityValue(store.settings.paperStyle)
    }
    private func shortLabel(_ tool: CanvasTool) -> String {
        switch tool {
        case .highlighter: return "Marker"
        case .lasso: return "Lasso"
        case .select: return "Select"
        case .hand: return "Hand"
        default: return tool.label
        }
    }
    private func addPage(landscape: Bool) {
        let x = store.viewport.x + 140, y = store.viewport.y + 180
        let page = CanvasObject(kind: "frame", title: "Page \(store.notebook.objects.filter { $0.kind == "frame" }.count + 1)", x: x, y: y,
                                width: landscape ? 842 : 595, height: landscape ? 595 : 842, color: "#64748B", properties: ["paper": 1])
        store.add(page); store.tool = .select
        NotificationCenter.default.post(name: .canvasFitContent, object: nil)
    }

    private var selectionActions: some View {
        HStack(spacing: 16) {
            Button { NotificationCenter.default.post(name: .canvasCopySelection, object: nil) } label: { Label("Copy", systemImage: "doc.on.doc") }.accessibilityIdentifier("selectionCopy")
            Button { NotificationCenter.default.post(name: .canvasPasteSelection, object: nil) } label: { Image(systemName: "doc.on.clipboard") }.accessibilityLabel("Paste objects").accessibilityIdentifier("selectionPaste")
            Button { NotificationCenter.default.post(name: .canvasDuplicateSelection, object: nil) } label: { Image(systemName: "plus.square.on.square") }.accessibilityLabel("Duplicate objects").accessibilityIdentifier("selectionDuplicate")
            if store.selectedObjects.contains(where: { $0.kind == "widget" }) {
                Button { NotificationCenter.default.post(name: .canvasInteractSelected, object: nil) } label: { Label("Interact", systemImage: "hand.tap") }.accessibilityIdentifier("selectionInteract")
            }
            Button { showInspector.toggle() } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Object properties")
            Button(role: .destructive) { NotificationCenter.default.post(name: .canvasDeleteSelection, object: nil) } label: { Image(systemName: "trash") }.accessibilityLabel("Delete objects").accessibilityIdentifier("selectionDelete")
        }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 15).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 14) {
            if store.settings.aiEnabled {
                VStack(spacing: 7) {
                    Button {
                        if consumedMagicHold { consumedMagicHold = false; return }
                        store.tool = store.tool == .magic ? .pen : .magic
                    } label: {
                        Image(systemName: "wand.and.stars").font(.system(size: 23, weight: .medium))
                            .foregroundStyle(.white).frame(width: 58, height: 58)
                            .background(LinearGradient(colors: [accent, Color(red: 0.47, green: 0.32, blue: 0.89)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
                            .shadow(color: accent.opacity(0.22), radius: 12, y: 5)
                    }.accessibilityLabel("Magic Pen").accessibilityIdentifier("magic")
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                            consumedMagicHold = true
                            store.tool = .magic
                            if store.settings.voiceMode { startConversation() }
                        })
                    Text("MAGIC PEN").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                }
            }
            if showMagic && store.settings.aiEnabled {
                magicPanel.frame(maxWidth: 640)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.tool.label).font(.system(size: 12, weight: .medium))
                    Text(toolHint)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.bottom, 18).allowsHitTesting(false)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button { showJobs.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up")
                        if agent.busy { Text("\(agent.jobs.filter { $0.state == .running }.count)").font(.caption.monospacedDigit()) }
                    }
                }.accessibilityLabel("AI tasks").accessibilityIdentifier("aiTasks")
                    .popover(isPresented: $showJobs) { MagicTasksView(agent: agent, store: store).frame(width: 370, height: 440) }
                Button { NotificationCenter.default.post(name: .canvasFitContent, object: nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel("Fit content").accessibilityIdentifier("fit")
                Text("\(Int(store.zoom * 100))%").font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 43)
                Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }.accessibilityLabel("Help")
            }.foregroundStyle(.secondary).padding(13).background(.regularMaterial, in: Capsule()).padding(.bottom, 16)
        }
    }

    private var magicPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: store.reference == nil ? "sparkles" : "scope").foregroundStyle(accent)
                Text(store.reference == nil ? "Make room for an idea" : "Your focus is set").font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.settings.bridgeURL.isEmpty {
                    Text("OFFLINE COMMANDS").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                }
                if store.reference != nil {
                    Button { store.reference = nil } label: { Image(systemName: "xmark.circle.fill") }.foregroundStyle(.secondary).accessibilityLabel("Clear reference")
                }
            }
            if !store.settings.magicOnboardingSeen {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "hand.draw").font(.title2).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("One finger focuses. Two fingers navigate.").font(.system(size: 12, weight: .semibold))
                        Text("Tap a point or drag a reference area. Use two fingers to pan and pinch. Choose any drawing tool to leave Magic Pen.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Button("Got it") { store.settings.magicOnboardingSeen = true }.font(.caption.weight(.semibold)).accessibilityIdentifier("magicGotIt")
                }.padding(10).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            if prompt.isEmpty && agent.reply.isEmpty && !conversation.active {
                HStack(spacing: 7) {
                    suggestion("Plot a wave", prompt: "Create a graph of sin(x) here")
                    suggestion("Make it interactive", prompt: "Make an interactive coin that doubles when tapped")
                }
            }
            if conversation.active {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundStyle(accent)
                            .symbolEffect(.variableColor, options: .repeating)
                        Text(conversation.stateLabel).font(.system(size: 15, weight: .medium))
                        Spacer()
                        Button("End voice", systemImage: "stop.circle.fill") { stopConversation() }
                            .font(.system(size: 12, weight: .medium)).accessibilityIdentifier("endVoice")
                    }
                    if !conversation.transcript.isEmpty {
                        Text(conversation.transcript).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3)
                    } else {
                        Text("Speak an instruction, then pause. MagiBoard will make the change and listen again.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ProgressView(value: conversation.level).tint(accent).accessibilityLabel("Microphone level")
                }.accessibilityIdentifier("voiceConversation")
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField(voice.listening ? "Listening…" : "Ask anything about your canvas…", text: $prompt, axis: .vertical)
                        .lineLimit(1...4).font(.system(size: 16)).focused($promptFocused)
                        .accessibilityIdentifier("magicPrompt").onSubmit { submit() }
                    Button { toggleDictation() } label: {
                        Group {
                            if voice.isStarting { ProgressView() }
                            else { Image(systemName: voice.listening ? "stop.circle.fill" : "mic").font(.system(size: 19)) }
                        }.foregroundStyle(voice.listening ? Color.red : Color.secondary).frame(width: 28, height: 34)
                    }.accessibilityLabel(voice.listening || voice.isStarting ? "Stop dictation" : "Dictate").accessibilityIdentifier("dictation")
                    Button { startConversation() } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "waveform").font(.system(size: 17))
                            Text("Voice").font(.system(size: 9, weight: .medium))
                        }.frame(width: 34, height: 34)
                    }.accessibilityLabel("Start voice conversation").accessibilityIdentifier("startVoice")
                    Button { submit() } label: {
                        Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34).background(accent, in: Circle()).foregroundStyle(.white)
                    }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.jobs.filter { $0.state == .running }.count >= 4)
                        .accessibilityLabel("Send to Magic Pen").accessibilityIdentifier("magicSend")
                }
            }
            if !voice.error.isEmpty || !conversation.error.isEmpty {
                Text(!voice.error.isEmpty ? voice.error : conversation.error)
                    .font(.system(size: 12)).foregroundStyle(.red).lineLimit(5).textSelection(.enabled)
            } else if !agent.reply.isEmpty {
                Text(agent.reply).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                if let completed = agent.jobs.last, completed.state == .completed, !completed.resultIDs.isEmpty {
                    Button("Select result", systemImage: "cursorarrow") { agent.focus(completed, store: store) }.font(.caption).accessibilityIdentifier("selectTaskResult")
                }
            }
        }.padding(17).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.18)))
            .shadow(color: .black.opacity(0.07), radius: 18, y: 6)
    }
    private var toolHint: String {
        switch store.tool {
        case .pen, .pencil, .highlighter: return store.settings.drawWithFinger ? "Draw with Pencil or finger · two fingers to move" : "Apple Pencil to write · fingers to move"
        case .select: return "Tap an object · drag to move · corner to resize"
        case .hand: return "Drag with finger or Pencil · pinch to zoom"
        case .lasso: return "Circle handwriting to move or copy it"
        case .eraser: return "Erase handwriting with your Pencil"
        case .magic: return "Tap or drag to focus · two fingers to move and zoom"
        }
    }
    private func suggestion(_ title: String, prompt value: String) -> some View {
        Button { prompt = value } label: {
            Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                .background(accent.opacity(0.07), in: Capsule())
        }
    }
    private func toggleDictation() {
        if voice.listening || voice.isStarting { voice.stop(); return }
        stopConversation(); conversation.clearError()
        voice.localeIdentifier = store.settings.speechLocale
        promptFocused = false
        Task { await voice.start() }
    }
    private func stopConversation() {
        conversation.stop()
        if let id = voiceRequestID { agent.cancel(id); voiceRequestID = nil }
    }
    private func startConversation() {
        guard store.settings.aiEnabled, !conversation.active else { return }
        voice.stop(); voice.clearError(); promptFocused = false; store.tool = .magic
        conversation.localeIdentifier = store.settings.speechLocale
        conversation.spokenReplies = store.settings.spokenReplies
        Task {
            await conversation.start { command in
                voiceRequestID = agent.send(command, store: store, library: library) { message, failed in
                    voiceRequestID = nil
                    guard conversation.active else { return }
                    if failed { conversation.receiveFailure(message) }
                    else { conversation.receiveReply(message) }
                }
                if voiceRequestID == nil { conversation.receiveFailure("All four task slots are busy. Try again after one finishes.") }
            }
        }
    }
    private func submit() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        voice.stop(); stopConversation(); promptFocused = false
        if agent.send(prompt, store: store, library: library) != nil { prompt = ""; store.reference = nil }
    }
    private var shortcuts: some View {
        Group {
            Button("Magic Pen") { store.tool = .magic; promptFocused = true }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Undo") { store.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("Redo") { store.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            Button("Copy") { NotificationCenter.default.post(name: .canvasCopySelection, object: nil) }.keyboardShortcut("c", modifiers: .command)
            Button("Paste") { NotificationCenter.default.post(name: .canvasPasteSelection, object: nil) }.keyboardShortcut("v", modifiers: .command)
            Button("Duplicate") { NotificationCenter.default.post(name: .canvasDuplicateSelection, object: nil) }.keyboardShortcut("d", modifiers: .command)
        }.hidden().frame(width: 0, height: 0)
    }
    private func addObject(_ kind: String, shape: String = "rectangle") {
        let p = store.reference ?? CanvasRect(x: store.viewport.x + 160, y: store.viewport.y + 220)
        var object = CanvasObject(kind: kind, title: kind.capitalized, x: p.x, y: p.y, color: store.colorHex, shape: shape)
        switch kind {
        case "text": object.text = "Write something…"; object.height = 100; object.properties = ["fontSize": 24]
        case "latex": object.text = "E = mc^{2}"; object.width = 320; object.height = 100; object.properties = ["fontSize": 30]
        case "graph": object.width = 440; object.height = 300; object.text = "sin(x)"; object.properties = ["amplitude": 1, "frequency": 1, "c": 0, "xMin": -6.28, "xMax": 6.28, "yMin": -2, "yMax": 2]
        case "shape": object.properties = shape == "triangle" ? ["angleA": 49, "angleB": 52, "fillOpacity": 0.15] : ["fillOpacity": 0.15]
        case "frame": object.width = 500; object.height = 380; object.title = "New region"
        case "widget":
            object.width = 340; object.height = 240; object.title = "Interactive object"; object.properties = ["step": 1]
            object.code = "<body style='font-family:system-ui;background:#f4f3ff;display:grid;place-content:center;text-align:center;height:90vh;color:#4949d9'><h2 id='count'>0</h2><button onclick='n+=window.canvasProperties.step||1;document.getElementById(\"count\").textContent=n' style='padding:14px 28px;border:0;border-radius:14px;background:#4949d9;color:white;font-size:18px'>Tap to count</button><script>let n=0;</script></body>"
        default: break
        }
        store.add(object); store.tool = .select; showInspector = true
    }
    private func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        switch url.pathExtension.lowercased() {
        case "pdf":
            do { try library.importDocument(url: url); showReferences = true }
            catch { store.status = error.localizedDescription }
        case "magiboardobject":
            if store.importObjectPackage(url) { showCatalog = true }
        case "canvaspair": ConnectionClient.importPairing(url, into: store); Task { await agent.check(store.settings) }
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp":
            do { insertImage(try Data(contentsOf: url), title: url.deletingPathExtension().lastPathComponent) }
            catch { importError = error.localizedDescription }
        default: store.load(url: url)
        }
    }
    private func insertImage(_ data: Data, title: String) {
        do {
            let object = try CanvasImageImport.object(from: data, title: title, viewport: store.viewport)
            store.add(object); store.tool = .select; showInspector = true
            DispatchQueue.main.async { NotificationCenter.default.post(name: .canvasFocusObject, object: object.id) }
        } catch { importError = error.localizedDescription }
    }
    private var helpSheet: some View {
        NavigationStack {
            List {
                Section("A native space to think") {
                    Label("Write with Apple Pencil. Pan with fingers and pinch to zoom.", systemImage: "pencil.tip")
                    Label("Ink lasso selects handwriting. The arrow selects and resizes objects.", systemImage: "lasso")
                    Label("Choose Magic Pen, then tap a point or drag an area. Type, dictate, or choose Voice for a hands-free conversation.", systemImage: "wand.and.stars")
                    Label("A reference guides the agent; it does not limit the size of its creation.", systemImage: "scope")
                }
                Section("Make it yours") {
                    Text("Select any object to change its exposed properties, text or source. Save useful objects to your catalog.")
                    Text("Import PDFs into the reference library. Search the text and place pages on the canvas to annotate them.")
                    Text("Export uses your Magic Pen region, selected objects, or visible canvas. Editable notebook files include objects, images and ink.")
                }
                Section("Keyboard") { Text("⌘⇧M  Magic Pen\n⌘Z  Undo    ⌘⇧Z  Redo\n⌘C / ⌘V  Copy / Paste    ⌘D  Duplicate") }
                Section("Prototype") {
                    Text("Your notebooks stay on this iPad. AI requests send the canvas context to your paired Mac and Codex. Interactive objects run in an isolated web view. General native code execution, collaboration and a complete TeX typesetter are not included.")
                }
            }.navigationTitle("MagiBoard").toolbar { Button("Done") { showHelp = false } }
        }.presentationDetents([.large])
    }
}

struct ChromeButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 34, height: 34).background(configuration.isPressed ? .gray.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
    }
}
struct ShareFile: Identifiable { let url: URL; var id: String { url.absoluteString } }
struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
