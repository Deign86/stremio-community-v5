import Foundation
import Network
import CryptoKit

/// Serves the hosted web UI from http://127.0.0.1:<port>.
///
/// WebKit blocks an https page from calling the streaming server at
/// http://127.0.0.1:11470 (mixed content), which WebView2 on Windows allows.
/// Serving the UI from a loopback origin makes it a secure context that can reach
/// the server, and the Stremio API allows any origin. Responses are cached on
/// disk so the app still starts when the upstream site is unreachable.
final class WebUIServer {
    static let port: UInt16 = 11490
    static let upstreams = [
        "https://stremio.zarg.me/",
        "https://zaarrg.github.io/stremio-web-shell-fixes/",
        "https://web.stremio.com/",
    ].compactMap(URL.init(string:))

    let origin = URL(string: "http://127.0.0.1:\(WebUIServer.port)/")!
    var originString: String { "http://127.0.0.1:\(Self.port)" }
    private(set) var upstream: URL = WebUIServer.upstreams[0]

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "webui.server", attributes: .concurrent)
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20,
                                directory: Paths.webCache.appendingPathComponent("http", isDirectory: true))
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    /// Picks the first reachable upstream, like GetFirstReachableUrl. Blocking.
    func chooseUpstream() {
        for url in Self.upstreams where httpReachable(url, timeout: 4) {
            upstream = url
            Log.info("[WEBUI]: Using \(url.absoluteString)")
            return
        }
        // Offline: prefer whichever upstream we have a cached copy of.
        for url in Self.upstreams where FileManager.default.fileExists(atPath: cacheFile(url, path: "/").path) {
            upstream = url
            Log.info("[WEBUI]: Offline, using cached \(url.absoluteString)")
            return
        }
        Log.error("[WEBUI]: No web UI endpoint reachable")
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        if let failure { throw failure }
        listener = l
        Log.info("[WEBUI]: Serving on \(origin.absoluteString)")
    }

    func clearCache() {
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    // MARK: HTTP handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHeader(conn, buffer: Data())
    }

    private func receiveHeader(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(conn, header: buf[..<end.lowerBound])
            } else if error != nil || done || buf.count > 65536 {
                conn.cancel()
            } else {
                self.receiveHeader(conn, buffer: buf)
            }
        }
    }

    private func handle(_ conn: NWConnection, header: Data) {
        let text = String(decoding: header, as: UTF8.self)
        let parts = (text.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return respond(conn, 400, "text/plain", Data("Bad Request".utf8)) }
        let method = String(parts[0])
        let path = String(parts[1])
        guard method == "GET" || method == "HEAD" else {
            return respond(conn, 405, "text/plain", Data("Method Not Allowed".utf8))
        }
        guard let target = resolve(path) else {
            return respond(conn, 404, "text/plain", Data("Not Found".utf8))
        }
        let headOnly = method == "HEAD"
        let cachePath = cacheFile(upstream, path: path)

        session.dataTask(with: URLRequest(url: target)) { [weak self] data, resp, err in
            guard let self else { return }
            if let http = resp as? HTTPURLResponse, let data, err == nil {
                let type = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                if (200..<300).contains(http.statusCode) { self.store(cachePath, type: type, body: data) }
                self.respond(conn, http.statusCode, type, data, headOnly: headOnly)
            } else if let cached = self.load(cachePath) {
                self.respond(conn, 200, cached.type, cached.body, headOnly: headOnly)
            } else if path == "/" || path.hasPrefix("/?") {
                self.respond(conn, 503, "text/html; charset=utf-8", Data(Self.offlinePage.utf8), headOnly: headOnly)
            } else {
                self.respond(conn, 502, "text/plain", Data("Upstream unavailable".utf8), headOnly: headOnly)
            }
        }.resume()
    }

    /// Maps a request path onto the upstream, refusing anything that would leave its host.
    private func resolve(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        let relative = String(path.dropFirst())
        guard let url = relative.isEmpty ? upstream : URL(string: relative, relativeTo: upstream)?.absoluteURL,
              url.scheme == upstream.scheme, url.host == upstream.host else { return nil }
        return url
    }

    private func respond(_ conn: NWConnection, _ status: Int, _ type: String, _ body: Data, headOnly: Bool = false) {
        let reason = status == 200 ? "OK" : HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        if !headOnly { out.append(body) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: Offline cache

    private func cacheFile(_ base: URL, path: String) -> URL {
        let key = SHA256.hash(data: Data((base.absoluteString + path).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Paths.webCache.appendingPathComponent(base.host ?? "default", isDirectory: true)
            .appendingPathComponent(key)
    }

    private func store(_ file: URL, type: String, body: Data) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var blob = Data(type.utf8)
        blob.append(0)
        blob.append(body)
        try? blob.write(to: file, options: .atomic)
    }

    private func load(_ file: URL) -> (type: String, body: Data)? {
        guard let blob = try? Data(contentsOf: file), let nul = blob.firstIndex(of: 0) else { return nil }
        return (String(decoding: blob[..<nul], as: UTF8.self), blob[blob.index(after: nul)...])
    }

    private static let offlinePage = """
    <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="5">
    <title>Stremio</title><style>
    body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;
    background:#0c0b11;color:#ddd;font:15px -apple-system,sans-serif;text-align:center}
    </style></head><body><div><h2>Can't reach the Stremio web interface</h2>
    <p>Check your internet connection. Retrying automatically…</p></div></body></html>
    """
}
