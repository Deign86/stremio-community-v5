import AppKit
import CryptoKit

/// Self-updater. Disabled unless the build sets an update feed and public key
/// (build.sh: UPDATE_FEED_URL, UPDATE_PUBLIC_KEY → Info.plist).
///
/// The feed is a JSON manifest:
///   { "version": "5.0.23", "notes": "https://…",
///     "assets": { "x86_64": { "url": "…zip", "sha256": "…", "signature": "…" }, "arm64": { … } } }
/// where signature = Ed25519("<version>:<arch>:<sha256>") — see tools/sign-update.swift.
final class Updater {
    enum CheckResult {
        case upToDate(String)
        case ready(String)
        case failed(String)
    }

    private let feedURL: URL?
    private let publicKey: Curve25519.Signing.PublicKey?
    private(set) var readyVersion: String?
    private var readyApp: URL?
    private var notesURL: URL?
    private var checking = false
    private var timer: Timer?

    private static let workDir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppInfo.name, isDirectory: true)
        .appendingPathComponent("update", isDirectory: true)

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? AppInfo.version
    }

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    var isConfigured: Bool { feedURL != nil && publicKey != nil }

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SCUpdateFeedURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (info["SCUpdatePublicKey"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        feedURL = feed.hasPrefix("https://") ? URL(string: feed) : nil
        publicKey = Data(base64Encoded: key).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        if isConfigured {
            Log.info("[UPDATER]: Feed \(feed)")
        }
    }

    /// Checks shortly after launch and then every 6 hours.
    func startAutomaticChecks(onReady: @escaping (String) -> Void) {
        guard isConfigured else { return }
        let run: () -> Void = { [weak self] in
            self?.check { if case .ready(let v) = $0 { onReady(v) } }
        }
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { run() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in run() }
    }

    func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
    }

    /// Downloads and verifies a newer version if there is one. Completion runs on main.
    func check(completion: @escaping (CheckResult) -> Void) {
        guard let feedURL, let publicKey else { return completion(.failed("Updates are not configured for this build.")) }
        if let v = readyVersion { return completion(.ready(v)) }
        guard !checking else { return }
        checking = true
        let done = { (r: CheckResult) in
            DispatchQueue.main.async {
                self.checking = false
                if case .failed(let why) = r { Log.error("[UPDATER]: \(why)") }
                completion(r)
            }
        }

        let req = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard let data, err == nil, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = obj["version"] as? String,
                  let assets = obj["assets"] as? [String: Any],
                  let asset = assets[Self.arch] as? [String: Any],
                  let urlString = asset["url"] as? String, let url = URL(string: urlString),
                  let sha = (asset["sha256"] as? String)?.lowercased(),
                  let sigB64 = asset["signature"] as? String, let sig = Data(base64Encoded: sigB64) else {
                return done(.failed("Could not read the update feed (\(err?.localizedDescription ?? "bad response"))."))
            }
            self.notesURL = (obj["notes"] as? String).flatMap(URL.init(string:))
            let current = Self.currentVersion
            guard Self.isNewer(version, than: current) else {
                Log.info("[UPDATER]: Up to date (\(current), feed has \(version))")
                return done(.upToDate(current))
            }
            // Signature first: never download a payload the feed can't vouch for.
            guard publicKey.isValidSignature(sig, for: Data("\(version):\(Self.arch):\(sha)".utf8)) else {
                return done(.failed("Update \(version) has an invalid signature; ignoring it."))
            }
            Log.info("[UPDATER]: Downloading \(version) from \(url.absoluteString)")
            URLSession.shared.downloadTask(with: url) { tmp, resp, err in
                guard let tmp, err == nil, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    return done(.failed("Download failed: \(err?.localizedDescription ?? "HTTP error")."))
                }
                do {
                    let app = try self.prepare(zip: tmp, version: version, sha256: sha)
                    DispatchQueue.main.async {
                        self.readyApp = app
                        self.readyVersion = version
                        Log.info("[UPDATER]: \(version) verified and ready to install")
                        done(.ready(version))
                    }
                } catch {
                    done(.failed(error.localizedDescription))
                }
            }.resume()
        }.resume()
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Verifies the archive hash, unpacks it and checks the bundle inside.
    private func prepare(zip: URL, version: String, sha256: String) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.workDir)
        try fm.createDirectory(at: Self.workDir, withIntermediateDirectories: true)

        guard try Self.sha256(of: zip) == sha256 else { throw UpdateError("Downloaded update does not match its checksum.") }

        let out = Self.workDir.appendingPathComponent(version, isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard let app = try fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleVersion"] as? String == version else {
            throw UpdateError("Update archive does not contain the expected app.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        return app
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(p.terminationStatus)).")
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Dotted numeric comparison: 5.0.23 > 5.0.22.4 > 5.0.22.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Swaps the bundle once this process exits, then relaunches. Returns false
    /// (and leaves everything as is) when the app's folder isn't writable.
    func installAndRelaunch() -> Bool {
        guard let newApp = readyApp else { return false }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            Log.error("[UPDATER]: \(target.deletingLastPathComponent().path) is not writable")
            return false
        }
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old"; then
          if mv "$3" "$2"; then rm -rf "$2.old"; else mv "$2.old" "$2"; fi
        fi
        open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(getpid()), target.path, newApp.path]
        do {
            try p.run()
        } catch {
            Log.error("[UPDATER]: Could not start installer: \(error.localizedDescription)")
            return false
        }
        Log.info("[UPDATER]: Installing \(readyVersion ?? "?") and relaunching")
        NSApp.terminate(nil)
        return true
    }

    var releaseNotes: URL? { notesURL }
}
