import AppKit
import MediaPlayer

final class AppController: NSObject, NSApplicationDelegate, MainWindowDelegate, NSMenuDelegate {
    let settings = Settings()
    let mpv = MPVController()
    let server = StreamingServer()
    let webui = WebUIServer()
    let discord = DiscordRPC()
    lazy var bridge = ShellBridge(origin: webui.origin)
    var window: MainWindowController!

    private var statusItem: NSStatusItem?
    private var domainWhitelist: [String] = []
    private var loadAttempts = 0
    private var retryScheduled = false
    private var isPaused = true
    private var hasFile = false
    private var ignoreHoverUntil = Date.distantPast

    private let subtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "sub", "vtt", "ttml", "dfxp", "smi", "sami", "sup", "scc",
        "xml", "lrc", "pjs", "mpl", "usf", "qtvr",
    ]

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.info("[APP]: \(AppInfo.name) \(AppInfo.version) starting")
        Paths.installDefaultConfig()
        applyTheme()
        discord.enabled = settings.discordRPC
        mpv.currentVolume = settings.initialVolume

        guard mpv.start(configDir: Paths.portableConfig) else {
            fatal("mpv could not be initialized. See errors.txt in \(Paths.support.path).")
            return
        }
        mpv.onEvent = { [weak self] name, data in self?.bridge.send(name, data) }
        mpv.onPropertyChange = { [weak self] name, value in self?.playerPropertyChanged(name, value) }

        do {
            try webui.start()
        } catch {
            fatal("Could not start the local web UI server on port \(WebUIServer.port): \(error.localizedDescription)\nIs another copy of Stremio Community running?")
            return
        }

        window = MainWindowController(mpv: mpv, bridge: bridge, homeURL: webui.origin, settings: settings)
        window.delegate = self
        bridge.onEvent = { [weak self] ev, args in self?.handleEvent(ev, args) }
        bridge.onNative = { [weak self] msg in self?.handleNative(msg) }

        buildMainMenu()
        buildStatusItem()
        setupMediaKeys()
        window.showWindow()

        if ProcessInfo.processInfo.environment["STREMIO_NO_SERVER"] != "1" {
            server.onStarted = { [weak self] in self?.bridge.enqueue("ServerStarted", ["type": "ServerStarted"]) }
            server.start()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.webui.chooseUpstream()
            self.fetchWhitelist()
            DispatchQueue.main.async { self.window.loadHome() }
        }

        // Never leave the user staring at the splash forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, !self.bridge.isReady else { return }
            Log.error("[APP]: app-ready not received after 45s, hiding splash")
            self.window.splash.dismiss()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        settings.closeOnExit
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.showWindow()
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        settings.initialVolume = mpv.currentVolume
        settings.save()
        discord.clear()
        window?.videoView.videoLayer.destroy()
        mpv.shutdown()
        server.stop()
        Log.info("[APP]: Bye")
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls { openIncoming(url) }
        window?.showWindow()
    }

    private func fatal(_ message: String) {
        Log.error("[APP]: \(message)")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "\(AppInfo.name) could not start"
        alert.informativeText = message
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Events from the web UI (port of HandleEvent)

    private func handleEvent(_ ev: String, _ args: [String]) {
        switch ev {
        case "mpv-command":
            let name = args.first?.lowercased() ?? ""
            guard settings.mpvCommandAllowlist.contains(name) else {
                let full = args.joined(separator: " ")
                Log.error("[SECURITY]: BLOCKED mpv-command => \(full)")
                bridge.send("MpvCommandBlocked", ["type": "MpvCommandBlocked", "command": name, "full": full])
                return
            }
            var a = args
            if a.first == "loadfile", a.count > 1, !a[1].hasPrefix("http://"), !a[1].hasPrefix("https://") {
                if a[1].hasPrefix("file://"), let u = URL(string: a[1]) {
                    a[1] = u.path
                } else {
                    a[1] = a[1].removingPercentEncoding ?? a[1]
                }
            }
            mpv.command(a)

        case "mpv-set-prop":
            let prop = args.first?.lowercased() ?? ""
            guard settings.mpvSetPropAllowlist.contains(prop) else {
                let val = args.count > 1 ? args[1] : ""
                Log.error("[SECURITY]: BLOCKED mpv-set-prop => \(prop) = \(val)")
                bridge.send("MpvSetPropBlocked", ["type": "MpvSetPropBlocked", "prop": prop, "value": val])
                return
            }
            // Video always goes through the embedded render API on macOS.
            if prop == "vo" { return }
            guard args.count >= 2 else { return }
            mpv.setProperty(args[0], args[1])

        case "mpv-observe-prop":
            if let name = args.first { mpv.observe(name) }

        case "app-ready":
            Log.info("[APP]: Web UI ready")
            loadAttempts = 0
            window.splash.dismiss()
            bridge.markReady()

        case "app-error":
            if args.first == "shellComm" { scheduleRetry() }

        case "seek-hover":
            guard settings.thumbFastHeight > 0, Date() >= ignoreHoverUntil, args.count >= 3,
                  let x = Double(args[1]), let y = Double(args[2]) else { return }
            let scale = window.window?.backingScaleFactor ?? 1
            let px = Int(x * scale)
            let py = Int(y * scale) - settings.thumbFastHeight
            mpv.command(["script-message-to", "thumbfast", "thumb", args[0], String(px), String(py)])

        case "seek-leave":
            guard settings.thumbFastHeight > 0 else { return }
            ignoreHoverUntil = Date().addingTimeInterval(0.2)
            mpv.command(["script-message-to", "thumbfast", "clear"])

        case "start-drag":
            window.startDrag()

        case "refresh":
            refresh(all: args.first == "all")

        case "open-external":
            if let s = args.first, let url = URL(string: s),
               let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }

        case "navigate":
            guard let target = args.first else { return }
            if target == "home" {
                window.loadHome()
            } else if let url = URL(string: target), shouldAllowNavigation(to: url) {
                window.webView.load(URLRequest(url: url))
            }

        case "activity":
            discord.update(args)

        case "quit":
            NSApp.terminate(nil)

        case "update-requested":
            Log.info("[APP]: update-requested ignored (no macOS updater)")

        default:
            Log.info("[APP]: Unknown event=\(ev)")
        }
    }

    private func handleNative(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "fullscreen":
            let on = msg["value"] as? Bool ?? false
            if on && window.isPiP { togglePiP(nil) }
            window.setFullscreen(on)
        case "home":
            window.loadHome()
        case "console":
            Log.info("[JS \(msg["level"] as? String ?? "")]: \(msg["text"] as? String ?? "")")
        default:
            break
        }
    }

    private func refresh(all: Bool) {
        bridge.reset()
        if all { webui.clearCache() }
        window.reload(clearCaches: all)
    }

    // Port of WaitAndRefreshIfNeeded.
    private func scheduleRetry() {
        guard !bridge.isReady, !retryScheduled else { return }
        if loadAttempts >= 10 {
            let alert = NSAlert()
            alert.messageText = "The Stremio web interface could not be loaded"
            alert.informativeText = "Make sure you are online. Details are in \(Paths.sessionLog.path)."
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil); return }
            loadAttempts = 0
        }
        let wait = min(60, 5 * pow(1.25, Double(loadAttempts)))
        loadAttempts += 1
        retryScheduled = true
        Log.info("[WEBVIEW]: Web page not ready, retry \(loadAttempts) in \(Int(wait))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            if !self.bridge.isReady { self.window.loadHome() }
        }
    }

    // MARK: MainWindowDelegate

    /// Port of URLContainsAny: the web UI origin plus the published domain whitelist.
    func shouldAllowNavigation(to url: URL) -> Bool {
        let s = url.absoluteString
        if s.hasPrefix(webui.origin.absoluteString) { return true }
        return domainWhitelist.contains { s.contains($0) }
    }

    func handleLocalFile(_ url: URL) {
        let path = url.path
        if subtitleExtensions.contains(url.pathExtension.lowercased()) {
            mpv.command(["sub-add", path, "select", url.lastPathComponent + " External", "Other Tracks"])
            bridge.send("SubtitleDropped", ["type": "SubtitleDropped", "path": url.absoluteString])
        } else if url.pathExtension.lowercased() == "torrent" {
            openIncoming(url)
        } else {
            // Stremio core needs a URL; Windows paths ("C:\...") happen to parse as one.
            bridge.send("FileDropped", ["type": "FileDropped", "path": url.absoluteString])
        }
    }

    func handleOpenURL(_ url: URL) { openIncoming(url) }

    func windowWillHide() {
        if settings.pauseOnMinimize { mpv.pause() }
    }

    func windowDidLoseFocus() {
        if settings.pauseOnLostFocus { mpv.pause() }
    }

    func webContentFailed() { scheduleRetry() }

    /// Port of the WM_COPYDATA handler: files, stremio:// and magnet: links.
    private func openIncoming(_ url: URL) {
        Log.info("[APP]: Open \(url.absoluteString)")
        if url.isFileURL {
            if url.pathExtension.lowercased() == "torrent" {
                guard let data = try? Data(contentsOf: url) else {
                    Log.error("[APP]: Could not read torrent \(url.path)")
                    return
                }
                bridge.enqueue("OpenTorrent", ["type": "OpenTorrent", "data": [UInt8](data)])
            } else {
                bridge.enqueue("OpenFile", ["type": "OpenFile", "path": url.absoluteString])
            }
            return
        }
        let s = url.absoluteString
        if s.hasPrefix("stremio://detail") {
            bridge.enqueue("ReplaceLocation", ["type": "ReplaceLocation", "path": s])
        } else if s.hasPrefix("stremio://") {
            bridge.enqueue("AddonInstall", ["type": "AddonInstall", "path": s])
        } else if s.hasPrefix("magnet:") {
            bridge.enqueue("OpenTorrent", ["type": "OpenTorrent", "magnet": s])
        }
    }

    /// Port of FetchAndParseWhitelist. Blocking.
    private func fetchWhitelist() {
        guard let url = URL(string: "https://raw.githubusercontent.com/Zaarrg/stremio-desktop-v5/refs/heads/webview-windows/extensions/extensions.json") else { return }
        let sem = DispatchSemaphore(value: 0)
        var list = [String]()
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 3)) { data, _, _ in
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let domains = obj["domains"] as? [String] {
                list = domains.filter { $0.hasPrefix("https://") }
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 4)
        DispatchQueue.main.async { self.domainWhitelist = list }
    }

    // MARK: Native playback integration

    private func playerPropertyChanged(_ name: String, _ value: Any) {
        switch name {
        case "pause":
            isPaused = value as? Bool ?? true
        case "path":
            hasFile = !((value as? String) ?? "").isEmpty
        case "__end-file":
            hasFile = false
        default:
            return
        }
        let center = MPNowPlayingInfoCenter.default()
        if hasFile {
            center.playbackState = isPaused ? .paused : .playing
            center.nowPlayingInfo = [MPMediaItemPropertyTitle: AppInfo.name]
        } else {
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
        }
    }

    private func setupMediaKeys() {
        let cc = MPRemoteCommandCenter.shared()
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.mpv.command(["cycle", "pause"]); return .success
        }
        cc.playCommand.addTarget { [weak self] _ in
            self?.mpv.setProperty("pause", "no"); return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            self?.mpv.setProperty("pause", "yes"); return .success
        }
    }

    // MARK: Settings toggles (shared by the menu bar item and the app menu)

    private func applyTheme() {
        NSApp.appearance = settings.useDarkTheme ? NSAppearance(named: .darkAqua) : nil
    }

    @objc func toggleShowWindow(_ sender: Any?) {
        if window.window?.isVisible == true && NSApp.isActive {
            window.window?.orderOut(nil)
            windowWillHide()
        } else {
            window.showWindow()
        }
    }

    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        settings.alwaysOnTop.toggle()
        settings.save()
        window.setAlwaysOnTop(settings.alwaysOnTop)
    }

    @objc func togglePiP(_ sender: Any?) {
        let on = !window.isPiP
        window.setPiP(on)
        bridge.send(on ? "showPictureInPicture" : "hidePictureInPicture", [String: Any]())
    }

    @objc func togglePauseMinimized(_ sender: Any?) { settings.pauseOnMinimize.toggle(); settings.save() }
    @objc func togglePauseUnfocused(_ sender: Any?) { settings.pauseOnLostFocus.toggle(); settings.save() }
    @objc func toggleCloseOnExit(_ sender: Any?) { settings.closeOnExit.toggle(); settings.save() }

    @objc func toggleDarkTheme(_ sender: Any?) {
        settings.useDarkTheme.toggle()
        settings.save()
        applyTheme()
    }

    @objc func toggleDiscord(_ sender: Any?) {
        settings.discordRPC.toggle()
        settings.save()
        discord.enabled = settings.discordRPC
    }

    @objc func reloadPage(_ sender: Any?) { refresh(all: false) }
    @objc func fullRefresh(_ sender: Any?) { refresh(all: true) }
    @objc func toggleFullscreen(_ sender: Any?) { window.setFullscreen(!window.isFullscreen) }
    @objc func openConfigFolder(_ sender: Any?) { NSWorkspace.shared.open(Paths.portableConfig) }
    @objc func openLogFolder(_ sender: Any?) { NSWorkspace.shared.open(Paths.support) }

    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { openIncoming(url) }
    }

    @objc func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func optionItems() -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            return i
        }
        return [
            item("Always on Top", #selector(toggleAlwaysOnTop(_:))),
            item("Picture in Picture", #selector(togglePiP(_:)), "p", [.command, .option]),
            .separator(),
            item("Pause When Minimized", #selector(togglePauseMinimized(_:))),
            item("Pause When Unfocused", #selector(togglePauseUnfocused(_:))),
            item("Quit When Window Closes", #selector(toggleCloseOnExit(_:))),
            item("Use Dark Theme", #selector(toggleDarkTheme(_:))),
            item("Discord Rich Presence", #selector(toggleDiscord(_:))),
            .separator(),
            item("Open mpv Config Folder", #selector(openConfigFolder(_:))),
            item("Open Logs Folder", #selector(openLogFolder(_:))),
        ]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(toggleShowWindow(_:)):
                item.title = (window.window?.isVisible ?? false) ? "Hide Window" : "Show Window"
            case #selector(toggleAlwaysOnTop(_:)): item.state = settings.alwaysOnTop ? .on : .off
            case #selector(togglePiP(_:)): item.state = window.isPiP ? .on : .off
            case #selector(togglePauseMinimized(_:)): item.state = settings.pauseOnMinimize ? .on : .off
            case #selector(togglePauseUnfocused(_:)): item.state = settings.pauseOnLostFocus ? .on : .off
            case #selector(toggleCloseOnExit(_:)): item.state = settings.closeOnExit ? .on : .off
            case #selector(toggleDarkTheme(_:)): item.state = settings.useDarkTheme ? .on : .off
            case #selector(toggleDiscord(_:)): item.state = settings.discordRPC ? .on : .off
            default: break
            }
        }
    }

    /// Menu bar equivalent of the Windows tray icon.
    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "play.tv", accessibilityDescription: AppInfo.name) {
            img.isTemplate = true
            item.button?.image = img
        } else {
            item.button?.title = "S"
        }
        let menu = NSMenu()
        menu.delegate = self
        let show = NSMenuItem(title: "Show Window", action: #selector(toggleShowWindow(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        optionItems().forEach { $0.keyEquivalent = ""; menu.addItem($0) }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit \(AppInfo.name)", action: #selector(quit(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let name = AppInfo.name

        let appMenu = NSMenu(title: name)
        appMenu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let options = NSMenu(title: "Options")
        options.delegate = self
        optionItems().forEach { options.addItem($0) }
        let optionsItem = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        optionsItem.submenu = options
        appMenu.addItem(optionsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: name, action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openFile(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pastePlain = edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reloadPage(_:)), keyEquivalent: "r").target = self
        let full = view.addItem(withTitle: "Clear Cache and Reload", action: #selector(fullRefresh(_:)), keyEquivalent: "r")
        full.keyEquivalentModifierMask = [.command, .shift]
        full.target = self
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "Toggle Full Screen", action: #selector(toggleFullscreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        fs.target = self
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        win.addItem(withTitle: "Show Main Window", action: #selector(toggleShowWindow(_:)), keyEquivalent: "0").target = self
        win.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}
