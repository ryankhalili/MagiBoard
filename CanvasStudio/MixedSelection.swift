import Foundation
import UIKit
import PencilKit

/// A clipboard selection has one local coordinate system for both vector objects
/// and pressure-sensitive ink. Pasting translates the entire set together.
struct CanvasSelectionPayload: Codable {
    var version = 1
    var objects: [CanvasObject]
    var drawingData: Data
    var bounds: CanvasRect
    var isEmpty: Bool { objects.isEmpty && ((try? PKDrawing(data: drawingData).strokes.isEmpty) ?? true) }
}

final class CanvasSelectionSnapshot {
    var notebookID: UUID
    var objects: [CanvasObject]
    var drawing: PKDrawing
    let drawingData: Data
    var strokeIndices: Set<Int>
    let inkRevision: UInt64
    var expectedObjects: [UUID: CanvasObject]
    init(notebookID: UUID, objects: [CanvasObject], drawing: PKDrawing, drawingData: Data, strokeIndices: Set<Int>, inkRevision: UInt64) {
        self.notebookID = notebookID; self.objects = objects; self.drawing = drawing
        self.drawingData = drawingData
        self.strokeIndices = strokeIndices; self.inkRevision = inkRevision
        expectedObjects = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
    }
}

/// Original polygon hit testing. Boundary intersections count, so a lasso can
/// catch a thin stroke even when both endpoints lie outside its loop.
enum CanvasLasso {
    static func bounds(_ polygon: [CGPoint]) -> CGRect {
        polygon.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: CGSize(width: 0.01, height: 0.01))) }
    }
    static func contains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.last!
        for current in polygon {
            if distance(point, to: previous, current) < 0.01 { return true }
            if (current.y > point.y) != (previous.y > point.y),
               point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x { inside.toggle() }
            previous = current
        }
        return inside
    }
    static func intersects(_ rect: CGRect, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3, rect.intersects(bounds(polygon)) else { return false }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        if corners.contains(where: { contains($0, polygon: polygon) }) || polygon.contains(where: rect.contains) { return true }
        for index in corners.indices {
            if crossesPolygon(corners[index], corners[(index + 1) % 4], polygon) { return true }
        }
        return false
    }
    static func selectedStrokes(in drawing: PKDrawing, polygon: [CGPoint]) -> Set<Int> {
        let area = bounds(polygon)
        guard polygon.count >= 3, area.width > 2, area.height > 2 else { return [] }
        var selected: Set<Int> = []
        for (index, stroke) in drawing.strokes.enumerated() where stroke.renderBounds.intersects(area) {
            var previous: CGPoint?
            for point in samples(stroke) {
                if contains(point, polygon: polygon) || previous.map({ crossesPolygon($0, point, polygon) }) == true {
                    selected.insert(index); break
                }
                previous = point
            }
        }
        return selected
    }
    static func stroke(at point: CGPoint, in drawing: PKDrawing, tolerance: CGFloat) -> Int? {
        for index in drawing.strokes.indices.reversed() {
            let stroke = drawing.strokes[index]
            guard stroke.renderBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { continue }
            var previous: CGPoint?
            for sample in samples(stroke) {
                if hypot(sample.x - point.x, sample.y - point.y) <= tolerance || previous.map({ distance(point, to: $0, sample) <= tolerance }) == true { return index }
                previous = sample
            }
        }
        return nil
    }
    private static func samples(_ stroke: PKStroke) -> [CGPoint] {
        let count = min(512, max(2, stroke.path.count * 2))
        guard !stroke.path.isEmpty else { return [] }
        return (0..<count).map {
            stroke.path.interpolatedPoint(at: CGFloat($0) * CGFloat(stroke.path.count - 1) / CGFloat(count - 1)).location.applying(stroke.transform)
        }
    }
    private static func crossesPolygon(_ a: CGPoint, _ b: CGPoint, _ polygon: [CGPoint]) -> Bool {
        guard var previous = polygon.last else { return false }
        for current in polygon {
            if segmentsIntersect(a, b, previous, current) { return true }
            previous = current
        }
        return false
    }
    private static func segmentsIntersect(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        if abC * abD < 0 && cdA * cdB < 0 { return true }
        return distance(a, to: c, d) < 0.01 || distance(b, to: c, d) < 0.01 || distance(c, to: a, b) < 0.01 || distance(d, to: a, b) < 0.01
    }
    private static func distance(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
}
