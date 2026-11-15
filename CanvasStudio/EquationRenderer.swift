import UIKit
import CoreText

// Original, deliberately bounded LaTeX parser and baseline-based math layout.
// No web view, downloaded font, or third-party typesetter is used.
struct EquationDiagnostic: Error, LocalizedError, Equatable {
    var message: String
    var offset: Int
    var errorDescription: String? { "\(message) (character \(offset + 1))" }
}

enum EquationStyle: Equatable { case math, roman, italic, bold, monospace }
enum EquationAtom: Equatable { case ordinary, variable, binary, relation, open, close, punctuation, function }
indirect enum EquationNode: Equatable {
    case row([EquationNode])
    case glyph(String, EquationStyle, EquationAtom)
    case space(Double)
    case fraction(EquationNode, EquationNode, bar: Bool)
    case root(EquationNode, index: EquationNode?)
    case scripts(EquationNode, lower: EquationNode?, upper: EquationNode?)
    case operatorSymbol(String, scale: Double, limits: Bool)
    case fenced(String, EquationNode, String)
    case styled(EquationStyle, EquationNode)
    case accent(String, EquationNode)
    case lineBreak

    var atomClass: EquationAtom {
        switch self {
        case .glyph(_, _, let atom): return atom
        case .operatorSymbol: return .function
        case .scripts(let base, _, _), .styled(_, let base), .accent(_, let base): return base.atomClass
        default: return .ordinary
        }
    }
}

struct EquationParser {
    private var characters: [Character]
    private var position = 0
    private var depth = 0
    private var nodes = 0
    private init(_ source: String) { characters = Array(source) }
    static func parse(_ source: String) throws -> EquationNode {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for (left, right) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")] {
            if text.hasPrefix(left), text.hasSuffix(right), text.count >= left.count + right.count {
                text = String(text.dropFirst(left.count).dropLast(right.count)); break
            }
        }
        guard text.count <= 8192 else { throw EquationDiagnostic(message: "Use fewer than 8,192 characters in one equation", offset: 0) }
        var parser = EquationParser(text)
        return try parser.row(until: nil)
    }
    private var current: Character? { position < characters.count ? characters[position] : nil }
    private mutating func whitespace() {
        while let c = current {
            if c.isWhitespace { position += 1 }
            else if c == "%" { while let c = current, c != "\n" { position += 1 } }
            else { return }
        }
    }
    private func error(_ message: String) -> EquationDiagnostic { EquationDiagnostic(message: message, offset: min(position, characters.count)) }
    private func hasCommand(_ name: String) -> Bool {
        let value = Array("\\" + name)
        guard position + value.count <= characters.count, Array(characters[position..<position + value.count]) == value else { return false }
        return position + value.count == characters.count || !characters[position + value.count].isLetter
    }
    private mutating func row(until ending: Character?, rightDelimiter: Bool = false) throws -> EquationNode {
        depth += 1
        guard depth <= 64 else { throw error("This equation is nested too deeply") }
        defer { depth -= 1 }
        var items: [EquationNode] = []
        while true {
            whitespace()
            if rightDelimiter && hasCommand("right") { return .row(items) }
            guard let c = current else {
                if let ending { throw error("Close the group with \(ending)") }
                if rightDelimiter { throw error("Add \\right and a closing delimiter") }
                return .row(items)
            }
            if c == ending { position += 1; return .row(items) }
            if c == "}" { throw error("This closing brace has no opening brace") }
            if c == "^" || c == "_" { throw error("Add a base before this script") }
            let base = try atom()
            items.append(try postfix(base))
        }
    }
    private mutating func postfix(_ original: EquationNode) throws -> EquationNode {
        var base = original, lower: EquationNode?, upper: EquationNode?
        while true {
            whitespace()
            if hasCommand("limits") || hasCommand("nolimits") {
                let limits = hasCommand("limits")
                position += limits ? 7 : 9
                guard case .operatorSymbol(let symbol, let scale, _) = base else { throw error("Limits belong to an operator such as \\sum or \\int") }
                base = .operatorSymbol(symbol, scale: scale, limits: limits)
            } else if current == "^" {
                guard upper == nil else { throw error("Group multiple superscripts inside one pair of braces") }
                position += 1; upper = try argument()
            } else if current == "_" {
                guard lower == nil else { throw error("Group multiple subscripts inside one pair of braces") }
                position += 1; lower = try argument()
            } else { break }
        }
        return lower == nil && upper == nil ? base : .scripts(base, lower: lower, upper: upper)
    }
    private mutating func argument() throws -> EquationNode {
        depth += 1
        guard depth <= 64 else { throw error("This equation is nested too deeply") }
        defer { depth -= 1 }
        whitespace()
        guard let c = current else { throw error("Add an argument, usually inside {braces}") }
        if c == "{" { position += 1; return try row(until: "}") }
        guard c != "}" && c != "^" && c != "_" else { throw error("Add an argument inside {braces}") }
        return try atom()
    }
    private mutating func atom() throws -> EquationNode {
        nodes += 1
        guard nodes <= 2048 else { throw error("This equation has too many elements") }
        guard let c = current else { throw error("An expression is missing") }
        position += 1
        if c == "{" { return try row(until: "}") }
        if c == "\\" { return try command() }
        if c == "$" { throw error("Place math delimiters around the whole equation") }
        let kind: EquationAtom
        if "=<>≤≥≠≈≡∝∈∉⊂⊆→↔".contains(c) { kind = .relation }
        else if "+−-*/×÷±∓·".contains(c) { kind = .binary }
        else if "([".contains(c) { kind = .open }
        else if ")]".contains(c) { kind = .close }
        else if ",;:".contains(c) { kind = .punctuation }
        else { kind = c.isLetter ? .variable : .ordinary }
        return .glyph(c == "-" ? "−" : String(c), kind == .variable ? .math : .roman, kind)
    }
    private mutating func command() throws -> EquationNode {
        guard let c = current else { throw error("Complete the command after \\") }
        if !c.isLetter {
            position += 1
            switch c {
            case "\\": return .lineBreak
            case ",": return .space(0.16)
            case ":": return .space(0.22)
            case ";": return .space(0.28)
            case "!": return .space(-0.12)
            case " ": return .space(0.33)
            case "{", "}", "%", "_", "#", "$", "&", "|": return .glyph(String(c), .roman, .ordinary)
            default: throw error("The command \\\(c) is not supported")
            }
        }
        let start = position
        while let c = current, c.isLetter { position += 1 }
        let name = String(characters[start..<position])
        switch name {
        case "frac", "dfrac", "tfrac": return .fraction(try argument(), try argument(), bar: true)
        case "binom": return .fenced("(", .fraction(try argument(), try argument(), bar: false), ")")
        case "sqrt":
            whitespace()
            var index: EquationNode?
            if current == "[" { position += 1; index = try row(until: "]") }
            return .root(try argument(), index: index)
        case "left":
            let left = try delimiter()
            let content = try row(until: nil, rightDelimiter: true)
            guard hasCommand("right") else { throw error("Add \\right and a closing delimiter") }
            position += 6
            return .fenced(left, content, try delimiter())
        case "right": throw error("Add a matching \\left before \\right")
        case "text": return .glyph(try textGroup(), .roman, .ordinary)
        case "mathrm", "operatorname":
            if name == "operatorname" { return .glyph(try textGroup(), .roman, .function) }
            return .styled(.roman, try argument())
        case "mathbf", "boldsymbol": return .styled(.bold, try argument())
        case "mathit": return .styled(.italic, try argument())
        case "mathtt": return .styled(.monospace, try argument())
        case "hat", "widehat", "bar", "overline", "vec", "dot", "ddot", "tilde", "widetilde": return .accent(name, try argument())
        case "sum": return .operatorSymbol("∑", scale: 1.45, limits: true)
        case "prod": return .operatorSymbol("∏", scale: 1.45, limits: true)
        case "int": return .operatorSymbol("∫", scale: 1.7, limits: false)
        case "iint": return .operatorSymbol("∬", scale: 1.7, limits: false)
        case "iiint": return .operatorSymbol("∭", scale: 1.7, limits: false)
        case "oint": return .operatorSymbol("∮", scale: 1.7, limits: false)
        case "lim", "limsup", "liminf": return .operatorSymbol(name, scale: 1, limits: true)
        case "quad": return .space(1)
        case "qquad": return .space(2)
        case "enspace": return .space(0.5)
        case "displaystyle", "textstyle": return .space(0)
        default:
            if Self.functions.contains(name) { return .glyph(name, .roman, .function) }
            if let symbol = Self.symbols[name] {
                let kind: EquationAtom = Self.relations.contains(name) ? .relation : Self.binary.contains(name) ? .binary : Self.greek.contains(name) ? .variable : .ordinary
                return .glyph(symbol, kind == .variable ? .math : .roman, kind)
            }
            throw EquationDiagnostic(message: "\\\(name) is not supported yet", offset: max(0, start - 1))
        }
    }
    private mutating func delimiter() throws -> String {
        whitespace()
        guard let c = current else { throw error("Choose a delimiter such as ( or |") }
        if c == "\\" {
            position += 1
            guard let next = current else { throw error("A delimiter is missing") }
            if !next.isLetter { position += 1; return next == "." ? "" : String(next) }
            let start = position
            while let c = current, c.isLetter { position += 1 }
            let name = String(characters[start..<position])
            let delimiters = ["langle":"⟨", "rangle":"⟩", "lvert":"|", "rvert":"|", "vert":"|", "Vert":"‖", "lVert":"‖", "rVert":"‖", "lbrace":"{", "rbrace":"}", "lfloor":"⌊", "rfloor":"⌋", "lceil":"⌈", "rceil":"⌉"]
            guard let symbol = delimiters[name] else { throw error("Unsupported delimiter \\\(name)") }
            return symbol
        }
        guard "()[]{}|.⟨⟩⌊⌋⌈⌉‖".contains(c) else { throw error("Choose a delimiter such as (, [, or |") }
        position += 1; return c == "." ? "" : String(c)
    }
    private mutating func textGroup() throws -> String {
        whitespace()
        guard current == "{" else { throw error("Put text inside {braces}") }
        position += 1
        var result = "", nesting = 1
        while let c = current {
            position += 1
            if c == "{" { nesting += 1; result.append(c) }
            else if c == "}" { nesting -= 1; if nesting == 0 { return result }; result.append(c) }
            else if c == "\\", let next = current, "{}%_$&#".contains(next) { result.append(next); position += 1 }
            else { result.append(c) }
        }
        throw error("Close the text group with }")
    }
    private static let functions: Set<String> = ["sin","cos","tan","sec","csc","cot","sinh","cosh","tanh","arcsin","arccos","arctan","log","ln","exp","max","min","det","gcd","arg","Re","Im"]
    private static let greek: Set<String> = ["alpha","beta","gamma","delta","epsilon","varepsilon","zeta","eta","theta","vartheta","iota","kappa","lambda","mu","nu","xi","pi","varpi","rho","varrho","sigma","varsigma","tau","upsilon","phi","varphi","chi","psi","omega"]
    private static let relations: Set<String> = ["le","leq","ge","geq","ne","neq","approx","equiv","sim","simeq","propto","in","notin","subset","subseteq","supset","supseteq","to","rightarrow","leftarrow","leftrightarrow","Rightarrow","Leftarrow","Leftrightarrow","perp","parallel"]
    private static let binary: Set<String> = ["times","cdot","div","pm","mp","cup","cap","oplus","otimes"]
    private static let symbols: [String: String] = [
        "alpha":"α","beta":"β","gamma":"γ","delta":"δ","epsilon":"ϵ","varepsilon":"ε","zeta":"ζ","eta":"η","theta":"θ","vartheta":"ϑ","iota":"ι","kappa":"κ","lambda":"λ","mu":"μ","nu":"ν","xi":"ξ","pi":"π","varpi":"ϖ","rho":"ρ","varrho":"ϱ","sigma":"σ","varsigma":"ς","tau":"τ","upsilon":"υ","phi":"ϕ","varphi":"φ","chi":"χ","psi":"ψ","omega":"ω",
        "Gamma":"Γ","Delta":"Δ","Theta":"Θ","Lambda":"Λ","Xi":"Ξ","Pi":"Π","Sigma":"Σ","Upsilon":"Υ","Phi":"Φ","Psi":"Ψ","Omega":"Ω",
        "infty":"∞","partial":"∂","nabla":"∇","hbar":"ℏ","ell":"ℓ","emptyset":"∅","forall":"∀","exists":"∃","neg":"¬","aleph":"ℵ","angle":"∠","degree":"°","prime":"′","ldots":"…","cdots":"⋯","vdots":"⋮","ddots":"⋱",
        "times":"×","cdot":"·","div":"÷","pm":"±","mp":"∓","cup":"∪","cap":"∩","oplus":"⊕","otimes":"⊗",
        "le":"≤","leq":"≤","ge":"≥","geq":"≥","ne":"≠","neq":"≠","approx":"≈","equiv":"≡","sim":"∼","simeq":"≃","propto":"∝","in":"∈","notin":"∉","subset":"⊂","subseteq":"⊆","supset":"⊃","supseteq":"⊇","to":"→","rightarrow":"→","leftarrow":"←","leftrightarrow":"↔","Rightarrow":"⇒","Leftarrow":"⇐","Leftrightarrow":"⇔","perp":"⊥","parallel":"∥",
        "langle":"⟨","rangle":"⟩","vert":"|","Vert":"‖","backslash":"\\"]
}

struct EquationLayout {
    var width: CGFloat
    var ascent: CGFloat
    var descent: CGFloat
    var primitives: [EquationPrimitive]
    var size: CGSize { CGSize(width: max(1, width), height: max(1, ascent + descent)) }
    var bounds: CGRect { CGRect(x: 0, y: -ascent, width: width, height: ascent + descent) }
}

enum EquationPrimitive {
    case text(String, UIFont, CGPoint)
    case line(CGPoint, CGPoint, CGFloat)
    case path([CGPoint], CGFloat)
    case ellipse(CGRect)
    func translated(x: CGFloat, y: CGFloat) -> EquationPrimitive {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + x, y: p.y + y) }
        switch self {
        case .text(let text, let font, let p): return .text(text, font, move(p))
        case .line(let a, let b, let width): return .line(move(a), move(b), width)
        case .path(let points, let width): return .path(points.map(move), width)
        case .ellipse(let rect): return .ellipse(rect.offsetBy(dx: x, dy: y))
        }
    }
}

private final class EquationLayoutBox: NSObject {
    let value: EquationLayout
    init(_ value: EquationLayout) { self.value = value }
}

@MainActor
enum EquationRenderer {
    private static let cache: NSCache<NSString, EquationLayoutBox> = {
        let cache = NSCache<NSString, EquationLayoutBox>(); cache.countLimit = 128; cache.totalCostLimit = 4_000_000; return cache
    }()
    static func layout(_ source: String, fontSize: CGFloat = 28) throws -> EquationLayout {
        let size = min(240, max(8, fontSize))
        let key = "\(size)|\(source)" as NSString
        if let existing = cache.object(forKey: key) { return existing.value }
        let result = try layout(EquationParser.parse(source), size: size, style: nil)
        cache.setObject(EquationLayoutBox(result), forKey: key, cost: source.utf8.count + result.primitives.count * 64)
        return result
    }
    static func diagnostic(_ source: String) -> EquationDiagnostic? {
        do { _ = try EquationParser.parse(source); return nil }
        catch let error as EquationDiagnostic { return error }
        catch { return EquationDiagnostic(message: error.localizedDescription, offset: 0) }
    }
    @discardableResult
    static func draw(_ source: String, in rect: CGRect, context: CGContext, color: UIColor, fontSize: CGFloat = 28, centered: Bool = false) -> EquationDiagnostic? {
        do {
            let result = try layout(source, fontSize: fontSize)
            let available = rect.insetBy(dx: 3, dy: 3)
            guard available.width > 0, available.height > 0 else { return nil }
            let scale = min(1, available.width / max(1, result.width), available.height / max(1, result.ascent + result.descent))
            let x = centered ? available.midX - result.width * scale / 2 : available.minX
            let y = available.midY - (result.ascent + result.descent) * scale / 2 + result.ascent * scale
            context.saveGState(); context.translateBy(x: x, y: y); context.scaleBy(x: scale, y: scale)
            draw(result, context: context, color: color)
            context.restoreGState()
            return nil
        } catch {
            let diagnostic = (error as? EquationDiagnostic) ?? EquationDiagnostic(message: error.localizedDescription, offset: 0)
            let fallback = source.isEmpty ? "Equation" : String(source.prefix(180))
            (fallback as NSString).draw(in: rect.insetBy(dx: 4, dy: 4), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: min(16, fontSize), weight: .regular), .foregroundColor: color.withAlphaComponent(0.65)])
            context.setStrokeColor(UIColor.systemOrange.cgColor); context.setLineWidth(1)
            context.move(to: CGPoint(x: rect.minX + 3, y: rect.maxY - 3)); context.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.maxY - 3)); context.strokePath()
            return diagnostic
        }
    }
    static func draw(_ layout: EquationLayout, context: CGContext, color: UIColor) {
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(color.cgColor); context.setFillColor(color.cgColor)
        context.setLineCap(.round); context.setLineJoin(.round)
        for item in layout.primitives {
            switch item {
            case .text(let value, let font, let baseline):
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color]))
                context.saveGState(); context.translateBy(x: baseline.x, y: baseline.y); context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity; context.textPosition = .zero; CTLineDraw(line, context); context.restoreGState()
            case .line(let a, let b, let width):
                context.setLineWidth(width); context.move(to: a); context.addLine(to: b); context.strokePath()
            case .path(let points, let width):
                guard let first = points.first else { continue }
                context.setLineWidth(width); context.move(to: first)
                for point in points.dropFirst() { context.addLine(to: point) }
                context.strokePath()
            case .ellipse(let rect): context.fillEllipse(in: rect)
            }
        }
    }
    private static func font(_ size: CGFloat, _ style: EquationStyle) -> UIFont {
        switch style {
        case .math, .italic: return UIFont(name: "TimesNewRomanPS-ItalicMT", size: size) ?? .italicSystemFont(ofSize: size)
        case .bold: return UIFont(name: "TimesNewRomanPS-BoldMT", size: size) ?? .boldSystemFont(ofSize: size)
        case .monospace: return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .roman: return UIFont(name: "TimesNewRomanPSMT", size: size) ?? .systemFont(ofSize: size)
        }
    }
    private static func glyph(_ text: String, size: CGFloat, style: EquationStyle) -> EquationLayout {
        let typeface = font(size, style)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: typeface]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return EquationLayout(width: width, ascent: ascent, descent: descent, primitives: text.isEmpty ? [] : [.text(text, typeface, .zero)])
    }
    private static func layout(_ node: EquationNode, size: CGFloat, style: EquationStyle?) throws -> EquationLayout {
        switch node {
        case .glyph(let text, let ownStyle, _): return glyph(text, size: size, style: style ?? ownStyle)
        case .space(let em): return EquationLayout(width: CGFloat(em) * size, ascent: 0, descent: 0, primitives: [])
        case .lineBreak: return EquationLayout(width: 0, ascent: 0, descent: 0, primitives: [])
        case .styled(let next, let child): return try layout(child, size: size, style: next)
        case .operatorSymbol(let symbol, let scale, _): return glyph(symbol, size: size * scale, style: style ?? .roman)
        case .row(let nodes):
            if nodes.contains(.lineBreak) {
                var rows: [[EquationNode]] = [[]]
                for child in nodes { if child == .lineBreak { rows.append([]) } else { rows[rows.count - 1].append(child) } }
                let lines = try rows.map { try layout(.row($0), size: size, style: style) }
                let width = lines.map(\.width).max() ?? 0
                var primitives: [EquationPrimitive] = [], top: CGFloat = 0
                for line in lines {
                    primitives += line.primitives.map { $0.translated(x: 0, y: top + line.ascent) }
                    top += line.ascent + line.descent + size * 0.5
                }
                return EquationLayout(width: width, ascent: lines.first?.ascent ?? size * 0.75,
                                      descent: max(0, top - size * 0.5 - (lines.first?.ascent ?? 0)),
                                      primitives: primitives.map { $0.translated(x: 0, y: -(lines.first?.ascent ?? 0)) })
            }
            var result = EquationLayout(width: 0, ascent: 0, descent: 0, primitives: [])
            var previous: EquationAtom?
            for child in nodes {
                let childLayout = try layout(child, size: size, style: style)
                let atom = child.atomClass
                if let previous { result.width += spacing(previous, atom) * size }
                result.primitives += childLayout.primitives.map { $0.translated(x: result.width, y: 0) }
                result.width += childLayout.width; result.ascent = max(result.ascent, childLayout.ascent); result.descent = max(result.descent, childLayout.descent)
                if case .space = child {} else { previous = atom }
            }
            if nodes.isEmpty { result.ascent = size * 0.7; result.descent = size * 0.15 }
            return result
        case .fraction(let topNode, let bottomNode, let bar):
            let top = try layout(topNode, size: size * 0.87, style: style), bottom = try layout(bottomNode, size: size * 0.87, style: style)
            let padding = size * 0.15, gap = size * 0.14, rule = max(0.8, size * 0.042), axis = -size * 0.25
            let width = max(top.width, bottom.width) + padding * 2
            let topY = axis - gap - rule / 2 - top.descent
            let bottomY = axis + gap + rule / 2 + bottom.ascent
            var primitives = top.primitives.map { $0.translated(x: (width - top.width) / 2, y: topY) }
            primitives += bottom.primitives.map { $0.translated(x: (width - bottom.width) / 2, y: bottomY) }
            if bar { primitives.append(.line(CGPoint(x: 0, y: axis), CGPoint(x: width, y: axis), rule)) }
            return EquationLayout(width: width, ascent: top.ascent - topY, descent: bottomY + bottom.descent, primitives: primitives)
        case .root(let child, let index):
            let content = try layout(child, size: size, style: style)
            let indexLayout = try index.map { try layout($0, size: size * 0.52, style: style) }
            let leading = max(size * 0.5, (indexLayout?.width ?? 0) + size * 0.16)
            let top = -content.ascent - size * 0.1, bottom = content.descent + size * 0.03
            let width = leading + content.width + size * 0.12
            var primitives = content.primitives.map { $0.translated(x: leading + size * 0.05, y: 0) }
            primitives.append(.path([CGPoint(x: leading - size * 0.48, y: -size * 0.13), CGPoint(x: leading - size * 0.34, y: -size * 0.22), CGPoint(x: leading - size * 0.20, y: bottom), CGPoint(x: leading - size * 0.02, y: top), CGPoint(x: width, y: top)], max(0.9, size * 0.045)))
            if let indexLayout { primitives += indexLayout.primitives.map { $0.translated(x: 0, y: top + indexLayout.ascent * 0.65) } }
            return EquationLayout(width: width, ascent: max(-top + size * 0.025, -(top + (indexLayout?.ascent ?? 0) * 0.65) + (indexLayout?.ascent ?? 0)), descent: bottom, primitives: primitives)
        case .scripts(let baseNode, let lowerNode, let upperNode):
            let base = try layout(baseNode, size: size, style: style)
            let lower = try lowerNode.map { try layout($0, size: size * 0.66, style: style) }
            let upper = try upperNode.map { try layout($0, size: size * 0.66, style: style) }
            if case .operatorSymbol(_, _, true) = baseNode {
                let width = max(base.width, lower?.width ?? 0, upper?.width ?? 0)
                var result = EquationLayout(width: width, ascent: base.ascent, descent: base.descent, primitives: base.primitives.map { $0.translated(x: (width - base.width) / 2, y: 0) })
                if let upper {
                    let y = -base.ascent - size * 0.12 - upper.descent
                    result.primitives += upper.primitives.map { $0.translated(x: (width - upper.width) / 2, y: y) }; result.ascent = upper.ascent - y
                }
                if let lower {
                    let y = base.descent + size * 0.12 + lower.ascent
                    result.primitives += lower.primitives.map { $0.translated(x: (width - lower.width) / 2, y: y) }; result.descent = y + lower.descent
                }
                return result
            }
            let x = base.width + size * 0.03
            let upperY = -max(size * 0.46, base.ascent * 0.62)
            var lowerY = max(size * 0.26, base.descent + size * 0.09)
            if let upper, let lower { lowerY = max(lowerY, upperY + upper.descent + size * 0.13 + lower.ascent) }
            var result = base
            if let upper { result.primitives += upper.primitives.map { $0.translated(x: x, y: upperY) }; result.ascent = max(result.ascent, upper.ascent - upperY) }
            if let lower { result.primitives += lower.primitives.map { $0.translated(x: x, y: lowerY) }; result.descent = max(result.descent, lowerY + lower.descent) }
            result.width = x + max(upper?.width ?? 0, lower?.width ?? 0)
            return result
        case .fenced(let left, let child, let right):
            let content = try layout(child, size: size, style: style)
            let total = content.ascent + content.descent
            let delimiterSize = max(size, total * 0.94)
            let a = glyph(left, size: delimiterSize, style: .roman), b = glyph(right, size: delimiterSize, style: .roman)
            let center = (content.descent - content.ascent) / 2
            let aY = center + (a.ascent - a.descent) / 2, bY = center + (b.ascent - b.descent) / 2
            let gap = size * 0.06
            var primitives = a.primitives.map { $0.translated(x: 0, y: aY) }
            primitives += content.primitives.map { $0.translated(x: a.width + gap, y: 0) }
            primitives += b.primitives.map { $0.translated(x: a.width + gap + content.width + gap, y: bY) }
            return EquationLayout(width: a.width + b.width + content.width + gap * 2, ascent: max(content.ascent, a.ascent - aY, b.ascent - bY), descent: max(content.descent, a.descent + aY, b.descent + bY), primitives: primitives)
        case .accent(let kind, let child):
            var result = try layout(child, size: size, style: style)
            let top = -result.ascent - size * 0.10, width = max(size * 0.3, result.width), stroke = max(0.8, size * 0.04)
            if kind == "dot" || kind == "ddot" {
                let diameter = max(1.5, size * 0.065)
                let centers: [CGFloat] = kind == "dot" ? [width / 2] : [width / 2 - size * 0.1, width / 2 + size * 0.1]
                result.primitives += centers.map { .ellipse(CGRect(x: $0 - diameter / 2, y: top - diameter, width: diameter, height: diameter)) }
                result.ascent += size * 0.10 + diameter
            } else if kind == "hat" || kind == "widehat" {
                result.primitives.append(.path([CGPoint(x: 0, y: top), CGPoint(x: width / 2, y: top - size * 0.15), CGPoint(x: width, y: top)], stroke)); result.ascent += size * 0.27
            } else if kind == "tilde" || kind == "widetilde" {
                let mark = glyph("∼", size: max(size * 0.7, width), style: .roman)
                result.primitives += mark.primitives.map { $0.translated(x: (width - mark.width) / 2, y: top + mark.descent) }; result.ascent += mark.ascent - mark.descent + size * 0.10
            } else {
                result.primitives.append(.line(CGPoint(x: 0, y: top), CGPoint(x: width, y: top), stroke))
                if kind == "vec" { result.primitives.append(.path([CGPoint(x: width - size * 0.16, y: top - size * 0.10), CGPoint(x: width, y: top), CGPoint(x: width - size * 0.16, y: top + size * 0.10)], stroke)) }
                result.ascent += size * (kind == "vec" ? 0.22 : 0.13)
            }
            result.width = width; return result
        }
    }
    private static func spacing(_ left: EquationAtom, _ right: EquationAtom) -> CGFloat {
        if left == .open || right == .close { return 0 }
        if left == .relation || right == .relation { return 0.24 }
        if left == .binary || right == .binary { return 0.18 }
        if left == .punctuation { return 0.16 }
        if left == .function && right != .open { return 0.14 }
        if right == .function { return 0.12 }
        return 0
    }
}
