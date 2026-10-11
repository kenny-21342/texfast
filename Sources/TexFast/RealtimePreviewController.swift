import AppKit
import WebKit

private final class PreviewMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: RealtimePreviewController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message.body)
    }
}

/// Hosts the existing rtex display-list renderer inside the native preview pane.
final class RealtimePreviewController: NSViewController, WKNavigationDelegate {
    private var webView: WKWebView!
    private let handler = PreviewMessageHandler()
    private var ready = false
    private var backlog: [[String: Any]] = []
    var onCommand: ((String) -> Void)?
    var onJump: ((Int, Double, Double) -> Void)?
    var onFailure: ((String) -> Void)?

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        handler.owner = self
        configuration.userContentController.add(handler, name: "texfast")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        view = webView
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("RealtimePreview") else { return }
        webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !ready else { return }
            onFailure?("Realtime renderer did not start")
        }
    }

    func post(_ value: [String: Any]) {
        _ = view
        guard ready else { backlog.append(value); return }
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.texfastReceive(\(json))") { [weak self] _, error in
            if let error { self?.onFailure?("Realtime renderer failed: \(error.localizedDescription)") }
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        switch message["type"] as? String {
        case "ready":
            ready = true
            let pending = backlog; backlog.removeAll()
            pending.forEach(post)
        case "command": if let command = message["command"] as? String { onCommand?(command) }
        case "jump":
            if let page = message["page"] as? Int, let x = message["x"] as? Double, let y = message["y"] as? Double { onJump?(page, x, y) }
        case "error", "log": NSLog("Realtime renderer: %@", message["message"] as? String ?? "unknown diagnostic")
        case "renderFailure": onFailure?(message["message"] as? String ?? "Realtime preview failed")
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure?(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure?(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure?("Realtime preview process exited") }

    // The renderer loads only bundled code; external navigation is handed to the browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, !url.isFileURL, url.scheme != "about" {
            NSWorkspace.shared.open(url); decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
}
