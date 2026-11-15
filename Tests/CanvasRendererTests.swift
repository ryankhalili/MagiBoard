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

    private func contour(_ vertices: [CGPoint], scale: CGFloat = 1, rotation: CGFloat = 0,
                         start: Int = 0, reverse: Bool = false, noise: CGFloat = 0) -> [CGPoint] {
        var samples: [CGPoint] = []
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            // Unequal sampling density models speed changes and pauses at corners.
            let count = [19, 37, 29, 43][i % 4]
            for n in 0..<count {
                let t = CGFloat(n) / CGFloat(count)
                samples.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if reverse { samples.reverse() }
        let split = start % samples.count
        samples = Array(samples[split...]) + Array(samples[..<split])
        samples = samples.enumerated().map { index, point in
            let x = point.x + sin(CGFloat(index) * 1.7) * noise
            let y = point.y + cos(CGFloat(index) * 2.3) * noise
            return CGPoint(x: (x * cos(rotation) - y * sin(rotation)) * scale - 240,
                           y: (x * sin(rotation) + y * cos(rotation)) * scale + 130)
        }
        return samples + [samples[0]]
    }
    private func circlePoints(scale: CGFloat = 1, start: CGFloat = 0, reverse: Bool = false, turns: CGFloat = 1) -> [CGPoint] {
        (0...180).map { i in
            let t = pow(CGFloat(i) / 180, 1.3)
            let a = start + t * 2 * .pi * turns * (reverse ? -1 : 1)
            let radius = 100 + sin(CGFloat(i) * 1.8) * 1.2
            return CGPoint(x: -180 + cos(a) * radius * scale, y: 230 + sin(a) * radius * scale)
        }
    }
    private func stroke(_ points: [CGPoint], createdAt: Date = Date(), color: UIColor = .blue, seed: UInt32 = 123) -> PKStroke {
        let controls = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: controls, creationDate: createdAt), randomSeed: seed)
    }
    private func putDrawing(_ strokes: [PKStroke], in view: CanvasHostView) {
        view.ink.drawing = PKDrawing(strokes: strokes).transformed(using: CGAffineTransform(translationX: view.inkOrigin.x, y: view.inkOrigin.y))
        view.canvasViewDrawingDidChange(view.ink)
    }
    private func recognizingCanvas() throws -> (NotebookStore, CanvasHostView) {
        let store = try store()
        store.settings.recognizeShapes = true; store.tool = .pen; store.lineWidth = 3
        let view = CanvasHostView(store: store)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800); view.layoutIfNeeded()
        return (store, view)
    }
    func testRecognizesNoisyCirclesAcrossScaleStartAndWinding() throws {
        for scale: CGFloat in [0.25, 1, 3] {
            for start: CGFloat in [0, 0.7, 2.4] {
                for reverse in [false, true] {
                    let result = try XCTUnwrap(StrokeShapeRecognizer.recognize(circlePoints(scale: scale, start: start, reverse: reverse)))
                    XCTAssertEqual(result.kind, "circle")
                    XCTAssertEqual(result.bounds.midX, -180, accuracy: 3 * scale)
                    XCTAssertEqual(result.bounds.midY, 230, accuracy: 3 * scale)
                    XCTAssertEqual(result.bounds.width, result.bounds.height, accuracy: 0.001)
                }
            }
        }
    }
    func testRecognizesRotatedSquaresAndRectanglesWithoutChangingOrientation() throws {
        for width: CGFloat in [200, 310] {
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: width, y: 200), CGPoint(x: 0, y: 200)]
            for scale: CGFloat in [0.25, 1, 2] {
                for rotation: CGFloat in [0, 0.35, 0.79, 2.4] {
                    for reverse in [false, true] {
                        let result = try XCTUnwrap(StrokeShapeRecognizer.recognize(contour(corners, scale: scale, rotation: rotation, start: 31, reverse: reverse, noise: 1.5)))
                        XCTAssertEqual(result.kind, "rectangle")
                        XCTAssertEqual(result.title, width == 200 ? "Square" : "Rectangle")
                        XCTAssertEqual(result.vertices.count, 4)
                        for i in 0..<4 {
                            XCTAssertEqual(angle(result.vertices[i], result.vertices[(i + 3) % 4], result.vertices[(i + 1) % 4]), 90, accuracy: 0.001)
                        }
                        let actual = atan2(result.vertices[1].y - result.vertices[0].y, result.vertices[1].x - result.vertices[0].x)
                        XCTAssertLessThan(abs(sin((actual - rotation) * 2)), 0.08, "Preserve the original rectangle axes")
                    }
                }
            }
        }
    }
    func testRecognizesTrianglesFromEveryEdgeAndWindingWithRealVertices() throws {
        let vertices = [CGPoint(x: 0, y: 0), CGPoint(x: 240, y: 35), CGPoint(x: 60, y: 190)]
        for scale: CGFloat in [0.3, 1, 2] {
            for start in [0, 12, 33, 70] {
                for reverse in [false, true] {
                    let result = try XCTUnwrap(StrokeShapeRecognizer.recognize(contour(vertices, scale: scale, rotation: 0.65, start: start, reverse: reverse, noise: 1)))
                    XCTAssertEqual(result.kind, "triangle")
                    XCTAssertEqual(result.vertices.count, 3)
                    for original in vertices {
                        let expected = CGPoint(x: (original.x * cos(0.65) - original.y * sin(0.65)) * scale - 240,
                                               y: (original.x * sin(0.65) + original.y * cos(0.65)) * scale + 130)
                        XCTAssertLessThan(result.vertices.map { hypot($0.x - expected.x, $0.y - expected.y) }.min()!, 8 * scale,
                                          "Keep the user's corners rather than replacing the triangle with an upright template")
                    }
                    let object = result.object(color: .blue, width: 3)
                    XCTAssertEqual(object.shape, "polygon", "A fitted outline must not acquire unrelated canonical angle controls")
                    XCTAssertNil(object.properties["angleA"])
                    let rendered = try XCTUnwrap(RecognizedPolygonGeometry.vertices(for: object))
                    for (a, b) in zip(rendered, result.vertices) {
                        XCTAssertEqual(a.x, b.x, accuracy: 0.0001); XCTAssertEqual(a.y, b.y, accuracy: 0.0001)
                    }
                }
            }
        }
    }
    func testRecognitionRejectsOpenContoursCrossingsAndRepeatedLoops() {
        XCTAssertNil(StrokeShapeRecognizer.recognize(circlePoints(turns: 0.75)))
        XCTAssertNil(StrokeShapeRecognizer.recognize(circlePoints(turns: 2)))
        let square = contour([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0), CGPoint(x: 200, y: 200), CGPoint(x: 0, y: 200)])
        XCTAssertNil(StrokeShapeRecognizer.recognize(Array(square.dropLast(35))))
        let crossing = contour([CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 200), CGPoint(x: 200, y: 0), CGPoint(x: 0, y: 200)])
        XCTAssertNil(StrokeShapeRecognizer.recognize(crossing))
    }
    func testDelayedStrokeCommitRecognizesImmediatelyAndUndoRestoresRawInk() throws {
        let (store, view) = try recognizingCanvas()
        view.canvasViewDidBeginUsingTool(view.ink)
        let raw = stroke(circlePoints(), color: .blue)
        view.canvasViewDidEndUsingTool(view.ink)
        XCTAssertTrue(store.notebook.objects.isEmpty)
        store.colorHex = "#EF4444"; store.lineWidth = 19
        putDrawing([raw], in: view)
        XCTAssertEqual(store.notebook.objects.count, 1, "No second touch is needed after PencilKit commits")
        XCTAssertTrue(view.worldDrawing.strokes.isEmpty)
        XCTAssertEqual(store.notebook.objects[0].color, "#0000FFFF")
        XCTAssertEqual(store.notebook.objects[0].properties["strokeWidth"], 3)
        XCTAssertEqual(store.tool, .pen); XCTAssertTrue(store.selectedIDs.isEmpty)
        store.undo(); view.synchronize()
        XCTAssertTrue(store.notebook.objects.isEmpty)
        XCTAssertEqual(view.worldDrawing.strokes.map(ShapeStrokeIdentity.init), [ShapeStrokeIdentity(raw)])
        store.redo(); view.synchronize()
        XCTAssertEqual(store.notebook.objects.count, 1); XCTAssertTrue(view.worldDrawing.strokes.isEmpty)
    }
    func testCommittedStrokeWaitsForLiftAndQuickNextStrokeSurvives() throws {
        let (store, view) = try recognizingCanvas()
        view.canvasViewDidBeginUsingTool(view.ink)
        let shape = stroke(circlePoints(), seed: 11)
        putDrawing([shape], in: view)
        XCTAssertTrue(store.notebook.objects.isEmpty, "Do not convert an active stroke")
        view.canvasViewDidEndUsingTool(view.ink)
        XCTAssertEqual(store.notebook.objects.count, 1, "Drawing-before-end callback order also works")

        store.undo(); view.synchronize()
        store.undo(); view.synchronize()
        view.canvasViewDidBeginUsingTool(view.ink)
        let delayed = stroke(circlePoints(), seed: 22)
        view.canvasViewDidEndUsingTool(view.ink)
        view.canvasViewDidBeginUsingTool(view.ink)
        let following = stroke([CGPoint(x: 250, y: 100), CGPoint(x: 310, y: 145), CGPoint(x: 360, y: 160)], seed: 33)
        putDrawing([delayed], in: view)
        XCTAssertTrue(store.notebook.objects.isEmpty, "Do not replace drawing while a later stroke is active")
        putDrawing([delayed, following], in: view)
        view.canvasViewDidEndUsingTool(view.ink)
        XCTAssertEqual(store.notebook.objects.count, 1)
        XCTAssertEqual(view.worldDrawing.strokes.map(ShapeStrokeIdentity.init), [ShapeStrokeIdentity(following)], "Remove the recognized stroke, never the last stroke")
        XCTAssertEqual(try PKDrawing(data: store.notebook.drawingData).strokes.map(ShapeStrokeIdentity.init), [ShapeStrokeIdentity(following)])
    }
    func testRenderingCallbackAndObjectLimitNeverDiscardRawStroke() throws {
        let (store, view) = try recognizingCanvas()
        store.notebook.objects = (0..<2000).map { _ in CanvasObject() }; view.synchronize()
        view.canvasViewDidBeginUsingTool(view.ink)
        let raw = stroke(circlePoints(), seed: 44)
        view.canvasViewDidEndUsingTool(view.ink)
        view.ink.drawing = PKDrawing(strokes: [raw]).transformed(using: CGAffineTransform(translationX: view.inkOrigin.x, y: view.inkOrigin.y))
        view.canvasViewDidFinishRendering(view.ink)
        XCTAssertEqual(store.notebook.objects.count, 2000)
        XCTAssertEqual(view.worldDrawing.strokes.map(ShapeStrokeIdentity.init), [ShapeStrokeIdentity(raw)])
        XCTAssertEqual(try PKDrawing(data: store.notebook.drawingData).strokes.map(ShapeStrokeIdentity.init), [ShapeStrokeIdentity(raw)])
        XCTAssertTrue(store.status.hasPrefix("Kept your ink"))
    }
    func testCancelledSessionCannotClaimFollowingStrokeOrSurviveExternalDrawingReplace() throws {
        let (store, view) = try recognizingCanvas()
        view.canvasViewDidBeginUsingTool(view.ink)
        view.canvasViewDidEndUsingTool(view.ink) // Cancelled interaction, no committed path.
        store.lineWidth = 8; view.synchronize()
        view.canvasViewDidBeginUsingTool(view.ink)
        let raw = stroke(circlePoints(), seed: 55)
        view.canvasViewDidEndUsingTool(view.ink)
        putDrawing([raw], in: view)
        XCTAssertEqual(store.notebook.objects.count, 1)
        XCTAssertEqual(store.notebook.objects[0].properties["strokeWidth"], 8, "Only the actual producing session owns this stroke")

        view.canvasViewDidBeginUsingTool(view.ink)
        let late = stroke(circlePoints(), seed: 66)
        view.canvasViewDidEndUsingTool(view.ink)
        let external = stroke([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 40)], seed: 77)
        store.setDrawing(PKDrawing(strokes: [external]).dataRepresentation()); view.synchronize()
        putDrawing([external, late], in: view)
        XCTAssertEqual(store.notebook.objects.count, 1, "Undo/import/external replacement must invalidate queued recognition")
        XCTAssertEqual(view.worldDrawing.strokes.map(ShapeStrokeIdentity.init), [ShapeStrokeIdentity(external), ShapeStrokeIdentity(late)])
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
    func testPinchDefersNativeDrawingReplacementAndRebaseUntilZoomEnds() throws {
        let store = try store()
        store.setDrawing(negativeDrawing().dataRepresentation())
        let view = CanvasHostView(store: store)
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700); view.layoutIfNeeded()
        XCTAssertFalse(view.ink.bouncesZoom)
        let originalOrigin = view.inkOrigin
        let originalInk = view.ink.drawing.dataRepresentation()
        view.scrollViewWillBeginZooming(view.ink, with: nil)
        view.ink.setContentOffset(CGPoint(x: 100, y: 100), animated: false)
        let camera = view.worldContentOffset
        // A companion pan ending before the pinch must not replace the live surface.
        view.scrollViewDidEndDragging(view.ink, willDecelerate: false)
        XCTAssertEqual(view.inkOrigin, originalOrigin)
        XCTAssertEqual(view.ink.drawing.dataRepresentation(), originalInk)
        let replacement = negativeDrawing().transformed(using: CGAffineTransform(translationX: 800, y: 300))
        store.setDrawing(replacement.dataRepresentation())
        let modelData = store.notebook.drawingData
        view.synchronize()
        view.canvasViewDidFinishRendering(view.ink)
        view.canvasViewDrawingDidChange(view.ink)
        XCTAssertEqual(view.ink.drawing.dataRepresentation(), originalInk, "Defer external ink edits until PencilKit releases its zoom surface")
        XCTAssertEqual(store.notebook.drawingData, modelData, "A rendering callback must not overwrite an external edit")
        view.scrollViewDidEndZooming(view.ink, with: nil, atScale: view.ink.zoomScale)
        XCTAssertGreaterThan(view.inkOrigin.x, originalOrigin.x)
        XCTAssertEqual(view.worldContentOffset.x, camera.x, accuracy: 0.01)
        XCTAssertEqual(view.worldContentOffset.y, camera.y, accuracy: 0.01)
        XCTAssertEqual(view.worldDrawing.bounds.minX, replacement.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(view.worldDrawing.bounds.minY, replacement.bounds.minY, accuracy: 0.01)
        XCTAssertEqual(store.notebook.drawingData, modelData)
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
    func testInkSelectionFollowsMaskedStrokeSilhouetteAndLeavesEmptyBoundsClear() throws {
        let locations = [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 60), CGPoint(x: 100, y: 100)]
        let points: [PKStrokePoint] = locations.enumerated().map { index, point in
            let width = CGFloat(6 + index * 5)
            return PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                                 size: CGSize(width: width, height: width),
                                 opacity: 1, force: CGFloat(0.3) + CGFloat(index) * 0.3, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()),
                              transform: CGAffineTransform(translationX: 10, y: 0),
                              mask: UIBezierPath(rect: CGRect(x: 0, y: 0, width: 80, height: 160)))
        let drawing = PKDrawing(strokes: [stroke]), source = drawing.dataRepresentation()
        let highlight = InkSelectionHighlight(); highlight.setDrawing(drawing)
        let area = CGRect(x: 0, y: 0, width: 160, height: 160)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: area.size, format: format).image { output in
            highlight.draw(in: output.cgContext, visible: area, zoom: 1, displayScale: 1)
        }
        let ink = try pixel(image, at: CGPoint(x: 70, y: 60))
        XCTAssertGreaterThan(ink[2], ink[0] + 50, "Selected handwriting has a blue silhouette")
        XCTAssertGreaterThan(ink[3], 100)
        let gap = try pixel(image, at: CGPoint(x: 30, y: 70))
        XCTAssertEqual(gap[3], 0, "Do not fill or outline the handwriting's rectangular bounds")
        let erased = try pixel(image, at: CGPoint(x: 108, y: 98))
        XCTAssertEqual(erased[3], 0, "The selection must preserve PencilKit's erased mask")
        XCTAssertEqual(drawing.dataRepresentation(), source, "Highlighting never recolors the saved ink")
    }
    func testInkSelectionCachesSmallCameraChangesAndClearsWithoutStaleGlow() {
        let highlight = InkSelectionHighlight()
        highlight.setDrawing(negativeDrawing().transformed(using: CGAffineTransform(translationX: 150, y: 150)))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let area = CGRect(x: 0, y: 0, width: 300, height: 200)
        let renderer = UIGraphicsImageRenderer(size: area.size, format: format)
        _ = renderer.image { highlight.draw(in: $0.cgContext, visible: area, zoom: 1, displayScale: 1) }
        XCTAssertEqual(highlight.renderCount, 1)
        _ = renderer.image { highlight.draw(in: $0.cgContext, visible: area.offsetBy(dx: 8, dy: 3), zoom: 1.1, displayScale: 1) }
        XCTAssertEqual(highlight.renderCount, 1, "Reuse the selected-ink texture during ordinary pan and zoom")
        highlight.setDrawing(PKDrawing())
        let cleared = renderer.image { highlight.draw(in: $0.cgContext, visible: area, zoom: 1, displayScale: 1) }
        XCTAssertTrue(highlight.isEmpty)
        XCTAssertEqual(highlight.renderCount, 1)
        XCTAssertEqual(try pixel(cleared, at: CGPoint(x: 75, y: 60))[3], 0)
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

    func testToolSwitchCancelsObjectDragWithoutLeavingUndoOrCameraMotion() throws {
        let store = try store()
        let object = CanvasObject(x: -300, y: -200, width: 180, height: 140)
        store.notebook.objects = [object]
        store.tool = .select
        let view = CanvasHostView(store: store)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800); view.layoutIfNeeded()
        let camera = view.worldContentOffset
        view.beginSelectionDrag(at: CGPoint(x: -220, y: -130))
        view.updateSelectionDrag(to: CGPoint(x: -140, y: -80))
        XCTAssertEqual(store.notebook.objects[0].x, object.x + 80)
        store.tool = .magic; view.synchronize()
        XCTAssertEqual(store.notebook.objects, [object])
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertFalse(store.canUndo, "Cancelling a move must not create an undo entry")
        XCTAssertEqual(view.worldContentOffset.x, camera.x, accuracy: 0.001)
        XCTAssertEqual(view.worldContentOffset.y, camera.y, accuracy: 0.001)
        // A late callback from the cancelled recognizer cannot apply its old delta.
        view.updateSelectionDrag(to: CGPoint(x: 500, y: 500))
        view.finishSelectionDrag(cancelled: false)
        XCTAssertEqual(store.notebook.objects, [object])
    }

    func testMagicDragCancelsUsingOriginalToolAndOnlyCompletedGestureSubmits() throws {
        let store = try store()
        store.tool = .magic
        let previous = CanvasRect(x: -80, y: -120, width: 0, height: 0)
        store.reference = previous
        let view = CanvasHostView(store: store)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800); view.layoutIfNeeded()
        var submissions = 0
        view.onReference = { submissions += 1 }
        view.beginSelectionDrag(at: CGPoint(x: -100, y: -100))
        view.updateSelectionDrag(to: CGPoint(x: 200, y: 180))
        store.tool = .pen; view.synchronize()
        XCTAssertEqual(store.reference, previous)
        XCTAssertEqual(submissions, 0)
        XCTAssertFalse(store.canUndo)
        store.tool = .magic; view.synchronize()
        view.beginSelectionDrag(at: CGPoint(x: -100, y: -100))
        view.updateSelectionDrag(to: CGPoint(x: 200, y: 180))
        view.finishSelectionDrag(cancelled: false)
        view.finishSelectionDrag(cancelled: false)
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(store.reference, CanvasRect(x: -100, y: -100, width: 300, height: 280))
    }

    func testToolAndKeyboardLayoutChangesKeepWorldCameraAndScopeInkMenus() throws {
        let store = try store()
        let view = CanvasHostView(store: store)
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800); view.layoutIfNeeded()
        view.ink.setZoomScale(1.4, animated: false)
        view.ink.setContentOffset(CGPoint(x: view.inkOrigin.x * 1.4 - 800, y: view.inkOrigin.y * 1.4 - 600), animated: false)
        let camera = view.worldContentOffset
        for tool in CanvasTool.allCases {
            store.tool = tool; view.synchronize()
            XCTAssertFalse(view.ink.allowsInkEditingMenu, "Combined lasso uses the canvas clipboard bar rather than PencilKit's ink-only menu")
            if tool != .lasso { XCTAssertFalse(view.ink.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil)) }
            view.ink.scrollRectToVisible(CGRect(x: 0, y: 0, width: 300, height: 300), animated: false)
            view.frame.size.height = 500; view.setNeedsLayout(); view.layoutIfNeeded()
            view.frame.size.height = 800; view.setNeedsLayout(); view.layoutIfNeeded()
            XCTAssertEqual(view.ink.zoomScale, 1.4, accuracy: 0.001)
            XCTAssertEqual(view.worldContentOffset.x, camera.x, accuracy: 0.001)
            XCTAssertEqual(view.worldContentOffset.y, camera.y, accuracy: 0.001)
        }
    }

    func testWidgetHostBatchCreatesRealWorldObjectsAndIsOneUndoStep() throws {
        let store = try store()
        let source = CanvasObject(kind: "widget", title: "Coin", x: -200, y: -100, width: 110, height: 110,
                                  properties: ["value": 1, "speed": 2], code: "<button>Coin</button>")
        store.notebook.objects = [source]
        let created = CanvasObject(kind: "shape", x: -600, y: -400, width: 60, height: 60, shape: "circle")
        let request = WidgetHostRequest(requestID: "world-objects", operations: [
            WidgetHostOperation(type: .create, object: created),
            WidgetHostOperation(type: .duplicate, id: source.id, dx: 134, dy: 0),
            WidgetHostOperation(type: .update, id: source.id, patch: WidgetObjectPatch(properties: ["value": 5]))
        ])
        let result = try WidgetHostProtocol.apply(request, sourceID: source.id, store: store)
        XCTAssertEqual(store.notebook.objects.count, 3)
        XCTAssertEqual(result.objects.count, 3)
        XCTAssertNotEqual(result.ids[0], created.id)
        XCTAssertNotEqual(result.ids[1], source.id)
        XCTAssertEqual(store.notebook.objects[1].x, -600)
        XCTAssertEqual(store.notebook.objects[2].x, -66)
        XCTAssertEqual(store.notebook.objects[2].code, source.code)
        XCTAssertEqual(store.notebook.objects[0].properties, ["value": 5, "speed": 2])
        XCTAssertTrue(store.canUndo)
        store.undo()
        XCTAssertEqual(store.notebook.objects, [source])
        XCTAssertFalse(store.canUndo)
        store.redo()
        XCTAssertEqual(store.notebook.objects.count, 3)
    }

    func testWidgetProtocolRejectsInvalidBatchAtomicallyAndBoundsMutationRate() throws {
        let store = try store()
        let source = CanvasObject(kind: "widget", code: "<button>Coin</button>")
        store.notebook.objects = [source]
        let invalid = WidgetHostRequest(requestID: "invalid", operations: [
            WidgetHostOperation(type: .duplicate, id: source.id),
            WidgetHostOperation(type: .update, id: source.id, patch: WidgetObjectPatch(width: -10))
        ])
        XCTAssertThrowsError(try WidgetHostProtocol.apply(invalid, sourceID: source.id, store: store))
        XCTAssertEqual(store.notebook.objects, [source])
        XCTAssertFalse(store.canUndo)
        XCTAssertThrowsError(try WidgetHostProtocol.decode(["version": 1, "requestID": "unsupported", "operations": [["type": "delete", "id": source.id.uuidString]]]))
        XCTAssertThrowsError(try WidgetHostProtocol.decode(["version": 1, "requestID": "large", "operations": [["type": "create", "object": ["code": String(repeating: "x", count: 262_144)]]]]))
        let many = WidgetHostRequest(requestID: "too-many", operations: Array(repeating: WidgetHostOperation(type: .duplicate, id: source.id), count: 25))
        XCTAssertThrowsError(try WidgetHostProtocol.apply(many, sourceID: source.id, store: store))
        XCTAssertEqual(store.notebook.objects, [source])
        var budget = WidgetMutationBudget()
        for _ in 0..<5 { XCTAssertTrue(budget.consume(24, at: 100)) }
        XCTAssertFalse(budget.consume(1, at: 100))
        XCTAssertTrue(budget.consume(24, at: 112))
        XCTAssertFalse(budget.consume(25, at: 200))
    }
}
