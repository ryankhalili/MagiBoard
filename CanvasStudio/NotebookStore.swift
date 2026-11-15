import Foundation
import SwiftUI
import UIKit
import Security
import PencilKit

@MainActor
final class NotebookStore: ObservableObject {
    @Published var notebook: Notebook { didSet {
        if !preservingInkSelection && (notebook.id != oldValue.id || notebook.drawingData != oldValue.drawingData) {
            inkRevision &+= 1; selectedStrokeIndices = []
        }
        if !isLoading { scheduleSave() }
    } }
    @Published var selectedIDs: Set<UUID> = []
    @Published var selectedStrokeIndices: Set<Int> = []
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
    private var clipboard: CanvasSelectionPayload?
    private var preservingInkSelection = false
    private var inkRevision: UInt64 = 0
    private var cachedInkData = Data()
    private var cachedInk = PKDrawing()
    private var saveTask: Task<Void, Never>?
    private var isLoading = true
    private let directory: URL
    private let usesSharedKeychain: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let clipboardType = "org.madhacks.canvasstudio.objects"
    private let mixedClipboardType = "org.madhacks.canvasstudio.selection.v1"
    var selectedObjects: [CanvasObject] { notebook.objects.filter { selectedIDs.contains($0.id) } }
    var worldInk: PKDrawing {
        if cachedInkData != notebook.drawingData {
            cachedInkData = notebook.drawingData
            cachedInk = (try? PKDrawing(data: notebook.drawingData)) ?? PKDrawing()
        }
        return cachedInk
    }
    var hasSelection: Bool { !selectedObjects.isEmpty || selectedStrokeIndices.contains(where: worldInk.strokes.indices.contains) }
    var selectionBounds: CGRect? {
        var rect = selectedObjects.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        for index in selectedStrokeIndices where worldInk.strokes.indices.contains(index) { rect = rect.union(worldInk.strokes[index].renderBounds) }
        return rect.isNull ? nil : rect
    }
    func clearSelection() { selectedIDs = []; selectedStrokeIndices = [] }
    func setSelection(objects: Set<UUID>, strokes: Set<Int>) {
        selectedIDs = objects.intersection(Set(notebook.objects.map(\.id)))
        selectedStrokeIndices = strokes.filter { worldInk.strokes.indices.contains($0) }
    }
    func selectAll() { setSelection(objects: Set(notebook.objects.map(\.id)), strokes: Set(worldInk.strokes.indices)) }

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
            mutate { $0.objects.append(item) }; selectedIDs = [item.id]; selectedStrokeIndices = []
        } catch { status = error.localizedDescription }
    }
    func update(_ object: CanvasObject) {
        do {
            try NotebookValidation.validate(object)
            guard let i = notebook.objects.firstIndex(where: { $0.id == object.id }), notebook.objects[i] != object else { return }
            mutate { $0.objects[i] = object }
        } catch { status = error.localizedDescription }
    }
    func selectionSnapshot() -> CanvasSelectionSnapshot {
        CanvasSelectionSnapshot(notebookID: notebook.id, objects: selectedObjects, drawing: worldInk, drawingData: notebook.drawingData, strokeIndices: selectedStrokeIndices, inkRevision: inkRevision)
    }
    /// During a drag, transform from its captured starting state, never cumulatively.
    @discardableResult
    func moveSelection(from snapshot: CanvasSelectionSnapshot, by delta: CGPoint) -> Bool {
        guard snapshot.notebookID == notebook.id, delta.x.isFinite, delta.y.isFinite,
              snapshot.strokeIndices.isEmpty || snapshot.inkRevision == inkRevision,
              snapshot.expectedObjects.allSatisfy({ id, expected in notebook.objects.first { $0.id == id } == expected }) else { return false }
        var proposed = notebook
        for original in snapshot.objects {
            guard let index = proposed.objects.firstIndex(where: { $0.id == original.id }) else { continue }
            var object = original; object.x += delta.x; object.y += delta.y
            proposed.objects[index] = object
        }
        if !snapshot.strokeIndices.isEmpty {
            let strokes = snapshot.drawing.strokes.enumerated().map { index, stroke in
                snapshot.strokeIndices.contains(index) ? PKDrawing(strokes: [stroke]).transformed(using: CGAffineTransform(translationX: delta.x, y: delta.y)).strokes[0] : stroke
            }
            proposed.drawingData = PKDrawing(strokes: strokes).dataRepresentation()
        }
        guard (try? NotebookValidation.validate(proposed)) != nil,
              snapshot.strokeIndices.isEmpty || Self.validInk((try? PKDrawing(data: proposed.drawingData)) ?? PKDrawing()) else { return false }
        preservingInkSelection = true
        mutate { $0 = proposed }
        preservingInkSelection = false
        snapshot.expectedObjects = Dictionary(uniqueKeysWithValues: proposed.objects.filter { snapshot.expectedObjects[$0.id] != nil }.map { ($0.id, $0) })
        return true
    }
    @discardableResult
    func cancelSelectionMove(_ snapshot: CanvasSelectionSnapshot) -> Bool {
        guard snapshot.notebookID == notebook.id else { return false }
        var proposed = notebook
        for original in snapshot.objects {
            if let index = proposed.objects.firstIndex(where: { $0.id == original.id }), proposed.objects[index] == snapshot.expectedObjects[original.id] {
                proposed.objects[index] = original
            }
        }
        if !snapshot.strokeIndices.isEmpty && snapshot.inkRevision == inkRevision { proposed.drawingData = snapshot.drawingData }
        preservingInkSelection = true; mutate { $0 = proposed }; preservingInkSelection = false
        if snapshot.inkRevision != inkRevision { selectedStrokeIndices = [] }
        return snapshot.inkRevision == inkRevision
    }
    private static func validInk(_ drawing: PKDrawing) -> Bool {
        guard drawing.strokes.count <= 100_000 else { return false }
        for stroke in drawing.strokes {
            let rect = stroke.renderBounds, t = stroke.transform
            guard [rect.minX, rect.minY, rect.maxX, rect.maxY, t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }) else { return false }
        }
        return true
    }
    func deleteSelection() {
        guard hasSelection else { return }
        let ids = selectedIDs, indices = selectedStrokeIndices
        let drawing = PKDrawing(strokes: worldInk.strokes.enumerated().filter { !indices.contains($0.offset) }.map(\.element))
        mutate {
            $0.objects.removeAll { ids.contains($0.id) }
            if !indices.isEmpty { $0.drawingData = drawing.dataRepresentation() }
        }
        clearSelection()
    }
    func duplicateSelection() {
        guard let bounds = selectionBounds, let payload = selectionPayload() else { return }
        _ = pasteSelection(payload, at: CGPoint(x: bounds.minX + 28, y: bounds.minY + 28))
    }
    func selectionPayload() -> CanvasSelectionPayload? {
        guard let bounds = selectionBounds else { return nil }
        let transform = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        let objects = selectedObjects.map { original -> CanvasObject in
            var copy = original; copy.x -= bounds.minX; copy.y -= bounds.minY; return copy
        }
        let strokes = worldInk.strokes.enumerated().filter { selectedStrokeIndices.contains($0.offset) }.map(\.element)
        let ink = PKDrawing(strokes: strokes).transformed(using: transform)
        return CanvasSelectionPayload(objects: objects, drawingData: ink.dataRepresentation(), bounds: CanvasRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
    }
    func copySelection() {
        guard let payload = selectionPayload(), let data = try? encoder.encode(payload), data.count <= 40_000_000 else { return }
        clipboard = payload
        var item: [String: Any] = [mixedClipboardType: data]
        if !payload.objects.isEmpty, let objects = try? encoder.encode(payload.objects) { item[clipboardType] = objects }
        UIPasteboard.general.items = [item]
        status = "Copied selection"
    }
    @discardableResult
    func pasteSelection(_ payload: CanvasSelectionPayload, at point: CGPoint) -> Bool {
        do {
            guard payload.version == 1, payload.objects.count <= 2000, payload.drawingData.count <= 40_000_000,
                  point.x.isFinite, point.y.isFinite, abs(point.x) <= 10_000_000, abs(point.y) <= 10_000_000 else {
                throw NotebookError.invalid("The copied selection is too large or has an invalid position.")
            }
            let source = try PKDrawing(data: payload.drawingData)
            guard Self.validInk(source) else { throw NotebookError.invalid("The copied ink has invalid coordinates.") }
            guard !source.strokes.isEmpty || !payload.objects.isEmpty else { return false }
            guard source.strokes.count + worldInk.strokes.count <= 100_000 else { throw NotebookError.invalid("This selection contains too many ink strokes.") }
            let incoming = source.transformed(using: CGAffineTransform(translationX: point.x, y: point.y))
            guard Self.validInk(incoming) else { throw NotebookError.invalid("The pasted ink would lie outside the canvas coordinate limits.") }
            let objects = payload.objects.map { original -> CanvasObject in
                var copy = original; copy.id = UUID(); copy.x += point.x; copy.y += point.y; return copy
            }
            var proposed = notebook
            proposed.objects.append(contentsOf: objects)
            let firstStroke = worldInk.strokes.count
            if !incoming.strokes.isEmpty { proposed.drawingData = PKDrawing(strokes: worldInk.strokes + incoming.strokes).dataRepresentation() }
            try NotebookValidation.validate(proposed)
            mutate { $0 = proposed }
            setSelection(objects: Set(objects.map(\.id)), strokes: Set(firstStroke..<(firstStroke + incoming.strokes.count)))
            status = "Pasted selection"
            return true
        } catch { status = "Could not paste: \(error.localizedDescription)"; return false }
    }
    func paste() {
        if let data = UIPasteboard.general.data(forPasteboardType: mixedClipboardType) {
            guard data.count <= 40_000_000, let payload = try? decoder.decode(CanvasSelectionPayload.self, from: data) else { status = "Could not read the copied selection"; return }
            clipboard = payload
        } else if let data = UIPasteboard.general.data(forPasteboardType: clipboardType) {
            guard data.count <= 30_000_000, let objects = try? decoder.decode([CanvasObject].self, from: data), objects.count <= 2000,
                  objects.allSatisfy({ (try? NotebookValidation.validate($0)) != nil }) else { status = "Could not read copied objects"; return }
            let bounds = objects.map(\.rect).reduce(CGRect.null) { $0.union($1) }
            guard !bounds.isNull else { return }
            let normalized = objects.map { original -> CanvasObject in var copy = original; copy.x -= bounds.minX; copy.y -= bounds.minY; return copy }
            clipboard = CanvasSelectionPayload(objects: normalized, drawingData: PKDrawing().dataRepresentation(), bounds: CanvasRect(CGRect(origin: .zero, size: bounds.size)))
        } else if let image = UIPasteboard.general.image, let data = image.pngData() {
            do { add(try CanvasImageImport.object(from: data, title: "Pasted image", viewport: viewport)) }
            catch { status = error.localizedDescription }
            return
        } else if let text = UIPasteboard.general.string, !text.isEmpty {
            add(CanvasObject(kind: "text", title: "Pasted text", x: viewport.x + 120, y: viewport.y + 180,
                             width: 360, height: 180, color: colorHex, text: text, properties: ["fontSize": 20])); return
        }
        guard let clipboard else { return }
        _ = pasteSelection(clipboard, at: CGPoint(x: viewport.x + 120, y: viewport.y + 180))
    }
    func setDrawing(_ data: Data) {
        guard data != notebook.drawingData else { return }
        mutate { $0.drawingData = data }
    }
    func undo() {
        commit()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(notebook); notebook = previous; clearSelection()
        updateHistoryState()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(notebook); notebook = next; clearSelection()
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
        if selectResults { selectedIDs = Set(response.operations.compactMap { $0.type == "delete" ? nil : ($0.id ?? $0.object?.id) }); selectedStrokeIndices = [] }
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
        saveTask?.cancel(); clearHistory(); clearSelection(); reference = nil
        notebook = Notebook(title: title); save()
    }
    func openNotebook(id: UUID) {
        guard id != notebook.id else { return }
        guard save() else { return }
        do {
            let loaded = try readNotebook(at: fileURL(id))
            clearHistory(); clearSelection(); reference = nil; notebook = loaded; save()
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
            clearHistory(); clearSelection(); reference = nil; notebook = loaded; save()
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
