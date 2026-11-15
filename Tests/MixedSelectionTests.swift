import XCTest
import UIKit
import PencilKit
@testable import CanvasStudio

@MainActor
final class MixedSelectionTests: XCTestCase {
    private func makeStore() throws -> NotebookStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MixedSelectionTests-\(UUID())")
        let store = NotebookStore(storageURL: url, loadSaved: false)
        store.newNotebook(title: "Mixed selections")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return store
    }
    private func stroke(_ points: [CGPoint], color: UIColor = .blue) -> PKStroke {
        let path = points.enumerated().map {
            PKStrokePoint(location: $0.element, timeOffset: Double($0.offset) * 0.12,
                          size: CGSize(width: 5 + $0.offset, height: 5 + $0.offset), opacity: 0.85,
                          force: 0.4 + Double($0.offset) * 0.1, azimuth: 0.5, altitude: 1.1)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: path, creationDate: Date(timeIntervalSince1970: 12345)))
    }
    private func setupMixed(_ store: NotebookStore) -> CanvasObject {
        let object = CanvasObject(kind: "shape", x: -80, y: -60, width: 80, height: 70, shape: "circle")
        store.notebook.objects = [object]
        store.notebook.drawingData = PKDrawing(strokes: [
            stroke([CGPoint(x: -150, y: -100), CGPoint(x: -30, y: -20)]),
            stroke([CGPoint(x: 300, y: 300), CGPoint(x: 420, y: 380)], color: .red)
        ]).dataRepresentation()
        store.setSelection(objects: [object.id], strokes: [0])
        return object
    }
    private func assertStroke(_ actual: PKStroke, matches original: PKStroke, delta: CGPoint = .zero, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.path.count, original.path.count, file: file, line: line)
        XCTAssertEqual(actual.ink.color, original.ink.color, file: file, line: line)
        XCTAssertEqual(actual.path.creationDate, original.path.creationDate, file: file, line: line)
        for index in original.path.indices {
            let a = actual.path[index], b = original.path[index]
            let point = a.location.applying(actual.transform), expected = b.location.applying(original.transform)
            XCTAssertEqual(point.x, expected.x + delta.x, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(point.y, expected.y + delta.y, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(a.force, b.force, file: file, line: line)
            XCTAssertEqual(a.size, b.size, file: file, line: line)
            XCTAssertEqual(a.altitude, b.altitude, file: file, line: line)
        }
    }

    func testPolygonLassoSelectsInkAndObjectsWithoutGrabbingContainingPage() throws {
        let store = try makeStore()
        let object = setupMixed(store)
        let page = CanvasObject(kind: "frame", x: -500, y: -500, width: 1400, height: 1400, properties: ["paper": 1])
        store.notebook.objects.insert(page, at: 0)
        store.clearSelection(); store.tool = .lasso
        let host = CanvasHostView(store: store)
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 800); host.layoutIfNeeded()
        let polygon = [CGPoint(x: -200, y: -150), CGPoint(x: 30, y: -150), CGPoint(x: 30, y: 40), CGPoint(x: -200, y: 40)]
        host.beginSelectionDrag(at: polygon[0])
        for point in polygon.dropFirst() { host.updateSelectionDrag(to: point) }
        host.updateSelectionDrag(to: polygon[0]); host.finishSelectionDrag(cancelled: false)
        XCTAssertEqual(store.selectedIDs, [object.id])
        XCTAssertEqual(store.selectedStrokeIndices, [0])
        XCTAssertTrue(store.hasSelection)
        XCTAssertFalse(host.ink.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(host.ink.allowsInkEditingMenu)
        XCTAssertFalse(store.canUndo, "Selecting must not change document history")
    }

    func testSparseLongStrokeCrossesLassoWithBoundedSampling() {
        let line = stroke([CGPoint(x: -1_000_000, y: 0), CGPoint(x: 1_000_000, y: 0)])
        let polygon = [CGPoint(x: -10, y: -10), CGPoint(x: 10, y: -10), CGPoint(x: 10, y: 10), CGPoint(x: -10, y: 10)]
        XCTAssertEqual(CanvasLasso.selectedStrokes(in: PKDrawing(strokes: [line]), polygon: polygon), [0])
        XCTAssertEqual(CanvasLasso.stroke(at: .zero, in: PKDrawing(strokes: [line]), tolerance: 10), 0)
    }

    func testMixedMoveIsOneUndoStepAndPreservesPressureAndUnselectedInk() throws {
        let store = try makeStore()
        let object = setupMixed(store)
        let before = store.notebook
        let snapshot = store.selectionSnapshot()
        store.checkpoint()
        XCTAssertTrue(store.moveSelection(from: snapshot, by: CGPoint(x: 30, y: -20)))
        XCTAssertTrue(store.moveSelection(from: snapshot, by: CGPoint(x: 80, y: 50)))
        store.commit()
        XCTAssertEqual(store.notebook.objects[0].x, object.x + 80)
        XCTAssertEqual(store.notebook.objects[0].y, object.y + 50)
        assertStroke(store.worldInk.strokes[0], matches: snapshot.drawing.strokes[0], delta: CGPoint(x: 80, y: 50))
        assertStroke(store.worldInk.strokes[1], matches: snapshot.drawing.strokes[1])
        store.undo()
        XCTAssertEqual(store.notebook.objects, before.objects)
        XCTAssertEqual(store.notebook.drawingData, before.drawingData)
        XCTAssertFalse(store.canUndo)
        store.redo()
        XCTAssertEqual(store.notebook.objects[0].x, object.x + 80)
        XCTAssertEqual(store.worldInk.strokes.count, 2)
    }

    func testToolSwitchCancelsMixedMoveAndPreservesOriginalSelection() throws {
        let store = try makeStore()
        let object = setupMixed(store)
        let original = store.selectionSnapshot()
        store.tool = .lasso
        let host = CanvasHostView(store: store)
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 800); host.layoutIfNeeded()
        host.beginSelectionDrag(at: CGPoint(x: -60, y: -40))
        host.updateSelectionDrag(to: CGPoint(x: 20, y: 10))
        store.tool = .hand; host.synchronize()
        XCTAssertEqual(store.notebook.objects, [object])
        assertStroke(store.worldInk.strokes[0], matches: original.drawing.strokes[0])
        XCTAssertEqual(store.selectedIDs, [object.id]); XCTAssertEqual(store.selectedStrokeIndices, [0])
        XCTAssertFalse(store.canUndo)
    }

    func testMixedCopyDuplicatePasteDeleteAndUndoPreserveRelativeLayout() throws {
        let store = try makeStore()
        let object = setupMixed(store)
        let original = store.selectionSnapshot()
        let oldClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = oldClipboard }
        store.copySelection()
        XCTAssertFalse(store.canUndo)
        store.duplicateSelection()
        XCTAssertEqual(store.notebook.objects.count, 2); XCTAssertEqual(store.worldInk.strokes.count, 3)
        XCTAssertNotEqual(store.notebook.objects[1].id, object.id)
        XCTAssertEqual(store.notebook.objects[1].x, object.x + 28, accuracy: 0.001)
        assertStroke(store.worldInk.strokes[2], matches: original.drawing.strokes[0], delta: CGPoint(x: 28, y: 28))
        store.undo()
        store.viewport = CanvasRect(x: -900, y: -800, width: 1000, height: 800)
        store.paste()
        XCTAssertEqual(store.notebook.objects.count, 2); XCTAssertEqual(store.worldInk.strokes.count, 3)
        XCTAssertEqual(store.selectedStrokeIndices, [2]); XCTAssertEqual(store.selectedIDs.count, 1)
        let pasted = store.notebook.objects[1]
        let delta = CGPoint(x: pasted.x - object.x, y: pasted.y - object.y)
        assertStroke(store.worldInk.strokes[2], matches: original.drawing.strokes[0], delta: delta)
        store.deleteSelection()
        XCTAssertEqual(store.notebook.objects, [object]); XCTAssertEqual(store.worldInk.strokes.count, 2)
        store.undo()
        XCTAssertEqual(store.notebook.objects.count, 2); XCTAssertEqual(store.worldInk.strokes.count, 3)
        store.undo()
        XCTAssertEqual(store.notebook.objects, [object]); XCTAssertEqual(store.worldInk.strokes.count, 2)
        assertStroke(store.worldInk.strokes[0], matches: original.drawing.strokes[0])
    }

    func testInvalidMixedPasteIsAtomicAndKeepsSelectionAndHistory() throws {
        let store = try makeStore()
        _ = setupMixed(store)
        let before = store.notebook, ids = store.selectedIDs, strokes = store.selectedStrokeIndices
        var invalid = try XCTUnwrap(store.selectionPayload())
        invalid.objects[0].width = -1
        XCTAssertFalse(store.pasteSelection(invalid, at: .zero))
        invalid = try XCTUnwrap(store.selectionPayload())
        invalid.drawingData = Data("invalid ink".utf8)
        XCTAssertFalse(store.pasteSelection(invalid, at: .zero))
        invalid = try XCTUnwrap(store.selectionPayload())
        invalid.drawingData = PKDrawing(strokes: [stroke([CGPoint(x: 20_000_000, y: 0), CGPoint(x: 20_000_100, y: 40)])]).dataRepresentation()
        XCTAssertFalse(store.pasteSelection(invalid, at: .zero))
        XCTAssertEqual(store.notebook, before); XCTAssertEqual(store.selectedIDs, ids); XCTAssertEqual(store.selectedStrokeIndices, strokes)
        XCTAssertFalse(store.canUndo)
    }

    func testExternalInkChangeInvalidatesDragAndCancellationNeverResurrectsOldInk() throws {
        let store = try makeStore()
        let object = setupMixed(store)
        let snapshot = store.selectionSnapshot()
        store.checkpoint(); XCTAssertTrue(store.moveSelection(from: snapshot, by: CGPoint(x: 40, y: 30)))
        let incoming = stroke([CGPoint(x: 800, y: 700), CGPoint(x: 900, y: 750)], color: .green)
        let external = PKDrawing(strokes: store.worldInk.strokes + [incoming]).dataRepresentation()
        store.setDrawing(external)
        XCTAssertTrue(store.selectedStrokeIndices.isEmpty)
        XCTAssertFalse(store.moveSelection(from: snapshot, by: CGPoint(x: 90, y: 90)))
        XCTAssertFalse(store.cancelSelectionMove(snapshot)); store.commit()
        XCTAssertEqual(store.notebook.drawingData, external)
        XCTAssertEqual(store.notebook.objects, [object])
    }

    func testExternalObjectEditBeforeFirstMoveIsPreserved() throws {
        let store = try makeStore()
        let object = setupMixed(store)
        let snapshot = store.selectionSnapshot()
        var edited = object; edited.color = "#16A34A"; edited.title = "Changed by completed task"
        store.update(edited)
        XCTAssertFalse(store.moveSelection(from: snapshot, by: CGPoint(x: 50, y: 50)))
        store.cancelSelectionMove(snapshot)
        XCTAssertEqual(store.notebook.objects, [edited])
        assertStroke(store.worldInk.strokes[0], matches: snapshot.drawing.strokes[0])
    }

    func testLegacyObjectsAndExternalTextStillPaste() throws {
        let store = try makeStore()
        let oldClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = oldClipboard }
        let old = CanvasObject(title: "Legacy object", x: -200, y: -100)
        UIPasteboard.general.setData(try JSONEncoder().encode([old]), forPasteboardType: "org.madhacks.canvasstudio.objects")
        store.paste()
        XCTAssertEqual(store.notebook.objects.count, 1); XCTAssertNotEqual(store.notebook.objects[0].id, old.id)
        UIPasteboard.general.string = "A copied lecture note"
        store.paste()
        XCTAssertEqual(store.notebook.objects.count, 2)
        XCTAssertEqual(store.notebook.objects.last?.text, "A copied lecture note")
    }

    func testSelectedPageMovesFromBlankInteriorButChildrenAndInkKeepPriority() throws {
        let store = try makeStore()
        let page = CanvasObject(kind: "frame", x: 0, y: 0, width: 600, height: 800, properties: ["paper": 1])
        let child = CanvasObject(kind: "latex", x: 200, y: 200, width: 100, height: 100, text: "x^2")
        store.notebook.objects = [page, child]
        store.notebook.drawingData = PKDrawing(strokes: [stroke([CGPoint(x: 300, y: 500), CGPoint(x: 400, y: 500)])]).dataRepresentation()
        store.tool = .select; store.setSelection(objects: [page.id], strokes: [])
        let host = CanvasHostView(store: store)
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 800); host.layoutIfNeeded()
        host.beginSelectionDrag(at: CGPoint(x: 100, y: 400))
        host.updateSelectionDrag(to: CGPoint(x: 170, y: 440)); host.finishSelectionDrag(cancelled: false)
        XCTAssertEqual(store.notebook.objects[0].x, 70); XCTAssertEqual(store.notebook.objects[0].y, 40)
        XCTAssertEqual(store.notebook.objects[1], child)
        store.undo(); host.synchronize()
        store.setSelection(objects: [page.id], strokes: [])
        host.beginSelectionDrag(at: CGPoint(x: 240, y: 240))
        host.updateSelectionDrag(to: CGPoint(x: 280, y: 260)); host.finishSelectionDrag(cancelled: false)
        XCTAssertEqual(store.notebook.objects[0], page)
        XCTAssertEqual(store.notebook.objects[1].x, 240); XCTAssertEqual(store.selectedIDs, [child.id])
        store.undo(); host.synchronize()
        store.setSelection(objects: [page.id], strokes: [])
        host.beginSelectionDrag(at: CGPoint(x: 350, y: 500))
        host.updateSelectionDrag(to: CGPoint(x: 380, y: 530)); host.finishSelectionDrag(cancelled: false)
        XCTAssertEqual(store.notebook.objects, [page, child]); XCTAssertEqual(store.selectedStrokeIndices, [0])
        XCTAssertEqual(store.worldInk.strokes[0].path[0].location.applying(store.worldInk.strokes[0].transform).y, 530, accuracy: 0.001)
        store.undo(); host.synchronize(); store.clearSelection()
        host.beginSelectionDrag(at: CGPoint(x: 100, y: 400))
        host.updateSelectionDrag(to: CGPoint(x: 160, y: 430)); host.finishSelectionDrag(cancelled: false)
        XCTAssertEqual(store.notebook.objects, [page, child])
        XCTAssertTrue(store.selectedIDs.isEmpty, "An unselected background page must not steal blank-area selection")
    }
}
