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
    private var zoomInProgress = false
    private var deferredDrawingChange = false
    private var isZoomInteractionActive: Bool { zoomInProgress || ink.isZooming || widgetPinchAnchor != nil }
    private var pendingInitialFit = true
    private var startPoint: CGPoint?
    private var referenceBeforeDrag: CanvasRect?
    private var selectionBeforeDrag: Set<UUID> = []
    private var strokesBeforeDrag: Set<Int> = []
    private var lassoPoints: [CGPoint] = []
    private var mixedDrag: CanvasSelectionSnapshot?
    private var mixedDragLastInk: Data?
    private var dragTool: CanvasTool?
    private var dragNotebookID: UUID?
    private var inkSessionTool: CanvasTool?
    private var shapeSession: ShapeStrokeSession?
    private var completedShapeSessions: [ShapeStrokeSession] = []
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
        ink.bounces = true; ink.bouncesZoom = false
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
        surface.frame = bounds
        // Reassigning a scroll view frame during a live pinch can invalidate its
        // internal zoom anchor even when SwiftUI only republished the viewport.
        if ink.frame != bounds { ink.frame = bounds }
        widgetLayer.frame = bounds
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
        activeWidgetID = nil; store.clearSelection(); store.reference = nil
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
        store.setSelection(objects: [id], strokes: [])
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
            shapeSession = nil; completedShapeSessions.removeAll()
        }
        let cameraBeforeToolChange = ink.contentOffset
        let dark = store.settings.darkMode
        backgroundColor = dark ? UIColor(red: 0.075, green: 0.09, blue: 0.12, alpha: 1) : UIColor(red: 0.975, green: 0.979, blue: 0.985, alpha: 1)
        surface.backgroundColor = backgroundColor
        surface.objects = store.notebook.objects
        surface.selectedIDs = store.selectedIDs
        surface.mixedSelectionBounds = store.selectedStrokeIndices.isEmpty ? nil : store.selectionBounds
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
        if lastDrawing != store.notebook.drawingData && !isZoomInteractionActive {
            // Undo, import, or another document edit invalidates pending stroke identities.
            shapeSession = nil; completedShapeSessions.removeAll()
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
        case .lasso: break // Studio's polygon lasso selects ink and structured objects together.
        default: break
        }
        }
        if changingInput {
            inputSignature = nextInputSignature
            let draws = [.pen, .pencil, .highlighter, .eraser].contains(store.tool)
            let hand = store.tool == .hand
            ink.drawingPolicy = store.settings.drawWithFinger ? .anyInput : .pencilOnly
            ink.allowsInkEditingMenu = false
            ink.isScrollEnabled = true
            ink.drawingGestureRecognizer.isEnabled = draws
            // Hand navigation has its own recognizer so Pencil and touch behave identically.
            // PencilKit's built-in scroll recognizer remains responsible for finger navigation in other tools.
            ink.panGestureRecognizer.isEnabled = false
            ink.panGestureRecognizer.minimumNumberOfTouches = draws && !store.settings.drawWithFinger ? 1 : 2
            ink.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            ink.panGestureRecognizer.isEnabled = true
            navigationPan.isEnabled = hand
            selectionPan.isEnabled = [.select, .lasso, .magic].contains(store.tool)
            selectionTap.isEnabled = [.select, .lasso, .magic].contains(store.tool)
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
        surface.lassoPoints = lassoPoints
        surface.mixedSelectionBounds = store.selectedStrokeIndices.isEmpty ? nil : store.selectionBounds
        surface.setNeedsDisplay()
        if isUITesting {
            let selectedObject = store.notebook.objects.first { store.selectedIDs.contains($0.id) }
            accessibilityValue = String(format: "x=%.3f;y=%.3f;zoom=%.3f;strokes=%d;selected=%d;drawing=%d;navigation=%d;panMin=%d;finger=%d;tool=%d;selectedX=%.3f;selectedY=%.3f;objects=%d;interacting=%d;reference=%d;referenceX=%.3f;referenceY=%.3f;referenceWidth=%.3f;referenceHeight=%.3f;pinchEnabled=%d;selectedStrokes=%d", worldContentOffset.x / ink.zoomScale, worldContentOffset.y / ink.zoomScale, ink.zoomScale, ink.drawing.strokes.count, store.selectedIDs.count, ink.drawingGestureRecognizer.isEnabled ? 1 : 0, navigationPan.isEnabled ? 1 : 0, ink.panGestureRecognizer.minimumNumberOfTouches, ink.drawingPolicy == .anyInput ? 1 : 0, CanvasTool.allCases.firstIndex(of: store.tool) ?? -1, selectedObject?.x ?? 0, selectedObject?.y ?? 0, store.notebook.objects.count, activeWidgetID == nil ? 0 : 1, store.reference == nil ? 0 : 1, store.reference?.x ?? 0, store.reference?.y ?? 0, store.reference?.width ?? 0, store.reference?.height ?? 0, ink.pinchGestureRecognizer?.isEnabled == true ? 1 : 0, store.selectedStrokeIndices.count)
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
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { zoomInProgress = true }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        zoomInProgress = false
        finishZoomInteraction()
        // UIKit may clear isZooming after its delegate callback returns.
        if isZoomInteractionActive {
            DispatchQueue.main.async { [weak self] in self?.finishZoomInteraction() }
        }
    }
    private func finishZoomInteraction() {
        guard !isZoomInteractionActive else { return }
        // An undo/import that arrived during zoom wins over a delayed native redraw.
        if lastDrawing != store.notebook.drawingData { synchronize() }
        if deferredDrawingChange { deferredDrawingChange = false; canvasViewDrawingDidChange(ink) }
        recognizeCompletedStrokes()
        expandWorldIfNeeded()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { expandWorldIfNeeded() }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { expandWorldIfNeeded() }
    func expandWorldIfNeeded() {
        // A two-finger pan can end before the companion pinch. Moving the native
        // origin then replaces PencilKit's live zoom surface and makes ink jump.
        guard !isZoomInteractionActive, inkSessionTool == nil else { return }
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
        guard [.pen, .pencil, .highlighter, .eraser].contains(store.tool) else { return }
        inkSessionTool = store.tool
        if store.settings.recognizeShapes && [.pen, .pencil].contains(store.tool) {
            shapeSession = ShapeStrokeSession(notebookID: store.notebook.id,
                existing: Set(canvasView.drawing.strokes.map(ShapeStrokeIdentity.init)),
                startedAt: Date(), width: (canvasView.tool as? PKInkingTool)?.width ?? CGFloat(store.lineWidth))
        } else { shapeSession = nil }
        store.checkpoint()
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isApplyingDrawing else { return }
        guard !isZoomInteractionActive else { deferredDrawingChange = true; return }
        let data = canvasView.drawing.dataRepresentation()
        if data != lastNativeDrawing {
            lastNativeDrawing = data
            let worldData = worldDrawing.dataRepresentation()
            lastDrawing = worldData
            store.setDrawing(worldData)
        }
        recognizeCompletedStrokes()
        updateCamera()
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        if var session = shapeSession {
            session.endedAt = Date()
            completedShapeSessions.append(session)
            if completedShapeSessions.count > 16 { completedShapeSessions.removeFirst() }
        }
        shapeSession = nil
        inkSessionTool = nil
        // didEnd can precede the final pressure samples and drawingDidChange.
        // Apple documents this ordering in WWDC 2019 session 221:
        // https://developer.apple.com/videos/play/wwdc2019/221/
        // Persist any already committed ink, then wait for the identified stroke.
        canvasViewDrawingDidChange(canvasView)
        store.commit()
        updateCamera()
    }
    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        // Zooming renders the existing drawing; it is not a document edit.
        // Only a pending stroke finalization needs this fallback callback.
        guard !isApplyingDrawing, !completedShapeSessions.isEmpty else { return }
        canvasViewDrawingDidChange(canvasView)
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
            store.clearSelection()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onReference?()
        } else if store.tool == .select || store.tool == .lasso {
            if store.tool == .lasso, let stroke = CanvasLasso.stroke(at: point, in: store.worldInk, tolerance: 12 / ink.zoomScale) {
                store.setSelection(objects: [], strokes: [stroke])
            } else if let object = hitObject(point) { store.setSelection(objects: [object.id], strokes: []) }
            else if let stroke = CanvasLasso.stroke(at: point, in: store.worldInk, tolerance: 12 / ink.zoomScale) {
                store.setSelection(objects: [], strokes: [stroke])
            } else { store.clearSelection() }
        }
        synchronize()
    }
    @objc private func activateWidget(_ gesture: UITapGestureRecognizer) {
        guard store.tool == .select else { return }
        let point = worldPoint(gesture.location(in: self))
        if let object = hitObject(point), object.kind == "widget" {
            store.setSelection(objects: [object.id], strokes: [])
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
        guard [.select, .lasso, .magic].contains(store.tool) else { return }
        finishSelectionDrag(cancelled: true)
        startPoint = point; activeWidgetID = nil; dragOriginals = []; resizingID = nil
        mixedDrag = nil; mixedDragLastInk = nil; lassoPoints = []
        dragTool = store.tool; dragNotebookID = store.notebook.id
        referenceBeforeDrag = store.reference; selectionBeforeDrag = store.selectedIDs; strokesBeforeDrag = store.selectedStrokeIndices
        if dragTool == .magic {
            store.reference = CanvasRect(x: point.x, y: point.y, width: 0, height: 0)
        } else if store.hasSelection, let bounds = store.selectionBounds,
                  bounds.insetBy(dx: -8 / ink.zoomScale, dy: -8 / ink.zoomScale).contains(point),
                  !store.selectedStrokeIndices.isEmpty || dragTool == .lasso {
            mixedDrag = store.selectionSnapshot(); mixedDragLastInk = store.notebook.drawingData; store.checkpoint()
        } else if dragTool == .lasso {
            store.clearSelection(); lassoPoints = [point]
        } else if store.selectedIDs.count == 1, store.selectedStrokeIndices.isEmpty, let object = store.selectedObjects.first,
                  hypot(point.x - object.rect.maxX, point.y - object.rect.maxY) < 24 / ink.zoomScale {
            resizingID = object.id; dragOriginals = [object]; store.checkpoint()
        } else if canDragSelectedFrame(at: point) {
            mixedDrag = store.selectionSnapshot(); mixedDragLastInk = store.notebook.drawingData; store.checkpoint()
        } else if let object = hitObject(point) {
            if !store.selectedIDs.contains(object.id) { store.setSelection(objects: [object.id], strokes: []) }
            mixedDrag = store.selectionSnapshot(); mixedDragLastInk = store.notebook.drawingData; store.checkpoint()
        } else if let stroke = CanvasLasso.stroke(at: point, in: store.worldInk, tolerance: 12 / ink.zoomScale) {
            store.setSelection(objects: [], strokes: [stroke])
            mixedDrag = store.selectionSnapshot(); mixedDragLastInk = store.notebook.drawingData; store.checkpoint()
        } else { store.clearSelection(); marquee = CGRect(origin: point, size: .zero) }
    }
    private func canDragSelectedFrame(at point: CGPoint) -> Bool {
        guard let frame = store.selectedObjects.last(where: { $0.kind == "frame" && $0.rect.contains(point) }) else { return false }
        if let hit = hitObject(point), hit.id != frame.id { return false }
        return CanvasLasso.stroke(at: point, in: store.worldInk, tolerance: 12 / ink.zoomScale) == nil
    }
    func updateSelectionDrag(to point: CGPoint) {
        guard let start = startPoint, let tool = dragTool, dragNotebookID == store.notebook.id else { return }
        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
        let area = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(delta.x), height: abs(delta.y))
        if tool == .magic { store.reference = CanvasRect(area) }
        else if let snapshot = mixedDrag {
            guard snapshot.strokeIndices.isEmpty || store.notebook.drawingData == mixedDragLastInk else {
                finishSelectionDrag(cancelled: true); synchronize(); return
            }
            guard store.moveSelection(from: snapshot, by: delta) else { finishSelectionDrag(cancelled: true); synchronize(); return }
            mixedDragLastInk = store.notebook.drawingData
        } else if !dragOriginals.isEmpty {
            for original in dragOriginals {
                guard let index = store.notebook.objects.firstIndex(where: { $0.id == original.id }) else { continue }
                var updated = original
                updated.width = max(60, original.width + delta.x); updated.height = max(45, original.height + delta.y)
                guard (try? NotebookValidation.validate(updated)) != nil else { continue }
                store.notebook.objects[index] = updated
            }
        } else if tool == .lasso {
            if let last = lassoPoints.last, hypot(point.x - last.x, point.y - last.y) >= 2 / ink.zoomScale { lassoPoints.append(point) }
            if lassoPoints.count > 256 { lassoPoints = lassoPoints.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element) }
        } else { marquee = area }
        surface.objects = store.notebook.objects; surface.selectedIDs = store.selectedIDs
        surface.reference = tool == .magic ? store.reference?.cgRect : nil
        updateCamera()
    }
    func finishSelectionDrag(cancelled: Bool) {
        guard let tool = dragTool else { return }
        let sameNotebook = dragNotebookID == store.notebook.id
        dragTool = nil; dragNotebookID = nil; startPoint = nil
        if sameNotebook {
            if cancelled {
                var restoreStrokeSelection = mixedDrag == nil
                for original in dragOriginals {
                    if let index = store.notebook.objects.firstIndex(where: { $0.id == original.id }) { store.notebook.objects[index] = original }
                }
                if let snapshot = mixedDrag {
                    restoreStrokeSelection = store.cancelSelectionMove(snapshot)
                }
                store.setSelection(objects: selectionBeforeDrag, strokes: restoreStrokeSelection ? strokesBeforeDrag : [])
                if tool == .magic { store.reference = referenceBeforeDrag }
            } else if tool == .lasso, mixedDrag == nil {
                selectWithLasso(lassoPoints)
            } else if tool == .select, let area = marquee {
                selectWithLasso([area.origin, CGPoint(x: area.maxX, y: area.minY), CGPoint(x: area.maxX, y: area.maxY), CGPoint(x: area.minX, y: area.maxY)])
            }
            if !dragOriginals.isEmpty || mixedDrag != nil { store.commit() }
        }
        marquee = nil; lassoPoints = []; dragOriginals = []; resizingID = nil; referenceBeforeDrag = nil
        selectionBeforeDrag = []; strokesBeforeDrag = []; mixedDrag = nil; mixedDragLastInk = nil
        if sameNotebook && !cancelled && tool == .magic {
            UIImpactFeedbackGenerator(style: .light).impactOccurred(); onReference?()
        }
    }
    func selectWithLasso(_ polygon: [CGPoint]) {
        guard polygon.count >= 3 else { store.clearSelection(); return }
        let ids = Set(store.notebook.objects.filter {
            if $0.kind == "frame" { return CanvasLasso.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY), polygon: polygon) }
            return CanvasLasso.intersects($0.rect, polygon: polygon)
        }.map(\.id))
        let strokes = CanvasLasso.selectedStrokes(in: store.worldInk, polygon: polygon)
        store.setSelection(objects: ids, strokes: strokes)
        store.status = store.hasSelection ? "Selection ready · drag to move, or use Copy, Duplicate and Delete" : "Nothing inside the lasso"
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
            finishZoomInteraction()
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

    private func recognizeCompletedStrokes() {
        // Replacing drawing while another Pencil stroke is in flight can cancel it.
        guard !isApplyingDrawing, !isZoomInteractionActive, inkSessionTool == nil, store.settings.recognizeShapes else { return }
        completedShapeSessions.removeAll {
            $0.notebookID != store.notebook.id || ($0.endedAt.map { Date().timeIntervalSince($0) > 3 } ?? true)
        }
        let sessions = completedShapeSessions
        for session in sessions {
            let strokes = worldDrawing.strokes
            let candidates = strokes.filter { stroke in
                let identity = ShapeStrokeIdentity(stroke)
                guard session.accepts(identity) else { return false }
                // A cancelled interaction must not claim the next interaction's stroke.
                let owner = sessions.filter { $0.accepts(identity) }.min {
                    abs(identity.createdAt.timeIntervalSince($0.startedAt)) < abs(identity.createdAt.timeIntervalSince($1.startedAt))
                }
                return owner?.id == session.id
            }
            guard let stroke = candidates.min(by: { $0.path.creationDate < $1.path.creationDate }) else { continue }
            completedShapeSessions.removeAll { $0.id == session.id }
            guard stroke.mask == nil, stroke.path.count >= 3 else { continue }
            let points = stroke.path.map { $0.location.applying(stroke.transform) }
            guard let recognized = StrokeShapeRecognizer.recognize(points) else { continue }
            let object = recognized.object(color: stroke.ink.color, width: session.width)
            let target = ShapeStrokeIdentity(stroke)
            guard let index = strokes.firstIndex(where: { ShapeStrokeIdentity($0) == target }) else { continue }
            var remaining = strokes
            remaining.remove(at: index)
            // Validate a complete proposal before removing any ink (including at the object cap).
            var proposed = store.notebook
            proposed.objects.append(object)
            proposed.drawingData = PKDrawing(strokes: remaining).dataRepresentation()
            do { try NotebookValidation.validate(proposed) }
            catch { store.status = "Kept your ink: \(error.localizedDescription)"; continue }
            // Raw ink and its replacement have separate undo entries. Undo restores handwriting.
            store.commit()
            store.checkpoint()
            isApplyingDrawing = true
            ink.drawing = PKDrawing(strokes: remaining).transformed(using: CGAffineTransform(translationX: inkOrigin.x, y: inkOrigin.y))
            lastNativeDrawing = ink.drawing.dataRepresentation()
            lastDrawing = proposed.drawingData
            store.notebook = proposed
            isApplyingDrawing = false
            store.commit()
            surface.objects = store.notebook.objects
            store.status = "Recognized \(recognized.title.lowercased()) · Undo to restore your stroke"
        }
    }
}

/// These fields survive drawing serialization and native-coordinate rebasing on iPadOS 18+.
/// Unlike an array index or .last, they still identify the same stroke after more ink arrives.
struct ShapeStrokeIdentity: Hashable {
    var createdAt: Date
    var seed: UInt32
    init(_ stroke: PKStroke) { createdAt = stroke.path.creationDate; seed = stroke.randomSeed }
}

private struct ShapeStrokeSession {
    var id = UUID()
    var notebookID: UUID
    var existing: Set<ShapeStrokeIdentity>
    var startedAt: Date
    var width: CGFloat
    var endedAt: Date?
    func accepts(_ identity: ShapeStrokeIdentity) -> Bool {
        guard let endedAt, !existing.contains(identity) else { return false }
        // PencilKit stamps path creation near touch-down, before its delayed force commit.
        return identity.createdAt >= startedAt.addingTimeInterval(-0.1) && identity.createdAt <= endedAt.addingTimeInterval(0.1)
    }
}

struct RecognizedStrokeShape {
    var kind: String
    var title: String
    var bounds: CGRect
    var vertices: [CGPoint] = []
    @MainActor func object(color: UIColor, width: CGFloat) -> CanvasObject {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let hex = String(format: "#%02X%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255), Int(alpha * 255))
        var properties: [String: Double] = ["recognizedOutline": 1, "opacity": 0, "strokeWidth": Double(width)]
        if !vertices.isEmpty {
            properties["vertexCount"] = Double(vertices.count)
            for (index, point) in vertices.enumerated() {
                properties["vertex\(index)X"] = Double((point.x - bounds.minX) / bounds.width)
                properties["vertex\(index)Y"] = Double((point.y - bounds.minY) / bounds.height)
            }
        }
        // Fitted polygons preserve the actual drawn orientation. They intentionally do not
        // expose canonical triangle angle controls, whose geometry would be different.
        return CanvasObject(kind: "shape", title: title, x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: bounds.height, color: hex, properties: properties,
            shape: vertices.isEmpty ? kind : "polygon")
    }
}

/// Original closed-contour fitting: uniform arc-length samples, polygon edge residuals,
/// orthogonal rectangle fitting, and ellipse radial residuals. No external recognizer code.
enum StrokeShapeRecognizer {
    static func recognize(_ input: [CGPoint]) -> RecognizedStrokeShape? {
        guard input.count >= 8, input.count <= 100_000, input.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var points: [CGPoint] = []
        for point in input where points.last.map({ distance($0, point) > 0.05 }) ?? true { points.append(point) }
        guard points.count >= 8, let first = points.first, let last = points.last else { return nil }
        let box = bounds(points), extent = max(box.width, box.height)
        guard min(box.width, box.height) >= 18 else { return nil }
        let openLength = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + distance($1.0, $1.1) }
        guard distance(first, last) <= min(extent * 0.16, openLength * 0.055),
              openLength > extent * 2, openLength < extent * 5.5 else { return nil }
        let samples = resample(points, count: 128)
        guard abs(area(samples)) > box.width * box.height * 0.28 else { return nil }
        var pair = (0, 1), longest: CGFloat = 0
        for i in samples.indices {
            for j in (i + 1)..<samples.count {
                let length = distance(samples[i], samples[j])
                if length > longest { pair = (i, j); longest = length }
            }
        }
        let firstArc = Array(samples[pair.0...pair.1])
        let secondArc = Array(samples[pair.1...]) + Array(samples[...pair.0])
        let corners = Array(simplify(firstArc, tolerance: extent * 0.035).dropLast())
            + Array(simplify(secondArc, tolerance: extent * 0.035).dropLast())
        if (3...4).contains(corners.count), convex(corners), polygonFits(corners, samples: samples, extent: extent) {
            if corners.count == 3 {
                let angles = cornerCosines(corners)
                if angles.allSatisfy({ $0 > -0.94 && $0 < 0.97 }) {
                    return RecognizedStrokeShape(kind: "triangle", title: "Triangle", bounds: bounds(corners), vertices: corners)
                }
            } else if cornerCosines(corners).allSatisfy({ abs($0) < 0.38 }) {
                let a = unit(subtract(corners[1], corners[0])), b = unit(subtract(corners[2], corners[3]))
                let u = unit(CGPoint(x: a.x + b.x, y: a.y + b.y)), v = CGPoint(x: -u.y, y: u.x)
                let xs = samples.map { dot($0, u) }.sorted(), ys = samples.map { dot($0, v) }.sorted()
                let low = samples.count / 40, high = samples.count - 1 - low
                let centerX = (xs[low] + xs[high]) / 2, centerY = (ys[low] + ys[high]) / 2
                var width = xs[high] - xs[low], height = ys[high] - ys[low]
                let square = abs(width / height - 1) < 0.14
                if square { let side = (width + height) / 2; width = side; height = side }
                let vertices = [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1)].map {
                    let x = centerX + $0.x * width / 2, y = centerY + $0.y * height / 2
                    return CGPoint(x: x * u.x + y * v.x, y: x * u.y + y * v.y)
                }
                return RecognizedStrokeShape(kind: "rectangle", title: square ? "Square" : "Rectangle", bounds: bounds(vertices), vertices: vertices)
            }
        }
        let normalized = samples.map { CGPoint(x: ($0.x - box.midX) / (box.width / 2), y: ($0.y - box.midY) / (box.height / 2)) }
        let errors = normalized.map { abs(hypot($0.x, $0.y) - 1) }
        let rms = sqrt(errors.reduce(0) { $0 + $1 * $1 } / CGFloat(errors.count))
        let winding = zip(normalized, normalized.dropFirst() + [normalized[0]]).reduce(CGFloat.zero) {
            $0 + atan2(cross($1.0, $1.1), dot($1.0, $1.1))
        }
        guard rms < 0.085, errors.sorted()[errors.count * 95 / 100] < 0.16,
              abs(abs(winding) - 2 * .pi) < 0.5, abs(area(normalized)) > 2.65 else { return nil }
        let circle = abs(box.width / box.height - 1) < 0.14
        let side = (box.width + box.height) / 2
        let fitted = circle ? CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side) : box
        return RecognizedStrokeShape(kind: circle ? "circle" : "ellipse", title: circle ? "Circle" : "Ellipse", bounds: fitted)
    }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private static func subtract(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
    private static func cross(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.y - a.y * b.x }
    private static func unit(_ a: CGPoint) -> CGPoint {
        let length = max(0.000001, hypot(a.x, a.y))
        return CGPoint(x: a.x / length, y: a.y / length)
    }
    private static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
    private static func area(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst() + [points[0]]).reduce(0) { $0 + cross($1.0, $1.1) } / 2
    }
    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let closed = points + [points[0]]
        var lengths: [CGFloat] = [0]
        for (a, b) in zip(closed, closed.dropFirst()) { lengths.append(lengths.last! + distance(a, b)) }
        let length = lengths.last!
        var segment = 1, result: [CGPoint] = []
        for index in 0..<count {
            let target = CGFloat(index) * length / CGFloat(count)
            while segment < lengths.count - 1 && lengths[segment] < target { segment += 1 }
            let fraction = (target - lengths[segment - 1]) / max(0.000001, lengths[segment] - lengths[segment - 1])
            let a = closed[segment - 1], b = closed[segment]
            result.append(CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction))
        }
        return result
    }
    private static func segmentDistance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = subtract(b, a)
        let t = min(1, max(0, dot(subtract(point, a), ab) / max(0.000001, dot(ab, ab))))
        return distance(point, CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y))
    }
    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let a = points[0], b = points.last!
        var index = 0, error: CGFloat = 0
        for i in 1..<(points.count - 1) {
            let d = segmentDistance(points[i], a, b)
            if d > error { index = i; error = d }
        }
        guard error > tolerance else { return [a, b] }
        return Array(simplify(Array(points[...index]), tolerance: tolerance).dropLast()) + simplify(Array(points[index...]), tolerance: tolerance)
    }
    private static func convex(_ corners: [CGPoint]) -> Bool {
        let turns = corners.indices.map { i in
            cross(subtract(corners[(i + 1) % corners.count], corners[i]), subtract(corners[(i + 2) % corners.count], corners[(i + 1) % corners.count]))
        }
        return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
    }
    private static func cornerCosines(_ corners: [CGPoint]) -> [CGFloat] {
        corners.indices.map { i in
            dot(unit(subtract(corners[(i + corners.count - 1) % corners.count], corners[i])),
                unit(subtract(corners[(i + 1) % corners.count], corners[i])))
        }
    }
    private static func polygonFits(_ corners: [CGPoint], samples: [CGPoint], extent: CGFloat) -> Bool {
        let edges = Array(zip(corners, corners.dropFirst() + [corners[0]]))
        guard edges.allSatisfy({ distance($0.0, $0.1) > extent * 0.13 }) else { return false }
        let residuals = samples.map { point in edges.map { segmentDistance(point, $0.0, $0.1) }.min()! }
        let rms = sqrt(residuals.reduce(0) { $0 + $1 * $1 } / CGFloat(samples.count))
        return rms < extent * 0.025 && residuals.max()! < extent * 0.065
    }
}

@MainActor
private final class CanvasSurfaceView: UIView {
    var objects: [CanvasObject] = []
    var selectedIDs: Set<UUID> = []
    var reference: CGRect?
    var marquee: CGRect?
    var lassoPoints: [CGPoint] = []
    var mixedSelectionBounds: CGRect?
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
        if let area = mixedSelectionBounds { drawRegion(area.insetBy(dx: -6 / zoom, dy: -6 / zoom), context: context, purple: false) }
        if let first = lassoPoints.first {
            context.saveGState()
            context.move(to: first)
            for point in lassoPoints.dropFirst() { context.addLine(to: point) }
            context.setStrokeColor(UIColor.systemBlue.cgColor); context.setLineWidth(1.5 / zoom)
            context.setLineDash(phase: 0, lengths: [5 / zoom, 4 / zoom]); context.strokePath()
            context.restoreGState()
        }
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
        if selectedIDs.count == 1 && mixedSelectionBounds == nil {
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
