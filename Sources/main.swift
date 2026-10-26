// Harness Desk — a native macOS launcher for the DeepSeek Harness Web UI.
// Starts or attaches to `dsh web`, then loads the authenticated URL.

import Cocoa
import WebKit

final class Launcher: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {

    private var window: NSWindow!
    private var web: WKWebView?
    private var popups: [NSWindow] = []
    private var statusLabel: NSTextField!
    private var spin: NSProgressIndicator!
    private var server: Process?
    private var ownsServer = false
    private var watchdog: DispatchWorkItem?
    private var healthTimer: Timer?
    private var serverPort: Int?
    private var isQuitting = false
    private var restarting = false
    private var restartAttempts = 0
    private var serverStartedAt: Date?
    private var healthFailures = 0
    private var gotURLForAttempt = false
    private var lastServerTail = ""
    private var checkAttachedAuth = false
    private var pricingLabel: NSTextField!
    private var pricingDot: NSView!
    private var pricingAccessory: NSTitlebarAccessoryViewController?
    private var pricingTimer: Timer?

    private let fm = FileManager.default

    /// Display name from the bundle, so renaming the app needs no code edits.
    private let appName: String = {
        let bundle = Bundle.main
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Harness Desk"
    }()

    /// Launcher port range; overridable for tests or a second instance.
    private var portRange: ClosedRange<Int> {
        let env = ProcessInfo.processInfo.environment
        let start = Int(env["DSH_LAUNCHER_PORT_START"] ?? "") ?? 3080
        let end = Int(env["DSH_LAUNCHER_PORT_END"] ?? "") ?? 3090
        return start...max(start, end)
    }
    private let lock = NSLock()
    private let logQueue = DispatchQueue(label: "ai.deepseek.harness.launcher.log")
    private var buffer = ""

    private var home: URL { fm.homeDirectoryForCurrentUser }
    private var stateDir: URL { home.appendingPathComponent(".dsh") }
    private var urlFile: URL { stateDir.appendingPathComponent("web-ui-url.txt") }
    private var logFile: URL { stateDir.appendingPathComponent("logs/web-launcher.log") }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        // One launcher per user: a duplicate only raises the first window.
        if activateExistingInstance() {
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        status("Starting \(appName)…")
        Thread.detachNewThread { self.boot() }
    }

    /// True when this is a duplicate launch; asks the first instance to come
    /// forward and tells the caller to quit.
    private func activateExistingInstance() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        var other: NSRunningApplication?
        for app in NSWorkspace.shared.runningApplications {
            if app.bundleIdentifier == id,
               app.processIdentifier != getpid(),
               !app.isTerminated {
                other = app
                break
            }
        }
        guard let other = other else { return false }
        other.unhide()
        other.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    // Closing the window keeps the harness alive so running tasks survive,
    // the same way the official Desktop app behaves. ⌘Q really quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Only the main window hides; sign-in popups close for real.
        guard sender === window else { return true }
        sender.orderOut(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win !== window else { return }
        popups.removeAll { $0 === win }
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        isQuitting = true
        healthTimer?.invalidate()
        watchdog?.cancel()
        pricingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if ownsServer, let p = server, p.isRunning {
            p.terminate()
            // Give the harness a moment to shut down cleanly.
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    // MARK: - UI

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.center()
        window.setFrameAutosaveName("DSHLauncherWindow")
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 520)
        buildPricingAccessory()

        let host = NSView(frame: window.contentLayoutRect)
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        spin = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        spin.style = .spinning
        spin.controlSize = .regular
        spin.isIndeterminate = true
        spin.startAnimation(nil)
        spin.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "Starting…")
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(spin)
        host.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            spin.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            spin.centerYAnchor.constraint(equalTo: host.centerYAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: spin.bottomAnchor, constant: 14),
            statusLabel.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -60),
        ])

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Pricing indicator

    /// Subtle title-bar readout of the official DeepSeek API rate window.
    /// Peak is 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday.
    private func buildPricingAccessory() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 22))
        let dot = NSView(frame: NSRect(x: 2, y: 8, width: 6, height: 6))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor

        let label = NSTextField(labelWithString: "Normal")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 12, y: 2, width: 80, height: 18)

        container.addSubview(dot)
        container.addSubview(label)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)

        pricingAccessory = accessory
        pricingDot = dot
        pricingLabel = label

        updatePricingStatus()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.updatePricingStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        pricingTimer = timer

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemTimeZoneChanged),
            name: Notification.Name.NSSystemTimeZoneDidChange,
            object: nil
        )
    }

    @objc private func systemTimeZoneChanged() {
        updatePricingStatus()
    }

    private func updatePricingStatus() {
        guard pricingLabel != nil, pricingDot != nil else { return }
        let now = Date()
        let peak = Pricing.isPeak(at: now)
        pricingLabel.stringValue = peak ? "Peak" : "Normal"
        pricingDot.layer?.backgroundColor = (peak ? NSColor.systemOrange : NSColor.systemGreen).cgColor

        let local = DateFormatter()
        local.timeZone = .current
        local.dateStyle = .none
        local.timeStyle = .short
        let localTime = local.string(from: now)
        let zone = TimeZone.current.abbreviation() ?? TimeZone.current.identifier
        let schedule = "Peak: 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday."
        let tooltip: String
        if peak {
            tooltip = "DeepSeek API pricing: peak right now.\n\(schedule)\nLocal time: \(localTime) \(zone).\nChinese public holidays are not included."
        } else {
            tooltip = "DeepSeek API pricing: normal (off-peak) right now.\n\(schedule)\nLocal time: \(localTime) \(zone).\nChinese public holidays are not included."
        }
        pricingLabel.toolTip = tooltip
        pricingAccessory?.view.toolTip = tooltip
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "O")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = winMenu
        main.addItem(winItem)

        NSApp.mainMenu = main
    }

    private func status(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.stringValue = text
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.spin.stopAnimation(nil)
            self.spin.isHidden = true
            self.statusLabel.stringValue = message
            self.statusLabel.textColor = .labelColor
        }
    }

    // MARK: - Web view

    private func present(_ urlString: String, replacing: Bool = false) {
        guard let url = URL(string: urlString) else {
            return fail("The harness printed an unreadable URL: \(urlString)")
        }
        DispatchQueue.main.async {
            // A restart keeps the same WKWebView and only reloads the new
            // token URL, so the window and its data store survive.
            if replacing, let existing = self.web {
                existing.load(URLRequest(url: url))
                self.window.title = self.appName
                self.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            guard self.web == nil, let host = self.window.contentView else { return }

            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let web = WKWebView(frame: host.bounds, configuration: config)
            web.autoresizingMask = [.width, .height]
            web.navigationDelegate = self
            web.uiDelegate = self
            // Inspectable WebViews let any local Safari attach to the
            // authenticated session, so only enable this on request.
            if #available(macOS 13.3, *),
               ProcessInfo.processInfo.environment["DSH_LAUNCHER_INSPECTABLE"] == "1" {
                web.isInspectable = true
            }
            web.allowsBackForwardNavigationGestures = true
            web.allowsMagnification = true
            if #available(macOS 12.0, *) {
                web.underPageBackgroundColor = .windowBackgroundColor
            }
            web.load(URLRequest(url: url))

            self.web = web
            self.spin.stopAnimation(nil)
            host.addSubview(web)
            self.statusLabel.isHidden = true
            self.spin.isHidden = true
            self.window.title = self.appName
            self.window.makeFirstResponder(web)
            if #available(macOS 13.0, *) { web.magnification = 1.0 }
        }
    }

    // External links go to the real browser; popup content stays in-app.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.web else { return decisionHandler(.allow) }
        guard let url = action.request.url, let host = url.host else {
            return decisionHandler(.allow)
        }
        let local = host == "127.0.0.1" || host == "localhost" || host == "::1"
        if action.navigationType == .linkActivated && !local {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    // `window.open` must produce a real popup WebView. The DeepSeek sign-in
    // flow starts with `window.open("about:blank")` and then navigates that
    // window to the auth page; handing the blank URL to NSWorkspace is what
    // produced "There is no application set to open the URL about:blank".
    func webView(_ webView: WKWebView, createWebViewWith config: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        let local = url?.host == "127.0.0.1" || url?.host == "localhost" || url?.host == "::1"

        // Ordinary external links still go to the default browser. Never send
        // about:blank there: it is the placeholder window.open() gives us.
        if action.navigationType == .linkActivated, let url, !local,
           url.absoluteString != "about:blank" {
            NSWorkspace.shared.open(url)
            return nil
        }

        let w = CGFloat(max(360.0, min(1200.0, windowFeatures.width?.doubleValue ?? 540)))
        let h = CGFloat(max(480.0, min(1000.0, windowFeatures.height?.doubleValue ?? 700)))
        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupWindow.title = local ? appName : "Sign in"
        popupWindow.isReleasedWhenClosed = false
        popupWindow.delegate = self
        popupWindow.center()

        let popup = WKWebView(frame: popupWindow.contentLayoutRect, configuration: config)
        popup.autoresizingMask = [.width, .height]
        popup.uiDelegate = self
        popup.navigationDelegate = self
        popup.allowsBackForwardNavigationGestures = true
        popupWindow.contentView = popup
        popups.append(popupWindow)
        popupWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // about:blank is the placeholder the opener fills in itself.
        if let url, url.absoluteString != "about:blank" {
            popup.load(URLRequest(url: url))
        }
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let win = popups.first(where: { $0.contentView === webView }) else { return }
        win.close()
    }

    // WKWebView hides navigator.mediaDevices unless the bundle declares
    // NSMicrophoneUsageDescription; this delegate is what grants the capture
    // request once the local harness page asks for it.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let local = origin.host == "127.0.0.1" || origin.host == "localhost" || origin.host == "::1"
        switch type {
        case .microphone where local:
            decisionHandler(.grant)
        default:
            decisionHandler(.deny)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.web else { return }
        webView.evaluateJavaScript("document.title + ' | ' + location.href") { value, _ in
            self.log("loaded: \(value ?? "unknown")")
        }
        if checkAttachedAuth {
            checkAttachedAuth = false
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in
                guard let text = value as? String,
                      text.contains("dsh web authentication required") else { return }
                self.showAlert(title: "Harness authentication required",
                               message: "A DSH server is already running on port \(self.serverPort ?? 0), but this launcher has no valid session for it. Quit that server (`pkill -f 'dsh web'`) and reopen the app, or open the token URL printed by that server in a browser.")
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.web else { return }
        log("load failed: \(error.localizedDescription)")
        fail("Could not load the harness UI: \(error.localizedDescription)")
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        appendToLog("[\(stamp)] \(line)\n")
    }

    /// Append to the launcher log with the bearer token redacted, and serialise
    /// stdout/stderr writes so concurrent chunks cannot interleave.
    private func appendToLog(_ text: String) {
        let redacted = text.replacingOccurrences(
            of: "token=[A-Za-z0-9_\\-]+",
            with: "token=<redacted>",
            options: .regularExpression
        )
        logQueue.sync {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(redacted.utf8))
            }
        }
    }

    @objc private func reloadPage() { web?.reload() }
    @objc private func actualSize() { if #available(macOS 11.0, *) { web?.pageZoom = 1.0 } }
    @objc private func zoomIn() { if #available(macOS 11.0, *) { web?.pageZoom = min((web?.pageZoom ?? 1) + 0.1, 3.0) } }
    @objc private func zoomOut() { if #available(macOS 11.0, *) { web?.pageZoom = max((web?.pageZoom ?? 1) - 0.1, 0.5) } }
    @objc private func openInBrowser() {
        // Safari has its own cookie jar, so the bare UI URL returns 401 there.
        // Hand the browser the tokenised URL saved for this exact server.
        if let s = try? String(contentsOf: urlFile, encoding: .utf8),
           let saved = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
           saved.host == web?.url?.host, saved.port == web?.url?.port {
            NSWorkspace.shared.open(saved)
        } else if let u = web?.url {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: - Boot

    private func boot() {
        do {
            try fm.createDirectory(at: stateDir.appendingPathComponent("logs"), withIntermediateDirectories: true)
            prepareLog()

            // Attach to a harness that is already listening instead of starting
            // a second one. This covers an orphan left by a crash and a server
            // started from a terminal whose token is still in the url file.
            if let existing = findExistingServer() {
                attach(to: existing)
                return
            }

            guard let port = firstFreePort() else {
                return fail("Ports \(portRange.lowerBound)–\(portRange.upperBound) are all in use. Quit another DSH server and try again.")
            }
            guard let dsh = resolveDSH() else {
                return fail("Could not find the dsh command. Install it with: npm install -g @deepseek-ai/dsh")
            }

            status("Starting dsh web on port \(port)…")
            log("starting dsh web on port \(port)")
            try startServer(dsh: dsh, port: port, replacing: false)
        } catch {
            restarting = false
            fail("Launch failed: \(error.localizedDescription)")
        }
    }

    /// Keep one bounded launcher log across restarts (0600: it can contain
    /// captured stderr, though the token itself is redacted).
    private func prepareLog() {
        let size = (try? fm.attributesOfItem(atPath: logFile.path))?[.size] as? NSNumber
        if size == nil || (size?.intValue ?? 0) > 1_000_000 {
            fm.createFile(atPath: logFile.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFile.path)
    }

    /// First port in the launcher range that answers like a DSH server.
    private func findExistingServer() -> Int? {
        for port in portRange where portOpen(port) {
            if isDSHServer(port: port) { return port }
        }
        return nil
    }

    /// DSH answers an unauthenticated root request with this exact 401 body.
    /// Use a raw loopback socket: URLSession can be blocked by the local-network
    /// policy for a GUI-launched app, while WebKit and BSD sockets are not.
    private func isDSHServer(port: Int) -> Bool {
        guard let response = rawHTTP(port: port) else { return false }
        return response.contains(" 401 ") && response.contains("dsh web authentication required")
    }

    /// Minimal HTTP/1.1 GET against 127.0.0.1. Returns the response text.
    private func rawHTTP(port: Int) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        let request = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { send(fd, $0, strlen($0), 0) }
        guard sent > 0 else { return nil }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 16_384 {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Load an already-running server. The launch token is per-process, so the
    /// saved token only works while that process lives; otherwise the WebView's
    /// 30-day cookie is the fallback.
    private func attach(to port: Int) {
        serverPort = port
        ownsServer = false
        server = nil
        restarting = false
        log("attaching to existing harness on port \(port)")
        status("Attached to the running harness on port \(port)…")

        // The WebView is the browser: let it follow the 303 and set the cookie.
        // If the saved token is stale it renders the 401 body, which didFinish
        // turns into an actionable alert.
        if let token = savedTokenURL(port: port) {
            log("saved token found; attaching with it")
            checkAttachedAuth = true
            present(token.absoluteString)
        } else {
            log("no saved token; trying the existing WebView cookie")
            checkAttachedAuth = true
            present("http://127.0.0.1:\(port)/")
        }
        DispatchQueue.main.async { self.markHealthy(port: port, owned: false) }
    }

    private func savedTokenURL(port: Int) -> URL? {
        guard let text = try? String(contentsOf: urlFile, encoding: .utf8) else { return nil }
        return TokenURL.parse(text, port: port)
    }

    /// Called on the main queue once a server is reachable; starts the health
    /// watchdog and clears the crash-loop counters.
    private func markHealthy(port: Int, owned: Bool) {
        serverPort = port
        ownsServer = owned
        restarting = false
        healthFailures = 0
        serverStartedAt = Date()
        window.title = appName
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func checkHealth() {
        guard !isQuitting, !restarting, let port = serverPort else { return }
        if portOpen(port) {
            healthFailures = 0
            return
        }
        healthFailures += 1
        if healthFailures >= 2 {
            healthFailures = 0
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        guard !isQuitting, !restarting else { return }
        healthTimer?.invalidate()
        if let started = serverStartedAt, Date().timeIntervalSince(started) > 60 {
            restartAttempts = 0
        }
        restartAttempts += 1
        guard restartAttempts <= 3 else {
            restarting = false
            showAlert(title: "\(appName) server stopped",
                      message: "The harness stopped repeatedly. Quit and reopen the app.\n\n\(lastServerTail)")
            return
        }
        restarting = true
        let delay = pow(2.0, Double(restartAttempts - 1))
        status("Server stopped — restarting in \(Int(delay))s…")
        log("server stopped; restart attempt \(restartAttempts) in \(Int(delay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isQuitting else { return }
            self.restartNow()
        }
    }

    private func restartNow() {
        guard !isQuitting else { return }
        guard let dsh = resolveDSH() else {
            restarting = false
            showAlert(title: "\(appName) could not restart",
                      message: "Could not find the dsh command. Install it with: npm install -g @deepseek-ai/dsh")
            return
        }
        guard let port = firstFreePort() else {
            restarting = false
            showAlert(title: "\(appName) could not restart",
                      message: "Ports \(portRange.lowerBound)–\(portRange.upperBound) are all in use. Quit another DSH server and try again.")
            return
        }
        log("restarting dsh web on port \(port)")
        do {
            try startServer(dsh: dsh, port: port, replacing: true)
        } catch {
            restarting = false
            showAlert(title: "\(appName) could not restart",
                      message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        log("alert: \(title) — \(message)")
        DispatchQueue.main.async {
            self.window.title = title
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            if self.window.isVisible {
                alert.beginSheetModal(for: self.window, completionHandler: nil)
            } else {
                alert.runModal()
            }
        }
    }

    private func resolveDSH() -> String? {
        let candidates = [
            "/opt/homebrew/bin/dsh",
            "/usr/local/bin/dsh",
            home.appendingPathComponent(".local/bin/dsh").path,
            home.appendingPathComponent(".npm-global/bin/dsh").path,
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }

        // Fall back to asking a login shell, in case npm's global prefix moved.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v dsh"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    private func workspace() -> URL {
        if let override = ProcessInfo.processInfo.environment["DSH_WEB_WORKSPACE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        for name in ["Projects", "Developer", "coding_projects"] {
            let candidate = home.appendingPathComponent(name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return home
    }

    private func startServer(dsh: String, port: Int, replacing: Bool) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dsh)
        p.arguments = ["web", "--no-open", "--port", String(port)]
        p.currentDirectoryURL = workspace()
        p.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = env["PATH"].map { path + ":" + $0 } ?? path
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        let err = Pipe()
        p.standardError = err
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFile.path)

        watchdog?.cancel()
        healthTimer?.invalidate()
        restarting = true
        gotURLForAttempt = false
        serverPort = port
        lock.lock()
        buffer = ""
        lock.unlock()

        // Drain stderr too: it carries boot failures that the window reports,
        // and routing both streams through one queue keeps the log readable.
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            self.appendToLog(chunk)
            self.lock.lock()
            self.buffer += chunk
            self.lock.unlock()
        }

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            self.appendToLog(chunk)

            self.lock.lock()
            self.buffer += chunk
            let found = self.extractURL()
            self.lock.unlock()

            if let url = found {
                out.fileHandleForReading.readabilityHandler = nil
                self.watchdog?.cancel()
                self.gotURLForAttempt = true
                try? Data((url + "\n").utf8).write(to: self.urlFile, options: .atomic)
                // This file holds a bearer token, not just a URL: owner-only.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: self.urlFile.path)
                self.ownsServer = true
                self.present(url, replacing: replacing)
                self.log("harness ready on port \(port)")
                DispatchQueue.main.async { self.markHealthy(port: port, owned: true) }
            }
        }

        p.terminationHandler = { proc in
            // A superseded process (for example one left hung during a restart)
            // must not trigger another restart.
            if let current = self.server, current !== proc { return }
            self.lock.lock()
            let pending = self.extractURL()
            let tail = String(self.buffer.suffix(600))
            self.lock.unlock()
            if let url = pending {
                self.ownsServer = true
                self.present(url, replacing: replacing)
                DispatchQueue.main.async { self.markHealthy(port: port, owned: true) }
                return
            }
            self.lastServerTail = tail
            DispatchQueue.main.async {
                self.restarting = false
                guard !self.isQuitting else { return }
                self.log("dsh exited with status \(proc.terminationStatus)")
                self.scheduleRestart()
            }
        }

        try p.run()
        server = p
        ownsServer = true

        let guardItem = DispatchWorkItem { [weak self] in
            guard let self, !self.gotURLForAttempt, !self.isQuitting else { return }
            self.restarting = false
            self.log("no URL after 90s; retrying")
            self.scheduleRestart()
        }
        watchdog = guardItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: guardItem)
    }

    /// Caller must hold `lock`.
    private func extractURL() -> String? {
        guard let range = buffer.range(of: "dsh web: ") else { return nil }
        let rest = buffer[range.upperBound...]
        let url = rest.prefix { !$0.isWhitespace }
        return url.hasPrefix("http") ? String(url) : nil
    }

    private func firstFreePort() -> Int? {
        for port in portRange where !portOpen(port) { return port }
        return nil
    }

    private func portOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

}

let app = NSApplication.shared
let launcher = Launcher()
app.delegate = launcher
app.run()
