import WebKit

/// Speaks the Qt WebChannel-style protocol the web UI uses with the shell
/// (port of HandleInboundJSON / SendToJS from the Windows build).
final class ShellBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    /// (event, args) from the web UI.
    var onEvent: ((String, [String]) -> Void)?
    /// Internal messages from our injected scripts (fullscreen, back button).
    var onNative: (([String: Any]) -> Void)?

    private let trustedOrigin: (host: String, port: Int)
    private var nextId = 1
    private(set) var isReady = false
    private var pending: [(String, Any)] = []

    init(origin: URL) {
        trustedOrigin = (origin.host ?? "127.0.0.1", origin.port ?? 80)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        let so = message.frameInfo.securityOrigin
        if message.name == "stremioNative" {
            if let body = message.body as? [String: Any] { onNative?(body) }
            return
        }
        // Only the web UI itself may drive the player.
        guard so.host == trustedOrigin.host, so.port == trustedOrigin.port,
              let text = message.body as? String else { return }
        handleInbound(text)
    }

    private func handleInbound(_ text: String) {
        Log.debug("[JS -> NATIVE]: \(text)")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            Log.info("[BRIDGE]: Unparseable message")
            return
        }
        let type = obj["type"] as? Int ?? 0

        if type == 3 {
            // Init: describe the "transport" object like QWebChannel does.
            let transport: [String: Any] = [
                "properties": [
                    1,
                    [0, "shellVersion", 0, AppInfo.version],
                    [0, "BrowserExtensions", 0, [String: Any]()],
                ],
                "signals": [[0, "handleInboundJSONSignal"]],
                "methods": [["onEvent", "handleInboundJSON"]],
            ]
            post(["id": 0, "data": ["transport": transport]])
            return
        }

        guard type == 6, let method = obj["method"] as? String,
              method == "handleInboundJSON" || method == "onEvent" else { return }
        guard let args = obj["args"] as? [Any], !args.isEmpty else {
            Log.info("[BRIDGE]: invokeMethod without args")
            return
        }
        let event = args[0] as? String ?? "Unknown"
        var argv = [String]()
        if args.count > 1 {
            switch args[1] {
            case let list as [Any]: argv = list.map(Self.stringify)
            case let s as String: argv = [s]
            default: argv = [Self.stringify(args[1])]
            }
        }
        onEvent?(event, argv)
    }

    /// Non-string values become their JSON text, like nlohmann::json::dump().
    private static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]) {
            return String(decoding: d, as: UTF8.self)
        }
        return "\(v)"
    }

    // MARK: Outbound

    func markReady() {
        isReady = true
        let queued = pending
        pending.removeAll()
        for (name, data) in queued { send(name, data) }
    }

    func reset() { isReady = false }

    /// Sends now if the UI is ready, otherwise after app-ready (g_outboundMessages).
    func enqueue(_ name: String, _ data: Any) {
        if isReady { send(name, data) } else { pending.append((name, data)) }
    }

    func send(_ name: String, _ data: Any) {
        let msg: [String: Any] = ["type": 1, "object": "transport", "id": nextId, "args": [name, data]]
        nextId += 1
        post(msg)
    }

    private func post(_ obj: Any) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let payload = String(decoding: data, as: UTF8.self)
        Log.debug("[NATIVE -> JS]: \(payload.prefix(300))")
        let js = "window.__stremioShellDeliver && window.__stremioShellDeliver(\(Scripts.jsString(payload)))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
