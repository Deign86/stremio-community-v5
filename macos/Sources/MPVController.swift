import Foundation

/// Owns the libmpv handle. Video is drawn by VideoLayer through the render API,
/// so mpv never opens a window of its own (vo=libmpv).
final class MPVController {
    private(set) var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "mpv.commands")

    /// (eventName, payload) — forwarded to the web UI.
    var onEvent: ((String, [String: Any]) -> Void)?
    /// Raw property changes, for native features (media keys, Discord).
    var onPropertyChange: ((String, Any) -> Void)?

    var currentVolume = 50
    private var initialSet = false

    func start(configDir: URL) -> Bool {
        guard let h = mpv_create() else {
            Log.error("[MPV]: Create failed")
            return false
        }
        handle = h
        setOption("config-dir", configDir.path)
        setOption("config", "yes")
        setOption("load-scripts", "yes")
        setOption("vo", "libmpv")
        setOption("idle", "yes")
        setOption("terminal", AppInfo.debug ? "yes" : "no")
        setOption("msg-level", AppInfo.debug ? "all=v" : "all=status")
        setOption("input-media-keys", "no")
        setOption("hwdec", "auto-safe")
        mpv_request_log_messages(h, AppInfo.debug ? "v" : "warn")

        mpv_set_wakeup_callback(h, { ctx in
            guard let ctx else { return }
            let me = Unmanaged<MPVController>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())

        if mpv_initialize(h) < 0 {
            Log.error("[MPV]: Initialize failed")
            return false
        }

        // mpv.conf may set vo=gpu-next for the Windows build; embedding needs libmpv.
        mpv_set_property_string(h, "vo", "libmpv")

        // Same demux/cache tuning as the Windows build.
        let props: [(String, String)] = [
            ("demuxer-lavf-probesize", "524288"),
            ("demuxer-lavf-analyzeduration", "0.5"),
            ("demuxer-max-bytes", "300000000"),
            ("demuxer-max-packets", "150000000"),
            ("cache", "yes"),
            ("cache-pause", "no"),
            ("cache-secs", "60"),
            ("vd-lavc-threads", "0"),
            ("ad-lavc-threads", "0"),
            ("audio-fallback-to-null", "yes"),
            ("audio-client-name", AppInfo.name),
            ("title", AppInfo.name),
        ]
        for (k, v) in props { mpv_set_property_string(h, k, v) }

        let api = Int(mpv_client_api_version())
        Log.info("[MPV]: Initialized (client API \(api >> 16).\(api & 0xffff))")
        return true
    }

    private func setOption(_ name: String, _ value: String) {
        guard let h = handle else { return }
        if mpv_set_option_string(h, name, value) < 0 {
            Log.info("[MPV]: Could not set option \(name)=\(value)")
        }
    }

    // MARK: Commands from the web UI

    func command(_ args: [String]) {
        guard !args.isEmpty else { return }
        if args[0] == "loadfile" {
            // Matches the Windows build: restore the last volume when a file loads.
            setProperty("volume", String(currentVolume))
            initialSet = true
        }
        queue.async { [weak self] in
            guard let h = self?.handle else { return }
            var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
            cargs.append(nil)
            defer { cargs.forEach { free($0) } }
            let rc = cargs.withUnsafeMutableBufferPointer { buf -> Int32 in
                buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) {
                    mpv_command(h, $0)
                }
            }
            if rc < 0 {
                Log.info("[MPV]: command \(args.first ?? "") failed: \(String(cString: mpv_error_string(rc)))")
            }
        }
    }

    func setProperty(_ name: String, _ value: String) {
        var v = value
        if v == "true" { v = "yes" }
        if v == "false" { v = "no" }
        queue.async { [weak self] in
            guard let h = self?.handle else { return }
            let rc = mpv_set_property_string(h, name, v)
            if rc < 0 {
                Log.debug("[MPV]: set \(name)=\(v) failed: \(String(cString: mpv_error_string(rc)))")
            }
        }
    }

    func observe(_ name: String) {
        queue.async { [weak self] in
            guard let h = self?.handle else { return }
            mpv_observe_property(h, 0, name, MPV_FORMAT_NODE)
        }
    }

    func pause() { setProperty("pause", "yes") }

    // MARK: Events

    private func drainEvents() {
        while let h = handle, let evp = mpv_wait_event(h, 0) {
            let ev = evp.pointee
            if ev.event_id == MPV_EVENT_NONE { break }
            switch ev.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let prop = ev.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                      let cname = prop.name else { break }
                let name = String(cString: cname)
                var data: Any = NSNull()
                if prop.format == MPV_FORMAT_NODE, let p = prop.data {
                    data = Self.nodeToAny(p.assumingMemoryBound(to: mpv_node.self).pointee)
                }
                var j: [String: Any] = ["type": "mpv-prop-change", "id": Int(ev.reply_userdata), "name": name, "data": data]
                if ev.error < 0 { j["error"] = String(cString: mpv_error_string(ev.error)) }
                if name == "volume", initialSet, let vol = data as? Double {
                    currentVolume = Int(vol.rounded())
                }
                onPropertyChange?(name, data)
                onEvent?("mpv-prop-change", j)

            case MPV_EVENT_END_FILE:
                guard let ef = ev.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { break }
                if ef.reason == MPV_END_FILE_REASON_EOF {
                    onEvent?("mpv-event-ended", ["type": "mpv-event-ended", "reason": "quit"])
                } else if ef.reason == MPV_END_FILE_REASON_ERROR {
                    var msg = String(cString: mpv_error_string(ef.error))
                    msg = msg.prefix(1).uppercased() + msg.dropFirst()
                    var j: [String: Any] = ["type": "mpv-event-ended", "reason": "error"]
                    if ef.error < 0 { j["error"] = msg }
                    onEvent?("mpv-event-ended", j)
                    Log.error("[MPV]: \(msg)")
                }
                onPropertyChange?("__end-file", NSNull())

            case MPV_EVENT_LOG_MESSAGE:
                if let m = ev.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                    let prefix = m.prefix.map { String(cString: $0) } ?? ""
                    let level = m.level.map { String(cString: $0) } ?? ""
                    let text = (m.text.map { String(cString: $0) } ?? "").trimmingCharacters(in: .newlines)
                    Log.info("[mpv/\(prefix)] \(level): \(text)")
                }

            case MPV_EVENT_SHUTDOWN:
                Log.info("[MPV]: shutdown")

            default:
                break
            }
        }
    }

    static func nodeToAny(_ n: mpv_node) -> Any {
        switch n.format {
        case MPV_FORMAT_STRING:
            return n.u.string.map { String(cString: $0) } ?? ""
        case MPV_FORMAT_FLAG:
            return n.u.flag != 0
        case MPV_FORMAT_INT64:
            return n.u.int64
        case MPV_FORMAT_DOUBLE:
            return n.u.double_.isFinite ? n.u.double_ : NSNull()
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = n.u.list?.pointee else { return [Any]() }
            return (0..<Int(list.num)).map { nodeToAny(list.values[$0]) }
        case MPV_FORMAT_NODE_MAP:
            guard let list = n.u.list?.pointee else { return [String: Any]() }
            var d = [String: Any]()
            for i in 0..<Int(list.num) {
                let key = list.keys?[i].map { String(cString: $0) } ?? ""
                d[key] = nodeToAny(list.values[i])
            }
            return d
        default:
            return NSNull()
        }
    }

    /// The render context must already be freed (VideoLayer.destroy) before this.
    func shutdown() {
        guard let h = handle else { return }
        queue.sync {}
        handle = nil
        mpv_terminate_destroy(h)
    }
}
