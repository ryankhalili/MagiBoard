import UIKit
import PencilKit

/// Original Core Graphics renderer shared by the live canvas and crop exports.
@MainActor
final class ObjectRenderer {
    static let shared = ObjectRenderer()
    private let imageCache = NSCache<NSString, UIImage>()
    private let graphCache: NSCache<NSString, UIBezierPath> = { let cache = NSCache<NSString, UIBezierPath>(); cache.countLimit = 64; return cache }()
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
            drawCard(rect, context: context, dark: dark)
            if let snapshot = widgetSnapshots[object.id] {
                context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 16).cgPath)
                context.clip()
                snapshot.draw(in: rect)
            } else {
                text(object.title, in: CGRect(x: rect.minX + 22, y: rect.minY + 22, width: rect.width - 44, height: 40), font: .systemFont(ofSize: 20, weight: .semibold), color: foreground)
                text("Interactive object", in: CGRect(x: rect.minX + 22, y: rect.minY + 65, width: rect.width - 44, height: 35), font: .systemFont(ofSize: 14), color: secondary)
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
            drawCard(rect, context: context, dark: dark)
            if !object.title.isEmpty {
                text(object.title.uppercased(), in: CGRect(x: rect.minX + 22, y: rect.minY + 16, width: rect.width - 44, height: 22), font: .systemFont(ofSize: 10, weight: .semibold), color: secondary)
            }
            let display = MathDisplay.attributed(object.text, size: CGFloat(min(240, max(8, object.properties["fontSize"] ?? 27))), color: ink)
            let available = CGRect(x: rect.minX + 22, y: rect.minY + 42, width: rect.width - 44, height: rect.height - 54)
            display.draw(with: available, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
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
        let titleHeight: CGFloat = object.title.isEmpty ? 0 : 32
        let area = CGRect(x: rect.minX + 22, y: rect.minY + titleHeight + 10, width: max(1, rect.width - 44), height: max(1, rect.height - titleHeight - 34))
        let path = UIBezierPath()
        var vertices: [CGPoint] = []
        let shape = object.shape.lowercased()
        if shape == "triangle" {
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
        if !object.title.isEmpty {
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
        text("y = \(formula)" + ((object.properties["c"] ?? 0) == 0 ? "" : String(format: "  + %.1f", object.properties["c"] ?? 0)), in: CGRect(x: rect.minX + 22, y: rect.minY + 45, width: rect.width - 44, height: 24), font: .monospacedSystemFont(ofSize: 13, weight: .regular), color: ink)
        let plot = CGRect(x: rect.minX + 42, y: rect.minY + 82, width: max(10, rect.width - 64), height: max(10, rect.height - 113))
        let xMin = max(-1000, min(999.9, object.properties["xMin"] ?? -(object.properties["xRange"] ?? 6)))
        let xMax = max(xMin + 0.1, min(1000, object.properties["xMax"] ?? (object.properties["xRange"] ?? 6)))
        let yMin = max(-1000, min(999.9, object.properties["yMin"] ?? -(object.properties["yRange"] ?? 3)))
        let yMax = max(yMin + 0.1, min(1000, object.properties["yMax"] ?? (object.properties["yRange"] ?? 3)))
        let xSpan = xMax - xMin, ySpan = yMax - yMin
        let zero = CGPoint(x: plot.minX - xMin / xSpan * plot.width, y: plot.maxY + yMin / ySpan * plot.height)
        context.saveGState(); context.clip(to: plot)
        let grid = (dark ? UIColor.white : UIColor.black).withAlphaComponent(0.055)
        context.setStrokeColor(grid.cgColor); context.setLineWidth(0.7)
        let xStep = max(1, Int(ceil(xSpan / 16)))
        let yStep = max(1, Int(ceil(ySpan / 10)))
        for i in stride(from: Int(ceil(xMin)), through: Int(floor(xMax)), by: xStep) {
            let x = plot.minX + (Double(i) - xMin) / xSpan * plot.width
            context.move(to: CGPoint(x: x, y: plot.minY)); context.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        for i in stride(from: Int(ceil(yMin)), through: Int(floor(yMax)), by: yStep) {
            let y = plot.maxY - (Double(i) - yMin) / ySpan * plot.height
            context.move(to: CGPoint(x: plot.minX, y: y)); context.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        context.strokePath()
        context.setStrokeColor(secondary.withAlphaComponent(0.5).cgColor); context.setLineWidth(1)
        context.move(to: CGPoint(x: zero.x, y: plot.minY)); context.addLine(to: CGPoint(x: zero.x, y: plot.maxY))
        context.move(to: CGPoint(x: plot.minX, y: zero.y)); context.addLine(to: CGPoint(x: plot.maxX, y: zero.y)); context.strokePath()
        let amplitude = object.properties["amplitude"] ?? 1
        let frequency = object.properties["frequency"] ?? 1
        let c = object.properties["c"] ?? 0
        let cacheKey = ([formula] + [plot.width, plot.height, xMin, xMax, yMin, yMax, amplitude, frequency, c].map { String($0) }).joined(separator: "|") as NSString
        let curve: UIBezierPath
        if let cached = graphCache.object(forKey: cacheKey) { curve = cached }
        else {
            curve = UIBezierPath()
            let evaluator = PlotExpression(formula)
            var previous: CGPoint?
            let sampleCount = min(2048, max(32, Int(plot.width * 1.5)))
            for pixel in 0...sampleCount {
                let fraction = Double(pixel) / Double(sampleCount)
                let x = xMin + fraction * xSpan
                let y = amplitude * evaluator.evaluate(x: x * frequency) + c
                guard y.isFinite, abs(y) < max(abs(yMin), abs(yMax)) * 10 + 10 else { previous = nil; continue }
                let point = CGPoint(x: fraction * plot.width, y: plot.height - (y - yMin) / ySpan * plot.height)
                if let last = previous, abs(last.y - point.y) < plot.height * 1.5 { curve.addLine(to: point) }
                else { curve.move(to: point) }
                previous = point
            }
            graphCache.setObject(curve, forKey: cacheKey)
        }
        context.setStrokeColor(ink.cgColor); context.setLineWidth(2.5); context.setLineJoin(.round)
        context.translateBy(x: plot.minX, y: plot.minY)
        context.addPath(curve.cgPath); context.strokePath(); context.restoreGState()
        text("x", in: CGRect(x: plot.maxX - 10, y: min(plot.maxY - 18, max(plot.minY, zero.y + 6)), width: 15, height: 20), font: .italicSystemFont(ofSize: 12), color: secondary)
        if plot.contains(zero) { text("0", in: CGRect(x: zero.x + 6, y: zero.y + 6, width: 20, height: 20), font: .systemFont(ofSize: 10), color: secondary) }
        text(String(format: "%.1f", xMin), in: CGRect(x: plot.minX, y: plot.maxY + 8, width: 35, height: 20), font: .systemFont(ofSize: 10), color: secondary)
        text(String(format: "%.1f", xMax), in: CGRect(x: plot.maxX - 25, y: plot.maxY + 8, width: 25, height: 20), font: .systemFont(ofSize: 10), color: secondary, alignment: .right)
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

/// A small, bounded expression parser. Plot expressions never run JavaScript or host code.
struct PlotExpression {
    private let source: String
    init(_ source: String) {
        self.source = source.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "y=", with: "").replacingOccurrences(of: "**", with: "^").replacingOccurrences(of: "π", with: "pi").replacingOccurrences(of: "−", with: "-")
    }
    func evaluate(x: Double) -> Double {
        var parser = Parser(chars: Array(source.prefix(512)), x: x)
        let value = parser.sum()
        return parser.index == parser.chars.count ? value : .nan
    }
    private struct Parser {
        let chars: [Character]
        let x: Double
        var index = 0
        var depth = 0
        mutating func consume(_ char: Character) -> Bool {
            if index < chars.count && chars[index] == char { index += 1; return true }; return false
        }
        mutating func sum() -> Double {
            var v = product()
            while index < chars.count {
                if consume("+") { v += product() } else if consume("-") { v -= product() } else { break }
            }; return v
        }
        mutating func product() -> Double {
            var v = unary()
            while index < chars.count {
                if consume("*") { v *= unary() } else if consume("/") { v /= unary() }
                else if chars[index] == "(" || chars[index].isLetter { v *= unary() }
                else { break }
            }; return v
        }
        mutating func unary() -> Double {
            if consume("+") { return unary() }; if consume("-") { return -unary() }
            var value = atom()
            if consume("^") { value = pow(value, unary()) }
            return value
        }
        mutating func atom() -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 32, index < chars.count else { index = chars.count; return .nan }
            if consume("(") { let value = sum(); guard consume(")") else { return .nan }; return value }
            if chars[index].isNumber || chars[index] == "." {
                let start = index
                while index < chars.count && (chars[index].isNumber || chars[index] == ".") { index += 1 }
                return Double(String(chars[start..<index])) ?? .nan
            }
            let start = index
            while index < chars.count && chars[index].isLetter { index += 1 }
            let name = String(chars[start..<index])
            if name == "x" { return x }; if name == "pi" { return .pi }; if name == "e" { return M_E }
            guard index > start, consume("(") else { index = chars.count; return .nan }
            let value = sum(); guard consume(")") else { return .nan }
            switch name {
            case "sin": return sin(value)
            case "cos": return cos(value)
            case "tan": return tan(value)
            case "sqrt": return sqrt(value)
            case "abs": return abs(value)
            case "ln", "log": return log(value)
            case "exp": return exp(value)
            case "asin": return asin(value)
            case "acos": return acos(value)
            case "atan": return atan(value)
            default: return .nan
            }
        }
    }
}

/// Lightweight native display for common math notation. Original LaTeX remains editable in the model.
enum MathDisplay {
    static func attributed(_ source: String, size: CGFloat, color: UIColor) -> NSAttributedString {
        var value = source.replacingOccurrences(of: "$$", with: "").replacingOccurrences(of: "$", with: "").replacingOccurrences(of: "\\(", with: "").replacingOccurrences(of: "\\)", with: "").replacingOccurrences(of: "\\[", with: "").replacingOccurrences(of: "\\]", with: "")
        let symbols = ["\\alpha":"α", "\\beta":"β", "\\gamma":"γ", "\\theta":"θ", "\\omega":"ω", "\\Delta":"Δ", "\\pi":"π", "\\sigma":"σ", "\\lambda":"λ", "\\mu":"μ", "\\hbar":"ℏ", "\\infty":"∞", "\\sum":"∑", "\\int":"∫", "\\partial":"∂", "\\times":"×", "\\cdot":"·", "\\pm":"±", "\\approx":"≈", "\\leq":"≤", "\\geq":"≥", "\\rightarrow":"→", "\\sin":"sin", "\\cos":"cos", "\\tan":"tan", "\\log":"log", "\\ln":"ln", "\\left":"", "\\right":"", "\\,":" ", "\\!":"", "\\quad":"  "]
        for (key, replacement) in symbols.sorted(by: { $0.key.count > $1.key.count }) { value = value.replacingOccurrences(of: key, with: replacement) }
        value = value.replacingOccurrences(of: #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "($1)/($2)", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\sqrt\{([^{}]*)\}"#, with: "√($1)", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\\(?:text|mathrm|mathbf)\{([^{}]*)\}"#, with: "$1", options: .regularExpression)
        let result = NSMutableAttributedString(string: "")
        let chars = Array(value)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "^" || char == "_", index + 1 < chars.count {
                let superscript = char == "^"
                index += 1
                var part = ""
                if chars[index] == "{" {
                    index += 1
                    while index < chars.count && chars[index] != "}" { part.append(chars[index]); index += 1 }
                    if index < chars.count { index += 1 }
                } else { part.append(chars[index]); index += 1 }
                result.append(NSAttributedString(string: part, attributes: [.font: UIFont(name: "TimesNewRomanPSMT", size: size * 0.64) ?? .systemFont(ofSize: size * 0.64), .foregroundColor: color, .baselineOffset: superscript ? size * 0.38 : -size * 0.18]))
            } else {
                result.append(NSAttributedString(string: String(char), attributes: [.font: UIFont(name: "TimesNewRomanPS-ItalicMT", size: size) ?? .systemFont(ofSize: size), .foregroundColor: color]))
                index += 1
            }
        }
        return result
    }
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
