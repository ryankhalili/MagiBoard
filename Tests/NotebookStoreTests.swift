import XCTest
@testable import CanvasStudio

@MainActor
final class NotebookStoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasStudioXCTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAgentBatchIsAtomicAndUndoable() throws {
        let store = NotebookStore(storageURL: try temporaryDirectory(), loadSaved: false)
        let before = store.notebook
        let id = before.objects[0].id
        var invalid = CanvasObject(); invalid.width = -1
        XCTAssertThrowsError(try store.apply(AgentResponse(message: "Invalid", operations: [
            AgentOperation(type: "delete", id: id), AgentOperation(type: "add", object: invalid)
        ])))
        XCTAssertEqual(store.notebook, before)
        let valid = CanvasObject(title: "A new object")
        try store.apply(AgentResponse(message: "Added", operations: [AgentOperation(type: "add", object: valid)]))
        XCTAssertEqual(store.notebook.objects.count, before.objects.count + 1)
        store.undo()
        XCTAssertEqual(store.notebook.objects, before.objects)
    }

    func testOfflineCompletionFiresOnceAfterCanvasMutationAndReturnsToIdle() async throws {
        let directory = try temporaryDirectory()
        let store = NotebookStore(storageURL: directory, loadSaved: false)
        store.newNotebook(title: "Offline conversation")
        store.settings.bridgeURL = ""
        store.settings.aiEnabled = true
        let library = PDFLibrary(directory: directory.appendingPathComponent("References"))
        let client = ConnectionClient()
        let completed = expectation(description: "Offline command finishes after applying its objects")
        completed.assertForOverFulfill = true
        var callbackCount = 0
        client.onCompletion = { message, failed in
            callbackCount += 1
            XCTAssertFalse(failed)
            XCTAssertFalse(client.busy, "A voice conversation must be able to start its next turn from this callback")
            XCTAssertTrue(message.contains("Offline command applied"))
            XCTAssertEqual(store.notebook.objects.count, 1, "The spoken reply must follow the actual canvas edit")
            let triangle = store.notebook.objects.first
            XCTAssertEqual(triangle?.shape, "triangle")
            XCTAssertEqual(triangle?.properties["angleA"], 49)
            XCTAssertEqual(triangle?.properties["angleB"], 52)
            XCTAssertEqual(triangle?.properties["angleC"], 79)
            XCTAssertEqual(triangle?.color, "#16A34A")
            XCTAssertEqual(store.selectedIDs, Set(store.notebook.objects.map(\.id)))
            XCTAssertTrue(store.canUndo)
            completed.fulfill()
        }
        defer { client.onCompletion = nil; client.cancel() }

        client.send("Create a green triangle with angles 49 and 52", store: store, library: library)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertEqual(callbackCount, 1)
        client.cancel()
        await Task.yield()
        XCTAssertEqual(callbackCount, 1, "Stopping an already completed conversation must not deliver its reply twice")
        store.undo()
        XCTAssertTrue(store.notebook.objects.isEmpty, "The completed command must remain one undoable canvas edit")
    }

    func testSaveFailurePreservesActiveNotebookAndInMemoryEdits() throws {
        let directory = try temporaryDirectory()
        let store = NotebookStore(storageURL: directory, loadSaved: false)
        store.add(CanvasObject(title: "Keep this edit"))
        let edited = store.notebook
        // Replace the storage directory with a regular file to force a deterministic I/O error.
        try FileManager.default.removeItem(at: directory)
        try Data("storage unavailable".utf8).write(to: directory)
        XCTAssertFalse(store.save())
        XCTAssertTrue(store.status.contains("Could not save"))
        store.newNotebook(title: "Should not replace unsaved work")
        XCTAssertEqual(store.notebook, edited)
        store.openNotebook(id: UUID())
        XCTAssertEqual(store.notebook, edited)
        // A recovery export still uses the in-memory document if the primary storage is unavailable.
        let exported = try XCTUnwrap(store.exportNotebook())
        addTeardownBlock { try? FileManager.default.removeItem(at: exported) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
    }

    func testDrawingGestureIsOneUndoStep() throws {
        let store = NotebookStore(storageURL: try temporaryDirectory(), loadSaved: false)
        store.checkpoint()
        store.setDrawing(Data([1]))
        store.setDrawing(Data([1, 2]))
        store.setDrawing(Data([1, 2, 3]))
        store.commit()
        store.undo()
        XCTAssertEqual(store.notebook.drawingData, Data())
        store.redo()
        XCTAssertEqual(store.notebook.drawingData, Data([1, 2, 3]))
    }

    func testInvalidTriangleAnglesAreRejected() throws {
        var triangle = CanvasObject(shape: "triangle")
        triangle.properties = ["angleA": 49, "angleB": 52, "angleC": 79]
        XCTAssertNoThrow(try NotebookValidation.validate(triangle))
        triangle.properties["angleC"] = 90
        XCTAssertThrowsError(try NotebookValidation.validate(triangle))
        triangle.properties = ["angleA": -1, "angleB": 52]
        XCTAssertThrowsError(try NotebookValidation.validate(triangle))
        triangle.properties = ["angleA": 120, "angleB": 70]
        XCTAssertThrowsError(try NotebookValidation.validate(triangle))
        triangle.properties = ["angleA": 1, "angleB": 89, "angleC": 90]
        XCTAssertNoThrow(try NotebookValidation.validate(triangle))
    }

    func testRoundTripAndImportCannotReplaceExistingNotebook() throws {
        let directory = try temporaryDirectory()
        let store = NotebookStore(storageURL: directory, loadSaved: false)
        let existingID = store.notebook.id
        store.add(CanvasObject(title: "Persisted object"))
        XCTAssertTrue(store.save())
        let reopened = NotebookStore(storageURL: directory)
        XCTAssertEqual(reopened.notebook.objects, store.notebook.objects)
        let exported = try XCTUnwrap(store.exportNotebook())
        addTeardownBlock { try? FileManager.default.removeItem(at: exported) }
        store.load(url: exported)
        XCTAssertNotEqual(store.notebook.id, existingID)
        XCTAssertTrue(store.notebooks.contains { $0.id == existingID })
    }
}
