import Foundation
import SwiftUI
import UIKit
import Security

@MainActor
final class NotebookStore: ObservableObject {
    @Published var notebook: Notebook { didSet { if !isLoading { scheduleSave() } } }
    @Published var selectedIDs: Set<UUID> = []
    @Published var tool: CanvasTool = .pen
    @Published var colorHex: String = "#243449"
    @Published var lineWidth: Double = 3
    @Published var reference: CanvasRect?
    @Published var pendingTasks: [CanvasTaskRegion] = []
    @Published var status = "Saved on this iPad"
    @Published var zoom: Double = 1
    @Published var viewport = CanvasRect(x: 0, y: 0, width: 1100, height: 800)
    @Published var settings: StudioSettings { didSet { if !isLoading { persistSettings() } } }
    @Published var catalog: [CanvasObject] = []
    @Published var notebooks: [NotebookSummary] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [Notebook] = []
    private var redoStack: [Notebook] = []
    private var pendingCheckpoint: Notebook?
    private var clipboard: [CanvasObject] = []
    private var saveTask: Task<Void, Never>?
    private var isLoading = true
    private let directory: URL
    private let usesSharedKeychain: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let clipboardType = "org.madhacks.canvasstudio.objects"
    var selectedObjects: [CanvasObject] { notebook.objects.filter { selectedIDs.contains($0.id) } }

    init(storageURL: URL? = nil, loadSaved: Bool = true) {
        usesSharedKeychain = storageURL == nil
        directory = storageURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CanvasStudio", isDirectory: true)
        notebook = Notebook.welcome()
        settings = StudioSettings()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if loadSaved {
                if let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
                   let saved = try? decoder.decode(StudioSettings.self, from: data) { settings = saved }
                if usesSharedKeychain { settings.bridgeToken = PairingKeychain.read() ?? "" }
                if let data = try? Data(contentsOf: directory.appendingPathComponent("catalog.json")),
                   let saved = try? decoder.decode([CanvasObject].self, from: data) {
                    catalog = saved.filter { (try? NotebookValidation.validate($0)) != nil }
                }
                refreshLibrary()
                let activeURL = directory.appendingPathComponent("active.txt")
                let activeID = (try? String(contentsOf: activeURL, encoding: .utf8)).flatMap(UUID.init(uuidString:))
                if let id = activeID ?? notebooks.first?.id {
                    do { notebook = try readNotebook(at: fileURL(id)) }
                    catch { status = "Could not open the last notebook. Its file has been preserved." }
                }
            }
        } catch { status = "Local storage is unavailable: \(error.localizedDescription)" }
        isLoading = false
        save()
    }

    func checkpoint() { if pendingCheckpoint == nil { pendingCheckpoint = notebook } }
    func commit() {
        guard let before = pendingCheckpoint else { return }
        pendingCheckpoint = nil
        guard before != notebook else { return }
        undoStack.append(before)
        if undoStack.count > 50 { undoStack.removeFirst(undoStack.count - 50) }
        // Large ink documents get fewer historical copies, keeping the app responsive.
        while undoStack.count > 1 && undoStack.reduce(0, { $0 + $1.drawingData.count }) > 64_000_000 { undoStack.removeFirst() }
        redoStack.removeAll()
        notebook.updatedAt = Date()
        updateHistoryState()
    }
    private func mutate(_ change: (inout Notebook) -> Void) {
        let ownsCheckpoint = pendingCheckpoint == nil
        checkpoint(); change(&notebook)
        if ownsCheckpoint { commit() }
    }
    func add(_ object: CanvasObject) {
        do {
            try NotebookValidation.validate(object)
            guard notebook.objects.count < 2000 else { throw NotebookError.invalid("This notebook has reached the prototype’s object limit.") }
            var item = object
            if notebook.objects.contains(where: { $0.id == item.id }) { item.id = UUID() }
            mutate { $0.objects.append(item) }; selectedIDs = [item.id]
        } catch { status = error.localizedDescription }
    }
    func update(_ object: CanvasObject) {
        do {
            try NotebookValidation.validate(object)
            guard let i = notebook.objects.firstIndex(where: { $0.id == object.id }), notebook.objects[i] != object else { return }
            mutate { $0.objects[i] = object }
        } catch { status = error.localizedDescription }
    }
    func deleteSelection() {
        guard !selectedIDs.isEmpty else { return }
        let ids = selectedIDs
        mutate { $0.objects.removeAll { ids.contains($0.id) } }
        selectedIDs = []
    }
    func duplicateSelection() {
        let copies = selectedObjects.map { item -> CanvasObject in
            var copy = item; copy.id = UUID(); copy.x += 28; copy.y += 28; return copy
        }
        guard !copies.isEmpty, notebook.objects.count + copies.count <= 2000 else { return }
        mutate { $0.objects.append(contentsOf: copies) }; selectedIDs = Set(copies.map(\.id))
    }
    func copySelection() {
        clipboard = selectedObjects
        guard !clipboard.isEmpty else { return }
        if let data = try? encoder.encode(clipboard) { UIPasteboard.general.setData(data, forPasteboardType: clipboardType) }
        status = "Copied \(clipboard.count) object\(clipboard.count == 1 ? "" : "s")"
    }
    func paste() {
        if let data = UIPasteboard.general.data(forPasteboardType: clipboardType), data.count <= 30_000_000,
           let objects = try? decoder.decode([CanvasObject].self, from: data), objects.count <= 2000,
           objects.allSatisfy({ (try? NotebookValidation.validate($0)) != nil }) { clipboard = objects }
        else if let image = UIPasteboard.general.image, let data = image.pngData() {
            let width = min(Double(image.size.width), 500)
            add(CanvasObject(kind: "image", title: "Pasted image", x: viewport.x + 100, y: viewport.y + 100,
                             width: width, height: width * Double(image.size.height / max(image.size.width, 1)), imageData: data)); return
        } else if let text = UIPasteboard.general.string, !text.isEmpty {
            add(CanvasObject(kind: "text", title: "Pasted text", x: viewport.x + 100, y: viewport.y + 100,
                             width: 360, height: 180, color: colorHex, text: text, properties: ["fontSize": 20])); return
        }
        guard !clipboard.isEmpty, notebook.objects.count + clipboard.count <= 2000 else { return }
        let minX = clipboard.map(\.x).min() ?? 0, minY = clipboard.map(\.y).min() ?? 0
        let copies = clipboard.map { item -> CanvasObject in
            var copy = item; copy.id = UUID(); copy.x += viewport.x + 120 - minX; copy.y += viewport.y + 120 - minY; return copy
        }
        mutate { $0.objects.append(contentsOf: copies) }; selectedIDs = Set(copies.map(\.id))
    }
    func setDrawing(_ data: Data) {
        guard data != notebook.drawingData else { return }
        mutate { $0.drawingData = data }
    }
    func undo() {
        commit()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(notebook); notebook = previous; selectedIDs = []
        updateHistoryState()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(notebook); notebook = next; selectedIDs = []
        updateHistoryState()
    }
    private func updateHistoryState() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }
    private func clearHistory() { pendingCheckpoint = nil; undoStack = []; redoStack = []; updateHistoryState() }

    func apply(_ response: AgentResponse, selectResults: Bool = true) throws {
        guard response.operations.count <= 100 else { throw NotebookError.invalid("The agent proposed too many operations at once.") }
        var proposed = notebook
        for operation in response.operations {
            switch operation.type {
            case "add":
                guard let object = operation.object else { throw NotebookError.invalid("An add operation is missing its object.") }
                guard !proposed.objects.contains(where: { $0.id == object.id }) else { throw NotebookError.invalid("The agent reused an existing object identifier.") }
                try NotebookValidation.validate(object); proposed.objects.append(object)
            case "update":
                guard var object = operation.object, let id = operation.id ?? operation.object?.id,
                      let i = proposed.objects.firstIndex(where: { $0.id == id }) else { throw NotebookError.invalid("The object to update could not be found.") }
                object.id = id; try NotebookValidation.validate(object); proposed.objects[i] = object
            case "delete":
                guard let id = operation.id, proposed.objects.contains(where: { $0.id == id }) else { throw NotebookError.invalid("The object to remove could not be found.") }
                proposed.objects.removeAll { $0.id == id }
            default: throw NotebookError.invalid("Unsupported agent operation: \(operation.type)")
            }
        }
        try NotebookValidation.validate(proposed)
        guard proposed != notebook else { status = response.message; return }
        mutate { $0 = proposed }
        if selectResults { selectedIDs = Set(response.operations.compactMap { $0.type == "delete" ? nil : ($0.id ?? $0.object?.id) }) }
        else { selectedIDs.formIntersection(Set(notebook.objects.map(\.id))) }
        status = response.message
    }

    /// Merge independent agent work without overwriting an object edited since its snapshot.
    func applyAgentResponse(_ response: AgentResponse, basedOn baseline: Notebook) throws {
        guard baseline.id == notebook.id else { throw NotebookError.invalid("This task belongs to another notebook.") }
        let before = Dictionary(uniqueKeysWithValues: baseline.objects.map { ($0.id, $0) })
        let current = Dictionary(uniqueKeysWithValues: notebook.objects.map { ($0.id, $0) })
        for operation in response.operations where operation.type == "update" || operation.type == "delete" {
            guard let id = operation.id ?? operation.object?.id, let original = before[id], current[id] == original else {
                throw NotebookError.invalid("An object this task wanted to change was edited while it worked. Your edits are safe; retry with the latest canvas.")
            }
        }
        let gestureInProgress = pendingCheckpoint != nil
        if gestureInProgress { commit() }
        do {
            try apply(response, selectResults: false)
            if gestureInProgress { checkpoint() }
        } catch {
            if gestureInProgress { checkpoint() }
            throw error
        }
    }

    func newNotebook(title: String = "Untitled notebook") {
        guard save() else { return }
        saveTask?.cancel(); clearHistory(); selectedIDs = []; reference = nil
        notebook = Notebook(title: title); save()
    }
    func openNotebook(id: UUID) {
        guard id != notebook.id else { return }
        guard save() else { return }
        do {
            let loaded = try readNotebook(at: fileURL(id))
            clearHistory(); selectedIDs = []; reference = nil; notebook = loaded; save()
        } catch { status = error.localizedDescription }
    }
    func load(url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            var loaded = try readNotebook(at: url)
            // Import a distinct notebook so a shared document can never overwrite local work.
            loaded.id = UUID(); loaded.updatedAt = Date()
            guard save() else { return }
            clearHistory(); selectedIDs = []; reference = nil; notebook = loaded; save()
            status = "Imported \(loaded.title)"
        } catch { status = "Could not import: \(error.localizedDescription)" }
    }
    private func readNotebook(at url: URL) throws -> Notebook {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 70_000_000 else { throw NotebookError.invalid("This notebook file is too large.") }
        let document = try decoder.decode(Notebook.self, from: Data(contentsOf: url))
        try NotebookValidation.validate(document)
        return document
    }
    func exportNotebook() -> URL? {
        save()
        do {
            let safeTitle = notebook.title.replacingOccurrences(of: "[^a-zA-Z0-9 _-]", with: "", options: .regularExpression)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeTitle.isEmpty ? "Notebook" : String(safeTitle.prefix(80))).canvasstudio")
            try encoder.encode(notebook).write(to: url, options: .atomic)
            return url
        } catch { status = "Export failed: \(error.localizedDescription)"; return nil }
    }
    func saveToCatalog(_ object: CanvasObject) {
        do {
            try NotebookValidation.validate(object)
            var copy = object; copy.id = UUID(); copy.x = 0; copy.y = 0
            var proposed = catalog; proposed.append(copy)
            try encoder.encode(proposed).write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
            catalog = proposed; status = "Saved to your object catalog"
        } catch { status = "Could not save object: \(error.localizedDescription)" }
    }
    func exportObject(_ object: CanvasObject) -> URL? {
        do {
            try NotebookValidation.validate(object)
            let name = object.title.replacingOccurrences(of: "[^a-zA-Z0-9 _-]", with: "", options: .regularExpression)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.isEmpty ? "Object" : String(name.prefix(70)))-\(object.id.uuidString.prefix(8)).magiboardobject")
            try encoder.encode(ObjectPackage(object: object)).write(to: url, options: .atomic)
            return url
        } catch { status = "Could not export object: \(error.localizedDescription)"; return nil }
    }
    @discardableResult func importObjectPackage(_ url: URL) -> Bool {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 30_000_000 else { throw NotebookError.invalid("This object package is too large.") }
            let package = try decoder.decode(ObjectPackage.self, from: Data(contentsOf: url))
            try package.validate()
            let oldCount = catalog.count
            saveToCatalog(package.object)
            return catalog.count > oldCount
        } catch { status = "Could not import object: \(error.localizedDescription)"; return false }
    }
    @discardableResult func insertFromCatalog(_ object: CanvasObject) -> Bool {
        var copy = object; copy.id = UUID(); copy.x = viewport.x + 120; copy.y = viewport.y + 180; add(copy)
        guard notebook.objects.contains(where: { $0.id == copy.id }) else { return false }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .canvasFocusObject, object: copy.id) }
        return true
    }
    func removeFromCatalog(id: UUID) {
        do {
            let proposed = catalog.filter { $0.id != id }
            try encoder.encode(proposed).write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
            catalog = proposed
        } catch { status = error.localizedDescription }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            self?.save()
        }
    }
    @discardableResult func save() -> Bool {
        do {
            try NotebookValidation.validate(notebook)
            try encoder.encode(notebook).write(to: fileURL(notebook.id), options: .atomic)
            try notebook.id.uuidString.write(to: directory.appendingPathComponent("active.txt"), atomically: true, encoding: .utf8)
            let summary = NotebookSummary(id: notebook.id, title: notebook.title, updatedAt: notebook.updatedAt, objectCount: notebook.objects.count)
            notebooks.removeAll { $0.id == summary.id }; notebooks.append(summary)
            notebooks.sort { $0.updatedAt > $1.updatedAt }
            return true
        } catch { status = "Could not save: \(error.localizedDescription)"; return false }
    }
    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("canvasstudio") }
    private func refreshLibrary() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        notebooks = urls.filter { $0.pathExtension == "canvasstudio" }.compactMap { url in
            guard let item = try? readNotebook(at: url) else { return nil }
            return NotebookSummary(id: item.id, title: item.title, updatedAt: item.updatedAt, objectCount: item.objects.count)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private func persistSettings() {
        do {
            try encoder.encode(settings).write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
            if usesSharedKeychain { try PairingKeychain.write(settings.bridgeToken) }
        } catch { status = "Could not save settings: \(error.localizedDescription)" }
    }
}

private enum PairingKeychain {
    static let service = "org.madhacks.CanvasStudio.bridge"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "pairing-token"] }
    static func read() -> String? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ token: String) throws {
        guard !token.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var insertion = query; attributes.forEach { insertion[$0.key] = $0.value }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw NotebookError.invalid("The connection token could not be saved in Keychain.") }
        } else if result != errSecSuccess { throw NotebookError.invalid("The connection token could not be updated in Keychain.") }
    }
}
