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
    let ink = StudioInkCanvasView()
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
    private(set) var activeWidgetID: UUID?
    private let interactionDone = UIButton(type: .system)
    private var widgetNavigationPan: UIPanGestureRecognizer!
    private var widgetNavigationPinch: UIPinchGestureRecognizer!
    private var widgetPanOffset: CGPoint?
    private var widgetPinchAnchor: CGPoint?
    private var widgetPinchZoom: CGFloat = 1
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
    private var selectionBeforeDrag: Set<UUID> = []
    private var dragTool: CanvasTool?
    private var dragNotebookID: UUID?
    private var inkSessionTool: CanvasTool?
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
        ink.keyboardDismissMode = .none
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
        selectionTap.require(toFail: selectionPan)
        ink.addGestureRecognizer(selectionTap)
        widgetTap = UITapGestureRecognizer(target: self, action: #selector(activateWidget(_:)))
        widgetTap.numberOfTapsRequired = 2; widgetTap.delegate = self
        ink.addGestureRecognizer(widgetTap)
        selectionTap.require(toFail: widgetTap)
        ink.panGestureRecognizer.addTarget(self, action: #selector(nativeNavigationChanged(_:)))
        ink.pinchGestureRecognizer?.addTarget(self, action: #selector(nativeNavigationChanged(_:)))
        widgetNavigationPan = UIPanGestureRecognizer(target: self, action: #selector(panOverWidget(_:)))
        widgetNavigationPan.minimumNumberOfTouches = 2
        widgetNavigationPan.delegate = self
        addGestureRecognizer(widgetNavigationPan)
        widgetNavigationPinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchOverWidget(_:)))
        widgetNavigationPinch.delegate = self
        addGestureRecognizer(widgetNavigationPinch)
        interactionDone.setTitle("Done interacting", for: .normal)
        interactionDone.setImage(UIImage(systemName: "checkmark"), for: .normal)
        interactionDone.backgroundColor = .systemBackground
        interactionDone.tintColor = .systemIndigo
        interactionDone.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        interactionDone.layer.cornerRadius = 15
        interactionDone.layer.borderColor = UIColor.systemIndigo.withAlphaComponent(0.3).cgColor
        interactionDone.layer.borderWidth = 1
        interactionDone.accessibilityIdentifier = "widgetDone"
        interactionDone.addTarget(self, action: #selector(stopWidgetInteraction), for: .touchUpInside)
        interactionDone.isHidden = true
        addSubview(interactionDone)
        pencilInteraction.delegate = self; ink.addInteraction(pencilInteraction)
        NotificationCenter.default.addObserver(self, selector: #selector(fitContent), name: .canvasFitContent, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(focusObject(_:)), name: .canvasFocusObject, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resetCamera), name: .canvasResetCamera, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interactSelected), name: .canvasInteractSelected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stopWidgetInteraction), name: .canvasEndInteraction, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(copySelection), name: .canvasCopySelection, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pasteSelection), name: .canvasPasteSelection, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(duplicateSelection), name: .canvasDuplicateSelection, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deleteSelection), name: .canvasDeleteSelection, object: nil)
        synchronize()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let camera = ink.contentOffset
        surface.frame = bounds; ink.frame = bounds; widgetLayer.frame = bounds
        if !pendingInitialFit && ink.contentOffset != camera { ink.setContentOffset(camera, animated: false) }
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
         UIKeyCommand(input: "c", modifierFlags: [.command], action: #selector(copySelection)),
         UIKeyCommand(input: "v", modifierFlags: [.command], action: #selector(pasteSelection)),
         UIKeyCommand(input: "d", modifierFlags: [.command], action: #selector(duplicateSelection)),
         UIKeyCommand(input: "\u{8}", modifierFlags: [], action: #selector(deleteSelection)),
         UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(endInteraction))]
    }
    @objc private func toggleMagic() {
        guard store.settings.aiEnabled else { return }
        store.tool = store.tool == .magic ? .pen : .magic
    }
    @objc private func endInteraction() {
        finishSelectionDrag(cancelled: true)
        activeWidgetID = nil; store.selectedIDs = []; store.reference = nil
        if store.tool == .magic { store.tool = .pen }
        synchronize()
    }
    @objc private func copySelection() { finishSelectionDrag(cancelled: true); store.copySelection(); synchronize() }
    @objc private func pasteSelection() { finishSelectionDrag(cancelled: true); store.paste(); synchronize() }
    @objc private func duplicateSelection() { finishSelectionDrag(cancelled: true); store.duplicateSelection(); synchronize() }
    @objc private func deleteSelection() { finishSelectionDrag(cancelled: true); activeWidgetID = nil; store.deleteSelection(); synchronize() }
    @objc private func interactSelected() {
        guard let object = store.notebook.objects.first(where: { store.selectedIDs.contains($0.id) && $0.kind == "widget" }) else { return }
        finishSelectionDrag(cancelled: true)
        store.tool = .select
        activeWidgetID = object.id
        store.status = "Interacting · two fingers move the canvas · Done to select"
        synchronize()
    }
    @objc private func stopWidgetInteraction() {
        if let id = activeWidgetID { widgets[id]?.captureSnapshot() }
        activeWidgetID = nil
        store.status = "Select objects to move or edit them"
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
        let nextInputSignature = "\(store.tool.rawValue)|\(store.settings.drawWithFinger)"
        let changingInput = nextInputSignature != inputSignature
        if changingInput || notebookID != store.notebook.id {
            // A recognizer's cancellation callback can arrive after the tool has changed.
            // Roll back using the captured gesture tool, never the newly selected tool.
            finishSelectionDrag(cancelled: true)
            navigationStartOffset = nil
            selectionPan.isEnabled = false
            navigationPan.isEnabled = false
            if inkSessionTool != nil { inkSessionTool = nil; store.commit() }
        }
        let cameraBeforeToolChange = ink.contentOffset
        let dark = store.settings.darkMode
        backgroundColor = dark ? UIColor(red: 0.075, green: 0.09, blue: 0.12, alpha: 1) : UIColor(red: 0.975, green: 0.979, blue: 0.985, alpha: 1)
        surface.backgroundColor = backgroundColor
        surface.objects = store.notebook.objects
        surface.selectedIDs = store.selectedIDs
        surface.reference = store.tool == .magic ? store.reference?.cgRect : nil
        surface.pendingTasks = store.pendingTasks
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
        if changingInput {
            inputSignature = nextInputSignature
            let draws = [.pen, .pencil, .highlighter, .eraser, .lasso].contains(store.tool)
            let hand = store.tool == .hand
            ink.drawingPolicy = store.settings.drawWithFinger ? .anyInput : .pencilOnly
            ink.allowsInkEditingMenu = store.tool == .lasso
            ink.isScrollEnabled = true
            ink.drawingGestureRecognizer.isEnabled = draws
            // Hand navigation has its own recognizer so Pencil and touch behave identically.
            // PencilKit's built-in scroll recognizer remains responsible for finger navigation in other tools.
            ink.panGestureRecognizer.isEnabled = false
            ink.panGestureRecognizer.minimumNumberOfTouches = draws && !store.settings.drawWithFinger ? 1 : 2
            ink.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            ink.panGestureRecognizer.isEnabled = true
            navigationPan.isEnabled = hand
            selectionPan.isEnabled = store.tool == .select || store.tool == .magic
            selectionTap.isEnabled = store.tool == .select || store.tool == .magic
            widgetTap.isEnabled = store.tool == .select
            if !pendingInitialFit { ink.setContentOffset(cameraBeforeToolChange, animated: false) }
        }
        if store.tool != .select || !store.selectedIDs.contains(activeWidgetID ?? UUID()) { activeWidgetID = nil }
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
            accessibilityValue = String(format: "x=%.3f;y=%.3f;zoom=%.3f;strokes=%d;selected=%d;drawing=%d;navigation=%d;panMin=%d;finger=%d;tool=%d;selectedX=%.3f;selectedY=%.3f;objects=%d;interacting=%d;reference=%d;referenceX=%.3f;referenceY=%.3f;referenceWidth=%.3f;referenceHeight=%.3f;pinchEnabled=%d", worldContentOffset.x / ink.zoomScale, worldContentOffset.y / ink.zoomScale, ink.zoomScale, ink.drawing.strokes.count, store.selectedIDs.count, ink.drawingGestureRecognizer.isEnabled ? 1 : 0, navigationPan.isEnabled ? 1 : 0, ink.panGestureRecognizer.minimumNumberOfTouches, ink.drawingPolicy == .anyInput ? 1 : 0, CanvasTool.allCases.firstIndex(of: store.tool) ?? -1, selectedObject?.x ?? 0, selectedObject?.y ?? 0, store.notebook.objects.count, activeWidgetID == nil ? 0 : 1, store.reference == nil ? 0 : 1, store.reference?.x ?? 0, store.reference?.y ?? 0, store.reference?.width ?? 0, store.reference?.height ?? 0, ink.pinchGestureRecognizer?.isEnabled == true ? 1 : 0)
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
            else {
                view = CanvasWidgetView(); widgets[object.id] = view; widgetLayer.addSubview(view)
                view.onHostRequest = { [weak self] request in
                    guard let self, self.activeWidgetID == object.id, self.store.tool == .select else {
                        throw NotebookError.invalid("Choose Interact before changing the canvas from this object.")
                    }
                    let previousSelection = self.store.selectedIDs
                    let result = try WidgetHostProtocol.apply(request, sourceID: object.id, store: self.store)
                    self.store.selectedIDs = previousSelection.intersection(Set(self.store.notebook.objects.map(\.id)))
                    self.synchronize()
                    return result
                }
            }
            let frame = screenRect(object.rect)
            // Preserve CSS pixels while zooming: layout at world dimensions, then transform.
            view.transform = .identity
            view.bounds = CGRect(origin: .zero, size: object.rect.size)
            view.center = CGPoint(x: frame.midX, y: frame.midY)
            view.transform = CGAffineTransform(scaleX: ink.zoomScale, y: ink.zoomScale)
            view.isHidden = false
            view.update(object: object, interactive: activeWidgetID == object.id && store.tool == .select, scale: ink.zoomScale)
        }
        interactionDone.isHidden = activeWidgetID == nil
        if let id = activeWidgetID, let object = store.notebook.objects.first(where: { $0.id == id }) {
            let rect = screenRect(object.rect)
            interactionDone.frame = CGRect(x: max(12, min(bounds.width - 180, rect.maxX - 170)),
                                           y: max(150, min(bounds.height - 65, rect.minY - 42)), width: 170, height: 34)
            bringSubviewToFront(interactionDone)
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

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard [.pen, .pencil, .highlighter, .eraser, .lasso].contains(store.tool) else { return }
        inkSessionTool = store.tool
        store.checkpoint()
    }
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
        if let tool = inkSessionTool, store.settings.recognizeShapes, [.pen, .pencil].contains(tool) { recognizeLastStroke() }
        inkSessionTool = nil
        store.commit()
        updateCamera()
    }
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        if store.tool == .eraser { store.tool = previousTool }
        else { previousTool = store.tool; store.tool = .eraser }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @objc private func panCanvas(_ gesture: UIPanGestureRecognizer) {
        guard store.tool == .hand else { navigationStartOffset = nil; return }
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
            store.selectedIDs = [object.id]
            interactSelected()
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
        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: self)
            let location = gesture.location(in: self)
            beginSelectionDrag(at: worldPoint(CGPoint(x: location.x - translation.x, y: location.y - translation.y)))
        case .changed:
            guard let start = startPoint else { return }
            let translation = gesture.translation(in: self)
            updateSelectionDrag(to: CGPoint(x: start.x + translation.x / ink.zoomScale, y: start.y + translation.y / ink.zoomScale))
        case .ended: finishSelectionDrag(cancelled: false); synchronize()
        case .cancelled, .failed: finishSelectionDrag(cancelled: true); synchronize()
        default: break
        }
    }

    // Shared by gesture callbacks and lifecycle cancellation; coordinates are always world-space.
    func beginSelectionDrag(at point: CGPoint) {
        guard store.tool == .select || store.tool == .magic else { return }
        finishSelectionDrag(cancelled: true)
        startPoint = point; activeWidgetID = nil; dragOriginals = []; resizingID = nil
        dragTool = store.tool; dragNotebookID = store.notebook.id
        referenceBeforeDrag = store.reference; selectionBeforeDrag = store.selectedIDs
        if dragTool == .select {
            if store.selectedIDs.count == 1, let object = store.selectedObjects.first,
               hypot(point.x - object.rect.maxX, point.y - object.rect.maxY) < 24 / ink.zoomScale {
                resizingID = object.id; dragOriginals = [object]; store.checkpoint()
            } else if let object = hitObject(point) {
                if !store.selectedIDs.contains(object.id) { store.selectedIDs = [object.id] }
                dragOriginals = store.selectedObjects; store.checkpoint()
            } else { store.selectedIDs = []; marquee = CGRect(origin: point, size: .zero) }
        } else { store.reference = CanvasRect(x: point.x, y: point.y, width: 0, height: 0) }
    }
    func updateSelectionDrag(to point: CGPoint) {
        guard let start = startPoint, let tool = dragTool, dragNotebookID == store.notebook.id else { return }
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        let area = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(delta.x), height: abs(delta.y))
        if tool == .magic { store.reference = CanvasRect(area) }
        else if !dragOriginals.isEmpty {
            for original in dragOriginals {
                guard let index = store.notebook.objects.firstIndex(where: { $0.id == original.id }) else { continue }
                var updated = original
                if resizingID == original.id { updated.width = max(60, original.width + delta.x); updated.height = max(45, original.height + delta.y) }
                else { updated.x += delta.x; updated.y += delta.y }
                guard (try? NotebookValidation.validate(updated)) != nil else { continue }
                store.notebook.objects[index] = updated
            }
        } else { marquee = area }
        surface.objects = store.notebook.objects; surface.selectedIDs = store.selectedIDs
        surface.reference = tool == .magic ? store.reference?.cgRect : nil
        updateCamera()
    }
    func finishSelectionDrag(cancelled: Bool) {
        guard let tool = dragTool else { return }
        let sameNotebook = dragNotebookID == store.notebook.id
        // Clear the session before publishing, so reentrant SwiftUI updates cannot finish it twice.
        dragTool = nil; dragNotebookID = nil; startPoint = nil
        if sameNotebook {
            if cancelled {
                for original in dragOriginals {
                    if let index = store.notebook.objects.firstIndex(where: { $0.id == original.id }) { store.notebook.objects[index] = original }
                }
                store.selectedIDs = selectionBeforeDrag
                if tool == .magic { store.reference = referenceBeforeDrag }
            } else if tool == .select, let area = marquee {
                store.selectedIDs = Set(store.notebook.objects.filter { $0.rect.intersects(area) }.map(\.id))
            }
            if !dragOriginals.isEmpty { store.commit() }
        }
        marquee = nil; dragOriginals = []; resizingID = nil; referenceBeforeDrag = nil; selectionBeforeDrag = []
        if sameNotebook && !cancelled && tool == .magic {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onReference?()
        }
    }
    @objc private func nativeNavigationChanged(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began else { return }
        finishSelectionDrag(cancelled: true)
        navigationStartOffset = nil
        surface.objects = store.notebook.objects; surface.reference = store.tool == .magic ? store.reference?.cgRect : nil
        surface.selectedIDs = store.selectedIDs
        updateCamera()
    }
    @objc private func panOverWidget(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            widgetPanOffset = ink.contentOffset
            finishSelectionDrag(cancelled: true)
        case .changed:
            guard widgetPinchAnchor == nil, let offset = widgetPanOffset else { return }
            let delta = gesture.translation(in: self)
            ink.setContentOffset(CGPoint(x: offset.x - delta.x, y: offset.y - delta.y), animated: false)
        case .ended, .cancelled, .failed:
            widgetPanOffset = nil; expandWorldIfNeeded()
        default: break
        }
    }
    @objc private func pinchOverWidget(_ gesture: UIPinchGestureRecognizer) {
        let focal = gesture.location(in: self)
        switch gesture.state {
        case .began:
            finishSelectionDrag(cancelled: true)
            widgetPinchZoom = ink.zoomScale
            widgetPinchAnchor = worldPoint(focal)
        case .changed:
            guard let anchor = widgetPinchAnchor else { return }
            let scale = min(ink.maximumZoomScale, max(ink.minimumZoomScale, widgetPinchZoom * gesture.scale))
            ink.setZoomScale(scale, animated: false)
            ink.setContentOffset(CGPoint(x: (anchor.x + inkOrigin.x) * scale - focal.x,
                                        y: (anchor.y + inkOrigin.y) * scale - focal.y), animated: false)
        case .ended, .cancelled, .failed:
            widgetPinchAnchor = nil
            widgetPanOffset = ink.contentOffset
            widgetNavigationPan.setTranslation(.zero, in: self)
            expandWorldIfNeeded()
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === widgetNavigationPan || gestureRecognizer === widgetNavigationPinch {
            guard let id = activeWidgetID, let view = widgets[id] else { return false }
            return view.bounds.contains(touch.location(in: view))
        }
        if gestureRecognizer === widgetTap {
            return store.tool == .select && hitObject(worldPoint(touch.location(in: self)))?.kind == "widget"
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === widgetNavigationPan || gestureRecognizer === widgetNavigationPinch { return true }
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
    var pendingTasks: [CanvasTaskRegion] = []
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
        for task in pendingTasks where task.rect.cgRect.intersects(visible) {
            let area = task.rect.cgRect
            drawRegion(area, context: context, purple: true)
            let label = "◌  " + task.label
            let font = UIFont.systemFont(ofSize: 12 / zoom, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.systemIndigo]
            let size = (label as NSString).size(withAttributes: attributes)
            let pill = CGRect(x: area.minX + 8 / zoom, y: area.minY + 8 / zoom,
                              width: min(size.width + 20 / zoom, 240 / zoom), height: 27 / zoom)
            context.setFillColor(UIColor.systemBackground.withAlphaComponent(0.94).cgColor)
            context.addPath(UIBezierPath(roundedRect: pill, cornerRadius: 13 / zoom).cgPath); context.fillPath()
            (label as NSString).draw(in: pill.insetBy(dx: 10 / zoom, dy: 6 / zoom), withAttributes: attributes)
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
    static let canvasInteractSelected = Notification.Name("CanvasStudio.interactSelected")
    static let canvasEndInteraction = Notification.Name("CanvasStudio.endInteraction")
    static let canvasCopySelection = Notification.Name("CanvasStudio.copySelection")
    static let canvasPasteSelection = Notification.Name("CanvasStudio.pasteSelection")
    static let canvasDuplicateSelection = Notification.Name("CanvasStudio.duplicateSelection")
    static let canvasDeleteSelection = Notification.Name("CanvasStudio.deleteSelection")
}

/// Keep native ink editing actions scoped to the ink lasso. Object editing belongs
/// to the studio toolbar and must never invoke PencilKit's Insert Space menu.
final class StudioInkCanvasView: PKCanvasView {
    var allowsInkEditingMenu = false {
        didSet { if allowsInkEditingMenu != oldValue { updateInkMenuPolicy(in: self) } }
    }
    private var menuPressStates: [ObjectIdentifier: Bool] = [:]
    override func layoutSubviews() {
        super.layoutSubviews()
        updateInkMenuPolicy(in: self)
    }
    private func updateInkMenuPolicy(in view: UIView) {
        for gesture in view.gestureRecognizers ?? [] where gesture is UILongPressGestureRecognizer && gesture !== drawingGestureRecognizer {
            let id = ObjectIdentifier(gesture)
            if menuPressStates[id] == nil { menuPressStates[id] = gesture.isEnabled }
            let enabled = allowsInkEditingMenu && menuPressStates[id] == true
            if gesture.isEnabled != enabled { gesture.isEnabled = enabled }
        }
        if !allowsInkEditingMenu {
            for interaction in view.interactions {
                (interaction as? UIEditMenuInteraction)?.dismissMenu()
            }
        }
        for child in view.subviews { updateInkMenuPolicy(in: child) }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        allowsInkEditingMenu && super.canPerformAction(action, withSender: sender)
    }
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        // Focus/keyboard requests must not recenter an infinite world. Its camera is
        // changed explicitly by pan, pinch, Fit and page navigation only.
    }
}
