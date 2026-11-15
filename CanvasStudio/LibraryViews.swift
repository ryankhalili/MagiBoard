import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct NotebookLibraryView: View {
    @ObservedObject var store: NotebookStore
    @Environment(\.dismiss) private var dismiss
    @State private var showNew = false
    @State private var showRename = false
    @State private var name = ""
    @State private var importing = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.notebooks) { notebook in
                        Button {
                            store.openNotebook(id: notebook.id)
                            if store.notebook.id == notebook.id { dismiss() }
                        } label: {
                            HStack(spacing: 15) {
                                Image(systemName: "book.closed.fill")
                                    .font(.title2).foregroundStyle(.purple)
                                    .frame(width: 46, height: 58).background(.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(notebook.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    Text("\(notebook.objectCount) objects · \(notebook.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if notebook.id == store.notebook.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple)
                                } else { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                } header: { Text("On this iPad") } footer: { Text("Your notebooks save automatically. Export a .canvasstudio file to keep a portable copy or share it with another iPad.") }
                Section {
                    Button { name = store.notebook.title; showRename = true } label: { Label("Rename current notebook", systemImage: "pencil") }
                    Button { importing = true } label: { Label("Import a notebook", systemImage: "square.and.arrow.down") }
                }
            }
            .navigationTitle("Notebooks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { name = ""; showNew = true } label: { Label("New notebook", systemImage: "plus") } }
            }
            .alert("New notebook", isPresented: $showNew) {
                TextField("Notebook name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let oldID = store.notebook.id
                    store.newNotebook(title: cleanName)
                    if store.notebook.id != oldID { dismiss() }
                }
            }
            .alert("Rename notebook", isPresented: $showRename) {
                TextField("Notebook name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    store.checkpoint(); store.notebook.title = cleanName; store.commit(); store.save()
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
                switch result {
                case .success(let url):
                    let oldID = store.notebook.id; store.load(url: url)
                    if store.notebook.id != oldID { dismiss() }
                case .failure(let error): store.status = "Could not import: \(error.localizedDescription)"
                }
            }
        }.tint(.purple)
    }
    private var cleanName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled notebook" : String(trimmed.prefix(150))
    }
}

struct ObjectCatalogView: View {
    @ObservedObject var store: NotebookStore
    @ObservedObject var agent: ConnectionClient
    @StateObject private var cloud = CloudObjectCatalog()
    @Environment(\.dismiss) private var dismiss
    @State private var location = "On this iPad"
    @State private var importing = false
    @State private var shareURL: URL?
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Catalog location", selection: $location) {
                    Text("On this iPad").tag("On this iPad")
                    Text("Databricks").tag("Databricks")
                }.pickerStyle(.segmented).padding()
                List {
                    if location == "On this iPad" {
                        Section {
                            if store.catalog.isEmpty { Text("Save an object from its inspector, or import a shared object package.").foregroundStyle(.secondary) }
                            ForEach(store.catalog) { object in
                                HStack(spacing: 12) {
                                    Button {
                                        if store.insertFromCatalog(object) { store.tool = .select; dismiss() }
                                        else { errorMessage = store.status }
                                    } label: {
                                        catalogRow(title: object.title, kind: object.kind, icon: object.libraryIcon)
                                    }.buttonStyle(.plain)
                                    Menu {
                                        Button("Share object package", systemImage: "square.and.arrow.up") { shareURL = store.exportObject(object) }
                                        Button("Save version to Databricks", systemImage: "cloud.upload") {
                                            Task {
                                                if await cloud.save(object, using: agent, settings: store.settings) { location = "Databricks" }
                                                else { errorMessage = cloud.status }
                                            }
                                        }.disabled(cloud.busy || store.settings.bridgeURL.isEmpty)
                                        Button("Delete local copy", role: .destructive) { store.removeFromCatalog(id: object.id) }
                                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                                }.padding(.vertical, 5)
                            }
                            Button("Import shared object", systemImage: "square.and.arrow.down") { importing = true }
                        } footer: { Text("Tap to insert an independent copy. Share an object package with your team; it includes the artwork, behavior, and exposed controls.") }
                    } else {
                        Section {
                            Label("Databricks object library", systemImage: "externaldrive.badge.icloud")
                            Text(cloud.status).font(.caption).foregroundStyle(.secondary)
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await cloud.refresh(using: agent, settings: store.settings) } }.disabled(cloud.busy)
                            if cloud.busy { ProgressView() }
                        }
                        Section {
                            ForEach(cloud.entries) { entry in
                                Button {
                                    Task { if await cloud.load(entry, using: agent, store: store) { dismiss() } }
                                } label: {
                                    catalogRow(title: entry.title, kind: entry.kind, icon: "shippingbox")
                                }.buttonStyle(.plain).disabled(cloud.busy)
                            }
                            if cloud.truncated {
                                Text("Showing a limited set of saved versions. More objects remain in your Databricks volume.").font(.caption).foregroundStyle(.secondary)
                            }
                            if cloud.available && cloud.entries.isEmpty { Text("No shared objects yet. Save a version from the local catalog’s menu.").font(.subheadline).foregroundStyle(.secondary) }
                        } footer: { Text("Each Save creates an immutable version in your workspace. Nothing uploads automatically. Loaded objects work locally, even when you disconnect.") }
                    }
                }
            }.navigationTitle("Object catalog")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onChange(of: location) { _, value in
                    if value == "Databricks" && cloud.entries.isEmpty {
                        Task { await cloud.refresh(using: agent, settings: store.settings) }
                    }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
                    do { if !store.importObjectPackage(try result.get()) { errorMessage = store.status } }
                    catch { errorMessage = error.localizedDescription }
                }
                .sheet(item: Binding(get: { shareURL.map(ShareFile.init) }, set: { shareURL = $0?.url })) { ActivitySheet(url: $0.url) }
                .alert("Object catalog", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
        }.tint(.purple)
    }
    private func catalogRow(title: String, kind: String, icon: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.title3).foregroundStyle(.purple).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.isEmpty ? "Untitled object" : title).font(.headline).foregroundStyle(.primary)
                Text(kind.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "plus.circle").foregroundStyle(.purple)
        }.contentShape(Rectangle())
    }
}

struct ReferenceLibraryView: View {
    @ObservedObject var store: NotebookStore
    @ObservedObject var library: PDFLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var query = ""
    @State private var results: [PDFSearchResult] = []
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Group {
                if library.documents.isEmpty {
                    ContentUnavailableView {
                        Label("Bring your references along", systemImage: "doc.richtext")
                    } description: {
                        Text("Import a PDF from Files. Search its text, browse its pages and place a page directly on your canvas.")
                    } actions: {
                        Button("Import PDF") { importing = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Section {
                                ForEach(library.documents) { document in
                                    NavigationLink {
                                        PDFPageBrowser(store: store, library: library, document: document, initialPage: 1)
                                    } label: {
                                        HStack(spacing: 14) {
                                            Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.purple)
                                                .frame(width: 46, height: 56).background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(document.title).font(.headline).lineLimit(2)
                                                Text("\(document.pages) pages").font(.subheadline).foregroundStyle(.secondary)
                                            }
                                        }.padding(.vertical, 4)
                                    }
                                }
                            } header: { Text("Reference library") } footer: { Text("PDFs stay on this iPad. Magic Pen can use relevant text excerpts when you ask about your references. Scanned pages may not contain searchable text.") }
                        } else if results.isEmpty {
                            ContentUnavailableView.search(text: query)
                                .listRowBackground(Color.clear)
                        } else {
                            Section("Matching pages") {
                                ForEach(results) { result in
                                    if let document = library.documents.first(where: { $0.id == result.documentID }) {
                                        NavigationLink {
                                            PDFPageBrowser(store: store, library: library, document: document, initialPage: result.page)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 7) {
                                                HStack {
                                                    Text(result.title).font(.headline).lineLimit(1)
                                                    Spacer()
                                                    Text("p. \(result.page)").font(.subheadline.monospacedDigit()).foregroundStyle(.purple)
                                                }
                                                Text(result.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
                                            }.padding(.vertical, 5)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Reference library")
            .searchable(text: $query, prompt: "Search text or a question")
            .task(id: query) {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                results = library.search(query: query)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { importing = true } label: { Label("Import PDF", systemImage: "plus") } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                do {
                    let url = try result.get(); try library.importDocument(url: url)
                    results = library.search(query: query)
                } catch { errorMessage = error.localizedDescription }
            }
            .alert("Could not import PDF", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }.tint(.purple)
    }
}

private struct PDFPageBrowser: View {
    @ObservedObject var store: NotebookStore
    @ObservedObject var library: PDFLibrary
    let document: LibraryPDF
    @State private var page: Int
    @State private var preview: CanvasObject?
    @State private var inserted = false
    init(store: NotebookStore, library: PDFLibrary, document: LibraryPDF, initialPage: Int) {
        self.store = store; self.library = library; self.document = document
        _page = State(initialValue: min(document.pages, max(1, initialPage)))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { page = max(1, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page <= 1)
                Text("Page \(page) of \(document.pages)").font(.subheadline.monospacedDigit()).frame(minWidth: 135)
                Button { page = min(document.pages, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page >= document.pages)
                Spacer()
                Stepper("Page", value: $page, in: 1...max(1, document.pages)).labelsHidden()
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                if let data = preview?.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: min(660, image.size.width))
                        .background(.white).clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.1), radius: 12, y: 4).padding(24)
                } else { ProgressView().padding(80) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .secondarySystemGroupedBackground))
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Make room for a reference").font(.subheadline.weight(.semibold))
                    Text("Insert this page, then write directly over it.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    guard var object = preview else { return }
                    object.id = UUID(); object.x = store.viewport.x + 140; object.y = store.viewport.y + 180
                    store.add(object); store.tool = .pen; inserted = true
                } label: { Label(inserted ? "Inserted" : "Insert page", systemImage: inserted ? "checkmark" : "plus") }
                    .buttonStyle(.borderedProminent).disabled(preview == nil || inserted)
            }.padding(20)
        }
        .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
        .task(id: page) {
            inserted = false
            preview = library.pageObject(documentID: document.id, page: page,
                                         at: CGPoint(x: store.viewport.x + 140, y: store.viewport.y + 180))
        }
    }
}

private extension CanvasObject {
    var libraryIcon: String {
        switch kind {
        case "graph": return "chart.xyaxis.line"
        case "image": return "photo"
        case "widget": return "play.rectangle"
        case "text": return "text.alignleft"
        case "latex": return "function"
        case "frame": return "rectangle.dashed"
        default: return shape == "triangle" ? "triangle" : "square.on.circle"
        }
    }
}
