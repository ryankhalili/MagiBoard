import UIKit
import PencilKit

/// Original Core Graphics renderer shared by the live canvas and crop exports.
@MainActor
final class ObjectRenderer {
    static let shared = ObjectRenderer()
    private let imageCache = NSCache<NSString, UIImage>()
    private let graphCache: NSCache<NSString, UIBezierPath> = { let cache = NSCache<NSString, UIBezierPath>(); cache.countLimit = 64; return cache }()
    private let graphAnalysisCache: NSCache<NSString, GraphPlotCacheEntry> = { let cache = NSCache<NSString, GraphPlotCacheEntry>(); cache.countLimit = 64; return cache }()
    var widgetSnapshots: [UUID: UIImage] = [:]

    func draw(_ object: CanvasObject, in context: CGContext, dark: Bool = false) {
        let rect = object.rect
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let ink = UIColor(studioHex: object.color)
        let foreground = dark ? UIColor(white: 0.93, alpha: 1) : UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1)
        let secondary = dark ? UIColor(white: 0.65, alpha: 1) : UIColor(red: 0.43, green: 0.48, blue: 0.55, alpha: 1)
        switch object.kind {
        case "shape": drawShape(object, context: context, ink: ink, foreground: foreground)
        case "graph": drawGraph(object, context: context, ink: ink, foreground: foreground, secondary: secondary, dark: dark)
        case "image":
            if let image = image(for: object) {
                image.draw(in: rect)
            } else {
                drawCard(rect, context: context, dark: dark)
                text("Image", in: rect.insetBy(dx: 20, dy: 20), font: .systemFont(ofSize: 18, weight: .medium), color: secondary)
            }
        case "widget":
            if (object.properties["card"] ?? 0) > 0 { drawCard(rect, context: context, dark: dark) }
            if let snapshot = widgetSnapshots[object.id] {
                snapshot.draw(in: rect)
            }
        case "frame":
            let paper = (object.properties["paper"] ?? 0) > 0
            context.setStrokeColor(ink.withAlphaComponent(0.25).cgColor)
            context.setFillColor((paper ? UIColor.white : ink.withAlphaComponent(0.035)).cgColor)
            context.setLineWidth(1.5)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 18).cgPath)
            context.drawPath(using: .fillStroke)
            text(object.title, in: CGRect(x: rect.minX + 16, y: rect.minY + 12, width: rect.width - 32, height: 28), font: .systemFont(ofSize: 14, weight: .semibold), color: ink)
        case "latex":
            EquationRenderer.draw(object.text, in: rect, context: context,
                                  color: dark && ink.studioLuminance < 0.22 ? foreground : ink,
                                  fontSize: CGFloat(min(240, max(8, object.properties["fontSize"] ?? 28))))
        default:
            let size = CGFloat(min(240, max(8, object.properties["fontSize"] ?? (object.title == "Heading" ? 32 : 21))))
            let weight: UIFont.Weight = (object.properties["bold"] ?? 0) > 0 ? .semibold : .regular
            if (object.properties["card"] ?? 0) > 0 { drawCard(rect, context: context, dark: dark) }
            text(object.text.isEmpty ? object.title : object.text, in: rect.insetBy(dx: (object.properties["card"] ?? 0) > 0 ? 20 : 0, dy: (object.properties["card"] ?? 0) > 0 ? 16 : 0), font: .systemFont(ofSize: size, weight: weight), color: dark && ink.studioLuminance < 0.22 ? foreground : ink)
        }
    }

    private func drawCard(_ rect: CGRect, context: CGContext, dark: Bool) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 3), blur: 14, color: UIColor.black.withAlphaComponent(dark ? 0.15 : 0.035).cgColor)
        context.setFillColor((dark ? UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1) : .white).cgColor)
        context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 16).cgPath)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0)
        context.setStrokeColor((dark ? UIColor.white : UIColor.black).withAlphaComponent(0.08).cgColor)
        context.setLineWidth(1)
        context.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 16).cgPath)
        context.strokePath()
        context.restoreGState()
    }

    private func drawShape(_ object: CanvasObject, context: CGContext, ink: UIColor, foreground: UIColor) {
        let rect = object.rect
        let recognized = (object.properties["recognizedOutline"] ?? 0) > 0
        let titleHeight: CGFloat = object.title.isEmpty || recognized ? 0 : 32
        let area = recognized ? rect : CGRect(x: rect.minX + 22, y: rect.minY + titleHeight + 10, width: max(1, rect.width - 44), height: max(1, rect.height - titleHeight - 34))
        let path = UIBezierPath()
        var vertices: [CGPoint] = []
        let shape = object.shape.lowercased()
        if shape == "polygon", let outline = RecognizedPolygonGeometry.vertices(for: object) {
            path.move(to: outline[0])
            for point in outline.dropFirst() { path.addLine(to: point) }
            path.close()
        } else if shape == "triangle" {
            let a = max(0.000001, object.properties["angleA"] ?? 49)
            let b = max(0.000001, object.properties["angleB"] ?? 52)
            vertices = TriangleGeometry.vertices(in: area, angleA: a, angleB: b)
            path.move(to: vertices[0]); path.addLine(to: vertices[1]); path.addLine(to: vertices[2]); path.close()
        } else if shape == "circle" || shape == "ellipse" {
            let diameter = min(area.width, area.height)
            let circle = shape == "circle" ? CGRect(x: area.midX - diameter / 2, y: area.midY - diameter / 2, width: diameter, height: diameter) : area
            path.append(UIBezierPath(ovalIn: circle))
        } else if shape == "line" || shape == "arrow" {
            path.move(to: CGPoint(x: area.minX, y: area.maxY)); path.addLine(to: CGPoint(x: area.maxX, y: area.minY))
            if shape == "arrow" {
                let angle = atan2(area.height, area.width)
                let tip = CGPoint(x: area.maxX, y: area.minY)
                path.move(to: CGPoint(x: tip.x - 22 * cos(angle - .pi / 6), y: tip.y + 22 * sin(angle - .pi / 6)))
                path.addLine(to: tip)
                path.addLine(to: CGPoint(x: tip.x - 22 * cos(angle + .pi / 6), y: tip.y + 22 * sin(angle + .pi / 6)))
            }
        } else if shape == "diamond" {
            path.move(to: CGPoint(x: area.midX, y: area.minY)); path.addLine(to: CGPoint(x: area.maxX, y: area.midY)); path.addLine(to: CGPoint(x: area.midX, y: area.maxY)); path.addLine(to: CGPoint(x: area.minX, y: area.midY)); path.close()
        } else if shape == "star" {
            for i in 0..<10 {
                let angle = CGFloat(i) * .pi / 5 - .pi / 2
                let radius = min(area.width, area.height) / 2 * (i.isMultiple(of: 2) ? 1 : 0.44)
                let p = CGPoint(x: area.midX + cos(angle) * radius, y: area.midY + sin(angle) * radius)
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            path.close()
        } else {
            path.append(UIBezierPath(roundedRect: area, cornerRadius: CGFloat(object.properties["cornerRadius"] ?? 8)))
        }
        context.setFillColor(ink.withAlphaComponent(["starry", "stars"].contains(object.pattern) ? 0.95 : CGFloat(object.properties["opacity"] ?? object.properties["fillOpacity"] ?? 0.12)).cgColor)
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(CGFloat(object.properties["strokeWidth"] ?? 2.5))
        context.setLineJoin(.round); context.setLineCap(.round)
        context.addPath(path.cgPath)
        context.drawPath(using: (shape == "line" || shape == "arrow") ? .stroke : .fillStroke)
        if ["starry", "stars"].contains(object.pattern) {
            context.saveGState(); context.addPath(path.cgPath); context.clip()
            for i in 0..<90 {
                let x = area.minX + CGFloat((i * 137 + 17) % 997) / 997 * area.width
                let y = area.minY + CGFloat((i * 251 + 113) % 991) / 991 * area.height
                let radius: CGFloat = i.isMultiple(of: 7) ? 2.3 : 1.0
                context.setFillColor(UIColor.white.withAlphaComponent(i.isMultiple(of: 3) ? 0.92 : 0.55).cgColor)
                context.fillEllipse(in: CGRect(x: x, y: y, width: radius * 2, height: radius * 2))
                if i.isMultiple(of: 7) {
                    context.setStrokeColor(UIColor.white.withAlphaComponent(0.65).cgColor)
                    context.setLineWidth(0.8)
                    context.move(to: CGPoint(x: x + radius, y: y - 3)); context.addLine(to: CGPoint(x: x + radius, y: y + 2 * radius + 3))
                    context.move(to: CGPoint(x: x - 3, y: y + radius)); context.addLine(to: CGPoint(x: x + 2 * radius + 3, y: y + radius)); context.strokePath()
                }
            }
            context.restoreGState()
        }
        if !object.title.isEmpty && !recognized {
            text(object.title, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 28), font: .systemFont(ofSize: 15, weight: .medium), color: foreground, alignment: .center)
        }
        if vertices.count == 3 {
            let a = max(0.000001, object.properties["angleA"] ?? 49)
            let b = max(0.000001, object.properties["angleB"] ?? 52)
            let labels = [a, b, 180 - a - b]
            let offsets = [CGPoint(x: 8, y: -28), CGPoint(x: -48, y: -28), CGPoint(x: -18, y: 12)]
            for i in 0..<3 {
                text(String(format: "%.0f°", labels[i]), in: CGRect(x: vertices[i].x + offsets[i].x, y: vertices[i].y + offsets[i].y, width: 44, height: 22), font: .systemFont(ofSize: 13, weight: .medium), color: ["starry", "stars"].contains(object.pattern) ? .white : ink, alignment: .center)
            }
        }
    }

    private func drawGraph(_ object: CanvasObject, context: CGContext, ink: UIColor, foreground: UIColor, secondary: UIColor, dark: Bool) {
        let rect = object.rect
        drawCard(rect, context: context, dark: dark)
        text(object.title.isEmpty ? "Function" : object.title, in: CGRect(x: rect.minX + 22, y: rect.minY + 17, width: rect.width - 44, height: 26), font: .systemFont(ofSize: 16, weight: .semibold), color: foreground)
        let formula = object.text.isEmpty ? "sin(x)" : object.text
        let plotRect = CGRect(x: rect.minX + 58, y: rect.minY + 82, width: max(10, rect.width - 82), height: max(10, rect.height - 121))
        let sampleCount = min(2048, max(256, Int(plotRect.width * 1.8)))
        let key = (formula + "|" + object.properties.keys.sorted().map { "\($0)=\(object.properties[$0]!)" }.joined(separator: "|") + "|\(sampleCount)") as NSString
        let graph: GraphPlot
        if let entry = graphAnalysisCache.object(forKey: key) { graph = entry.plot }
        else { graph = GraphPlot(formula: formula, properties: object.properties, sampleCount: sampleCount); graphAnalysisCache.setObject(GraphPlotCacheEntry(graph), forKey: key) }
        text(graph.displayFormula, in: CGRect(x: rect.minX + 22, y: rect.minY + 45, width: rect.width - 44, height: 24), font: .monospacedSystemFont(ofSize: 13, weight: .regular), color: ink)
        if let error = graph.error {
            text(error, in: plotRect.insetBy(dx: 8, dy: 20), font: .systemFont(ofSize: 14), color: .systemOrange)
            return
        }
        let xticks = GraphPlot.ticks(min: graph.xMin, max: graph.xMax, target: max(2, Int(plotRect.width / 70)))
        let yticks = GraphPlot.ticks(min: graph.yMin, max: graph.yMax, target: max(2, Int(plotRect.height / 45)))
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: plotRect.minX + (x - graph.xMin) / graph.xSpan * plotRect.width,
                    y: plotRect.maxY - (y - graph.yMin) / graph.ySpan * plotRect.height)
        }
        context.saveGState(); context.clip(to: plotRect)
        if (object.properties["showGrid"] ?? 1) != 0 {
            context.setStrokeColor((dark ? UIColor.white : UIColor.black).withAlphaComponent(0.07).cgColor)
            context.setLineWidth(0.7)
            for value in xticks { let x = point(value, graph.yMin).x; context.move(to: CGPoint(x: x, y: plotRect.minY)); context.addLine(to: CGPoint(x: x, y: plotRect.maxY)) }
            for value in yticks { let y = point(graph.xMin, value).y; context.move(to: CGPoint(x: plotRect.minX, y: y)); context.addLine(to: CGPoint(x: plotRect.maxX, y: y)) }
            context.strokePath()
        }
        if (object.properties["showAxes"] ?? 1) != 0 {
            context.setStrokeColor(secondary.withAlphaComponent(0.55).cgColor); context.setLineWidth(1)
            if graph.xMin <= 0 && graph.xMax >= 0 { let x = point(0, graph.yMin).x; context.move(to: CGPoint(x: x, y: plotRect.minY)); context.addLine(to: CGPoint(x: x, y: plotRect.maxY)) }
            if graph.yMin <= 0 && graph.yMax >= 0 { let y = point(graph.xMin, 0).y; context.move(to: CGPoint(x: plotRect.minX, y: y)); context.addLine(to: CGPoint(x: plotRect.maxX, y: y)) }
            context.strokePath()
        }
        let pathKey = "\(key)|\(plotRect.width)|\(plotRect.height)" as NSString
        let curve: UIBezierPath
        if let cached = graphCache.object(forKey: pathKey) { curve = cached }
        else {
            curve = UIBezierPath()
            for segment in graph.segments where segment.count > 1 {
                for (index, normalized) in segment.enumerated() {
                    let point = CGPoint(x: normalized.x * plotRect.width, y: normalized.y * plotRect.height)
                    if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
            }
            graphCache.setObject(curve, forKey: pathKey)
        }
        context.setStrokeColor(ink.cgColor); context.setLineWidth(CGFloat(object.properties["strokeWidth"] ?? 2.5)); context.setLineJoin(.round)
        context.translateBy(x: plotRect.minX, y: plotRect.minY)
        context.addPath(curve.cgPath); context.strokePath(); context.restoreGState()
        let xStep = GraphPlot.tickStep(min: graph.xMin, max: graph.xMax, target: max(2, Int(plotRect.width / 70)))
        let yStep = GraphPlot.tickStep(min: graph.yMin, max: graph.yMax, target: max(2, Int(plotRect.height / 45)))
        for value in xticks {
            text(GraphPlot.tickLabel(value, step: xStep), in: CGRect(x: point(value, 0).x - 28, y: plotRect.maxY + 7, width: 56, height: 18), font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: secondary, alignment: .center)
        }
        for value in yticks {
            text(GraphPlot.tickLabel(value, step: yStep), in: CGRect(x: rect.minX + 3, y: point(0, value).y - 7, width: 47, height: 18), font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: secondary, alignment: .right)
        }
        text("x", in: CGRect(x: plotRect.maxX - 8, y: plotRect.maxY + 22, width: 15, height: 18), font: .italicSystemFont(ofSize: 11), color: secondary)
        text("y", in: CGRect(x: plotRect.minX - 17, y: plotRect.minY - 17, width: 15, height: 18), font: .italicSystemFont(ofSize: 11), color: secondary)
    }

    private func image(for object: CanvasObject) -> UIImage? {
        guard let data = object.imageData else { return nil }
        let key = "\(object.id)-\(data.hashValue)" as NSString
        if let image = imageCache.object(forKey: key) { return image }
        guard let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    private func text(_ value: String, in rect: CGRect, font: UIFont, color: UIColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineSpacing = 4
        (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph], context: nil)
    }
}


/// Recognized outlines store normalized vertices so moving/resizing remains native and
/// their original orientation survives serialization. They are not canonical angle diagrams.
enum RecognizedPolygonGeometry {
    static func vertices(for object: CanvasObject) -> [CGPoint]? {
        guard let count = object.properties["vertexCount"], count == 3 || count == 4 else { return nil }
        var result: [CGPoint] = []
        for index in 0..<Int(count) {
            guard let x = object.properties["vertex\(index)X"], let y = object.properties["vertex\(index)Y"],
                  x.isFinite, y.isFinite, (-0.000001...1.000001).contains(x), (-0.000001...1.000001).contains(y) else { return nil }
            result.append(CGPoint(x: object.x + x * object.width, y: object.y + y * object.height))
        }
        return result
    }
}

/// Computes a true Euclidean triangle, fitting it without nonuniform scaling.
enum TriangleGeometry {
    static func vertices(in area: CGRect, angleA: Double, angleB: Double) -> [CGPoint] {
        let c = 180 - angleA - angleB
        let radians = Double.pi / 180
        let side = sin(angleB * radians) / sin(c * radians)
        let rawTop = CGPoint(x: side * cos(angleA * radians), y: side * sin(angleA * radians))
        let minX = min(0, rawTop.x), maxX = max(1, rawTop.x)
        let scale = min(area.width / (maxX - minX), area.height / max(rawTop.y, 0.0000001))
        let width = (maxX - minX) * scale, height = rawTop.y * scale
        let origin = CGPoint(x: area.midX - width / 2 - minX * scale, y: area.midY + height / 2)
        return [origin, CGPoint(x: origin.x + scale, y: origin.y), CGPoint(x: origin.x + rawTop.x * scale, y: origin.y - height)]
    }
}

extension UIColor {
    var studioLuminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return r * 0.2126 + g * 0.7152 + b * 0.0722
    }
    convenience init(studioHex: String) {
        let clean = studioHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(String(clean.prefix(6)), radix: 16) ?? 0x4F46E5
        let alpha = clean.count == 8 ? CGFloat(UInt64(String(clean.suffix(2)), radix: 16) ?? 255) / 255 : 1
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: alpha)
    }
}

/// A bounded original scalar-expression parser. Parsing happens once; sampling
/// evaluates a typed tree and never executes JavaScript or host code.
struct PlotExpression {
    let source: String
    let error: String?
    let variables: Set<String>
    private let root: Node?

    init(_ input: String) {
        var normalized = input.lowercased().filter { !$0.isWhitespace }
            .replacingOccurrences(of: "**", with: "^")
            .replacingOccurrences(of: "π", with: "pi")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "·", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
        if let range = normalized.range(of: #"^(?:y|[a-z][a-z0-9_]*\(x\))="#, options: .regularExpression) { normalized.removeSubrange(range) }
        source = normalized
        if normalized.isEmpty || normalized.count > 2048 {
            root = nil; variables = []; error = normalized.isEmpty ? "Enter a function of x." : "Keep graph expressions under 2,048 characters."; return
        }
        var parser = Parser(chars: Array(normalized))
        let parsed = parser.sum()
        if parser.index != parser.chars.count && parser.error == nil { parser.error = "Unexpected symbol ‘\(parser.chars[parser.index])’. Use an explicit function y = f(x)." }
        root = parser.error == nil ? parsed : nil
        variables = parser.variables
        error = parser.error
    }

    func diagnostic(parameters: [String: Double] = [:]) -> String? {
        if let error { return error }
        let missing = variables.subtracting(["x", "pi", "e"]).filter { parameters[$0] == nil }.sorted()
        if !missing.isEmpty { return "Missing parameter\(missing.count == 1 ? "" : "s"): \(missing.joined(separator: ", ")). Add numeric values in Properties." }
        return nil
    }

    func evaluate(x: Double, parameters: [String: Double] = [:]) -> Double {
        guard let root, x.isFinite else { return .nan }
        return root.value(x: x, parameters: parameters)
    }

    private indirect enum Node {
        case number(Double), variable(String), negative(Node), binary(Character, Node, Node), function(String, [Node])
        func value(x: Double, parameters: [String: Double]) -> Double {
            switch self {
            case .number(let value): return value
            case .variable(let name):
                switch name { case "x": return x; case "pi": return .pi; case "e": return M_E; default: return parameters[name] ?? .nan }
            case .negative(let node): return -node.value(x: x, parameters: parameters)
            case .binary(let op, let left, let right):
                let a = left.value(x: x, parameters: parameters), b = right.value(x: x, parameters: parameters)
                switch op { case "+": return a + b; case "-": return a - b; case "*": return a * b; case "/": return a / b; case "^": return pow(a, b); default: return .nan }
            case .function(let name, let nodes):
                let a = nodes[0].value(x: x, parameters: parameters)
                switch name {
                case "sin": return sin(a); case "cos": return cos(a); case "tan": return tan(a)
                case "asin": return asin(a); case "acos": return acos(a); case "atan": return atan(a)
                case "sinh": return sinh(a); case "cosh": return cosh(a); case "tanh": return tanh(a)
                case "sqrt": return sqrt(a); case "abs": return abs(a)
                case "ln", "log": return log(a); case "log10": return log10(a); case "log2": return log2(a)
                case "exp": return exp(a); case "floor": return floor(a); case "ceil": return ceil(a)
                case "min": return min(a, nodes[1].value(x: x, parameters: parameters))
                case "max": return max(a, nodes[1].value(x: x, parameters: parameters))
                case "pow": return pow(a, nodes[1].value(x: x, parameters: parameters))
                case "atan2": return atan2(a, nodes[1].value(x: x, parameters: parameters))
                default: return .nan
                }
            }
        }
    }

    private struct Parser {
        let chars: [Character]
        var index = 0, depth = 0
        var error: String?
        var variables: Set<String> = []
        mutating func fail(_ message: String) -> Node { if error == nil { error = message }; return .number(.nan) }
        mutating func consume(_ char: Character) -> Bool {
            if index < chars.count && chars[index] == char { index += 1; return true }; return false
        }
        mutating func sum() -> Node {
            var node = product()
            while error == nil && index < chars.count {
                if consume("+") { node = .binary("+", node, product()) }
                else if consume("-") { node = .binary("-", node, product()) }
                else { break }
            }
            return node
        }
        mutating func product() -> Node {
            var node = unary()
            while error == nil && index < chars.count {
                if consume("*") { node = .binary("*", node, unary()) }
                else if consume("/") { node = .binary("/", node, unary()) }
                else if chars[index] == "(" || chars[index].isLetter || chars[index] == "_" { node = .binary("*", node, unary()) }
                else { break }
            }
            return node
        }
        mutating func unary() -> Node {
            depth += 1; defer { depth -= 1 }
            guard depth <= 64 else { return fail("The expression is nested too deeply.") }
            if consume("+") { return unary() }
            if consume("-") { return .negative(unary()) }
            var node = atom()
            // Power binds before a leading minus and associates to the right:
            // -x^2 = -(x^2), x^-2 = x^(-2), 2^3^2 = 2^(3^2).
            if error == nil && consume("^") { node = .binary("^", node, unary()) }
            return node
        }
        mutating func atom() -> Node {
            guard index < chars.count else { return fail("The expression ends before a value.") }
            if consume("(") {
                let node = sum()
                guard consume(")") else { return fail("Close the parenthesis with ).") }
                return node
            }
            if chars[index].isNumber || chars[index] == "." {
                let start = index
                while index < chars.count && (chars[index].isNumber || chars[index] == ".") { index += 1 }
                if index < chars.count && chars[index] == "e" {
                    var end = index + 1
                    if end < chars.count && (chars[end] == "+" || chars[end] == "-") { end += 1 }
                    let digits = end
                    while end < chars.count && chars[end].isNumber { end += 1 }
                    if end > digits { index = end }
                }
                guard let value = Double(String(chars[start..<index])), value.isFinite else { return fail("Invalid or out-of-range number.") }
                return .number(value)
            }
            guard chars[index].isLetter || chars[index] == "_" else { return fail("Expected a number, x, parameter, or function.") }
            let start = index
            while index < chars.count && (chars[index].isLetter || chars[index].isNumber || chars[index] == "_") { index += 1 }
            let name = String(chars[start..<index])
            let functions: [String: Int] = ["sin": 1, "cos": 1, "tan": 1, "asin": 1, "acos": 1, "atan": 1, "sinh": 1, "cosh": 1, "tanh": 1, "sqrt": 1, "abs": 1, "ln": 1, "log": 1, "log10": 1, "log2": 1, "exp": 1, "floor": 1, "ceil": 1, "min": 2, "max": 2, "pow": 2, "atan2": 2]
            if let count = functions[name] {
                guard consume("(") else { return fail("Write \(name)(…) with parentheses.") }
                var arguments = [sum()]
                while error == nil && consume(",") { arguments.append(sum()) }
                guard consume(")"), arguments.count == count else { return fail("\(name) needs \(count) argument\(count == 1 ? "" : "s") in parentheses.") }
                return .function(name, arguments)
            }
            // x(x+1) and a(x+1) mean multiplication; a misspelled
            // multi-letter function is reported instead of silently guessed.
            if index < chars.count && chars[index] == "(" && name.count > 1 && !["pi"].contains(name) {
                return fail("Unknown function ‘\(name)’. Use a supported scalar function.")
            }
            variables.insert(name)
            return .variable(name)
        }
    }
}

/// Shared sampled graph model for rendering, diagnostics, parameter behavior and
/// tests. Explicit bounds are retained; absent Y bounds fit finite samples.
struct GraphPlot {
    let expression: PlotExpression
    let parameters: [String: Double]
    let xMin: Double, xMax: Double, yMin: Double, yMax: Double
    let samples: [CGPoint]
    let error: String?
    var xSpan: Double { xMax - xMin }
    var ySpan: Double { yMax - yMin }
    var displayFormula: String {
        var body = expression.source
        let frequency = parameters["frequency"] ?? 1, amplitude = parameters["amplitude"] ?? 1
        if !expression.variables.contains("frequency"), frequency != 1 {
            body = body.replacingOccurrences(of: #"(?<![a-z_])x(?![a-z0-9_])"#, with: "(\(frequency.formatted())*x)", options: .regularExpression)
        }
        if !expression.variables.contains("amplitude"), amplitude != 1 { body = "\(amplitude.formatted())*(\(body))" }
        let shift = (expression.variables.contains("c") ? 0 : (parameters["c"] ?? 0)) + (expression.variables.contains("offset") ? 0 : (parameters["offset"] ?? 0))
        if shift != 0 { body += shift < 0 ? " − \(abs(shift).formatted())" : " + \(shift.formatted())" }
        return "y = " + body
    }

    init(formula: String, properties: [String: Double], sampleCount: Int = 512) {
        let expression = PlotExpression(formula)
        self.expression = expression
        var values = properties
        for (name, fallback) in [("amplitude", 1.0), ("frequency", 1.0), ("c", 0.0), ("offset", 0.0)] where values[name] == nil { values[name] = fallback }
        parameters = values
        let proposedXMin = properties["xMin"] ?? -(abs(properties["xRange"] ?? 6))
        let proposedXMax = properties["xMax"] ?? abs(properties["xRange"] ?? 6)
        let validX = proposedXMin.isFinite && proposedXMax.isFinite && proposedXMax > proposedXMin && (proposedXMax - proposedXMin).isFinite
        xMin = validX ? proposedXMin : -6; xMax = validX ? proposedXMax : 6
        var diagnostic = expression.diagnostic(parameters: values)
        if !validX { diagnostic = "X maximum must be greater than X minimum." }
        let count = max(128, min(4096, sampleCount))
        let xmin = xMin, span = xMax - xMin
        let samples = (0...count).map { index -> CGPoint in
            let x = xmin + Double(index) / Double(count) * span
            return CGPoint(x: x, y: Self.value(x: x, expression: expression, parameters: values))
        }
        self.samples = samples
        let finite = samples.map(\.y).filter(\.isFinite).sorted()
        if finite.isEmpty && diagnostic == nil { diagnostic = "No real values in this X range. Check the function’s domain." }
        var low = finite.first ?? -1, high = finite.last ?? 1
        if finite.count > 40 {
            let innerLow = finite[finite.count / 20], innerHigh = finite[finite.count - 1 - finite.count / 20]
            // Avoid letting a sampled pole flatten the entire visible graph.
            // Ordinary quadratics/exponentials keep their complete extrema.
            if innerHigh > innerLow && (high - low) / (innerHigh - innerLow) > 12 { low = innerLow; high = innerHigh }
        }
        if high == low {
            let margin = max(abs(high) * 0.1, 1)
            low -= margin; high += margin
        } else {
            let margin = (high - low) * 0.08
            low -= margin; high += margin
        }
        if !low.isFinite || !high.isFinite || !(high > low) { low = -1; high = 1 }
        let proposedYMin = properties["yMin"] ?? properties["yRange"].map { -abs($0) } ?? low
        let proposedYMax = properties["yMax"] ?? properties["yRange"].map { abs($0) } ?? high
        let validY = proposedYMin.isFinite && proposedYMax.isFinite && proposedYMax > proposedYMin && (proposedYMax - proposedYMin).isFinite
        yMin = validY ? proposedYMin : -1; yMax = validY ? proposedYMax : 1
        if !validY { diagnostic = "Y maximum must be greater than Y minimum." }
        error = diagnostic
    }

    func value(x: Double) -> Double { Self.value(x: x, expression: expression, parameters: parameters) }
    private static func value(x: Double, expression: PlotExpression, parameters: [String: Double]) -> Double {
        let names = expression.variables
        let frequency = names.contains("frequency") ? 1 : (parameters["frequency"] ?? 1)
        let amplitude = names.contains("amplitude") ? 1 : (parameters["amplitude"] ?? 1)
        let legacyC = names.contains("c") ? 0 : (parameters["c"] ?? 0)
        let offset = names.contains("offset") ? 0 : (parameters["offset"] ?? 0)
        return amplitude * expression.evaluate(x: x * frequency, parameters: parameters) + legacyC + offset
    }

    /// Normalized points; discontinuities start separate paths.
    var segments: [[CGPoint]] {
        guard error == nil else { return [] }
        var result: [[CGPoint]] = [], current: [CGPoint] = []
        for sample in samples {
            let point = CGPoint(x: (sample.x - xMin) / xSpan, y: 1 - (sample.y - yMin) / ySpan)
            guard point.x.isFinite, point.y.isFinite, abs(point.y) < 20 else {
                if !current.isEmpty { result.append(current); current = [] }; continue
            }
            if let previous = current.last, abs(previous.y - point.y) > 1.5 {
                result.append(current); current = []
            }
            current.append(point)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func tickStep(min: Double, max: Double, target: Int = 6) -> Double {
        let raw = (max - min) / Double(Swift.max(2, target))
        guard raw.isFinite, raw > 0 else { return 1 }
        let power = pow(10, floor(log10(raw))), normalized = raw / power
        let factor = [1.0, 2, 2.5, 5, 10].first(where: { $0 >= normalized }) ?? 10
        let step = factor * power
        return step.isFinite && step > 0 ? step : raw
    }
    static func ticks(min: Double, max: Double, target: Int = 6) -> [Double] {
        let step = tickStep(min: min, max: max, target: target)
        let first = ceil(min / step) * step
        guard first.isFinite else { return [] }
        return (0..<64).map { first + Double($0) * step }.prefix(while: { $0 <= max + step * 0.000001 }).filter { $0 >= min - step * 0.000001 }
    }
    static func tickLabel(_ value: Double, step: Double) -> String {
        if abs(value) < abs(step) * 0.000001 { return "0" }
        if abs(value) >= 100_000 || abs(step) < 0.0001 {
            let relative = abs(value / step)
            let digits = relative.isFinite ? max(3, min(15, Int(ceil(log10(max(1, relative)))) + 1)) : 15
            return String(format: "%.*g", digits, value)
        }
        let decimals = max(0, min(12, Int(ceil(-log10(abs(step)))) + 1))
        var label = String(format: "%.*f", decimals, value)
        if label.contains(".") { while label.last == "0" { label.removeLast() }; if label.last == "." { label.removeLast() } }
        return label
    }
}

private final class GraphPlotCacheEntry: NSObject {
    let plot: GraphPlot
    init(_ plot: GraphPlot) { self.plot = plot }
}

@MainActor
enum CanvasExporter {
    static func export(store: NotebookStore, asPDF: Bool) -> URL? {
        let rect = exportRect(store: store)
        guard rect.width > 1, rect.height > 1 else { return nil }
        let title = store.notebook.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(title)-\(UUID().uuidString.prefix(6)).\(asPDF ? "pdf" : "png")")
        do {
            if asPDF {
                let scale = min(1, 14400 / max(rect.width, rect.height))
                let page = CGRect(origin: .zero, size: CGSize(width: rect.width * scale, height: rect.height * scale))
                let renderer = UIGraphicsPDFRenderer(bounds: page)
                try renderer.writePDF(to: url) { output in
                    output.beginPage()
                    let context = output.cgContext
                    context.scaleBy(x: scale, y: scale)
                    draw(store: store, rect: rect, context: context, background: true)
                }
            } else {
                guard let image = snapshot(store: store, rect: rect), let data = image.pngData() else { return nil }
                try data.write(to: url, options: .atomic)
            }
            return url
        } catch { store.status = "Export failed: \(error.localizedDescription)"; return nil }
    }

    static func exportRect(store: NotebookStore) -> CGRect {
        if let reference = store.reference, reference.width > 10, reference.height > 10 { return reference.cgRect }
        let selected = store.notebook.objects.filter { store.selectedIDs.contains($0.id) }
        if !selected.isEmpty { return selected.map(\.rect).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -24, dy: -24) }
        return store.viewport.cgRect
    }

    static func snapshot(store: NotebookStore, rect: CGRect? = nil) -> UIImage? {
        let crop = rect ?? exportRect(store: store)
        guard crop.width.isFinite, crop.height.isFinite, crop.width > 1, crop.height > 1 else { return nil }
        let maxDimension: CGFloat = 4096
        let scale = min(2, maxDimension / max(crop.width, crop.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: crop.size, format: format)
        return renderer.image { output in draw(store: store, rect: crop, context: output.cgContext, background: true) }
    }

    private static func draw(store: NotebookStore, rect: CGRect, context: CGContext, background: Bool) {
        context.saveGState()
        if background { UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: rect.size)) }
        context.translateBy(x: -rect.minX, y: -rect.minY)
        for object in store.notebook.objects.filter({ $0.kind == "frame" }) + store.notebook.objects.filter({ $0.kind != "frame" }) where object.rect.intersects(rect) { ObjectRenderer.shared.draw(object, in: context, dark: false) }
        if let drawing = try? PKDrawing(data: store.notebook.drawingData), !drawing.bounds.isNull {
            let scale = min(2, 4096 / max(rect.width, rect.height))
            drawing.image(from: rect, scale: scale).draw(in: rect)
        }
        context.restoreGState()
    }
}
