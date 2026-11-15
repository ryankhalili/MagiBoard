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
        store.tool = .magic
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
            XCTAssertTrue(store.selectedIDs.isEmpty, "Completing a task must not select objects while the user is working")
            XCTAssertEqual(store.tool, .magic)
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

    func testDeclaredPropertyRangesAreInclusiveAndAllowOneSidedBounds() throws {
        for spec in [
            ObjectPropertySpec(key: "value", label: "Value", min: -2, max: 3),
            ObjectPropertySpec(key: "value", label: "Value", control: "slider", min: -2, max: 3, step: 0.5)
        ] {
            var object = CanvasObject(properties: ["value": -2], propertySpecs: [spec])
            for valid in [-2.0, 0.25, 3.0] {
                object.properties["value"] = valid
                XCTAssertNoThrow(try NotebookValidation.validate(object), "Range endpoints and intermediate values must remain valid")
            }
            for invalid in [-2.001, 3.001] {
                object.properties["value"] = invalid
                XCTAssertThrowsError(try NotebookValidation.validate(object), "Both numeric and slider bounds apply to stored values")
            }
        }
        var minimumOnly = CanvasObject(properties: ["value": 100], propertySpecs: [ObjectPropertySpec(key: "value", label: "Minimum", min: 1)])
        XCTAssertNoThrow(try NotebookValidation.validate(minimumOnly))
        minimumOnly.properties["value"] = 0
        XCTAssertThrowsError(try NotebookValidation.validate(minimumOnly))
        var maximumOnly = CanvasObject(properties: ["value": -100], propertySpecs: [ObjectPropertySpec(key: "value", label: "Maximum", max: 1)])
        XCTAssertNoThrow(try NotebookValidation.validate(maximumOnly))
        maximumOnly.properties["value"] = 2
        XCTAssertThrowsError(try NotebookValidation.validate(maximumOnly))
    }

    func testToggleAndChoiceValuesMustMatchTheirNativeControls() throws {
        var toggle = CanvasObject(properties: ["enabled": 0], propertySpecs: [ObjectPropertySpec(key: "enabled", label: "Enabled", control: "toggle")])
        for valid in [0.0, 1.0] {
            toggle.properties["enabled"] = valid
            XCTAssertNoThrow(try NotebookValidation.validate(toggle))
        }
        for invalid in [-1.0, 0.5, 2.0] {
            toggle.properties["enabled"] = invalid
            XCTAssertThrowsError(try NotebookValidation.validate(toggle))
        }
        var choice = CanvasObject(properties: ["mode": -2], propertySpecs: [
            ObjectPropertySpec(key: "mode", label: "Mode", control: "choice", choices: [
                PropertyChoice(label: "First", value: -2), PropertyChoice(label: "Second", value: 0.5)
            ])
        ])
        XCTAssertNoThrow(try NotebookValidation.validate(choice))
        choice.properties["mode"] = 0.5
        XCTAssertNoThrow(try NotebookValidation.validate(choice))
        choice.properties["mode"] = 0
        XCTAssertThrowsError(try NotebookValidation.validate(choice), "A Picker must never receive an absent selection")
        choice.propertySpecs[0].choices = []
        XCTAssertThrowsError(try NotebookValidation.validate(choice))
    }

    func testSliderRequiresAnExplicitFinitePositiveStep() throws {
        var object = CanvasObject(properties: ["value": 0.5], propertySpecs: [
            ObjectPropertySpec(key: "value", label: "Value", control: "slider", min: 0, max: 1)
        ])
        XCTAssertThrowsError(try NotebookValidation.validate(object))
        for invalid in [0.0, -1.0, 0.0000000001, Double.infinity, Double.nan] {
            object.propertySpecs[0].step = invalid
            XCTAssertThrowsError(try NotebookValidation.validate(object))
        }
        object.propertySpecs[0].step = 0.000000001
        XCTAssertNoThrow(try NotebookValidation.validate(object))
        object.propertySpecs[0].control = "number"
        object.propertySpecs[0].step = nil
        XCTAssertNoThrow(try NotebookValidation.validate(object), "Free numeric fields do not require a step")
    }

    func testLegacyPropertiesWithoutDescriptorsRemainCompatible() throws {
        let legacy = Data(#"{"kind":"widget","properties":{"enabled":0.5,"mode":-42,"custom":1000000}}"#.utf8)
        let object = try JSONDecoder().decode(CanvasObject.self, from: legacy)
        XCTAssertTrue(object.propertySpecs.isEmpty)
        XCTAssertEqual(object.properties["enabled"], 0.5)
        XCTAssertNoThrow(try NotebookValidation.validate(object), "Property names alone must not imply new constraints")
        let restored = try JSONDecoder().decode(CanvasObject.self, from: JSONEncoder().encode(object))
        XCTAssertEqual(restored, object)
    }

    func testStarterCatalogContainsValidEditableObjectsAndInsertsIndependentCopies() throws {
        let starters = StarterObjects.all
        XCTAssertEqual(starters.count, 16)
        XCTAssertEqual(Set(starters.map(\.id)).count, starters.count)
        XCTAssertEqual(Set(starters.map { $0.object.id }).count, starters.count)
        let store = NotebookStore(storageURL: try temporaryDirectory(), loadSaved: false)
        store.newNotebook(title: "Starter validation")
        for starter in starters {
            XCTAssertNoThrow(try NotebookValidation.validate(starter.object), starter.id)
            let decoded = try JSONDecoder().decode(CanvasObject.self, from: JSONEncoder().encode(starter.object))
            XCTAssertEqual(decoded, starter.object)
            if starter.object.kind == "latex" {
                XCTAssertNil(EquationRenderer.diagnostic(starter.object.text), starter.id)
            }
            if starter.object.kind == "graph" {
                XCTAssertTrue(PlotExpression(starter.object.text).evaluate(x: 1).isFinite, starter.id)
            }
            XCTAssertTrue(store.insertFromCatalog(starter.object), starter.id)
            let inserted = try XCTUnwrap(store.notebook.objects.last)
            XCTAssertNotEqual(inserted.id, starter.object.id)
            XCTAssertEqual(inserted.propertySpecs, starter.object.propertySpecs)
            XCTAssertEqual(inserted.code, starter.object.code)
        }
        XCTAssertEqual(store.notebook.objects.count, starters.count)
        var edited = try XCTUnwrap(store.notebook.objects.first)
        edited.title = "My edited copy"; store.update(edited)
        XCTAssertEqual(StarterObjects.all.first?.object.title, "Triangle")
    }

    func testCatalogPreviewsRenderNativeContentWithoutRunningWidgetCode() throws {
        for starter in StarterObjects.all {
            let object = starter.object
            if object.kind == "widget" {
                XCTAssertNil(CatalogThumbnailRenderer.image(for: object), "Unrendered widgets use an honest placeholder, never background execution")
            } else {
                let image = try XCTUnwrap(CatalogThumbnailRenderer.image(for: object), starter.id)
                XCTAssertEqual(image.size.width, 360)
                XCTAssertEqual(image.size.height, 210)
                XCTAssertNotNil(image.pngData())
            }
        }
    }

    func testInvalidDeclaredValueRejectsEntireAgentTransaction() throws {
        let store = NotebookStore(storageURL: try temporaryDirectory(), loadSaved: false)
        let before = store.notebook, selection = store.selectedIDs, couldUndo = store.canUndo
        let invalid = CanvasObject(properties: ["speed": 99], propertySpecs: [
            ObjectPropertySpec(key: "speed", label: "Speed", control: "slider", min: 0, max: 3, step: 0.1)
        ])
        XCTAssertThrowsError(try store.apply(AgentResponse(message: "Invalid controls", operations: [
            AgentOperation(type: "delete", id: before.objects[0].id),
            AgentOperation(type: "add", object: invalid)
        ])))
        XCTAssertEqual(store.notebook, before, "An invalid property must also roll back earlier operations")
        XCTAssertEqual(store.selectedIDs, selection)
        XCTAssertEqual(store.canUndo, couldUndo, "Rejected transactions must not create an undo entry")
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
