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
    @AppStorage("magiboard.catalogGrid") private var grid = true
    @State private var location = "Starter"
    @State private var query = ""
    @State private var kind: CatalogKind = .all
    @State private var importing = false
    @State private var shareURL: URL?
    @State private var previewObject: CanvasObject?
    @State private var errorMessage: String?
    private var assets: [CanvasObject] {
        let source = location == "Starter" ? StarterObjects.all.map(\.object) : store.catalog
        return source.filter { matches(title: $0.title, kind: $0.kind, detail: summary($0) + " " + String($0.text.prefix(2000))) }
    }
    private var cloudEntries: [CloudCatalogEntry] {
        cloud.entries.filter { matches(title: $0.title, kind: $0.kind, detail: $0.createdAt) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Catalog location", selection: $location) {
                    Text("Starter").tag("Starter")
                    Text("On this iPad").tag("On this iPad")
                    Text("Databricks").tag("Databricks")
                }.pickerStyle(.segmented).padding(.horizontal).padding(.top, 12)
                    .accessibilityIdentifier("catalogLocation")
                HStack {
                    Text("\(location == "Databricks" ? cloudEntries.count : assets.count) objects")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Picker("Object kind", selection: $kind) {
                            ForEach(CatalogKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label(kind.rawValue, systemImage: "line.3.horizontal.decrease.circle").font(.subheadline)
                    }.accessibilityIdentifier("catalogKindFilter")
                    Picker("Catalog layout", selection: $grid) {
                        Image(systemName: "square.grid.2x2").tag(true).accessibilityLabel("Grid")
                        Image(systemName: "list.bullet").tag(false).accessibilityLabel("List")
                    }.pickerStyle(.segmented).frame(width: 92).accessibilityIdentifier("catalogLayout")
                }.padding()
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if location == "Databricks" { cloudHeader }
                        if let selected = store.selectedObjects.first { selectedObjectActions(selected) }
                        if location == "Starter" {
                            Text("A starting point for your own ideas. Every object is editable after insertion.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else if location == "On this iPad" {
                            Button("Import shared object", systemImage: "square.and.arrow.down") { importing = true }
                                .buttonStyle(.bordered).accessibilityIdentifier("catalogImport")
                        }
                        if location == "Databricks" {
                            if cloudEntries.isEmpty { emptyState }
                            else if grid {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                                    ForEach(cloudEntries) { cloudCard($0) }
                                }
                            } else {
                                LazyVStack(spacing: 12) { ForEach(cloudEntries) { cloudRow($0) } }
                            }
                            if cloud.truncated {
                                Text("Showing a limited set of saved versions. More remain in your Databricks volume.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            if assets.isEmpty { emptyState }
                            else if grid {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                                    ForEach(assets) { assetCard($0) }
                                }
                            } else {
                                LazyVStack(spacing: 12) { ForEach(assets) { assetRow($0) } }
                            }
                        }
                    }.padding()
                }.background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle("Object catalog").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search objects")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: location) { _, value in
                if value == "Databricks" && cloud.entries.isEmpty { Task { await cloud.refresh(using: agent, settings: store.settings) } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
                do {
                    if store.importObjectPackage(try result.get()) { location = "On this iPad" }
                    else { errorMessage = store.status }
                } catch { errorMessage = error.localizedDescription }
            }
            .sheet(item: Binding(get: { shareURL.map(ShareFile.init) }, set: { shareURL = $0?.url })) { ActivitySheet(url: $0.url) }
            .sheet(item: $previewObject) { object in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            CatalogThumbnail(object: object, kind: object.kind).frame(height: 310)
                            Text(summary(object)).font(.subheadline).foregroundStyle(.secondary)
                            if !object.propertySpecs.isEmpty {
                                Text("Editable controls").font(.headline)
                                Text(object.propertySpecs.map { $0.label.isEmpty ? $0.key : $0.label }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            if object.kind == "widget" {
                                Label("Interactive behavior runs on the canvas after you choose Interact.", systemImage: "hand.tap")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Button("Insert on canvas", systemImage: "plus") { insert(object) }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("catalogPreviewInsert")
                        }.padding()
                    }.navigationTitle(displayTitle(object.title)).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { previewObject = nil } } }
                }.tint(.purple)
            }
            .alert("Object catalog", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }.tint(.purple)
    }
    private var cloudHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Databricks object library", systemImage: "externaldrive.badge.icloud").font(.headline)
                Spacer()
                if cloud.busy { ProgressView() }
                Button { Task { await cloud.refresh(using: agent, settings: store.settings) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.disabled(cloud.busy)
            }
            Text(cloud.status).font(.subheadline).foregroundStyle(.secondary)
            Text("Each Save creates a new version. Preview loads one object; nothing uploads automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding().background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
    private func selectedObjectActions(_ object: CanvasObject) -> some View {
        HStack(spacing: 12) {
            Image(systemName: CatalogKind.icon(object.kind)).font(.title2).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                Text("Selected on canvas").font(.caption).foregroundStyle(.secondary)
                Text(displayTitle(object.title)).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            Button { saveCloud(object) } label: { Label("Save to Databricks", systemImage: "icloud.and.arrow.up") }
                .buttonStyle(.borderedProminent).disabled(cloud.busy)
                .accessibilityIdentifier("catalogSaveSelectedToDatabricks")
        }.padding().background(.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
    private var emptyState: some View {
        ContentUnavailableView {
            Label(query.isEmpty && kind == .all ? (location == "Databricks" ? "No cloud objects" : "Your reusable objects") : "No matching objects",
                  systemImage: query.isEmpty && kind == .all ? "shippingbox" : "magnifyingglass")
        } description: {
            Text(query.isEmpty && kind == .all
                 ? (location == "Databricks" ? "Save a version from Starter, On this iPad, or the selected object above." : "Save an object from its inspector, or import an object package.")
                 : "Try another search or choose a different kind.")
        } actions: {
            if !query.isEmpty || kind != .all { Button("Clear filters") { query = ""; kind = .all } }
            else if location == "On this iPad" { Button("Browse starter objects") { location = "Starter" } }
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }
    private func assetCard(_ object: CanvasObject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { insert(object) } label: {
                VStack(alignment: .leading, spacing: 9) {
                    CatalogThumbnail(object: object, kind: object.kind).frame(height: 150)
                    Text(displayTitle(object.title)).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(summary(object)).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(height: 32, alignment: .top)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Insert \(displayTitle(object.title))")
                .accessibilityIdentifier("catalogInsert_\(object.id.uuidString)")
            HStack {
                Button("Insert", systemImage: "plus") { insert(object) }.buttonStyle(.bordered)
                Spacer()
                assetMenu(object)
            }
            Button { saveCloud(object) } label: {
                Label("Save to Databricks", systemImage: "icloud.and.arrow.up").font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).disabled(cloud.busy).accessibilityLabel("Save \(displayTitle(object.title)) version to Databricks")
        }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
    private func assetRow(_ object: CanvasObject) -> some View {
        HStack(spacing: 14) {
            Button { insert(object) } label: { CatalogThumbnail(object: object, kind: object.kind).frame(width: 118, height: 80) }
                .buttonStyle(.plain).accessibilityLabel("Insert \(displayTitle(object.title))")
            VStack(alignment: .leading, spacing: 5) {
                Button(displayTitle(object.title)) { insert(object) }.font(.headline).foregroundStyle(.primary)
                Text(summary(object)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Button { saveCloud(object) } label: { Label("Save to Databricks", systemImage: "icloud.and.arrow.up").font(.caption.weight(.medium)) }.disabled(cloud.busy)
            }
            Spacer(minLength: 0)
            Button { insert(object) } label: { Image(systemName: "plus.circle.fill").font(.title2) }.accessibilityLabel("Insert \(displayTitle(object.title))")
            assetMenu(object)
        }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
    private func assetMenu(_ object: CanvasObject) -> some View {
        Menu {
            Button("Preview", systemImage: "eye") { previewObject = object }
            if location == "Starter" { Button("Save on this iPad", systemImage: "square.and.arrow.down") { store.saveToCatalog(object); location = "On this iPad" } }
            Button("Share object package", systemImage: "square.and.arrow.up") { shareURL = store.exportObject(object) }
            if location == "On this iPad" { Button("Delete local copy", role: .destructive) { store.removeFromCatalog(id: object.id) } }
        } label: { Image(systemName: "ellipsis.circle").font(.title3).padding(5) }
            .accessibilityLabel("Actions for \(displayTitle(object.title))")
    }
    private func cloudCard(_ entry: CloudCatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { previewCloud(entry) } label: {
                CatalogThumbnail(object: cloud.previews[entry.id], kind: entry.kind, cloud: true).frame(height: 150)
            }.buttonStyle(.plain).disabled(cloud.busy).accessibilityLabel("Preview \(displayTitle(entry.title))")
            Text(displayTitle(entry.title)).font(.headline).lineLimit(1)
            Text(CatalogKind.title(entry.kind) + " · " + versionDate(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Button("Preview", systemImage: "eye") { previewCloud(entry) }.buttonStyle(.bordered)
                Spacer()
                Button("Insert", systemImage: "plus") { insertCloud(entry) }.buttonStyle(.borderedProminent)
            }.disabled(cloud.busy)
        }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
    private func cloudRow(_ entry: CloudCatalogEntry) -> some View {
        HStack(spacing: 14) {
            Button { previewCloud(entry) } label: {
                CatalogThumbnail(object: cloud.previews[entry.id], kind: entry.kind, cloud: true).frame(width: 118, height: 80)
            }.buttonStyle(.plain).accessibilityLabel("Preview \(displayTitle(entry.title))")
            VStack(alignment: .leading, spacing: 5) {
                Text(displayTitle(entry.title)).font(.headline)
                Text(CatalogKind.title(entry.kind) + " · " + versionDate(entry)).font(.caption).foregroundStyle(.secondary)
                Button("Preview", systemImage: "eye") { previewCloud(entry) }.font(.caption)
            }
            Spacer()
            Button("Insert", systemImage: "plus") { insertCloud(entry) }.buttonStyle(.borderedProminent)
        }.disabled(cloud.busy).padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
    private func insert(_ object: CanvasObject) {
        if store.insertFromCatalog(object) { store.tool = .select; previewObject = nil; dismiss() }
        else { errorMessage = store.status }
    }
    private func saveCloud(_ object: CanvasObject) {
        Task {
            if await cloud.save(object, using: agent, settings: store.settings) { location = "Databricks"; query = ""; kind = .all }
            else { errorMessage = cloud.status }
        }
    }
    private func insertCloud(_ entry: CloudCatalogEntry) {
        Task {
            if await cloud.load(entry, using: agent, store: store) { dismiss() }
            else { errorMessage = cloud.status }
        }
    }
    private func previewCloud(_ entry: CloudCatalogEntry) {
        Task {
            if let object = await cloud.preview(entry, using: agent, settings: store.settings) { previewObject = object }
            else { errorMessage = cloud.status }
        }
    }
    private func displayTitle(_ title: String) -> String { title.isEmpty ? "Untitled object" : title }
    private func summary(_ object: CanvasObject) -> String {
        StarterObjects.all.first { $0.object.id == object.id }?.summary
            ?? (CatalogKind.title(object.kind) + (object.propertySpecs.isEmpty ? "" : " · \(object.propertySpecs.count) editable controls"))
    }
    private func matches(title: String, kind objectKind: String, detail: String) -> Bool {
        guard kind.objectKind == nil || kind.objectKind == objectKind else { return false }
        let keywords = StarterObjects.all.first { $0.object.title == title }?.keywords ?? ""
        let haystack = title + " " + CatalogKind.title(objectKind) + " " + detail + " " + keywords
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { haystack.localizedCaseInsensitiveContains(String($0)) }
    }
    private func versionDate(_ entry: CloudCatalogEntry) -> String {
        if let date = ISO8601DateFormatter().date(from: entry.createdAt) { return date.formatted(date: .abbreviated, time: .omitted) }
        return "Saved version"
    }
}

struct ReferenceLibraryView: View {
    @ObservedObject var store: NotebookStore
    @ObservedObject var library: PDFLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var query = ""
    @State private var results: [PDFSearchResult] = []
    @State private var searchID: UUID?
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
                        Button("Import PDF") { importing = true }.buttonStyle(.borderedProminent).disabled(library.isImporting)
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
                            } header: { Text("Reference library") } footer: { Text("Import PDFs up to 1 GB, with no 300-page restriction. Originals stay on this iPad. Text search covers every page; scanned books need a searchable text layer. Magic Pen receives only relevant excerpts.") }
                        } else if searchID != nil {
                            HStack { ProgressView(); Text("Searching your references…").foregroundStyle(.secondary) }
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
            .overlay(alignment: .bottom) {
                if library.isImporting {
                    HStack(spacing: 12) { ProgressView(); Text(library.status).font(.subheadline) }
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
                }
            }
            .searchable(text: $query, prompt: "Search text or a question")
            .task(id: query) {
                let id = UUID(); searchID = id
                defer { if searchID == id { searchID = nil } }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                let found = await library.search(query: query)
                guard !Task.isCancelled, searchID == id else { return }
                results = found
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { importing = true } label: { Label("Import PDF", systemImage: "plus") }.disabled(library.isImporting) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                Task {
                    do {
                        let url = try result.get(); try await library.importDocument(url: url)
                        results = await library.search(query: query)
                    } catch { errorMessage = error.localizedDescription }
                }
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
    @State private var pageInput = ""
    @State private var renderingError: String?
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
                TextField("Page", text: $pageInput).keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder).frame(width: 70).accessibilityLabel("Jump to page")
                    .onSubmit { jumpToPage() }
                Button("Go") { jumpToPage() }.accessibilityIdentifier("pdfJumpToPage")
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                if let data = preview?.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: min(660, image.size.width))
                        .background(.white).clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.1), radius: 12, y: 4).padding(24)
                } else if let renderingError { Text(renderingError).foregroundStyle(.secondary).padding(40) }
                else { ProgressView().padding(80) }
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
                    store.add(object)
                    if store.notebook.objects.contains(where: { $0.id == object.id }) { store.tool = .pen; inserted = true }
                } label: { Label(inserted ? "Inserted" : "Insert page", systemImage: inserted ? "checkmark" : "plus") }
                    .buttonStyle(.borderedProminent).disabled(preview == nil || inserted)
            }.padding(20)
        }
        .navigationTitle(document.title).navigationBarTitleDisplayMode(.inline)
        .task(id: page) {
            inserted = false; preview = nil; renderingError = nil; pageInput = String(page)
            let requestedPage = page
            let object = await library.pageObject(documentID: document.id, page: requestedPage,
                                                  at: CGPoint(x: store.viewport.x + 140, y: store.viewport.y + 180))
            guard !Task.isCancelled, requestedPage == page else { return }
            preview = object
            if object == nil { renderingError = "This page could not be rendered. Try another page." }
        }
    }
    private func jumpToPage() {
        guard let requested = Int(pageInput), (1...document.pages).contains(requested) else { pageInput = String(page); return }
        page = requested
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
