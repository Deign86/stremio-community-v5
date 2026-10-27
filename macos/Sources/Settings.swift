import Foundation

/// Minimal INI reader/writer that keeps section and key order, so the file
/// stays compatible with the Windows build's stremio-settings.ini.
final class IniFile {
    private var sections: [(name: String, entries: [(key: String, value: String)])] = []
    let url: URL

    init(url: URL) {
        self.url = url
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var current = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                if index(of: current) == nil { sections.append((current, [])) }
            } else if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                set(current, key, value)
            }
        }
    }

    private func index(of section: String) -> Int? {
        sections.firstIndex { $0.name.caseInsensitiveCompare(section) == .orderedSame }
    }

    func get(_ section: String, _ key: String) -> String? {
        guard let s = index(of: section) else { return nil }
        return sections[s].entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    func set(_ section: String, _ key: String, _ value: String) {
        let s: Int
        if let found = index(of: section) {
            s = found
        } else {
            sections.append((section, []))
            s = sections.count - 1
        }
        if let k = sections[s].entries.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            sections[s].entries[k].value = value
        } else {
            sections[s].entries.append((key, value))
        }
    }

    func save() {
        var out = ""
        for section in sections where !section.name.isEmpty {
            out += "[\(section.name)]\n"
            for e in section.entries { out += "\(e.key)=\(e.value)\n" }
            out += "\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class Settings {
    var closeOnExit = false
    var useDarkTheme = true
    var thumbFastHeight = 0
    var allowZoom = false
    var pauseOnMinimize = true
    var pauseOnLostFocus = false
    var discordRPC = true
    var autoUpdate = true
    var initialVolume = 50
    var alwaysOnTop = false

    private(set) var mpvCommandAllowlist = Set<String>()
    private(set) var mpvSetPropAllowlist = Set<String>()

    // Same default-deny allow-lists as the Windows build.
    private static let defaultCommands = "loadfile,sub-add,keypress,stop,script-message-to,cycle"
    private static let defaultProps =
        "pause,time-pos,speed,mute,volume,aid,sid,no-sub-ass,vo,osc," +
        "input-default-bindings,input-vo-keyboard,sub-scale,sub-pos,sub-delay," +
        "sub-color,sub-back-color,sub-border-color,hwdec,hwdec-codecs," +
        "subs-with-matching-audio,subs-match-os-language,subs-fallback,subs-fallback-forced"

    private let ini = IniFile(url: Paths.iniFile)

    init() { load() }

    private func bool(_ section: String, _ key: String, _ def: Bool) -> Bool {
        guard let v = ini.get(section, key) else { return def }
        return v == "1"
    }

    private func int(_ section: String, _ key: String, _ def: Int) -> Int {
        Int(ini.get(section, key) ?? "") ?? def
    }

    func load() {
        closeOnExit = bool("General", "CloseOnExit", false)
        useDarkTheme = bool("General", "UseDarkTheme", true)
        thumbFastHeight = int("General", "ThumbFastHeight", 0)
        allowZoom = bool("General", "AllowZoom", false)
        pauseOnMinimize = bool("General", "PauseOnMinimize", true)
        pauseOnLostFocus = bool("General", "PauseOnLostFocus", false)
        discordRPC = bool("General", "DiscordRPC", true)
        autoUpdate = bool("General", "AutoUpdate", true)
        alwaysOnTop = bool("General", "AlwaysOnTop", false)
        initialVolume = int("MPV", "InitialVolume", 50)

        mpvCommandAllowlist = mergedAllowlist(key: "MpvCommandAllowlist", defaults: Self.defaultCommands)
        mpvSetPropAllowlist = mergedAllowlist(key: "MpvSetPropAllowlist", defaults: Self.defaultProps)
        save()
    }

    /// effective = hardcoded defaults ∪ user extras; rewrites the ini if a default is missing.
    private func mergedAllowlist(key: String, defaults: String) -> Set<String> {
        func parse(_ s: String) -> [String] {
            s.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }
        let defs = parse(defaults)
        let users = parse(ini.get("Security", key) ?? "")
        var effective = defs
        for u in users where !effective.contains(u) { effective.append(u) }
        if defs.contains(where: { !users.contains($0) }) {
            ini.set("Security", key, effective.joined(separator: ","))
        }
        return Set(effective)
    }

    func save() {
        ini.set("General", "CloseOnExit", closeOnExit ? "1" : "0")
        ini.set("General", "UseDarkTheme", useDarkTheme ? "1" : "0")
        ini.set("General", "PauseOnMinimize", pauseOnMinimize ? "1" : "0")
        ini.set("General", "PauseOnLostFocus", pauseOnLostFocus ? "1" : "0")
        ini.set("General", "AllowZoom", allowZoom ? "1" : "0")
        ini.set("General", "DiscordRPC", discordRPC ? "1" : "0")
        ini.set("General", "AutoUpdate", autoUpdate ? "1" : "0")
        ini.set("General", "AlwaysOnTop", alwaysOnTop ? "1" : "0")
        ini.set("General", "ThumbFastHeight", String(thumbFastHeight))
        ini.set("MPV", "InitialVolume", String(initialVolume))
        ini.save()
    }
}
