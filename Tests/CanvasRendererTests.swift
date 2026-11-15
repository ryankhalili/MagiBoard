import XCTest
import UIKit
import PencilKit
import PDFKit
@testable import CanvasStudio

@MainActor
final class CanvasRendererTests: XCTestCase {
    private func store() throws -> NotebookStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanvasRendererTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let result = NotebookStore(storageURL: directory, loadSaved: false)
        result.newNotebook(title: "Renderer checks")
        return result
    }
    private func angle(_ vertex: CGPoint, _ first: CGPoint, _ second: CGPoint) -> Double {
        let a = CGPoint(x: first.x - vertex.x, y: first.y - vertex.y)
        let b = CGPoint(x: second.x - vertex.x, y: second.y - vertex.y)
        let cosine = (a.x * b.x + a.y * b.y) / (hypot(a.x, a.y) * hypot(b.x, b.y))
        return acos(Double(min(1, max(-1, cosine)))) * 180 / .pi
    }
    func testTriangleKeepsRequestedAnglesAcrossAspectRatios() {
        for (a, b) in [(49.0, 52.0), (120.0, 29.0), (1.0, 89.0), (35.5, 70.25)] {
            for area in [CGRect(x: -500, y: -200, width: 270, height: 190), CGRect(x: 4, y: 6, width: 90, height: 500)] {
                let p = TriangleGeometry.vertices(in: area, angleA: a, angleB: b)
                XCTAssertEqual(angle(p[0], p[1], p[2]), a, accuracy: 0.00001)
                XCTAssertEqual(angle(p[1], p[0], p[2]), b, accuracy: 0.00001)
                XCTAssertEqual(angle(p[2], p[0], p[1]), 180 - a - b, accuracy: 0.00001)
                for point in p { XCTAssertTrue(area.insetBy(dx: -0.001, dy: -0.001).contains(point)) }
            }
        }
    }
    func testInitialFitReservesChromeInPortraitAndLandscape() throws {
        for size in [CGSize(width: 834, height: 1180), CGSize(width: 1194, height: 800)] {
            let store = try store()
            store.notebook = Notebook.welcome()
            let view = CanvasHostView(store: store)
            view.frame = CGRect(origin: .zero, size: size)
            view.setNeedsLayout(); view.layoutIfNeeded()
            let world = store.notebook.objects.map(\.rect).reduce(CGRect.null) { $0.union($1) }
            let z = view.ink.zoomScale, offset = view.worldContentOffset
            let visible = CGRect(x: world.minX * z - offset.x, y: world.minY * z - offset.y, width: world.width * z, height: world.height * z)
            XCTAssertLessThanOrEqual(z, 1)
            XCTAssertGreaterThanOrEqual(visible.minX, 69.9)
            XCTAssertLessThanOrEqual(visible.maxX, size.width - 69.9)
            XCTAssertGreaterThanOrEqual(visible.minY, 159.9)
            XCTAssertLessThanOrEqual(visible.maxY, size.height - 99.9)
        }
    }
    func testNativeRebasePreservesWorldDrawingCameraAndUndo() throws {
        let store = try store()
        store.checkpoint(); store.setDrawing(negativeDrawing().dataRepresentation()); store.commit()
        let view = CanvasHostView(store: store)
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutIfNeeded()
        let beforeWorld = view.worldDrawing.bounds
        let modelBefore = store.notebook.drawingData
        view.ink.setContentOffset(CGPoint(x: 2000, y: 2000), animated: false)
        let cameraBefore = view.worldContentOffset
        let originBefore = view.inkOrigin
        view.expandWorldIfNeeded()
        XCTAssertGreaterThan(view.inkOrigin.x, originBefore.x)
        XCTAssertGreaterThan(view.inkOrigin.y, originBefore.y)
        XCTAssertEqual(view.worldContentOffset.x, cameraBefore.x, accuracy: 0.001)
        XCTAssertEqual(view.worldContentOffset.y, cameraBefore.y, accuracy: 0.001)
        XCTAssertEqual(view.worldDrawing.bounds.minX, beforeWorld.minX, accuracy: 0.01)
        XCTAssertEqual(view.worldDrawing.bounds.minY, beforeWorld.minY, accuracy: 0.01)
        XCTAssertEqual(store.notebook.drawingData, modelBefore)
        store.undo(); view.synchronize()
        XCTAssertEqual(view.ink.drawing.strokes.count, 0)
        store.redo(); view.synchronize()
        XCTAssertEqual(view.worldDrawing.bounds.minX, beforeWorld.minX, accuracy: 0.01)
    }
    func testExistingPositiveWorldInkSurvivesBiasedNativeEditAndUndo() throws {
        let store = try store()
        let existing = negativeDrawing().transformed(using: CGAffineTransform(translationX: 500, y: 400))
        store.setDrawing(existing.dataRepresentation())
        let view = CanvasHostView(store: store)
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutIfNeeded()
        XCTAssertEqual(view.worldDrawing.bounds.minX, existing.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(view.worldDrawing.bounds.minY, existing.bounds.minY, accuracy: 0.01)
        let newWorldStroke = negativeDrawing().transformed(using: CGAffineTransform(translationX: -300, y: 500))
        let expected = PKDrawing(strokes: existing.strokes + newWorldStroke.strokes)
        store.checkpoint()
        view.ink.drawing = expected.transformed(using: CGAffineTransform(translationX: view.inkOrigin.x, y: view.inkOrigin.y))
        view.canvasViewDrawingDidChange(view.ink)
        store.commit()
        let saved = try PKDrawing(data: store.notebook.drawingData)
        XCTAssertEqual(saved.strokes.count, 2)
        XCTAssertEqual(saved.bounds.minX, expected.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(saved.bounds.maxX, expected.bounds.maxX, accuracy: 0.01)
        let preserved = saved.strokes[0]
        XCTAssertEqual(preserved.path.first!.location.applying(preserved.transform).x, 400, accuracy: 0.01)
        XCTAssertEqual(preserved.path.first!.location.applying(preserved.transform).y, 300, accuracy: 0.01)
        store.undo(); view.synchronize()
        XCTAssertEqual(view.worldDrawing.strokes.count, 1)
        XCTAssertEqual(view.worldDrawing.bounds.minX, existing.bounds.minX, accuracy: 0.01)
        store.redo(); view.synchronize()
        XCTAssertEqual(view.worldDrawing.strokes.count, 2)
        XCTAssertEqual(view.worldDrawing.bounds.minX, expected.bounds.minX, accuracy: 0.01)
    }
    func testSafePlotParserAndOperatorPrecedence() {
        let cases: [(String, Double, Double)] = [("sin(x)", .pi / 2, 1), ("x^2", 3, 9), ("2x+1", 3, 7), ("2(x+1)", 3, 8), ("-2^2", 0, -4), ("2^3^2", 0, 512), ("sqrt(x)", 9, 3), ("exp(ln(x))", 3, 3)]
        for (expression, x, expected) in cases { XCTAssertEqual(PlotExpression(expression).evaluate(x: x), expected, accuracy: 0.000001) }
        for input in ["fetch(x)", "sin(", "unknown", String(repeating: "(", count: 40) + "x"] {
            XCTAssertTrue(PlotExpression(input).evaluate(x: 1).isNaN)
        }
    }
    private func negativeDrawing() -> PKDrawing {
        let points = [CGPoint(x: -100, y: -100), CGPoint(x: -50, y: -80)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: TimeInterval(index) * 0.1, size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }
    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(source.cropping(to: CGRect(x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    func testNegativeOriginCropIncludesImageAndNativeInk() throws {
        let store = try store()
        let red = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        store.add(CanvasObject(kind: "image", x: -240, y: -180, width: 100, height: 100, imageData: try XCTUnwrap(red.pngData())))
        store.setDrawing(negativeDrawing().dataRepresentation())
        let crop = CGRect(x: -250, y: -200, width: 400, height: 300)
        let image = try XCTUnwrap(CanvasExporter.snapshot(store: store, rect: crop))
        XCTAssertEqual(image.size.width, 400, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 300, accuracy: 0.01)
        let redPixel = try pixel(image, at: CGPoint(x: 30, y: 40))
        XCTAssertGreaterThan(redPixel[0], 220); XCTAssertLessThan(redPixel[1], 40); XCTAssertLessThan(redPixel[2], 40)
        let inkPixel = try pixel(image, at: CGPoint(x: 175, y: 110))
        XCTAssertLessThan(inkPixel[0], 70); XCTAssertLessThan(inkPixel[1], 70); XCTAssertLessThan(inkPixel[2], 70)
        let background = try pixel(image, at: CGPoint(x: 350, y: 250))
        XCTAssertGreaterThan(background[0], 240)
        store.reference = CanvasRect(crop)
        let pdfURL = try XCTUnwrap(CanvasExporter.export(store: store, asPDF: true))
        addTeardownBlock { try? FileManager.default.removeItem(at: pdfURL) }
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 400, height: 300))
    }
    func testCameraAndUndoKeepPencilCoordinates() throws {
        let store = try store()
        let view = CanvasHostView(store: store)
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutIfNeeded()
        store.checkpoint(); store.setDrawing(negativeDrawing().dataRepresentation()); store.commit()
        view.synchronize()
        let original = view.ink.drawing.dataRepresentation()
        view.ink.setZoomScale(1.8, animated: false)
        view.ink.setContentOffset(CGPoint(x: view.inkOrigin.x * view.ink.zoomScale - 420, y: view.inkOrigin.y * view.ink.zoomScale - 300), animated: false)
        XCTAssertEqual(view.ink.drawing.dataRepresentation(), original)
        XCTAssertLessThan(view.worldDrawing.bounds.minX, 0)
        XCTAssertGreaterThan(view.ink.drawing.bounds.minX, 0)
        store.undo(); view.synchronize()
        XCTAssertEqual(view.ink.drawing.strokes.count, 0)
        store.redo(); view.synchronize()
        XCTAssertEqual(view.ink.drawing.strokes.count, 1)
        let worldStroke = view.worldDrawing.strokes[0]
        XCTAssertEqual(worldStroke.path.first!.location.applying(worldStroke.transform).x, -100, accuracy: 0.001)
        store.tool = .select; view.synchronize()
        XCTAssertFalse(view.ink.drawingGestureRecognizer.isEnabled)
        store.tool = .magic; view.synchronize()
        XCTAssertFalse(view.ink.drawingGestureRecognizer.isEnabled)
        store.tool = .pen; view.synchronize()
        XCTAssertTrue(view.ink.drawingGestureRecognizer.isEnabled)
        XCTAssertEqual(view.ink.drawingPolicy, .pencilOnly)
    }
}
