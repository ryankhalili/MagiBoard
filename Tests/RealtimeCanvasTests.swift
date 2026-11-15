import XCTest
@testable import CanvasStudio

@MainActor
final class RealtimeCanvasTests: XCTestCase {
    private func environment() -> (NotebookStore, PDFLibrary) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NotebookStore(storageURL: root, loadSaved: false)
        store.newNotebook(title: "Voice references")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (store, PDFLibrary(directory: root.appendingPathComponent("PDFs")))
    }
    func testThreeVoiceTurnsKeepTheirOriginalReferencesAfterPointerMoves() throws {
        let (store, library) = environment(), session = RealtimeCanvasSession()
        for index in 0..<3 {
            store.reference = CanvasRect(x: Double(index * 500), y: Double(index * 100), width: 180, height: 120)
            _ = session.speechStarted(store: store, library: library)
            session.responseCreated("response-\(index)")
        }
        store.reference = CanvasRect(x: -900, y: -700)
        _ = session.focus(store: store, library: library)
        for index in 0..<3 {
            let focus = try session.resolve(responseID: "response-\(index)", suppliedReference: session.current?.id)
            XCTAssertEqual(focus.reference.x, Double(index * 500))
            XCTAssertEqual(focus.reference.y, Double(index * 100))
        }
        session.reset()
        XCTAssertThrowsError(try session.resolve(responseID: "response-0", suppliedReference: nil))
    }
    func testDirectTriangleEditHasExactAnglesAndOneUndoWithoutChangingTool() throws {
        let (store, library) = environment(), session = RealtimeCanvasSession()
        store.tool = .magic; store.reference = CanvasRect(x: 450, y: 320)
        _ = session.focus(store: store, library: library)
        let focus = try XCTUnwrap(session.current)
        let result = try RealtimeCanvasEdits.response(arguments: ["operations": [["action": "add", "kind": "shape", "shape": "triangle", "color": "green", "propertiesJSON": "{\"angleA\":49,\"angleB\":52}"]]], focus: focus)
        try store.applyAgentResponse(result, basedOn: focus.notebook)
        let triangle = try XCTUnwrap(store.notebook.objects.last)
        XCTAssertEqual(triangle.properties["angleC"], 79)
        XCTAssertEqual(triangle.color, "#16A34A")
        XCTAssertEqual(triangle.x, 450); XCTAssertEqual(triangle.y, 320)
        XCTAssertEqual(store.tool, .magic)
        store.undo(); XCTAssertTrue(store.notebook.objects.isEmpty)
    }
    func testInvalidDirectBatchCannotPartiallyApplyAndStaleUpdatePreservesUserEdit() throws {
        let (store, library) = environment(), session = RealtimeCanvasSession()
        let original = CanvasObject(kind: "shape", color: "#000000")
        store.add(original)
        _ = session.focus(store: store, library: library)
        let focus = try XCTUnwrap(session.current)
        XCTAssertThrowsError(try RealtimeCanvasEdits.response(arguments: ["operations": [
            ["action": "add", "kind": "shape"], ["action": "update", "id": UUID().uuidString]]], focus: focus))
        XCTAssertEqual(store.notebook.objects.count, 1)
        let result = try RealtimeCanvasEdits.response(arguments: ["operations": [["action": "update", "id": original.id.uuidString, "color": "#11AA22"]]], focus: focus)
        var changed = original; changed.text = "A newer manual edit"; store.update(changed)
        XCTAssertThrowsError(try store.applyAgentResponse(result, basedOn: focus.notebook))
        XCTAssertEqual(store.notebook.objects[0].color, "#000000")
        XCTAssertEqual(store.notebook.objects[0].text, "A newer manual edit")
    }
    func testGraphUpdatesPreserveCustomControlsAndTriangleUpdatesRecomputeThirdAngle() throws {
        let graph = CanvasObject(kind: "graph", text: "a*x^2", properties: ["a": 2], propertySpecs: [ObjectPropertySpec(key: "a", label: "Curvature")])
        let triangle = CanvasObject(properties: ["angleA": 60, "angleB": 60, "angleC": 60], shape: "triangle")
        let focus = RealtimeCanvasFocus(notebook: Notebook(objects: [graph, triangle]), reference: CanvasRect(), selectedIDs: [])
        let result = try RealtimeCanvasEdits.response(arguments: ["operations": [
            ["action": "update", "id": graph.id.uuidString, "color": "#AABBCC"],
            ["action": "update", "id": triangle.id.uuidString, "propertiesJSON": "{\"angleA\":49,\"angleB\":52}"]]], focus: focus)
        XCTAssertEqual(result.operations[0].object?.propertySpecs, graph.propertySpecs)
        XCTAssertEqual(result.operations[1].object?.properties["angleC"], 79)
    }
    func testDirectGraphUsesParametersAndRejectsUnsupportedRelations() throws {
        let focus = RealtimeCanvasFocus(notebook: Notebook(), reference: CanvasRect(), selectedIDs: [])
        let result = try RealtimeCanvasEdits.response(arguments: ["operations": [["action": "add", "kind": "graph", "text": "a*x^2+b*x+c", "propertiesJSON": "{\"a\":2,\"b\":3,\"c\":4}"]]], focus: focus)
        let object = try XCTUnwrap(result.operations.first?.object)
        let graph = GraphPlot(formula: object.text, properties: object.properties)
        XCTAssertNil(graph.error); XCTAssertEqual(graph.value(x: 2), 18, accuracy: 0.0001)
        XCTAssertThrowsError(try RealtimeCanvasEdits.response(arguments: ["operations": [["action": "add", "kind": "graph", "text": "x^2+y^2=9"]]], focus: focus))
    }
    func testToolContinuationCanRefineCreatedObjectWithoutMovingNewFocus() throws {
        let (store, library) = environment(), session = RealtimeCanvasSession()
        let agent = ConnectionClient(), voice = RealtimeVoice()
        store.reference = CanvasRect(x: 100, y: 200)
        _ = session.speechStarted(store: store, library: library); session.responseCreated("create")
        store.reference = CanvasRect(x: 900, y: 700)
        _ = session.focus(store: store, library: library)
        let newerID = session.current?.id
        let created = session.perform(name: "edit_canvas", arguments: ["operations": [["action": "add", "kind": "shape", "shape": "circle"]]], responseID: "create", store: store, library: library, agent: agent, voice: voice)
        XCTAssertEqual(created["status"] as? String, "applied")
        let objectID = try XCTUnwrap(store.notebook.objects.first?.id)
        session.responseCreated("continuation")
        let updated = session.perform(name: "edit_canvas", arguments: ["operations": [["action": "update", "id": objectID.uuidString, "color": "green"]]], responseID: "continuation", store: store, library: library, agent: agent, voice: voice)
        XCTAssertEqual(updated["status"] as? String, "applied")
        XCTAssertEqual(store.notebook.objects.first?.color, "#16A34A")
        XCTAssertEqual(store.notebook.objects.first?.x, 100)
        XCTAssertEqual(session.current?.id, newerID); XCTAssertEqual(session.current?.reference.x, 900)
    }
}
