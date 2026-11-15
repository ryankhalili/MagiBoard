import UIKit
import WebKit

struct WidgetHostRequest: Codable {
    var version: Int = 1
    var requestID: String
    var operations: [WidgetHostOperation]
}
struct WidgetHostOperation: Codable {
    enum Kind: String, Codable { case create, duplicate, update }
    var type: Kind
    var object: CanvasObject? = nil
    var id: UUID? = nil
    var patch: WidgetObjectPatch? = nil
    var dx: Double? = nil
    var dy: Double? = nil
}
struct WidgetObjectPatch: Codable {
    var title: String? = nil
    var x: Double? = nil
    var y: Double? = nil
    var width: Double? = nil
    var height: Double? = nil
    var color: String? = nil
    var text: String? = nil
    var properties: [String: Double]? = nil
    var code: String? = nil
    var shape: String? = nil
    var pattern: String? = nil
    func applying(to original: CanvasObject) -> CanvasObject {
        var object = original
        if let title { object.title = title }; if let x { object.x = x }; if let y { object.y = y }
        if let width { object.width = width }; if let height { object.height = height }
        if let color { object.color = color }; if let text { object.text = text }
        if let code { object.code = code }; if let shape { object.shape = shape }; if let pattern { object.pattern = pattern }
        if let properties { object.properties.merge(properties) { _, new in new } }
        return object
    }
}
struct WidgetObjectSummary: Codable, Equatable {
    var id: UUID
    var kind: String
    var title: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var properties: [String: Double]
    init(_ object: CanvasObject) {
        id = object.id; kind = object.kind; title = object.title
        x = object.x; y = object.y; width = object.width; height = object.height; properties = object.properties
    }
}
struct WidgetHostResult: Codable {
    var objects: [WidgetObjectSummary]
    var ids: [UUID] { objects.map(\.id) }
    enum CodingKeys: String, CodingKey { case objects, ids }
    init(objects: [WidgetObjectSummary]) { self.objects = objects }
    init(from decoder: Decoder) throws { objects = try decoder.container(keyedBy: CodingKeys.self).decode([WidgetObjectSummary].self, forKey: .objects) }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(objects, forKey: .objects); try container.encode(ids, forKey: .ids)
    }
}

/// A typed document protocol, not a general native-code bridge. All changes pass the
/// same atomic validation boundary as an agent response and create one Undo entry.
@MainActor
enum WidgetHostProtocol {
    static func decode(_ body: Any) throws -> WidgetHostRequest {
        guard JSONSerialization.isValidJSONObject(body) else { throw NotebookError.invalid("Invalid widget request.") }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 262_144 else { throw NotebookError.invalid("Widget requests must be smaller than 256 KB.") }
        let request = try JSONDecoder().decode(WidgetHostRequest.self, from: data)
        try validate(request)
        return request
    }
    static func validate(_ request: WidgetHostRequest) throws {
        guard request.version == 1, !request.requestID.isEmpty, request.requestID.utf8.count <= 80,
              !request.operations.isEmpty, request.operations.count <= 24 else {
            throw NotebookError.invalid("A widget request needs 1–24 supported operations.")
        }
    }
    static func apply(_ request: WidgetHostRequest, sourceID: UUID, store: NotebookStore) throws -> WidgetHostResult {
        try validate(request)
        guard store.notebook.objects.contains(where: { $0.id == sourceID && $0.kind == "widget" }) else {
            throw NotebookError.invalid("The interactive source object no longer exists.")
        }
        var proposed = store.notebook
        var operations: [AgentOperation] = []
        var results: [WidgetObjectSummary] = []
        for operation in request.operations {
            let object: CanvasObject
            switch operation.type {
            case .create:
                guard var supplied = operation.object else { throw NotebookError.invalid("Create requires an object.") }
                supplied.id = UUID() // Widgets cannot overwrite an existing object by reusing its ID.
                object = supplied
                proposed.objects.append(object)
                operations.append(AgentOperation(type: "add", object: object))
            case .duplicate:
                guard let id = operation.id, var copy = proposed.objects.first(where: { $0.id == id }) else {
                    throw NotebookError.invalid("The object to duplicate could not be found.")
                }
                copy.id = UUID(); copy.x += operation.dx ?? 36; copy.y += operation.dy ?? 36
                object = copy
                proposed.objects.append(object)
                operations.append(AgentOperation(type: "add", object: object))
            case .update:
                guard let id = operation.id, let patch = operation.patch,
                      let index = proposed.objects.firstIndex(where: { $0.id == id }) else {
                    throw NotebookError.invalid("Update requires an existing object ID and a patch.")
                }
                object = patch.applying(to: proposed.objects[index])
                proposed.objects[index] = object
                operations.append(AgentOperation(type: "update", id: id, object: object))
            }
            try NotebookValidation.validate(object)
            results.append(WidgetObjectSummary(object))
        }
        try NotebookValidation.validate(proposed)
        try store.apply(AgentResponse(message: "Interactive object updated the canvas", operations: operations))
        return WidgetHostResult(objects: results)
    }
}

struct WidgetMutationBudget {
    private var tokens = 120.0
    private var lastTime: TimeInterval?
    mutating func consume(_ count: Int, at time: TimeInterval) -> Bool {
        if let lastTime { tokens = min(120, tokens + max(0, time - lastTime) * 2) }
        lastTime = time
        guard count > 0, count <= 24, Double(count) <= tokens else { return false }
        tokens -= Double(count)
        return true
    }
}

private final class WeakWidgetMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: CanvasWidgetView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

/// Widget HTML runs in an origin-isolated, network-blocked iframe. A narrow native
/// bridge accepts validated document operations only while the user enables Interact.
@MainActor
final class CanvasWidgetView: UIView, WKNavigationDelegate, UIGestureRecognizerDelegate {
    private let webView: WKWebView
    private var loadedCode: String?
    private var loadedObject: WidgetObjectSummary?
    private var objectID: UUID?
    private var snapshotTask: Task<Void, Never>?
    private var interactive = false
    private var channel = UUID().uuidString
    private var mutationBudget = WidgetMutationBudget()
    private var processedRequests: Set<String> = []
    var onHostRequest: ((WidgetHostRequest) throws -> WidgetHostResult)?

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        let handler = WeakWidgetMessageHandler(); handler.owner = self
        configuration.userContentController.add(handler, name: "canvasHost")
        clipsToBounds = true
        backgroundColor = .clear
        webView.navigationDelegate = self
        webView.isOpaque = false; webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.allowsLinkPreview = false
        addSubview(webView)
        let captureTap = UITapGestureRecognizer(target: self, action: #selector(captureAfterInteraction))
        captureTap.cancelsTouchesInView = false; captureTap.delegate = self
        webView.addGestureRecognizer(captureTap)
        accessibilityLabel = "Interactive canvas object"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); webView.frame = bounds }
    func update(object: CanvasObject, interactive: Bool, scale: CGFloat) {
        let previousID = objectID
        objectID = object.id
        if self.interactive && !interactive { webView.endEditing(true) }
        self.interactive = interactive
        webView.isUserInteractionEnabled = interactive
        isUserInteractionEnabled = interactive
        accessibilityLabel = object.title.isEmpty ? "Interactive canvas object" : object.title
        let summary = WidgetObjectSummary(object)
        let state = Self.json(summary)
        if loadedCode == object.code, previousID == object.id {
            if loadedObject != summary {
                loadedObject = summary
                webView.evaluateJavaScript("window.__canvasHostState(\(state))", completionHandler: nil)
            }
            return
        }
        loadedCode = object.code; loadedObject = summary
        channel = UUID().uuidString; processedRequests = []
        let source = object.code.isEmpty ? "<p style='font:16px -apple-system;padding:16px;color:#64748b'>Add HTML behavior in Properties.</p>" : object.code
        let script = """
        (()=>{'use strict';
          let sequence=0; const pending=new Map();
          function state(value){window.canvasObject=value;window.properties=value.properties;window.canvasProperties=value.properties;window.objectProperties=value.properties;}
          state(\(state));
          function batch(operations){return new Promise((resolve,reject)=>{
            if(pending.size>=8){reject(new Error('Wait for the pending canvas changes.'));return;}
            const requestID=Date.now().toString(36)+'-'+(++sequence);
            const timer=setTimeout(()=>{pending.delete(requestID);reject(new Error('Canvas request timed out.'));},8000);
            pending.set(requestID,{resolve,reject,timer});
            parent.postMessage({type:'canvas-request',request:{version:1,requestID,operations}},'*');
          });}
          window.canvasHost=Object.freeze({batch,
            create:object=>batch([{type:'create',object}]).then(r=>r.objects[0]),
            duplicate:(id,offset={})=>batch([{type:'duplicate',id,dx:offset.dx,dy:offset.dy}]).then(r=>r.objects[0]),
            update:(id,patch)=>batch([{type:'update',id,patch}]).then(r=>r.objects[0])
          });
          addEventListener('message',event=>{
            if(event.source!==parent||!event.data)return;
            if(event.data.type==='canvas-state'){
              state(event.data.value);
              dispatchEvent(new CustomEvent('canvaspropertieschange',{detail:window.properties}));
              dispatchEvent(new CustomEvent('canvasobjectchange',{detail:window.canvasObject}));
            }else if(event.data.type==='canvas-reply'){
              const r=event.data.value,p=pending.get(r.requestID);if(!p)return;
              clearTimeout(p.timer);pending.delete(r.requestID);r.ok?p.resolve(r.result):p.reject(new Error(r.error));
            }
          });
        })();
        """
        let payload = "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1\"><style>html,body{margin:0;min-height:100%;font-family:-apple-system,system-ui,sans-serif;box-sizing:border-box;background:transparent}*{box-sizing:border-box}</style><script>\(script)</script>\(source)"
        let escaped = payload.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; frame-src about: 'self'; child-src about: 'self'; connect-src 'none'; media-src data: blob:; form-action 'none'; base-uri 'none'">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}iframe{border:0;width:100%;height:100%;display:block}</style></head><body><iframe id="object" sandbox="allow-scripts" srcdoc="\(escaped)"></iframe>
        <script>
        const child=document.getElementById('object');
        window.__canvasHostState=value=>child.contentWindow.postMessage({type:'canvas-state',value},'*');
        window.__canvasHostReply=value=>child.contentWindow.postMessage({type:'canvas-reply',value},'*');
        addEventListener('message',event=>{if(event.source!==child.contentWindow||event.data?.type!=='canvas-request')return;
          window.webkit.messageHandlers.canvasHost.postMessage({channel:'\(channel)',request:event.data.request});});
        </script></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
    private static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string.replacingOccurrences(of: "<", with: "\\u003c")
    }
    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.name == "canvasHost",
              let envelope = message.body as? [String: Any], envelope["channel"] as? String == channel,
              let body = envelope["request"] as? [String: Any], let requestID = body["requestID"] as? String, requestID.utf8.count <= 80 else { return }
        struct Reply: Encodable { var requestID: String; var ok: Bool; var result: WidgetHostResult?; var error: String? }
        let reply: Reply
        do {
            let request = try WidgetHostProtocol.decode(body)
            guard interactive, let onHostRequest else { throw NotebookError.invalid("Choose Interact to use this object's canvas actions.") }
            guard !processedRequests.contains(requestID) else { throw NotebookError.invalid("This canvas request was already handled.") }
            guard mutationBudget.consume(request.operations.count, at: ProcessInfo.processInfo.systemUptime) else {
                throw NotebookError.invalid("This object is changing the canvas too quickly. Try again in a moment.")
            }
            processedRequests.insert(requestID)
            if processedRequests.count > 512 { processedRequests = [requestID] }
            reply = Reply(requestID: requestID, ok: true, result: try onHostRequest(request), error: nil)
            captureAfterInteraction()
        } catch {
            reply = Reply(requestID: requestID, ok: false, result: nil, error: error.localizedDescription)
        }
        webView.evaluateJavaScript("window.__canvasHostReply(\(Self.json(reply)))", completionHandler: nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let allowed = url == nil || ["about:blank", "about:srcdoc"].contains(url?.absoluteString ?? "")
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let loadedObject { webView.evaluateJavaScript("window.__canvasHostState(\(Self.json(loadedObject)))", completionHandler: nil) }
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.captureSnapshot()
        }
    }
    @objc private func captureAfterInteraction() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.captureSnapshot()
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    func captureSnapshot() {
        guard bounds.width > 0, bounds.height > 0, let id = objectID else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: min(1200, bounds.width * 2))
        webView.takeSnapshot(with: config) { image, _ in
            guard let image else { return }
            Task { @MainActor in ObjectRenderer.shared.widgetSnapshots[id] = image }
        }
    }
}
