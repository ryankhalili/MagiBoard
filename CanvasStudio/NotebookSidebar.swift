import SwiftUI
import UniformTypeIdentifiers

struct NotebookSidebar: View {
    @ObservedObject var store: NotebookStore
    var onClose: () -> Void
    var onCatalog: () -> Void
    var onReferences: () -> Void
    @State private var creating = false
    @State private var renaming = false
    @State private var importing = false
    @State private var name = ""
    @State private var importError: String?

    private var pages: [CanvasObject] { store.notebook.objects.filter { $0.kind == "frame" } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Library").font(.title2.weight(.bold))
                Spacer()
                Button(action: onClose) { Image(systemName: "sidebar.left").font(.title3) }
                    .accessibilityLabel("Close library").accessibilityIdentifier("closeLibrary")
            }.padding(.horizontal, 22).padding(.top, 19).padding(.bottom, 15)
            Divider()
            List {
                Section {
                    ForEach(store.notebooks) { notebook in
                        Button {
                            store.openNotebook(id: notebook.id)
                        } label: {
                            NotebookSidebarRow(notebook: notebook, active: notebook.id == store.notebook.id)
                        }.buttonStyle(.plain)
                            .listRowBackground(notebook.id == store.notebook.id ? Color.purple.opacity(0.09) : Color.clear)
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") {
                                    store.openNotebook(id: notebook.id)
                                    guard store.notebook.id == notebook.id else { return }
                                    name = notebook.title; renaming = true
                                }
                            }
                    }
                    Button { name = ""; creating = true } label: { Label("New notebook", systemImage: "plus") }
                        .accessibilityIdentifier("newNotebook")
                } header: { Text("Notebooks") }
                Section {
                    if pages.isEmpty {
                        Text("Add a page to give a section of your canvas its own space.")
                            .font(.caption).foregroundStyle(.secondary).listRowBackground(Color.clear)
                    }
                    ForEach(pages) { page in
                        Button {
                            store.selectedIDs = [page.id]; store.tool = .select
                            focusPage(page.id)
                        } label: {
                            Label(page.title.isEmpty ? "Untitled page" : page.title, systemImage: page.properties["paper"] == 1 ? "doc" : "rectangle.dashed")
                                .font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                        }.buttonStyle(.plain)
                    }
                    Button(action: addPage) { Label("New page", systemImage: "doc.badge.plus") }
                        .accessibilityIdentifier("newPage")
                } header: { Text("Pages & regions") }
                Section {
                    Button(action: onCatalog) { Label("Object catalog", systemImage: "square.grid.2x2") }
                    Button(action: onReferences) { Label("Reference library", systemImage: "doc.text.magnifyingglass") }
                    Button { importing = true } label: { Label("Import notebook", systemImage: "square.and.arrow.down") }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 7) {
                Image(systemName: "internaldrive").font(.caption)
                Text(store.status.hasPrefix("Could not save") ? "Changes haven’t saved" : "Saved on this iPad").font(.caption)
                Spacer()
            }.foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 15)
        }
        .background(.regularMaterial)
        .tint(.purple)
        .alert("New notebook", isPresented: $creating) {
            TextField("Notebook name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { store.newNotebook(title: cleanName) }
        }
        .alert("Rename notebook", isPresented: $renaming) {
            TextField("Notebook name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                store.checkpoint(); store.notebook.title = cleanName; store.commit(); store.save()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json]) { result in
            do {
                let oldID = store.notebook.id
                store.load(url: try result.get())
                if store.notebook.id == oldID { importError = store.status }
            } catch { importError = error.localizedDescription }
        }
        .alert("Could not import notebook", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
    }
    private var cleanName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled notebook" : String(trimmed.prefix(150))
    }
    private func addPage() {
        let page = CanvasObject(kind: "frame", title: "Page \(pages.count + 1)",
                                x: store.viewport.x + 100, y: store.viewport.y + 180,
                                width: 595, height: 842, color: "#FFFFFF", properties: ["paper": 1])
        store.add(page); store.tool = .select
        if store.selectedIDs.contains(page.id) { focusPage(page.id) }
    }
    private func focusPage(_ id: UUID) {
        onClose()
        // Let SwiftUI remove the sidebar before fitting the page to the canvas.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .canvasFocusObject, object: id)
        }
    }
}

private struct NotebookSidebarRow: View {
    var notebook: NotebookSummary
    var active: Bool
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: active ? "book.closed.fill" : "book.closed")
                .font(.body).foregroundStyle(active ? Color.purple : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(notebook.title).font(Font.subheadline.weight(active ? .semibold : .regular))
                    .foregroundStyle(.primary).lineLimit(2)
                Text(notebook.updatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if active { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.purple) }
        }.padding(.vertical, 4)
    }
}
