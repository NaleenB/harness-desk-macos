// The About window: which versions are installed, and whether either project
// has a newer one. The npm and GitHub lookups happen only while this window is
// open, never in the background.

import Cocoa

final class AboutWindow: NSObject {

    let window: NSWindow

    private let appName: String
    private let appVersion: String
    private let appBuild: String
    private let dshPath: () -> String?

    private let stack = NSStackView()
    private let deskStatus = AboutWindow.makeValueLabel()
    private let dshStatus = AboutWindow.makeValueLabel()
    private let channelsStatus = AboutWindow.makeValueLabel()
    private let footnote = AboutWindow.makeFootnoteLabel()
    private let checkButton = NSButton(title: "Check Again", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Update Command", target: nil, action: nil)

    private struct CheckResult {
        var installedDSH: String?
        var tags: [String: String]?
        var deskLatest: String?
        var failures: [String] = []
    }

    private var result = CheckResult()
    private var generation = 0
    private var dshUpdateAvailable = false
    private var deskUpdateAvailable = false
    private var copiedReset: DispatchWorkItem?

    // MARK: - Setup

    init(appName: String, version: String, build: String, dshPath: @escaping () -> String?) {
        self.appName = appName
        self.appVersion = version
        self.appBuild = build
        self.dshPath = dshPath
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "About \(appName)"
        window.isReleasedWhenClosed = false
        buildContent()
    }

    private static func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "—")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = true
        return label
    }

    private static func makeFootnoteLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "Checking the npm registry and GitHub…")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.isSelectable = true
        return label
    }

    private func buildContent() {
        let content = NSView()
        window.contentView = content

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
        ])

        let name = NSTextField(labelWithString: appName)
        name.font = .systemFont(ofSize: 16, weight: .semibold)

        let versionLine = NSTextField(labelWithString: "Version \(appVersion) (build \(appBuild))")
        versionLine.font = .systemFont(ofSize: 11)
        versionLine.textColor = .secondaryLabelColor

        let titles = NSStackView(views: [name, versionLine])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2

        let header = NSStackView(views: [icon, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 440),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        let grid = NSGridView(views: [
            [makeRowLabel("Harness Desk"), deskStatus],
            [makeRowLabel("DeepSeek Harness"), dshStatus],
            [makeRowLabel("npm channels"), channelsStatus],
        ])
        grid.rowSpacing = 7
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .leading

        footnote.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            footnote.widthAnchor.constraint(equalToConstant: 440),
            footnote.heightAnchor.constraint(equalToConstant: 30),
        ])

        checkButton.target = self
        checkButton.action = #selector(checkAgain)
        checkButton.bezelStyle = .rounded

        copyButton.target = self
        copyButton.action = #selector(copyUpdateCommand)
        copyButton.bezelStyle = .rounded
        copyButton.isEnabled = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(close))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [checkButton, spacer, copyButton, doneButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setViews([header, separator, grid, footnote, buttons], in: .top)
        stack.setVisibilityPriority(.mustHold, for: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Width is fixed at 440 for the wide rows; let the stack work out the
        // height instead of hard-coding it.
        let size = stack.fittingSize
        stack.frame = NSRect(origin: .zero, size: size)
        stack.autoresizingMask = [.width, .height]
        content.addSubview(stack)
        window.setContentSize(size)
    }

    private func makeRowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        return label
    }

    // MARK: - Presentation

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    @objc private func close() {
        window.close()
    }

    @objc private func checkAgain() {
        refresh()
    }

    @objc private func copyUpdateCommand() {
        var commands: [String] = []
        if dshUpdateAvailable {
            commands.append("npm install -g @deepseek-ai/dsh@latest")
        }
        if deskUpdateAvailable {
            commands.append("git pull && ./scripts/build.sh --install")
        }
        guard !commands.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(commands.joined(separator: "\n"), forType: .string)

        copyButton.title = "Copied"
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            self?.copyButton.title = "Copy Update Command"
        }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
    }

    // MARK: - Update check

    private func refresh() {
        generation += 1
        let current = generation

        deskStatus.stringValue = "\(appVersion) — checking…"
        deskStatus.textColor = .secondaryLabelColor
        dshStatus.stringValue = "checking…"
        dshStatus.textColor = .secondaryLabelColor
        channelsStatus.stringValue = "checking…"
        footnote.stringValue = "Checking the npm registry and GitHub…"
        copyButton.isEnabled = false
        checkButton.isEnabled = false

        let resolvePath = dshPath
        DispatchQueue.global(qos: .userInitiated).async {
            var check = CheckResult()

            check.installedDSH = resolvePath().flatMap { UpdateFeed.installedDSHVersion(atPath: $0) }
            do {
                check.tags = try UpdateFeed.dshDistTags()
            } catch {
                check.failures.append("npm")
            }
            do {
                check.deskLatest = try UpdateFeed.latestDeskRelease()
            } catch {
                check.failures.append("GitHub")
            }

            DispatchQueue.main.async {
                guard current == self.generation else { return }
                self.apply(check)
            }
        }
    }

    private func apply(_ check: CheckResult) {
        result = check
        dshUpdateAvailable = false
        deskUpdateAvailable = false

        applyDesk(check)
        applyDSH(check)
        applyChannels(check)

        checkButton.isEnabled = true
        copyButton.isEnabled = dshUpdateAvailable || deskUpdateAvailable
        footnote.stringValue = footnoteText(for: check)
    }

    private func applyDesk(_ check: CheckResult) {
        guard let latest = check.deskLatest else {
            deskStatus.stringValue = check.failures.contains("GitHub")
                ? "\(appVersion) — check failed"
                : "\(appVersion) — no release published yet"
            deskStatus.textColor = .secondaryLabelColor
            return
        }

        switch VersionOrder.compare(appVersion, latest) {
        case .orderedSame:
            deskStatus.stringValue = "\(appVersion) — up to date"
            deskStatus.textColor = .secondaryLabelColor
        case .orderedAscending:
            deskStatus.stringValue = "\(appVersion) → \(latest) available"
            deskStatus.textColor = .systemOrange
            deskUpdateAvailable = true
        case .orderedDescending:
            deskStatus.stringValue = "\(appVersion) — ahead of the latest release"
            deskStatus.textColor = .secondaryLabelColor
        }
    }

    private func applyDSH(_ check: CheckResult) {
        guard let installed = check.installedDSH else {
            dshStatus.stringValue = "not found on PATH"
            dshStatus.textColor = .systemOrange
            return
        }
        guard let latest = check.tags?["latest"] else {
            dshStatus.stringValue = installed
            dshStatus.textColor = .secondaryLabelColor
            return
        }

        switch VersionOrder.compare(installed, latest) {
        case .orderedSame:
            dshStatus.stringValue = "\(installed) — up to date"
            dshStatus.textColor = .secondaryLabelColor
        case .orderedAscending:
            dshStatus.stringValue = "\(installed) → \(latest) available"
            dshStatus.textColor = .systemOrange
            dshUpdateAvailable = true
        case .orderedDescending:
            dshStatus.stringValue = "\(installed) — ahead of npm latest"
            dshStatus.textColor = .secondaryLabelColor
        }
    }

    private func applyChannels(_ check: CheckResult) {
        guard let tags = check.tags else {
            channelsStatus.stringValue = "—"
            channelsStatus.textColor = .secondaryLabelColor
            return
        }
        let others = tags
            .filter { $0.key != "latest" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
        channelsStatus.stringValue = others.isEmpty ? "none" : others.joined(separator: " · ")
        channelsStatus.textColor = .secondaryLabelColor
    }

    private func footnoteText(for check: CheckResult) -> String {
        var notes: [String] = []

        if deskUpdateAvailable {
            notes.append("Update Harness Desk with git pull, then rebuild.")
        }
        if dshUpdateAvailable {
            notes.append("Quit Harness Desk, run the copied npm command, then reopen.")
        }
        if check.installedDSH == nil && !check.failures.contains("npm") {
            notes.append("DeepSeek Harness is not on PATH.")
        }
        if !check.failures.isEmpty {
            notes.append("Couldn't reach \(check.failures.joined(separator: " and ")).")
        }
        if notes.isEmpty {
            notes.append("Everything is up to date.")
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        notes.append("Checked at \(formatter.string(from: Date())).")
        return notes.joined(separator: " ")
    }
}
