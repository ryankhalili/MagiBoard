import Foundation

struct StarterObject: Identifiable {
    var id: String
    var summary: String
    var keywords: String
    var object: CanvasObject
}

/// Original examples packaged as ordinary editable objects, not special renderer types.
enum StarterObjects {
    static let all: [StarterObject] = {
        let font = ObjectPropertySpec(key: "fontSize", label: "Text size", control: "slider", min: 12, max: 64, step: 1, unit: "pt")
        let fill = ObjectPropertySpec(key: "fillOpacity", label: "Fill", control: "slider", min: 0, max: 1, step: 0.05)
        func item(_ id: String, _ summary: String, _ keywords: String, _ object: CanvasObject) -> StarterObject {
            StarterObject(id: id, summary: summary, keywords: keywords, object: object)
        }
        func graph(_ title: String, _ formula: String, x: ClosedRange<Double>, y: ClosedRange<Double>) -> CanvasObject {
            CanvasObject(kind: "graph", title: title, width: 460, height: 330, color: "#4F46E5", text: formula,
                properties: ["amplitude": 1, "frequency": 1, "c": 0, "xMin": x.lowerBound, "xMax": x.upperBound, "yMin": y.lowerBound, "yMax": y.upperBound],
                propertySpecs: [
                    ObjectPropertySpec(key: "amplitude", label: "Amplitude", control: "slider", min: 0.1, max: 5, step: 0.1),
                    ObjectPropertySpec(key: "frequency", label: "Horizontal scale", control: "slider", min: 0.1, max: 4, step: 0.1),
                    ObjectPropertySpec(key: "c", label: "Vertical shift", control: "slider", min: -5, max: 5, step: 0.1)
                ])
        }
        func equation(_ title: String, _ source: String, width: Double = 520) -> CanvasObject {
            CanvasObject(kind: "latex", title: title, width: width, height: 125, color: "#263445", text: source,
                         properties: ["fontSize": 32], propertySpecs: [font])
        }
        var coin = LocalAssistant.respond(prompt: "Create a coin", objects: []).operations[0].object!
        coin.title = "Coin multiplier"
        var result = [
            item("triangle", "Three angles you can adjust.", "geometry angles polygon",
                 CanvasObject(kind: "shape", title: "Triangle", width: 300, height: 260, color: "#2563EB",
                    properties: ["angleA": 49, "angleB": 52, "angleC": 79, "fillOpacity": 0.16], shape: "triangle", propertySpecs: [fill])),
            item("right-triangle", "A right angle and two 45° angles.", "geometry trigonometry pythagorean",
                 CanvasObject(kind: "shape", title: "Right triangle", width: 300, height: 260, color: "#059669",
                    properties: ["angleA": 90, "angleB": 45, "angleC": 45, "fillOpacity": 0.12], shape: "triangle", propertySpecs: [fill])),
            item("circle", "A simple circle for your diagrams.", "geometry round diagram",
                 CanvasObject(kind: "shape", title: "Circle", width: 220, height: 220, color: "#7C3AED",
                    properties: ["recognizedOutline": 1, "fillOpacity": 0.12, "strokeWidth": 3], shape: "circle", propertySpecs: [fill])),
            item("square", "A clean square with adjustable fill.", "geometry rectangle diagram",
                 CanvasObject(kind: "shape", title: "Square", width: 220, height: 220, color: "#D97706",
                    properties: ["recognizedOutline": 1, "fillOpacity": 0.12, "strokeWidth": 3, "cornerRadius": 0], shape: "rectangle", propertySpecs: [fill])),
            item("sine", "Explore amplitude, frequency, and shift.", "graph waves trigonometry sine periodic",
                 graph("Sine wave", "sin(x)", x: -6.28...6.28, y: -2...2)),
            item("parabola", "A quadratic with a movable intercept.", "graph quadratic function parabola",
                 graph("Parabola", "x^2", x: -4...4, y: -2...12)),
            item("decay", "An exponential decay curve.", "graph function exponential physics",
                 graph("Exponential decay", "exp(-x)", x: 0...6, y: -0.2...1.5)),
            item("quadratic-formula", "Editable fractions, a radical, and scripts.", "equation algebra quadratic latex",
                 equation("Quadratic formula", #"x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}"#)),
            item("gaussian", "An improper integral and its exact value.", "equation calculus integral gaussian latex",
                 equation("Gaussian integral", #"\int_0^\infty e^{-x^2}\,dx=\frac{\sqrt{\pi}}{2}"#)),
            item("series", "An infinite series with stacked limits.", "equation calculus sum series latex",
                 equation("Basel series", #"\sum_{n=1}^\infty\frac{1}{n^2}=\frac{\pi^2}{6}"#)),
            item("heading", "Start a new topic with a clear heading.", "note text title heading",
                 CanvasObject(kind: "text", title: "Heading", width: 500, height: 70, color: "#263445", text: "A new idea",
                    properties: ["fontSize": 36, "bold": 1], propertySpecs: [font])),
            item("note", "An editable note with space for a key idea.", "note text callout summary",
                 CanvasObject(kind: "text", title: "Key idea", width: 360, height: 190, color: "#263445",
                    text: "Key idea\n\nWrite a definition, a question, or the next thing to explore.",
                    properties: ["fontSize": 20, "card": 1], propertySpecs: [font])),
            item("checklist", "A text checklist to plan a session.", "note text checklist plan study",
                 CanvasObject(kind: "text", title: "Study checklist", width: 360, height: 200, color: "#263445",
                    text: "Study plan\n\n□ Review the key idea\n□ Work through an example\n□ Write down a question",
                    properties: ["fontSize": 20], propertySpecs: [font])),
            item("page", "A portrait page region for notes or exports.", "paper page frame document A4",
                 CanvasObject(kind: "frame", title: "Page", width: 595, height: 842, color: "#64748B", properties: ["paper": 1])),
            item("coin", "Tap in Interact mode to duplicate onto the canvas.", "widget interactive coin duplicate counter", coin),
            item("pendulum", "Explore length, gravity, amplitude, and time.", "widget animation physics pendulum simulation",
                 CanvasObject(kind: "widget", title: "Pendulum", width: 420, height: 320, color: "#2563EB",
                    properties: ["length": 1.5, "gravity": 9.81, "amplitude": 30, "speed": 1, "paused": 0], code: pendulum,
                    propertySpecs: [
                        ObjectPropertySpec(key: "length", label: "Length", control: "slider", min: 0.3, max: 3, step: 0.1, unit: "m"),
                        ObjectPropertySpec(key: "gravity", label: "Gravity", control: "slider", min: 1, max: 20, step: 0.1, unit: "m/s²"),
                        ObjectPropertySpec(key: "amplitude", label: "Release angle", control: "slider", min: 5, max: 70, step: 1, unit: "°"),
                        ObjectPropertySpec(key: "speed", label: "Playback speed", control: "slider", min: 0, max: 3, step: 0.1),
                        ObjectPropertySpec(key: "paused", label: "Paused", control: "toggle")
                    ]))
        ]
        // Stable identities make previews and SwiftUI rows consistent. Insertion creates new IDs.
        for index in result.indices {
            result[index].object.id = UUID(uuidString: String(format: "8B62D1B0-78D5-4B40-9900-%012d", index + 1))!
            result[index].object.x = 0; result[index].object.y = 0
        }
        return result
    }()
    private static let pendulum = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
    body{margin:0;background:transparent;color:#334155;font:14px -apple-system,sans-serif;text-align:center}
    canvas{display:block;width:100%;height:264px}footer{display:flex;justify-content:center;align-items:center;gap:18px}
    button{font:inherit;border:0;border-radius:9px;padding:9px 15px;background:#e0e7ff;color:#3730a3}
    </style></head><body><canvas width="420" height="264" aria-label="Animated pendulum"></canvas><footer><span id="period"></span><button>Pause</button></footer><script>
    const c=document.querySelector('canvas'),g=c.getContext('2d'),button=document.querySelector('button');
    let time=0,last=performance.now();function frame(now){const p=canvasProperties;const dt=Math.min(.05,(now-last)/1000);last=now;
    if(!p.paused)time+=dt*p.speed;const omega=Math.sqrt(p.gravity/p.length),angle=p.amplitude*Math.PI/180*Math.cos(time*omega);
    const rod=60+p.length*42,x=210+rod*Math.sin(angle),y=35+rod*Math.cos(angle);g.clearRect(0,0,420,264);
    g.strokeStyle='#64748b';g.lineWidth=3;g.beginPath();g.moveTo(210,35);g.lineTo(x,y);g.stroke();
    g.fillStyle='#2563eb';g.beginPath();g.arc(x,y,17,0,Math.PI*2);g.fill();g.fillStyle='#475569';g.beginPath();g.arc(210,35,5,0,Math.PI*2);g.fill();
    document.querySelector('#period').textContent='Small-angle period: '+(2*Math.PI/omega).toFixed(2)+' s';button.textContent=p.paused?'Resume':'Pause';requestAnimationFrame(frame)}requestAnimationFrame(frame);
    button.onclick=async()=>{try{await canvasHost.update(canvasObject.id,{properties:{paused:canvasProperties.paused?0:1}})}catch(error){button.title=error.message}};
    </script></body></html>
    """
}
