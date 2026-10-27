import Foundation

enum AppInfo {
    static let name = "Stremio Community"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "5.0.0"
    }
    static let debug = ProcessInfo.processInfo.environment["STREMIO_DEBUG"] == "1"
}

enum Paths {
    private static let fm = FileManager.default

    /// ~/Library/Application Support/Stremio Community
    static let support: URL = {
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// mpv config dir + app settings, same layout as the Windows portable_config.
    static let portableConfig: URL = {
        let url = support.appendingPathComponent("portable_config", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var webmods: URL { portableConfig.appendingPathComponent("webmods", isDirectory: true) }
    static var iniFile: URL { portableConfig.appendingPathComponent("stremio-settings.ini") }
    static var errorLog: URL { support.appendingPathComponent("errors.txt") }
    static var sessionLog: URL { support.appendingPathComponent("stremio.log") }
    static var serverLog: URL { support.appendingPathComponent("server.log") }

    static let webCache: URL = {
        let url = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.name, isDirectory: true)
            .appendingPathComponent("webui", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var resources: URL { Bundle.main.resourceURL! }

    /// Copies bundled default mpv config files that the user does not have yet.
    /// Existing files are never overwritten, so user edits survive updates.
    static func installDefaultConfig() {
        let src = resources.appendingPathComponent("portable_config", isDirectory: true)
        guard let walker = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let file as URL in walker {
            let rel = file.path.dropFirst(src.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let dst = portableConfig.appendingPathComponent(rel)
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            } else if !fm.fileExists(atPath: dst.path) {
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: file, to: dst)
            }
        }
        try? fm.createDirectory(at: webmods, withIntermediateDirectories: true)
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "log")
    private static var session: FileHandle? = {
        FileManager.default.createFile(atPath: Paths.sessionLog.path, contents: nil)
        return try? FileHandle(forWritingTo: Paths.sessionLog)
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func info(_ msg: String) {
        let line = "[\(stamp.string(from: Date()))] \(msg)\n"
        queue.async {
            FileHandle.standardOutput.write(line.data(using: .utf8)!)
            session?.write(line.data(using: .utf8)!)
        }
    }

    static func debug(_ msg: @autoclosure () -> String) {
        if AppInfo.debug { info(msg()) }
    }

    /// Mirrors AppendToCrashLog: persistent errors.txt next to the config.
    static func error(_ msg: String) {
        info(msg)
        let line = "[\(stamp.string(from: Date()))] \(msg)\n"
        queue.async {
            let path = Paths.errorLog.path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            if let h = try? FileHandle(forWritingTo: Paths.errorLog) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            }
        }
    }
}

/// Blocking reachability probe; call off the main thread.
func httpReachable(_ url: URL, timeout: TimeInterval) -> Bool {
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    req.httpMethod = "GET"
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    let task = URLSession.shared.dataTask(with: req) { _, resp, err in
        if err == nil, let http = resp as? HTTPURLResponse, http.statusCode < 500 { ok = true }
        sem.signal()
    }
    task.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    task.cancel()
    return ok
}
