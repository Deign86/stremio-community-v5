import Foundation

/// Runs Stremio's streaming server (server.js) with the bundled Node runtime,
/// the macOS counterpart of stremio-runtime.exe + server.js.
final class StreamingServer {
    static let url = URL(string: "http://127.0.0.1:11470/settings")!

    /// Called on the main thread once the server answers.
    var onStarted: (() -> Void)?

    private var process: Process?
    private var stopping = false
    private var restarts = 0

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if httpReachable(Self.url, timeout: 1) {
                Log.info("[NODE]: A streaming server is already running on 11470, using it")
                DispatchQueue.main.async { self.onStarted?() }
                return
            }
            DispatchQueue.main.async { self.launch() }
        }
    }

    private func launch() {
        let res = Paths.resources
        let node = res.appendingPathComponent("node")
        let script = res.appendingPathComponent("server.js")
        let watchdog = res.appendingPathComponent("shell-watchdog.js")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: script.path) else {
            Log.error("[NODE]: Missing node or server.js in app bundle")
            return
        }

        let p = Process()
        p.executableURL = node
        p.arguments = ["-r", watchdog.path, script.path]
        var env = ProcessInfo.processInfo.environment
        env["NO_CORS"] = "1"
        env["STREMIO_SHELL_PID"] = String(getpid())
        p.environment = env
        p.currentDirectoryURL = Paths.support

        FileManager.default.createFile(atPath: Paths.serverLog.path, contents: nil)
        if let out = try? FileHandle(forWritingTo: Paths.serverLog) {
            p.standardOutput = out
            p.standardError = out
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.exited(status: proc.terminationStatus) }
        }

        do {
            try p.run()
        } catch {
            Log.error("[NODE]: Failed to launch server: \(error.localizedDescription)")
            return
        }
        process = p
        Log.info("[NODE]: Server started (pid \(p.processIdentifier))")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for _ in 0..<60 {
                guard let self, self.process?.isRunning == true else { return }
                if httpReachable(Self.url, timeout: 1) {
                    Log.info("[NODE]: Server is answering")
                    DispatchQueue.main.async { self.onStarted?() }
                    return
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            Log.error("[NODE]: Server did not answer within 30s, see server.log")
        }
    }

    private func exited(status: Int32) {
        process = nil
        guard !stopping else { return }
        Log.error("[NODE]: Server exited with status \(status)")
        if restarts < 3 {
            restarts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launch() }
        }
    }

    func stop() {
        stopping = true
        guard let p = process, p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        Log.info("[NODE]: Server stopped")
    }
}
