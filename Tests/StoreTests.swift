import Foundation

@main
struct StoreChecks {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasStudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NotebookStore(storageURL: directory, loadSaved: false)
        let baseline = store.notebook
        let object = CanvasObject(kind: "shape", title: "Test circle", shape: "ellipse")
        store.add(object)
        precondition(store.notebook.objects.count == baseline.objects.count + 1 && store.canUndo)
        store.undo()
        precondition(store.notebook.objects.count == baseline.objects.count && store.canRedo)
        store.redo()
        precondition(store.notebook.objects.contains { $0.id == object.id })
        store.checkpoint()
        store.setDrawing(Data([1, 2]))
        store.setDrawing(Data([1, 2, 3]))
        store.commit()
        store.undo()
        precondition(store.notebook.drawingData.isEmpty, "A drawing gesture must be one undo transaction")
        store.redo()
        precondition(store.notebook.drawingData == Data([1, 2, 3]))
        let beforeFailure = store.notebook
        var invalid = object; invalid.id = UUID(); invalid.width = -20
        do {
            try store.apply(AgentResponse(message: "bad", operations: [AgentOperation(type: "delete", id: object.id), AgentOperation(type: "add", object: invalid)]))
            preconditionFailure("Invalid agent batch should fail")
        } catch {}
        precondition(store.notebook == beforeFailure, "Invalid batch must roll back all changes")
        var changed = object; changed.color = "#16A34A"
        try store.apply(AgentResponse(message: "updated", operations: [AgentOperation(type: "update", id: object.id, object: changed)]))
        precondition(store.notebook.objects.first { $0.id == object.id }?.color == "#16A34A")
        store.undo()
        precondition(store.notebook.objects.first { $0.id == object.id }?.color == object.color)
        store.selectedIDs = [object.id]; store.duplicateSelection()
        precondition(Set(store.notebook.objects.map(\.id)).count == store.notebook.objects.count)
        store.saveToCatalog(object)
        precondition(store.catalog.count == 1)
        store.insertFromCatalog(store.catalog[0])
        precondition(store.selectedObjects.count == 1 && store.selectedObjects[0].id != object.id)
        store.save()
        let restored = NotebookStore(storageURL: directory)
        precondition(restored.notebook.objects == store.notebook.objects && restored.notebook.drawingData == store.notebook.drawingData)
        let exported = store.exportNotebook()!
        defer { try? FileManager.default.removeItem(at: exported) }
        let originalID = store.notebook.id
        store.load(url: exported)
        precondition(store.notebook.id != originalID && store.notebooks.contains { $0.id == originalID })
        let keep = store.notebook
        try FileManager.default.removeItem(at: directory)
        try Data("unavailable".utf8).write(to: directory)
        precondition(!store.save())
        store.newNotebook(title: "Cannot lose edits")
        precondition(store.notebook == keep)
        store.openNotebook(id: UUID())
        precondition(store.notebook == keep)
        print("10 store checks passed: undo, grouped ink, atomic agent validation, catalog, persistence, safe import and save-failure recovery")
    }
}
