import AppKit
import WebKit

/// WKWebView with the context menu trimmed to editing actions, like the Windows build.
final class ShellWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        if AppInfo.debug { return }
        let keepIds: Set<String> = [
            "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCut", "WKMenuItemIdentifierPaste",
            "WKMenuItemIdentifierSelectAll", "WKMenuItemIdentifierCopyLink",
        ]
        let keepActions: Set<Selector> = [
            #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)),
            #selector(NSText.selectAll(_:)), #selector(NSTextView.pasteAsPlainText(_:)),
        ]
        for item in menu.items.reversed() where !item.isSeparatorItem {
            let id = item.identifier?.rawValue ?? ""
            if keepIds.contains(id) { continue }
            if let action = item.action, keepActions.contains(action) { continue }
            menu.removeItem(item)
        }
        // Tidy leftover separators.
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        var prevSeparator = false
        for item in menu.items {
            if item.isSeparatorItem && prevSeparator { menu.removeItem(item) }
            prevSeparator = item.isSeparatorItem
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SplashView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.047, green: 0.043, blue: 0.067, alpha: 1).cgColor
        let logo = NSImageView()
        logo.image = NSImage(contentsOf: Paths.resources.appendingPathComponent("splash.png"))
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logo)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 128),
            logo.heightAnchor.constraint(equalToConstant: 128),
        ])
        logo.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        logo.layer?.add(pulse, forKey: "pulse")
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // Swallow clicks while visible.
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : self }

    func dismiss() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: { self.isHidden = true })
    }
}

protocol MainWindowDelegate: AnyObject {
    func shouldAllowNavigation(to url: URL) -> Bool
    func handleLocalFile(_ url: URL)
    func handleOpenURL(_ url: URL)
    func windowWillHide()
    func windowDidLoseFocus()
    func webContentFailed()
}

final class MainWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    let webView: ShellWebView
    let videoView: VideoView
    let splash = SplashView()
    weak var delegate: MainWindowDelegate?
    private let homeURL: URL
    private var lastMouseDown: NSEvent?
    private var mouseMonitor: Any?
    private(set) var isPiP = false
    private var preferredLevel: NSWindow.Level = .normal

    init(mpv: MPVController, bridge: ShellBridge, homeURL: URL, settings: Settings) {
        self.homeURL = homeURL
        videoView = VideoView(mpv: mpv)

        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(bridge, name: "stremioShell")
        ucc.add(bridge, name: "stremioNative")
        let origin = String(homeURL.absoluteString.dropLast())
        let debugScripts = AppInfo.debug ? [Scripts.consoleForwarder] : []
        for src in debugScripts + [Scripts.webviewShim(origin: origin), Scripts.execShell(origin: origin),
                                   Scripts.keydown, Scripts.fullscreenPolyfill] + Self.webmodScripts() {
            ucc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController = ucc
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15 StremioShell/\(AppInfo.version)"
        if #available(macOS 12.3, *) { config.preferences.isElementFullscreenEnabled = false }

        webView = ShellWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
        if #available(macOS 13.3, *) { webView.isInspectable = AppInfo.debug }
        webView.allowsMagnification = settings.allowZoom
        webView.allowsBackForwardNavigationGestures = false
        bridge.webView = webView

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = AppInfo.name
        window.minSize = NSSize(width: 640, height: 400)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")

        super.init(window: window)

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        for v in [videoView, webView, splash] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        window.contentView = container
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        setAlwaysOnTop(settings.alwaysOnTop)

        // start-drag needs the mouse-down that started it.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            if e.window === self?.window { self?.lastMouseDown = e }
            return e
        }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// Port of SetupWebMods: every .css/.js under portable_config/webmods, sorted.
    private static func webmodScripts() -> [String] {
        let root = Paths.webmods
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var css = [URL](), js = [URL]()
        for case let f as URL in walker {
            switch f.pathExtension.lowercased() {
            case "css": css.append(f)
            case "js": js.append(f)
            default: break
            }
        }
        let rel = { (u: URL) in String(u.path.dropFirst(root.path.count + 1)) }
        let sort = { (a: URL, b: URL) in rel(a).localizedCaseInsensitiveCompare(rel(b)) == .orderedAscending }
        var out = [String]()
        for f in css.sorted(by: sort) {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let id = String(rel(f).map { $0.isLetter || $0.isNumber ? $0 : "_" })
            out.append(Scripts.injectCss(id: id, css: text))
            Log.info("[WEBMODS] CSS: \(rel(f))")
        }
        for f in js.sorted(by: sort) {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            out.append(Scripts.injectJs(js: text))
            Log.info("[WEBMODS] JS: \(rel(f))")
        }
        return out
    }

    func loadHome() {
        webView.load(URLRequest(url: homeURL))
    }

    func reload(clearCaches: Bool, completion: (() -> Void)? = nil) {
        guard clearCaches else { webView.reload(); return }
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
            WKWebsiteDataTypeServiceWorkerRegistrations, WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            Log.info("[BROWSER]: Cleared browser cache")
            completion?()
            self?.webView.reload()
        }
    }

    // MARK: Window behaviour

    func startDrag() {
        guard let e = lastMouseDown, let window else { return }
        window.performDrag(with: e)
    }

    func setFullscreen(_ on: Bool) {
        guard let window else { return }
        if on && isPiP { setPiP(false) }
        if window.styleMask.contains(.fullScreen) != on { window.toggleFullScreen(nil) }
    }

    var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func setAlwaysOnTop(_ on: Bool) {
        preferredLevel = on ? .floating : .normal
        if !isPiP { window?.level = preferredLevel }
    }

    /// Port of TogglePictureInPicture: borderless-looking, floating window.
    func setPiP(_ on: Bool) {
        guard let window, on != isPiP else { return }
        if on && isFullscreen { window.toggleFullScreen(nil) }
        isPiP = on
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = on
        }
        if on {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.level = preferredLevel
            window.collectionBehavior = [.fullScreenPrimary]
        }
    }

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        delegate?.windowWillHide()
        return true
    }

    func windowDidMiniaturize(_ notification: Notification) { delegate?.windowWillHide() }
    func windowDidResignKey(_ notification: Notification) { delegate?.windowDidLoseFocus() }
    func windowDidBecomeKey(_ notification: Notification) { window?.makeFirstResponder(webView) }

    func windowDidEnterFullScreen(_ notification: Notification) {
        webView.evaluateJavaScript("window.__stremioShellSetFullscreen && window.__stremioShellSetFullscreen(true)")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        webView.evaluateJavaScript("window.__stremioShellSetFullscreen && window.__stremioShellSetFullscreen(false)")
    }

    // MARK: Navigation (port of NavigationStarting / NewWindowRequested)

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            return decisionHandler(.allow)
        }
        if url.isFileURL {
            // A video or subtitle dropped onto the page.
            decisionHandler(.cancel)
            delegate?.handleLocalFile(url)
            return
        }
        if scheme == "stremio" || scheme == "magnet" {
            decisionHandler(.cancel)
            delegate?.handleOpenURL(url)
            return
        }
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if !isMainFrame || ["about", "data", "blob"].contains(scheme) {
            return decisionHandler(.allow)
        }
        if delegate?.shouldAllowNavigation(to: url) ?? true {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            openExternally(url)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if url.isFileURL {
            delegate?.handleLocalFile(url)
        } else if let s = url.scheme?.lowercased(), s == "stremio" || s == "magnet" {
            delegate?.handleOpenURL(url)
        } else if delegate?.shouldAllowNavigation(to: url) ?? false {
            webView.load(URLRequest(url: url))
        } else {
            openExternally(url)
        }
        return nil
    }

    private func openExternally(_ url: URL) {
        guard let s = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(s) else {
            Log.info("[WEBVIEW]: Refusing to open \(url.absoluteString)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.info("[WEBVIEW]: Loaded \(webView.url?.absoluteString ?? "?")")
        if let url = webView.url, !url.absoluteString.hasPrefix(homeURL.absoluteString) {
            webView.evaluateJavaScript(Scripts.backButton)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        if code == NSURLErrorCancelled || code == 102 /* frame load interrupted */ { return }
        Log.info("[WEBVIEW]: Navigation failed: \(error.localizedDescription)")
        delegate?.webContentFailed()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.error("[WEBVIEW]: Web content process terminated, reloading")
        webView.reload()
    }

    // MARK: UI delegate

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window!) { resp in
            completionHandler(resp == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window!) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
}
