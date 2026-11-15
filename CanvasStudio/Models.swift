import Foundation
import CoreGraphics

struct CanvasRect: Codable, Equatable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 0
    var height: Double = 0
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    init(_ rect: CGRect) {
        x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height
    }
}

struct PropertyChoice: Codable, Equatable {
    var label: String
    var value: Double
}

struct ObjectPropertySpec: Codable, Equatable, Identifiable {
    var key: String
    var label: String
    var control: String = "number"
    var min: Double?
    var max: Double?
    var step: Double?
    var unit: String = ""
    var choices: [PropertyChoice] = []
    var id: String { key }
    init(key: String, label: String, control: String = "number", min: Double? = nil, max: Double? = nil,
         step: Double? = nil, unit: String = "", choices: [PropertyChoice] = []) {
        self.key = key; self.label = label; self.control = control; self.min = min; self.max = max
        self.step = step; self.unit = unit; self.choices = choices
    }
    enum CodingKeys: String, CodingKey { case key, label, control, min, max, step, unit, choices }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        control = try c.decodeIfPresent(String.self, forKey: .control) ?? "number"
        min = try c.decodeIfPresent(Double.self, forKey: .min); max = try c.decodeIfPresent(Double.self, forKey: .max)
        step = try c.decodeIfPresent(Double.self, forKey: .step)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        choices = try c.decodeIfPresent([PropertyChoice].self, forKey: .choices) ?? []
    }
}

struct CanvasTaskRegion: Identifiable, Equatable {
    var id: UUID
    var rect: CanvasRect
    var label: String
}

struct CanvasObject: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: String
    var title: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var color: String
    var text: String
    var properties: [String: Double]
    var propertySpecs: [ObjectPropertySpec]
    var code: String
    var imageData: Data?
    var shape: String
    var pattern: String
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(id: UUID = UUID(), kind: String = "shape", title: String = "Object", x: Double = 160, y: Double = 160,
         width: Double = 260, height: Double = 200, color: String = "#2563EB", text: String = "",
         properties: [String: Double] = [:], code: String = "", imageData: Data? = nil,
         shape: String = "rectangle", pattern: String = "solid", propertySpecs: [ObjectPropertySpec] = []) {
        self.id = id; self.kind = kind; self.title = title; self.x = x; self.y = y
        self.width = width; self.height = height; self.color = color; self.text = text
        self.properties = properties; self.code = code; self.imageData = imageData
        self.shape = shape; self.pattern = pattern; self.propertySpecs = propertySpecs
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, x, y, width, height, color, text, properties, propertySpecs, code, imageData, shape, pattern
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "shape"
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Object"
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 160
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 160
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 260
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 200
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#2563EB"
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        properties = try c.decodeIfPresent([String: Double].self, forKey: .properties) ?? [:]
        propertySpecs = try c.decodeIfPresent([ObjectPropertySpec].self, forKey: .propertySpecs) ?? []
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        shape = try c.decodeIfPresent(String.self, forKey: .shape) ?? "rectangle"
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? "solid"
    }
}

struct Notebook: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var title: String = "Untitled notebook"
    var objects: [CanvasObject] = []
    var drawingData: Data = Data()
    var updatedAt: Date = Date()
    var schemaVersion: Int = 1

    static func welcome() -> Notebook {
        Notebook(title: "A little room for big ideas", objects: [
            CanvasObject(kind: "text", title: "Exploring motion", x: 100, y: 90, width: 760, height: 65,
                         color: "#172534", text: "A little room for big ideas.", properties: ["fontSize": 36]),
            CanvasObject(kind: "text", title: "Introduction", x: 104, y: 162, width: 760, height: 54,
                         color: "#64748B", text: "Write freely. Make something interactive. Follow your curiosity.", properties: ["fontSize": 17]),
            CanvasObject(kind: "text", title: "Geometry label", x: 122, y: 255, width: 320, height: 36,
                         color: "#64748B", text: "01   A DIFFERENT ANGLE", properties: ["fontSize": 13]),
            CanvasObject(kind: "shape", title: "A triangle with exact angles", x: 145, y: 325, width: 270, height: 230,
                         color: "#3B82F6", properties: ["angleA": 49, "angleB": 52, "angleC": 79, "fillOpacity": 0.16], shape: "triangle"),
            CanvasObject(kind: "text", title: "Angle equation", x: 138, y: 575, width: 310, height: 55,
                         color: "#334155", text: "49° + 52° + 79° = 180°", properties: ["fontSize": 20]),
            CanvasObject(kind: "graph", title: "A wave you can change", x: 510, y: 270, width: 460, height: 330,
                         color: "#2563EB", text: "sin(x)", properties: ["amplitude": 1, "frequency": 1, "c": 0, "xMin": -6.28, "xMax": 6.28, "yMin": -2, "yMax": 2]),
            CanvasObject(kind: "text", title: "Graph hint", x: 528, y: 618, width: 440, height: 50,
                         color: "#64748B", text: "Select the graph. Adjust its amplitude or shift it up.", properties: ["fontSize": 15]),
            CanvasObject(kind: "text", title: "Magic hint", x: 125, y: 714, width: 820, height: 64,
                         color: "#64748B", text: "✦  Try Magic Pen: “Make the triangle green with a starry pattern.”", properties: ["fontSize": 16])
        ])
    }
}

struct NotebookSummary: Identifiable, Equatable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var objectCount: Int
}

enum CanvasTool: String, CaseIterable, Codable, Identifiable {
    case pen, pencil, highlighter, eraser, lasso, select, hand, magic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pen: return "Pen"
        case .pencil: return "Pencil"
        case .highlighter: return "Highlighter"
        case .eraser: return "Eraser"
        case .lasso: return "Ink lasso"
        case .select: return "Select objects"
        case .hand: return "Move canvas"
        case .magic: return "Magic Pen"
        }
    }
    var icon: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .select: return "cursorarrow"
        case .hand: return "hand.draw"
        case .magic: return "wand.and.stars"
        }
    }
}

struct StudioSettings: Codable, Equatable {
    var aiEnabled = true
    var darkMode = false
    var drawWithFinger = false
    var recognizeShapes = false
    var showGrid = true
    var paperStyle = "dots"
    var toolbarCollapsed = false
    var compactHeader = false
    var magicOnboardingSeen = false
    var voiceMode = false
    var spokenReplies = true
    var speechLocale = "en-US"
    var bridgeURL = ""
    var bridgeToken = ""
    // The pairing secret lives in Keychain, never in notebook or settings JSON.
    enum CodingKeys: String, CodingKey {
        case aiEnabled, darkMode, drawWithFinger, recognizeShapes, showGrid, paperStyle, toolbarCollapsed, compactHeader, magicOnboardingSeen, voiceMode, spokenReplies, speechLocale, bridgeURL
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aiEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? true
        darkMode = try c.decodeIfPresent(Bool.self, forKey: .darkMode) ?? false
        drawWithFinger = try c.decodeIfPresent(Bool.self, forKey: .drawWithFinger) ?? false
        recognizeShapes = try c.decodeIfPresent(Bool.self, forKey: .recognizeShapes) ?? false
        showGrid = try c.decodeIfPresent(Bool.self, forKey: .showGrid) ?? true
        paperStyle = try c.decodeIfPresent(String.self, forKey: .paperStyle) ?? "dots"
        toolbarCollapsed = try c.decodeIfPresent(Bool.self, forKey: .toolbarCollapsed) ?? false
        compactHeader = try c.decodeIfPresent(Bool.self, forKey: .compactHeader) ?? false
        magicOnboardingSeen = try c.decodeIfPresent(Bool.self, forKey: .magicOnboardingSeen) ?? false
        voiceMode = try c.decodeIfPresent(Bool.self, forKey: .voiceMode) ?? false
        spokenReplies = try c.decodeIfPresent(Bool.self, forKey: .spokenReplies) ?? true
        speechLocale = try c.decodeIfPresent(String.self, forKey: .speechLocale) ?? "en-US"
        bridgeURL = try c.decodeIfPresent(String.self, forKey: .bridgeURL) ?? ""
    }
}

struct AgentOperation: Codable, Equatable {
    var type: String
    var id: UUID?
    var object: CanvasObject?
    init(type: String, id: UUID? = nil, object: CanvasObject? = nil) {
        self.type = type; self.id = id; self.object = object
    }
}
struct AgentResponse: Codable, Equatable {
    var message: String
    var operations: [AgentOperation]
}

enum NotebookError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

// One validation boundary for imported notebooks and agent-generated changes.
enum NotebookValidation {
    static func validate(_ object: CanvasObject) throws {
        guard ["text", "shape", "graph", "image", "widget", "latex", "frame"].contains(object.kind) else {
            throw NotebookError.invalid("Unsupported object type: \(object.kind)")
        }
        guard [object.x, object.y, object.width, object.height].allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }),
              object.width >= 1, object.height >= 1, object.width <= 100_000, object.height <= 100_000 else {
            throw NotebookError.invalid("An object has invalid position or dimensions.")
        }
        guard object.properties.count <= 128, object.properties.values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }) else {
            throw NotebookError.invalid("An object has invalid properties.")
        }
        guard object.propertySpecs.count <= 64, Set(object.propertySpecs.map(\.key)).count == object.propertySpecs.count else {
            throw NotebookError.invalid("Property controls must have unique names.")
        }
        for spec in object.propertySpecs {
            guard let value = object.properties[spec.key], !spec.key.isEmpty, spec.key.count <= 80, spec.label.count <= 200,
                  ["number", "slider", "toggle", "choice"].contains(spec.control), spec.unit.count <= 40,
                  [spec.min, spec.max, spec.step].compactMap({ $0 }).allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }),
                  spec.step.map({ $0 >= 0.000000001 }) ?? true, spec.choices.count <= 40,
                  spec.choices.allSatisfy({ $0.value.isFinite && abs($0.value) <= 1_000_000_000 && $0.label.count <= 200 }) else {
                throw NotebookError.invalid("An exposed property control is invalid.")
            }
            if let lo = spec.min, let hi = spec.max, lo >= hi { throw NotebookError.invalid("A property range must increase.") }
            if (spec.min.map { value < $0 } ?? false) || (spec.max.map { value > $0 } ?? false) {
                throw NotebookError.invalid("A property value lies outside its declared control range.")
            }
            if spec.control == "slider", spec.min == nil || spec.max == nil || spec.step == nil {
                throw NotebookError.invalid("A slider needs minimum, maximum, and positive step values.")
            }
            if spec.control == "toggle", value != 0 && value != 1 {
                throw NotebookError.invalid("Toggle properties must be zero or one.")
            }
            if spec.control == "choice", !spec.choices.contains(where: { $0.value == value }) {
                throw NotebookError.invalid("A choice property must use a declared choice value.")
            }
        }
        if object.kind == "shape", object.shape == "triangle" {
            let a = object.properties["angleA"] ?? 49
            let b = object.properties["angleB"] ?? 52
            let c = object.properties["angleC"] ?? (180 - a - b)
            guard a > 0, b > 0, c > 0, a < 180, b < 180, c < 180,
                  abs(a + b + c - 180) < 0.001 else {
                throw NotebookError.invalid("Triangle angles must be positive and add to 180°.")
            }
        }
        guard object.title.utf8.count <= 4096, object.text.utf8.count <= 262_144,
              object.code.utf8.count <= 524_288, (object.imageData?.count ?? 0) <= 20_000_000 else {
            throw NotebookError.invalid("An object is too large to import safely.")
        }
        guard object.color.range(of: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$", options: .regularExpression) != nil else {
            throw NotebookError.invalid("Object colors must use a hexadecimal color such as #2563EB.")
        }
    }
    static func validate(_ notebook: Notebook) throws {
        guard notebook.schemaVersion == 1 else { throw NotebookError.invalid("This notebook uses a newer format. Update MagiBoard to open it.") }
        guard notebook.objects.count <= 2000, notebook.drawingData.count <= 40_000_000, notebook.title.utf8.count <= 4096 else {
            throw NotebookError.invalid("This notebook exceeds the prototype’s document size limit.")
        }
        guard Set(notebook.objects.map(\.id)).count == notebook.objects.count else {
            throw NotebookError.invalid("The notebook contains duplicate object identifiers.")
        }
        for object in notebook.objects { try validate(object) }
    }
}

/// A small, explicit offline command set. This is not an AI model.
enum LocalAssistant {
    static func respond(prompt: String, objects: [CanvasObject], reference: CanvasRect? = nil,
                        selectedIDs: Set<UUID> = []) -> AgentResponse {
        let request = prompt.lowercased()
        let point = reference ?? CanvasRect(x: 200, y: 240, width: 0, height: 0)
        let selected = objects.filter { selectedIDs.contains($0.id) }
        let nearby = objects.filter { object in
            guard let reference else { return false }
            return reference.width < 5 && reference.height < 5
                ? object.rect.insetBy(dx: -40, dy: -40).contains(CGPoint(x: reference.x, y: reference.y))
                : object.rect.intersects(reference.cgRect)
        }
        let pool = selected.isEmpty ? nearby : selected
        let candidates = pool.isEmpty ? objects : pool
        var target: CanvasObject?
        if request.contains("triangle") { target = candidates.last { $0.shape == "triangle" } }
        else if request.contains("graph") || request.contains("wave") { target = candidates.last { $0.kind == "graph" } }
        else { target = pool.last ?? objects.last { $0.kind == "shape" || $0.kind == "graph" } }
        let asksForNew = request.contains("make a ") || request.contains("create ") || request.contains("add ") || request.contains("draw ") || request.contains("plot ")
        let colors: [(String, String)] = [("green", "#16A34A"), ("blue", "#2563EB"), ("purple", "#8B5CF6"), ("orange", "#F97316"), ("red", "#EF4444"), ("pink", "#EC4899"), ("yellow", "#EAB308"), ("black", "#172534")]
        let requestedColor = colors.first { request.contains($0.0) }?.1
        let wantsStars = request.contains("starr") || request.contains("star pattern")
        let wantsAngles = request.range(of: #"\bangles?\b"#, options: .regularExpression) != nil
        if !asksForNew, var object = target,
           requestedColor != nil || wantsStars || wantsAngles || request.contains("intercept") {
            if let color = requestedColor { object.color = color }
            if wantsStars { object.pattern = "stars" }
            if wantsAngles, object.shape == "triangle" {
                let values = numbers(in: request)
                if values.count >= 2, values[0] > 0, values[1] > 0, values[0] + values[1] < 180 {
                    object.properties["angleA"] = values[0]; object.properties["angleB"] = values[1]
                    object.properties["angleC"] = 180 - values[0] - values[1]
                } else { return AgentResponse(message: "Offline commands need two positive angles whose sum is below 180°.", operations: []) }
            }
            if request.contains("intercept"), object.kind == "graph", let value = numbers(in: request).first { object.properties["c"] = value }
            return AgentResponse(message: "Updated \(object.title). Offline command applied.", operations: [AgentOperation(type: "update", id: object.id, object: object)])
        }
        if request.contains("duplicate"), let object = target, !request.contains("coin") {
            var copy = object; copy.id = UUID(); copy.x += 36; copy.y += 36
            return AgentResponse(message: "Duplicated the object. Offline command applied.", operations: [AgentOperation(type: "add", object: copy)])
        }
        var object: CanvasObject
        if request.contains("triangle") {
            var angles = [49.0, 52.0]
            let values = numbers(in: request)
            if values.count >= 2, values[0] > 0, values[1] > 0, values[0] + values[1] < 180 { angles = Array(values.prefix(2)) }
            object = CanvasObject(kind: "shape", title: "Triangle", x: point.x, y: point.y, width: 300, height: 250,
                                  color: requestedColor ?? "#2563EB", properties: ["angleA": angles[0], "angleB": angles[1], "angleC": 180 - angles[0] - angles[1], "fillOpacity": 0.18], shape: "triangle", pattern: wantsStars ? "stars" : "solid")
        } else if request.contains("graph") || request.contains("plot") || request.contains("sin(") || request.contains("wave") {
            let formula = request.contains("x²") || request.contains("x^2") || request.contains("parabola") ? "x^2" : "sin(x)"
            object = CanvasObject(kind: "graph", title: formula == "sin(x)" ? "Sine wave" : "Parabola", x: point.x, y: point.y, width: 460, height: 320,
                                  color: requestedColor ?? "#2563EB", text: formula, properties: ["amplitude": 1, "frequency": 1, "c": 0, "xMin": -6.28, "xMax": 6.28, "yMin": -2, "yMax": formula == "x^2" ? 12 : 2])
        } else if request.contains("circle") || request.contains("square") || request.contains("rectangle") {
            let circle = request.contains("circle")
            object = CanvasObject(kind: "shape", title: circle ? "Circle" : "Rectangle", x: point.x, y: point.y, width: 220, height: 220,
                                  color: requestedColor ?? "#8B5CF6", properties: ["fillOpacity": 0.2], shape: circle ? "ellipse" : "rectangle", pattern: wantsStars ? "stars" : "solid")
        } else if request.contains("coin") {
            object = CanvasObject(kind: "widget", title: "Coin multiplier", x: point.x, y: point.y, width: 110, height: 110,
                                  color: "#EAB308", properties: ["value": 1], code: coinCode,
                                  propertySpecs: [ObjectPropertySpec(key: "value", label: "Value", control: "number", min: 1, max: 1000, step: 1)])
        } else if request.contains("animate") || request.contains("animation") || request.contains("pendulum") {
            object = CanvasObject(kind: "widget", title: "Pendulum laboratory", x: point.x, y: point.y, width: 420, height: 320,
                                  color: "#2563EB", properties: ["speed": 1], code: pendulumCode)
        } else if request.contains("latex") || request.contains("equation") {
            object = CanvasObject(kind: "latex", title: "Equation", x: point.x, y: point.y, width: 380, height: 120,
                                  color: "#172534", text: "y = A\\sin(\\omega x) + C", properties: ["fontSize": 28])
        } else {
            return AgentResponse(message: "Offline mode supports triangles, circles, graphs, colors, star patterns, coins and pendulums. Connect Codex in Settings for open-ended requests.", operations: [])
        }
        return AgentResponse(message: "Created \(object.title). Offline command applied.", operations: [AgentOperation(type: "add", object: object)])
    }
    private static func numbers(in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: "-?[0-9]+(?:\\.[0-9]+)?") else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).flatMap { Double(text[$0]) }
        }
    }
    private static let coinCode = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
    html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;display:grid;place-items:center}
    button{width:82%;aspect-ratio:1;border:5px solid #ca8a04;border-radius:50%;background:radial-gradient(circle at 30% 25%,#fef08a,#eab308);box-shadow:inset 0 0 0 5px #fde047;color:#854d0e;font:bold 44px system-ui;cursor:pointer;touch-action:manipulation}
    </style></head><body><button aria-label="Duplicate coin">1</button><script>
    function refresh(){document.querySelector('button').textContent=canvasProperties.value||1}refresh();window.addEventListener('canvaspropertieschange',refresh);
    document.querySelector('button').onclick=async()=>{try{await canvasHost.duplicate(canvasObject.id,{dx:canvasObject.width+24,dy:0})}catch(e){document.querySelector('button').title=e.message}};
    </script></body></html>
    """
    private static let pendulumCode = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
    body{margin:0;background:#f8fafc;font:14px -apple-system,sans-serif;color:#334155;text-align:center}h3{margin:19px 0 0;font-size:17px}canvas{display:block;margin:auto}label{display:flex;align-items:center;justify-content:center;gap:12px}input{accent-color:#2563eb}
    </style></head><body><h3>Pendulum laboratory</h3><canvas width="400" height="220" id="c"></canvas><label>Speed<input type="range" min="0" max="3" step=".1" value="1" id="speed"></label><script>
    const c=document.getElementById('c'),ctx=c.getContext('2d');let t=0,prev=performance.now();function draw(now){t+=(now-prev)/1000*Number(document.getElementById('speed').value);prev=now;const a=.65*Math.sin(t*2),x=200+145*Math.sin(a),y=30+145*Math.cos(a);ctx.clearRect(0,0,400,220);ctx.strokeStyle='#94a3b8';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(200,30);ctx.lineTo(x,y);ctx.stroke();ctx.fillStyle='#2563eb';ctx.beginPath();ctx.arc(x,y,19,0,Math.PI*2);ctx.fill();ctx.fillStyle='#64748b';ctx.beginPath();ctx.arc(200,30,5,0,Math.PI*2);ctx.fill();requestAnimationFrame(draw)}requestAnimationFrame(draw);
    </script></body></html>
    """
}
