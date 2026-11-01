// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import WebKit

/// Runs web-bml in a transparent WKWebView that lies over the picture.
///
/// The page and its fonts come from the app through a URL scheme of our own, and everything else is
/// shut out: a content rule list blocks all other URLs, and the page has no way to navigate. A BML
/// document reaches the network only through `BMLNetwork`.
final class BMLBrowser: NSObject {
    private static let scheme = "bonbori-bml"
    private static let pageHandler = "bonbori"
    private static let httpHandler = "bonboriHTTP"
    /// Keeps localStorage, where the NVRAM of the broadcasters is, apart from anything else WebKit keeps.
    private static let storeID = UUID(uuidString: "6A0E1B5C-3F0D-4B8E-9D55-8C2F7D1E4A10")!
    private static let blockList = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^\(scheme):"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
        """

    /// Where the page is kept in the app, or nil if the app was built without it.
    static let resources: URL? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("DataBroadcasting", isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) else { return nil }
        return url
    }()

    let webView: WKWebView
    /// A message from the page.
    var onMessage: (([String: Any]) -> Void)?
    /// The page has loaded and takes calls.
    var onPageLoaded: (() -> Void)?
    /// WebKit lost the page.
    var onPageLost: (() -> Void)?
    var log: (String) -> Void = { _ in }

    private let network: BMLNetwork
    private(set) var isPageLoaded = false
    private var pageURL: URL?

    init(resources: URL, network: BMLNetwork, debug: Bool) {
        self.network = network
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: BMLBrowser.storeID)
        config.setURLSchemeHandler(ResourceHandler(root: resources), forURLScheme: BMLBrowser.scheme)
        // the sounds of a document play by themselves, like on a TV
        config.mediaTypesRequiringUserActionForPlayback = []
        if debug {
            config.userContentController.addUserScript(WKUserScript(source: BMLBrowser.consoleBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = debug
        // so that the picture shows through. There is no public way to do this on the Mac.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        super.init()
        webView.navigationDelegate = self
        let controller = config.userContentController
        controller.add(WeakHandler(self), contentWorld: .page, name: BMLBrowser.pageHandler)
        controller.addScriptMessageHandler(WeakHandler(self), contentWorld: .page, name: BMLBrowser.httpHandler)
    }

    /// Shuts the page off from the network. Must be done before the first `load`.
    func prepare(completion: @escaping () -> Void) {
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "BonboriDataBroadcasting", encodedContentRuleList: BMLBrowser.blockList) { [weak self] list, error in
            guard let self else { return }
            if let list {
                self.webView.configuration.userContentController.add(list)
                completion()
            } else {
                self.log("content rule list: \(String(describing: error))")
            }
        }
    }

    func load(serviceID: Int) {
        isPageLoaded = false
        var c = URLComponents()
        c.scheme = BMLBrowser.scheme
        c.host = "app"
        c.path = "/index.html"
        c.queryItems = [URLQueryItem(name: "serviceId", value: String(serviceID))]
        pageURL = c.url
        pageURL.map { _ = webView.load(URLRequest(url: $0)) }
    }

    func close() {
        isPageLoaded = false
        webView.stopLoading()
        let controller = webView.configuration.userContentController
        controller.removeAllScriptMessageHandlers()
        controller.removeAllContentRuleLists()
        webView.removeFromSuperview()
    }

    /// Calls a function of `window.bonbori`, which is defined by the page. `completion` runs when it has returned.
    func call(_ function: String, _ arguments: [Any] = [], completion: ((Any?) -> Void)? = nil) {
        guard isPageLoaded else {
            completion?(nil)
            return
        }
        let named = Dictionary(uniqueKeysWithValues: arguments.enumerated().map { ("a\($0.offset)", $0.element) })
        let list = arguments.indices.map { "a\($0)" }.joined(separator: ",")
        webView.callAsyncJavaScript("return bonbori.\(function)(\(list))", arguments: named, in: nil, in: .page) { [weak self] result in
            switch result {
            case .success(let value):
                completion?(value)
            case .failure(let error):
                self?.log("\(function): \(error)")
                completion?(nil)
            }
        }
    }

    /// Passes TS to the page. Base64 in a string is the quickest way in: WebKit has to copy anything else
    /// through the same kind of call, and there are only a few tens of kilobytes at a time.
    func stream(_ data: Data, completion: @escaping () -> Void) {
        guard isPageLoaded else {
            completion()
            return
        }
        webView.evaluateJavaScript("bonbori.stream('\(data.base64EncodedString())')") { _, _ in completion() }
    }

    private static let consoleBridge = """
        for (const level of ["log", "warn", "error"]) {
            const original = console[level];
            console[level] = (...args) => {
                original.apply(console, args);
                window.webkit.messageHandlers.bonbori.postMessage({ type: "log", text: level + ": " + args.join(" ") });
            };
        }
        window.addEventListener("error", (e) => {
            window.webkit.messageHandlers.bonbori.postMessage({ type: "log", text: "error: " + e.message + " at " + e.filename + ":" + e.lineno });
        });
        """
}

extension BMLBrowser: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme == BMLBrowser.scheme ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        onPageLoaded?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("navigation failed: \(error)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("web content process terminated")
        isPageLoaded = false
        onPageLost?()
    }
}

extension BMLBrowser: WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        onMessage?(body)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let method = body["method"] as? String, let uri = body["uri"] as? String else {
            replyHandler(nil, nil)
            return
        }
        network.request(method: method, uri: uri, body: (body["body"] as? String).flatMap { Data(base64Encoded: $0) }) { replyHandler($0, nil) }
    }
}

/// WKUserContentController keeps its handlers alive; this is what keeps it from keeping the browser.
private final class WeakHandler: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    private weak var target: BMLBrowser?

    init(_ target: BMLBrowser) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        if let target {
            target.userContentController(controller, didReceive: message, replyHandler: replyHandler)
        } else {
            replyHandler(nil, nil)
        }
    }
}

/// Serves the files of the page.
private final class ResourceHandler: NSObject, WKURLSchemeHandler {
    private static let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "woff2": "font/woff2"]

    private let root: URL

    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let file = root.appendingPathComponent(url.path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish()
            return
        }
        let type = ResourceHandler.types[file.pathExtension] ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
