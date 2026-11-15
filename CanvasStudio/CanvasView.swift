import SwiftUI
import UIKit
import PencilKit

struct NativeCanvas: UIViewRepresentable {
    @ObservedObject var store: NotebookStore
    var onReference: (() -> Void)? = nil

    func makeUIView(context: Context) -> CanvasHostView {
        let view = CanvasHostView(store: store)
        view.onReference = onReference
        return view
    }
    func updateUIView(_ uiView: CanvasHostView, context: Context) {
        uiView.onReference = onReference
        uiView.synchronize()
    }
}

@MainActor
final class CanvasHostView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    private let store: NotebookStore
    private let surface = CanvasSurfaceView()
    let ink = PKCanvasView()
    // PencilKit only accepts input inside its positive native content bounds.
    // Notebook geometry remains in world coordinates; this origin can rebase as we pan.
    private(set) var inkOrigin = CGPoint(x: 32768, y: 32768)
    var worldContentOffset: CGPoint {
        CGPoint(x: ink.contentOffset.x - inkOrigin.x * ink.zoomScale, y: ink.contentOffset.y - inkOrigin.y * ink.zoomScale)
    }
    var worldDrawing: PKDrawing {
        ink.drawing.transformed(using: CGAffineTransform(translationX: -inkOrigin.x, y: -inkOrigin.y))
    }
    private let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    private let widgetLayer = PassThroughView()
    private var widgets: [UUID: CanvasWidgetView] = [:]
    private var activeWidgetID: UUID?
    private var navigationPan: UIPanGestureRecognizer!
    private var navigationStartOffset: CGPoint?
    private var selectionPan: UIPanGestureRecognizer!
    private var selectionTap: UITapGestureRecognizer!
    private var widgetTap: UITapGestureRecognizer!
    private var pencilInteraction = UIPencilInteraction()
    private var lastDrawing = Data()
    private var lastNativeDrawing = Data()
    private var notebookID: UUID?
    private var isApplyingDrawing = false
    private var pendingInitialFit = true
    private var startPoint: CGPoint?
    private var referenceBeforeDrag: CanvasRect?
    private var dragOriginals: [CanvasObject] = []
    private var resizingID: UUID?
    private var marquee: CGRect?
    private var lastReportedZoom: Double = 1
        private var queuedCameraUpdate = false
    private var previousTool: CanvasTool = .pen
    private var toolSignature = ""
    private var inputSignature = ""
    var onReference: (() -> Void)?

    init(store: NotebookStore) {
        self.store = store
        super.init(frame: .zero)
        accessibilityIdentifier = "infiniteCanvas"
        accessibilityLabel = "Infinite whiteboard"
        isAccessibilityElement = false
        clipsToBounds = true
        addSubview(surface)
        ink.backgroundColor = .clear; ink.isOpaque = false
        ink.delegate = self
        lastNativeDrawing = ink.drawing.dataRepresentation()
        ink.contentSize = CGSize(width: 65536, height: 65536)
        ink.contentInset = .zero
        ink.contentInsetAdjustmentBehavior = .never
        ink.keyboardDismissMode = .interactive
        ink.minimumZoomScale = 0.15; ink.maximumZoomScale = 4
        ink.isScrollEnabled = true
        ink.bounces = true; ink.bouncesZoom = true
        ink.showsVerticalScrollIndicator = false; ink.showsHorizontalScrollIndicator = false
        ink.alwaysBounceHorizontal = true; ink.alwaysBounceVertical = true
        ink.panGestureRecognizer.minimumNumberOfTouches = 2
        ink.drawingPolicy = .pencilOnly
        ink.accessibilityIdentifier = "pencilCanvas"
        addSubview(ink)
        addSubview(widgetLayer)

        navigationPan = UIPanGestureRecognizer(target: self, action: #selector(panCanvas(_:)))
        navigationPan.minimumNumberOfTouches = 1
        navigationPan.maximumNumberOfTouches = 1
        navigationPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        navigationPan.delegate = self
        ink.addGestureRecognizer(navigationPan)

        selectionPan = UIPanGestureRecognizer(target: self, action: #selector(panSelection(_:)))
        selectionPan.minimumNumberOfTouches = 1; selectionPan.maximumNumberOfTouches = 1
        selectionPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        selectionPan.delegate = self
        ink.addGestureRecognizer(selectionPan)
        selectionTap = UITapGestureRecognizer(target: self, action: #selector(tapSelection(_:)))
        selectionTap.delegate = self
        ink.addGestureRecognizer(selectionTap)
        widgetTap = UITapGestureRecognizer(target: self, action: #selector(activateWidget(_:)))
        widgetTap.numberOfTapsRequired = 2; widgetTap.delegate = self
        ink.addGestureRecognizer(widgetTap)
        selectionTap.require(toFail: widgetTap)
        pencilInteraction.delegate = self; ink.addInteraction(pencilInteraction)
        NotificationCenter.default.addObserver(self, selector: #selector(fitContent), name: .canvasFitContent, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(focusObject(_:)), name: .canvasFocusObject, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetCamera), name: .canvasResetCamera, object: nil)
        synchronize()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds; ink.frame = bounds; widgetLayer.frame = bounds
        if pendingInitialFit, bounds.width > 200, bounds.height > 300 {
            pendingInitialFit = false
            if !store.notebook.objects.isEmpty || !ink.drawing.strokes.isEmpty { fitCanvas(animated: false) }
            else { ink.setContentOffset(inkOrigin, animated: false) }
        }
        updateCamera()
    }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "m", modifierFlags: [.command, .shift], action: #selector(toggleMagic)),
         UIKeyCommand(input: "0", modifierFlags: [.command], action: #selector(fitContent)),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(endInteraction))]
    }
    @objc private func toggleMagic() {
        guard store.settings.aiEnabled else { return }
        store.tool = store.tool == .magic ? .pen : .magic
    }
    @objc private func endInteraction() {
        activeWidgetID = nil; store.selectedIDs = []; store.reference = nil
        if store.tool == .magic { store.tool = .pen }
        synchronize()
    }
    @objc private func resetCamera() {
        ink.setZoomScale(1, animated: false)
        ink.setContentOffset(inkOrigin, animated: true)
    }
    @objc private func fitContent() { fitCanvas(animated: true) }
    @objc private func focusObject(_ notification: Notification) {
        guard let id = notification.object as? UUID,
              let object = store.notebook.objects.first(where: { $0.id == id }) else { return }
        let usable = CGRect(x: 40, y: 150, width: max(100, bounds.width - 360), height: max(100, bounds.height - 250))
        let rect = object.rect.insetBy(dx: -30, dy: -30)
        let scale = min(1.5, max(ink.minimumZoomScale, min(usable.width / rect.width, usable.height / rect.height)))
        ink.setZoomScale(scale, animated: false)
        ink.setContentOffset(CGPoint(x: (rect.midX + inkOrigin.x) * scale - usable.midX,
                                    y: (rect.midY + inkOrigin.y) * scale - usable.midY), animated: true)
        store.selectedIDs = [id]
    }
    private func fitCanvas(animated: Bool) {
        var rect = store.notebook.objects.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        let inkBounds = worldDrawing.bounds
        if !inkBounds.isNull && !inkBounds.isEmpty { rect = rect.union(inkBounds) }
        guard !rect.isNull, bounds.width > 1, bounds.height > 1 else { resetCamera(); return }
        rect = rect.insetBy(dx: -14, dy: -14)
        let usable = CGRect(x: 70, y: 160, width: max(100, bounds.width - 140), height: max(100, bounds.height - 260))
        let zoom = min(1, max(ink.minimumZoomScale, min(usable.width / rect.width, usable.height / rect.height)))
        ink.setZoomScale(zoom, animated: false)
        ink.setContentOffset(CGPoint(x: (rect.midX + inkOrigin.x) * zoom - usable.midX, y: (rect.midY + inkOrigin.y) * zoom - usable.midY), animated: animated)
    }

    func synchronize() {
        let dark = store.settings.darkMode
        backgroundColor = dark ? UIColor(red: 0.075, green: 0.09, blue: 0.12, alpha: 1) : UIColor(red: 0.975, green: 0.979, blue: 0.985, alpha: 1)
        surface.backgroundColor = backgroundColor
        surface.objects = store.notebook.objects
        surface.selectedIDs = store.selectedIDs
        surface.reference = store.reference?.cgRect
        surface.dark = dark; surface.showGrid = store.settings.showGrid; surface.paperStyle = store.settings.paperStyle
        if notebookID != store.notebook.id {
            notebookID = store.notebook.id; activeWidgetID = nil
            pendingInitialFit = true; setNeedsLayout()
            ink.undoManager?.removeAllActions()
            ink.setZoomScale(1, animated: false)
            ink.setContentOffset(inkOrigin, animated: false)
        }
        if lastDrawing != store.notebook.drawingData {
            isApplyingDrawing = true
            let drawing = (try? PKDrawing(data: store.notebook.drawingData)) ?? PKDrawing()
            ink.drawing = drawing.transformed(using: CGAffineTransform(translationX: inkOrigin.x, y: inkOrigin.y))
            lastNativeDrawing = ink.drawing.dataRepresentation()
            lastDrawing = store.notebook.drawingData
            isApplyingDrawing = false
        }
        let color = UIColor(studioHex: store.colorHex)
        let nextToolSignature = "\(store.tool.rawValue)|\(store.colorHex)|\(store.lineWidth)"
        if nextToolSignature != toolSignature {
        toolSignature = nextToolSignature
        switch store.tool {
        case .pen: ink.tool = PKInkingTool(.pen, color: color, width: store.lineWidth)
        case .pencil: ink.tool = PKInkingTool(.pencil, color: color, width: store.lineWidth)
        case .highlighter: ink.tool = PKInkingTool(.marker, color: color.withAlphaComponent(0.4), width: max(12, store.lineWidth * 6))
        case .eraser: ink.tool = PKEraserTool(.bitmap, width: max(12, store.lineWidth * 5))
        case .lasso: ink.tool = PKLassoTool()
        default: break
        }
        }
        let nextInputSignature = "\(store.tool.rawValue)|\(store.settings.drawWithFinger)"
        if nextInputSignature != inputSignature {
            inputSignature = nextInputSignature
            let draws = [.pen, .pencil, .highlighter, .eraser, .lasso].contains(store.tool)
            let hand = store.tool == .hand
            ink.drawingPolicy = store.settings.drawWithFinger ? .anyInput : .pencilOnly
            ink.isScrollEnabled = true
            ink.drawingGestureRecognizer.isEnabled = draws
            // Hand navigation has its own recognizer so Pencil and touch behave identically.
            // PencilKit's built-in scroll recognizer remains responsible for finger navigation in other tools.
            ink.panGestureRecognizer.isEnabled = true
            ink.panGestureRecognizer.minimumNumberOfTouches = draws && !store.settings.drawWithFinger ? 1 : 2
            ink.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            navigationPan.isEnabled = hand
            selectionPan.isEnabled = store.tool == .select || store.tool == .magic
            selectionTap.isEnabled = store.tool == .select || store.tool == .magic
            widgetTap.isEnabled = store.tool == .select
        }
        if store.tool != .select { activeWidgetID = nil }
        // The live camera is the sole producer of viewport. Reapplying asynchronously
        // published viewport values here can jump backwards during a pan.
        updateCamera()
    }

    private func worldPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x + ink.contentOffset.x) / ink.zoomScale - inkOrigin.x, y: (point.y + ink.contentOffset.y) / ink.zoomScale - inkOrigin.y)
    }
    private func screenRect(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX + inkOrigin.x) * ink.zoomScale - ink.contentOffset.x, y: (rect.minY + inkOrigin.y) * ink.zoomScale - ink.contentOffset.y, width: rect.width * ink.zoomScale, height: rect.height * ink.zoomScale)
    }
    private func updateCamera() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        surface.cameraOffset = worldContentOffset
        surface.zoom = ink.zoomScale
        surface.marquee = marquee
        surface.setNeedsDisplay()
        if isUITesting {
            let selectedObject = store.notebook.objects.first { store.selectedIDs.contains($0.id) }
            accessibilityValue = String(format: "x=%.3f;y=%.3f;zoom=%.3f;strokes=%d;selected=%d;drawing=%d;navigation=%d;panMin=%d;finger=%d;tool=%d;selectedX=%.3f;selectedY=%.3f", worldContentOffset.x / ink.zoomScale, worldContentOffset.y / ink.zoomScale, ink.zoomScale, ink.drawing.strokes.count, store.selectedIDs.count, ink.drawingGestureRecognizer.isEnabled ? 1 : 0, navigationPan.isEnabled ? 1 : 0, ink.panGestureRecognizer.minimumNumberOfTouches, ink.drawingPolicy == .anyInput ? 1 : 0, CanvasTool.allCases.firstIndex(of: store.tool) ?? -1, selectedObject?.x ?? 0, selectedObject?.y ?? 0)
        } else {
            accessibilityValue = "\(Int(ink.zoomScale * 100)) percent zoom, \(store.notebook.objects.count) objects"
        }
        updateWidgets()
        if !queuedCameraUpdate {
            queuedCameraUpdate = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.queuedCameraUpdate = false
                let viewport = CanvasRect(x: self.worldContentOffset.x / self.ink.zoomScale, y: self.worldContentOffset.y / self.ink.zoomScale, width: self.bounds.width / self.ink.zoomScale, height: self.bounds.height / self.ink.zoomScale)
                self.lastReportedZoom = Double(self.ink.zoomScale)
                if abs(self.store.zoom - self.lastReportedZoom) > 0.001 { self.store.zoom = self.lastReportedZoom }
                if self.store.viewport != viewport { self.store.viewport = viewport }
            }
        }
    }
    private func updateWidgets() {
        if activeWidgetID != nil && store.tool == .select { bringSubviewToFront(widgetLayer) }
        else { insertSubview(widgetLayer, belowSubview: ink) }
        let visible = bounds.insetBy(dx: -100, dy: -100)
        let candidates = store.notebook.objects.filter { $0.kind == "widget" && screenRect($0.rect).intersects(visible) }
        let ids = Set(candidates.map(\.id))
        for id in Array(widgets.keys) where !ids.contains(id) { widgets[id]?.removeFromSuperview(); widgets.removeValue(forKey: id) }
        for object in candidates.prefix(12) {
            let view: CanvasWidgetView
            if let existing = widgets[object.id] { view = existing }
            else { view = CanvasWidgetView(); widgets[object.id] = view; widgetLayer.addSubview(view) }
            let frame = screenRect(object.rect)
            // Preserve CSS pixels while zooming: layout at world dimensions, then transform.
            view.transform = .identity
            view.bounds = CGRect(origin: .zero, size: object.rect.size)
            view.center = CGPoint(x: frame.midX, y: frame.midY)
            view.transform = CGAffineTransform(scaleX: ink.zoomScale, y: ink.zoomScale)
            view.isHidden = false
            view.update(object: object, interactive: activeWidgetID == object.id && store.tool == .select, scale: ink.zoomScale)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateCamera() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { updateCamera() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { expandWorldIfNeeded() }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { expandWorldIfNeeded() }
    func expandWorldIfNeeded() {
        let zoom = ink.zoomScale
        let native = CGRect(x: ink.contentOffset.x / zoom, y: ink.contentOffset.y / zoom, width: bounds.width / zoom, height: bounds.height / zoom)
        let shift = CGPoint(x: native.minX < 4096 ? 32768 : 0, y: native.minY < 4096 ? 32768 : 0)
        if shift != .zero {
            let oldOffset = ink.contentOffset
            let size = ink.contentSize
            isApplyingDrawing = true
            ink.drawing = ink.drawing.transformed(using: CGAffineTransform(translationX: shift.x, y: shift.y))
            inkOrigin.x += shift.x; inkOrigin.y += shift.y
            lastNativeDrawing = ink.drawing.dataRepresentation()
            ink.contentSize = CGSize(width: size.width + shift.x * zoom, height: size.height + shift.y * zoom)
            ink.setContentOffset(CGPoint(x: oldOffset.x + shift.x * zoom, y: oldOffset.y + shift.y * zoom), animated: false)
            ink.undoManager?.removeAllActions()
            isApplyingDrawing = false
        }
        let viewport = CGRect(x: ink.contentOffset.x / zoom, y: ink.contentOffset.y / zoom, width: bounds.width / zoom, height: bounds.height / zoom)
        var size = ink.contentSize
        if viewport.maxX * zoom > size.width - 4096 * zoom { size.width += 32768 * zoom }
        if viewport.maxY * zoom > size.height - 4096 * zoom { size.height += 32768 * zoom }
        if size != ink.contentSize { ink.contentSize = size }
        updateCamera()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { store.checkpoint() }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplyingDrawing else { return }
        let data = canvasView.drawing.dataRepresentation()
        guard data != lastNativeDrawing else { return }
        lastNativeDrawing = data
        let worldData = worldDrawing.dataRepresentation()
        lastDrawing = worldData
        store.setDrawing(worldData)
        updateCamera()
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        if store.settings.recognizeShapes, [.pen, .pencil].contains(store.tool) { recognizeLastStroke() }
        store.commit()
        updateCamera()
    }
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        if store.tool == .eraser { store.tool = previousTool }
        else { previousTool = store.tool; store.tool = .eraser }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @objc private func panCanvas(_ gesture: UIPanGestureRecognizer) {
        guard store.tool == .hand else { return }
        switch gesture.state {
        case .began:
            navigationStartOffset = ink.contentOffset
            activeWidgetID = nil
        case .changed:
            guard let origin = navigationStartOffset else { return }
            let translation = gesture.translation(in: self)
            ink.setContentOffset(CGPoint(x: origin.x - translation.x, y: origin.y - translation.y), animated: false)
            updateCamera()
        case .ended, .cancelled, .failed:
            navigationStartOffset = nil
            expandWorldIfNeeded()
            updateCamera()
        default: break
        }
    }

    @objc private func tapSelection(_ gesture: UITapGestureRecognizer) {
        let point = worldPoint(gesture.location(in: self))
        activeWidgetID = nil
        if store.tool == .magic {
            store.reference = CanvasRect(x: point.x, y: point.y, width: 0, height: 0)
            store.selectedIDs = []
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onReference?()
        } else if store.tool == .select {
            if let object = hitObject(point) { store.selectedIDs = [object.id] }
            else { store.selectedIDs = [] }
        }
        synchronize()
    }
    @objc private func activateWidget(_ gesture: UITapGestureRecognizer) {
        guard store.tool == .select else { return }
        let point = worldPoint(gesture.location(in: self))
        if let object = hitObject(point), object.kind == "widget" {
            activeWidgetID = object.id; store.selectedIDs = [object.id]
            store.status = "Interactive object active · tap outside to leave"
            widgets[object.id]?.captureSnapshot()
            updateWidgets()
        }
    }
    private func hitObject(_ point: CGPoint) -> CanvasObject? {
        store.notebook.objects.reversed().first { $0.kind != "frame" && $0.rect.insetBy(dx: -5 / ink.zoomScale, dy: -5 / ink.zoomScale).contains(point) }
        ?? store.notebook.objects.reversed().first { object in
            guard object.rect.contains(point) else { return false }
            if object.kind == "frame", (object.properties["paper"] ?? 0) > 0 {
                return point.y <= object.rect.minY + 36 || !object.rect.insetBy(dx: 12 / ink.zoomScale, dy: 12 / ink.zoomScale).contains(point)
            }
            return true
        }
    }
    @objc private func panSelection(_ gesture: UIPanGestureRecognizer) {
        let point = worldPoint(gesture.location(in: self))
        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: self)
            let initialScreen = CGPoint(x: gesture.location(in: self).x - translation.x, y: gesture.location(in: self).y - translation.y)
            let initialPoint = worldPoint(initialScreen)
            startPoint = initialPoint; activeWidgetID = nil; dragOriginals = []; resizingID = nil
            referenceBeforeDrag = store.reference
            if store.tool == .select {
                if store.selectedIDs.count == 1, let object = store.notebook.objects.first(where: { store.selectedIDs.contains($0.id) }),
                   hypot(initialPoint.x - object.rect.maxX, initialPoint.y - object.rect.maxY) < 24 / ink.zoomScale {
                    resizingID = object.id; dragOriginals = [object]; store.checkpoint()
                } else if let object = hitObject(initialPoint) {
                    if !store.selectedIDs.contains(object.id) { store.selectedIDs = [object.id] }
                    dragOriginals = store.notebook.objects.filter { store.selectedIDs.contains($0.id) }
                    store.checkpoint()
                } else { store.selectedIDs = []; marquee = CGRect(origin: initialPoint, size: .zero) }
            } else { store.reference = CanvasRect(x: initialPoint.x, y: initialPoint.y, width: 0, height: 0) }
        case .changed:
            guard let start = startPoint else { return }
            let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
            let area = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(delta.x), height: abs(delta.y))
            if store.tool == .magic { store.reference = CanvasRect(area) }
            else if !dragOriginals.isEmpty {
                for original in dragOriginals {
                    guard let index = store.notebook.objects.firstIndex(where: { $0.id == original.id }) else { continue }
                    var updated = original
                    if resizingID == original.id { updated.width = max(60, original.width + delta.x); updated.height = max(45, original.height + delta.y) }
                    else { updated.x += delta.x; updated.y += delta.y }
                    store.notebook.objects[index] = updated
                }
            } else { marquee = area }
            surface.objects = store.notebook.objects; surface.selectedIDs = store.selectedIDs; surface.reference = store.reference?.cgRect
            updateCamera()
        case .ended:
            if store.tool == .magic {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onReference?()
            } else if let area = marquee {
                store.selectedIDs = Set(store.notebook.objects.filter { $0.rect.intersects(area) }.map(\.id))
            }
            if !dragOriginals.isEmpty { store.commit() }
            marquee = nil; startPoint = nil; dragOriginals = []; resizingID = nil
            synchronize()
        case .cancelled, .failed:
            // Adding a second finger must turn into navigation, not leave a partial object move behind.
            for original in dragOriginals {
                if let index = store.notebook.objects.firstIndex(where: { $0.id == original.id }) { store.notebook.objects[index] = original }
            }
            if !dragOriginals.isEmpty { store.commit() }
            if store.tool == .magic { store.reference = referenceBeforeDrag }
            marquee = nil; startPoint = nil; dragOriginals = []; resizingID = nil
            synchronize()
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === widgetTap {
            return store.tool == .select && hitObject(worldPoint(touch.location(in: self)))?.kind == "widget"
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let navigation = otherGestureRecognizer === ink.panGestureRecognizer || otherGestureRecognizer === ink.pinchGestureRecognizer
        if gestureRecognizer === navigationPan { return navigation }
        // Selection cancels and rolls back once its one-touch limit is exceeded; allow
        // the native two-finger pan/pinch to take over instead of blocking navigation.
        if gestureRecognizer === selectionPan { return navigation }
        return false
    }

    private func recognizeLastStroke() {
        guard let stroke = ink.drawing.strokes.last else { return }
        let path = stroke.path
        guard path.count > 14 else { return }
        let points = path.map { element -> CGPoint in
            let native = element.location.applying(stroke.transform)
            return CGPoint(x: native.x - inkOrigin.x, y: native.y - inkOrigin.y)
        }
        guard let first = points.first, let last = points.last else { return }
        let rect = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: CGSize(width: 0.01, height: 0.01))) }
        guard rect.width > 35, rect.height > 35, hypot(first.x - last.x, first.y - last.y) < max(rect.width, rect.height) * 0.20 else { return }
        let normalized = points.map { CGPoint(x: ($0.x - rect.midX) / (rect.width / 2), y: ($0.y - rect.midY) / (rect.height / 2)) }
        let ellipseError = normalized.reduce(0) { $0 + abs(hypot($1.x, $1.y) - 1) } / Double(normalized.count)
        let rectangleError = normalized.reduce(0) { $0 + min(abs(abs($1.x) - 1), abs(abs($1.y) - 1)) } / Double(normalized.count)
        let shape: String
        if ellipseError < 0.13 { shape = abs(rect.width / rect.height - 1) < 0.18 ? "circle" : "ellipse" }
        else if rectangleError < 0.11 { shape = "rectangle" }
        else { return }
        var strokes = ink.drawing.strokes; strokes.removeLast()
        isApplyingDrawing = true; ink.drawing = PKDrawing(strokes: strokes); isApplyingDrawing = false
        let data = worldDrawing.dataRepresentation(); lastNativeDrawing = ink.drawing.dataRepresentation(); lastDrawing = data; store.setDrawing(data)
        // Renderer uses an inset around shape geometry to leave room for labels.
        store.add(CanvasObject(kind: "shape", title: "", x: rect.minX - 22, y: rect.minY - 10, width: rect.width + 44, height: rect.height + 34,
                               color: store.colorHex, properties: ["opacity": 0, "strokeWidth": store.lineWidth], shape: shape))
        store.status = "Recognized \(shape) · Undo to restore your stroke"
    }
}

@MainActor
private final class CanvasSurfaceView: UIView {
    var objects: [CanvasObject] = []
    var selectedIDs: Set<UUID> = []
    var reference: CGRect?
    var marquee: CGRect?
    var cameraOffset: CGPoint = .zero
    var zoom: CGFloat = 1
    var dark = false
    var showGrid = true
    var paperStyle = "dots"
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false; contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        if showGrid && paperStyle != "blank" {
            let step: CGFloat = zoom < 0.4 ? 80 * zoom : 28 * zoom
            let originX = (-cameraOffset.x).truncatingRemainder(dividingBy: step)
            let originY = (-cameraOffset.y).truncatingRemainder(dividingBy: step)
            let paperInk = (dark ? UIColor.white : UIColor(red: 0.53, green: 0.60, blue: 0.70, alpha: 1)).withAlphaComponent(dark ? 0.12 : 0.23)
            context.setFillColor(paperInk.cgColor); context.setStrokeColor(paperInk.cgColor)
            if paperStyle == "ruled" || paperStyle == "grid" {
                context.setLineWidth(0.5)
                for y in stride(from: originY, through: bounds.height, by: step) { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: bounds.width, y: y)) }
                if paperStyle == "grid" {
                    for x in stride(from: originX, through: bounds.width, by: step) { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: bounds.height)) }
                }
                context.strokePath()
            } else {
                for x in stride(from: originX, through: bounds.width, by: step) {
                    for y in stride(from: originY, through: bounds.height, by: step) { context.fillEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2)) }
                }
            }
        }
        context.saveGState()
        context.translateBy(x: -cameraOffset.x, y: -cameraOffset.y)
        context.scaleBy(x: zoom, y: zoom)
        let visible = CGRect(x: cameraOffset.x / zoom, y: cameraOffset.y / zoom, width: bounds.width / zoom, height: bounds.height / zoom).insetBy(dx: -80, dy: -80)
        for object in objects.filter({ $0.kind == "frame" }) + objects.filter({ $0.kind != "frame" }) where object.rect.intersects(visible) {
            ObjectRenderer.shared.draw(object, in: context, dark: dark)
            if selectedIDs.contains(object.id) { drawSelection(object.rect, context: context) }
        }
        if let area = marquee { drawRegion(area, context: context, purple: false) }
        if let reference {
            if reference.width < 10 && reference.height < 10 {
                let center = reference.origin, radius = 12 / zoom
                context.setFillColor(UIColor.systemIndigo.withAlphaComponent(0.12).cgColor)
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.setStrokeColor(UIColor.systemIndigo.cgColor); context.setLineWidth(1.5 / zoom)
                context.strokeEllipse(in: CGRect(x: center.x - radius / 2, y: center.y - radius / 2, width: radius, height: radius))
                context.move(to: CGPoint(x: center.x - radius - 5 / zoom, y: center.y)); context.addLine(to: CGPoint(x: center.x + radius + 5 / zoom, y: center.y))
                context.move(to: CGPoint(x: center.x, y: center.y - radius - 5 / zoom)); context.addLine(to: CGPoint(x: center.x, y: center.y + radius + 5 / zoom)); context.strokePath()
            } else { drawRegion(reference, context: context, purple: true) }
        }
        context.restoreGState()
    }
    private func drawSelection(_ rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setStrokeColor(UIColor.systemBlue.cgColor); context.setLineWidth(1.5 / zoom)
        context.addPath(UIBezierPath(roundedRect: rect.insetBy(dx: -5 / zoom, dy: -5 / zoom), cornerRadius: 8 / zoom).cgPath); context.strokePath()
        if selectedIDs.count == 1 {
            let handle = CGRect(x: rect.maxX - 5 / zoom, y: rect.maxY - 5 / zoom, width: 10 / zoom, height: 10 / zoom)
            context.setFillColor(UIColor.white.cgColor); context.fillEllipse(in: handle); context.strokeEllipse(in: handle)
        }
        context.restoreGState()
    }
    private func drawRegion(_ area: CGRect, context: CGContext, purple: Bool) {
        context.saveGState()
        let color: UIColor = purple ? .systemIndigo : .systemBlue
        context.setFillColor(color.withAlphaComponent(0.05).cgColor); context.fill(area)
        context.setStrokeColor(color.withAlphaComponent(0.85).cgColor); context.setLineWidth(1.5 / zoom)
        context.setLineDash(phase: 0, lengths: [6 / zoom, 5 / zoom])
        context.addPath(UIBezierPath(roundedRect: area, cornerRadius: 6 / zoom).cgPath); context.strokePath()
        context.restoreGState()
    }
}

private final class PassThroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        return result === self ? nil : result
    }
}

extension Notification.Name {
    static let canvasFocusObject = Notification.Name("CanvasStudio.focusObject")
    static let canvasFitContent = Notification.Name("CanvasStudio.fitContent")
    static let canvasResetCamera = Notification.Name("CanvasStudio.resetCamera")
}
