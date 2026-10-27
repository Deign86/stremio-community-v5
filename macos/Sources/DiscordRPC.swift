import Foundation

/// Minimal Discord Rich Presence client over Discord's local IPC socket
/// ($TMPDIR/discord-ipc-N), replacing the discord-rpc library used on Windows.
final class DiscordRPC {
    private static let clientID = "1361448446862692492"
    private let queue = DispatchQueue(label: "discord.rpc")
    private var fd: Int32 = -1

    var enabled = true {
        didSet { if !enabled { clear() } }
    }

    /// Mirrors SetDiscordPresenceFromArgs.
    func update(_ args: [String]) {
        guard enabled, let kind = args.first else { return }
        let a = { (i: Int) -> String in i < args.count ? args[i] : "" }
        var activity: [String: Any]?

        switch kind {
        case "watching" where args.count >= 11:
            // 1 type, 2 title, 3 season, 4 episode, 5 episode name, 6 episode thumb,
            // 7 poster, 8 elapsed, 9 duration, 10 paused, 11 details link, 12 stremio link
            var act: [String: Any] = ["type": 3, "details": a(2)]
            var assets: [String: Any] = ["large_image": a(7), "large_text": a(2)]
            if a(10) == "yes" {
                act["state"] = "Paused"
            } else {
                let now = Int(Date().timeIntervalSince1970)
                let elapsed = Int(Double(a(8)) ?? 0)
                let duration = Int(Double(a(9)) ?? 0)
                act["timestamps"] = ["start": now - elapsed, "end": now + max(0, duration - elapsed)]
                if a(1) == "series" {
                    act["state"] = "\(a(5)) (S\(a(3))-E\(a(4)))"
                    if !a(6).isEmpty {
                        assets["small_image"] = a(6)
                        assets["small_text"] = a(5)
                    }
                } else {
                    act["state"] = "Enjoying a Movie"
                }
            }
            act["assets"] = assets
            var buttons = [[String: String]]()
            if !a(11).isEmpty { buttons.append(["label": "More Details", "url": a(11)]) }
            if !a(12).isEmpty { buttons.append(["label": "Watch on Stremio", "url": a(12)]) }
            if !buttons.isEmpty { act["buttons"] = buttons }
            activity = act
        case "meta-detail" where args.count >= 4:
            activity = [
                "type": 3,
                "details": a(2),
                "state": a(1) == "movie" ? "Exploring a Movie" : "Exploring a Series",
                "assets": ["large_image": a(3), "large_text": a(2)],
            ]
        case "board": activity = discover("Resuming Favorites", "On Board")
        case "discover": activity = discover("Finding New Gems", "In Discover")
        case "library": activity = discover("Revisiting Old Favorites", "In Library")
        case "calendar": activity = discover("Planning My Next Binge", "On Calendar")
        case "addons": activity = discover("Exploring Add-ons", "In Add-ons")
        case "settings": activity = discover("Tuning Preferences", "In Settings")
        case "search": activity = discover("Searching for Shows & Movies", "In Search")
        case "clear": clear(); return
        default: return
        }
        setActivity(activity)
    }

    private func discover(_ details: String, _ state: String) -> [String: Any] {
        [
            "type": 3,
            "details": details,
            "state": state,
            "assets": [
                "large_image": "https://raw.githubusercontent.com/Stremio/stremio-web/refs/heads/development/images/icon.png",
                "large_text": "Stremio",
            ],
        ]
    }

    func clear() { setActivity(nil) }

    private func setActivity(_ activity: [String: Any]?) {
        queue.async { [self] in
            var args: [String: Any] = ["pid": Int(getpid())]
            if let activity { args["activity"] = activity }
            let frame: [String: Any] = ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString]
            if !connect() { return }
            if !write(op: 1, frame) {
                disconnect()
                if connect() { _ = write(op: 1, frame) }
            }
        }
    }

    // MARK: IPC

    private func connect() -> Bool {
        if fd >= 0 { return true }
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        for i in 0..<10 {
            let path = (tmp as NSString).appendingPathComponent("discord-ipc-\(i)")
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            if s < 0 { continue }
            var on: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(s); continue }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                bytes.withUnsafeBytes { raw.copyMemory(from: $0) }
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if rc != 0 { close(s); continue }
            fd = s
            if write(op: 0, ["v": 1, "client_id": Self.clientID]) {
                Log.info("[DISCORD]: Connected via \(path)")
                return true
            }
            disconnect()
        }
        return false
    }

    private func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private func write(op: Int32, _ obj: [String: Any]) -> Bool {
        guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        var packet = Data()
        withUnsafeBytes(of: op.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(body.count).littleEndian) { packet.append(contentsOf: $0) }
        packet.append(body)
        let sent = packet.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, packet.count, 0) }
        guard sent == packet.count else { return false }
        drainReplies()
        return true
    }

    /// Reads and discards Discord's replies so the socket buffer never fills.
    private func drainReplies() {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var buf = [UInt8](repeating: 0, count: 4096)
        while poll(&pfd, 1, 150) > 0 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { disconnect(); return }
        }
    }
}
