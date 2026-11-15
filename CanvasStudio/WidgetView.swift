import UIKit
import WebKit

/// HTML objects execute inside an origin-isolated, network-blocked iframe.
/// They receive a copy of exposed properties and no native message handlers.
@MainActor
final class CanvasWidgetView: UIView, WKNavigationDelegate, UIGestureRecognizerDelegate {
    private let webView: WKWebView
    private var loadedCode: String?
    private var loadedProperties: [String: Double] = [:]
    private var loadedSize = CGSize.zero
    private var objectID: UUID?
    private var snapshotTask: Task<Void, Never>?
    private let interactionBadge = UILabel()

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frame)
        clipsToBounds = true; layer.cornerRadius = 16
        backgroundColor = .white
        webView.navigationDelegate = self
        webView.isOpaque = false; webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.allowsLinkPreview = false
        addSubview(webView)
        let captureTap = UITapGestureRecognizer(target: self, action: #selector(captureAfterInteraction))
        captureTap.cancelsTouchesInView = false
        captureTap.delegate = self
        webView.addGestureRecognizer(captureTap)
        interactionBadge.text = "  Double-tap to interact  "
        interactionBadge.font = .systemFont(ofSize: 10, weight: .medium)
        interactionBadge.textColor = .secondaryLabel
        interactionBadge.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        interactionBadge.layer.cornerRadius = 8; interactionBadge.clipsToBounds = true
        addSubview(interactionBadge)
        accessibilityLabel = "Interactive canvas object"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        interactionBadge.sizeToFit()
        interactionBadge.frame = CGRect(x: max(8, bounds.width - interactionBadge.bounds.width - 10), y: max(8, bounds.height - 28), width: interactionBadge.bounds.width, height: 20)
    }
    func update(object: CanvasObject, interactive: Bool, scale: CGFloat) {
        objectID = object.id
        webView.isUserInteractionEnabled = interactive
        isUserInteractionEnabled = interactive
        interactionBadge.isHidden = interactive
        let size = CGSize(width: object.width, height: object.height)
        guard loadedCode != object.code || loadedProperties != object.properties || loadedSize != size else { return }
        loadedCode = object.code; loadedProperties = object.properties; loadedSize = size
        let propertiesData = (try? JSONSerialization.data(withJSONObject: object.properties, options: [.sortedKeys])) ?? Data("{}".utf8)
        let properties = String(data: propertiesData, encoding: .utf8) ?? "{}"
        let source = object.code.isEmpty ? "<p style='font:16px -apple-system;padding:24px'>Create an interactive object with Magic Pen, or edit its code in the inspector.</p>" : object.code
        let payload = "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1\"><style>html,body{margin:0;min-height:100%;font-family:-apple-system,system-ui,sans-serif;box-sizing:border-box}*{box-sizing:border-box}</style><script>window.properties=\(properties.replacingOccurrences(of: "<", with: "\\u003c"));window.canvasProperties=window.properties;window.objectProperties=window.properties;</script>\(source)"
        let escaped = payload.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; frame-src about: 'self'; child-src about: 'self'; connect-src 'none'; media-src data: blob:; form-action 'none'; base-uri 'none'">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:white}iframe{border:0;width:100%;height:100%;display:block}</style></head><body><iframe sandbox="allow-scripts" srcdoc="\(escaped)"></iframe></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        // Initial local documents and the isolated srcdoc child are the only navigation surfaces.
        let allowed = url == nil || ["about:blank", "about:srcdoc"].contains(url?.absoluteString ?? "")
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
