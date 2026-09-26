import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem!
    private var controller: PopoverController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = PopoverController(state: state, showSettings: { [weak self] in self?.showSettings() })
        popover.contentViewController = controller
        popover.behavior = .transient
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        state.onChange = { [weak self] in self?.refresh() }
        refresh()
        if state.tokenDraft.isEmpty {
            showSettings()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    private func refresh() {
        controller.refresh()
        statusItem.button?.image = NSImage(
            systemSymbolName: state.isStreaming ? "dot.radiowaves.left.and.right" : "music.note",
            accessibilityDescription: "DiscordDJ"
        )
    }

    private func showSettings() {
        SettingsWindowController.show(state: state)
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class PopoverController: NSViewController {
    private let state: AppState
    private let showSettings: () -> Void
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    init(state: AppState, showSettings: @escaping () -> Void) {
        self.state = state
        self.showSettings = showSettings
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 270))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        let title = NSTextField(labelWithString: "DiscordDJ")
        title.font = .boldSystemFont(ofSize: 16)
        stack.addArrangedSubview(title)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)

        let sourceRow = NSStackView()
        sourceRow.orientation = .horizontal
        sourceRow.spacing = 8
        sourceRow.addArrangedSubview(NSTextField(labelWithString: "Capture app"))
        sourceButton.target = self
        sourceButton.action = #selector(sourceChanged)
        sourceRow.addArrangedSubview(sourceButton)
        let refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!, target: self, action: #selector(refreshApps))
        refreshButton.bezelStyle = .texturedRounded
        sourceRow.addArrangedSubview(refreshButton)
        stack.addArrangedSubview(sourceRow)

        let instructions = NSTextField(wrappingLabelWithString: "Choose an app here. From any computer, join a voice channel and type !here. Type !stop to disconnect.")
        instructions.textColor = .secondaryLabelColor
        stack.addArrangedSubview(instructions)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.addArrangedSubview(NSButton(title: "Settings…", target: self, action: #selector(openSettings)))
        actions.addArrangedSubview(NSView())
        stopButton.target = self
        stopButton.action = #selector(stopStreaming)
        actions.addArrangedSubview(stopButton)
        actions.addArrangedSubview(NSButton(title: "Quit", target: self, action: #selector(quitApp)))
        stack.addArrangedSubview(actions)
        view = root
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        statusLabel.stringValue = state.bridgeStatus
        sourceButton.removeAllItems()
        sourceButton.addItem(withTitle: "Choose an app…")
        state.applications.forEach { sourceButton.addItem(withTitle: $0.name) }
        if let selected = state.selectedSource, let index = state.applications.firstIndex(of: selected) {
            sourceButton.selectItem(at: index + 1)
        } else { sourceButton.selectItem(at: 0) }
        stopButton.isEnabled = state.isStreaming
    }
    @objc private func sourceChanged() {
        let index = sourceButton.indexOfSelectedItem - 1
        guard state.applications.indices.contains(index) else { return }
        state.selectSource(state.applications[index])
    }
    @objc private func refreshApps() { state.refreshApplications() }
    @objc private func stopStreaming() { state.stopStreaming() }
    @objc private func openSettings() { showSettings() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

private final class SettingsWindowController: NSWindowController {
    private let state: AppState
    private let tokenField = NSSecureTextField(string: "")
    private let launchAtLogin = NSButton(checkboxWithTitle: "Launch DiscordDJ at login", target: nil, action: nil)
    private static var current: SettingsWindowController?

    private init(state: AppState) {
        self.state = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 270), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DiscordDJ Settings"
        super.init(window: window)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func show(state: AppState) {
        current = SettingsWindowController(state: state)
        current?.showWindow(nil)
    }
    private func build() {
        let root = NSView(frame: window!.contentView!.bounds)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
        ])
        stack.addArrangedSubview(NSTextField(labelWithString: "Discord bot token"))
        tokenField.stringValue = state.tokenDraft
        tokenField.placeholderString = "Paste your bot token"
        tokenField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.addArrangedSubview(tokenField)
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.addArrangedSubview(NSButton(title: "Save & Connect", target: self, action: #selector(saveToken)))
        actions.addArrangedSubview(NSButton(title: "Clear Token", target: self, action: #selector(clearToken)))
        stack.addArrangedSubview(actions)
        launchAtLogin.state = state.launchAtLogin ? .on : .off
        launchAtLogin.target = self
        launchAtLogin.action = #selector(changeLaunchAtLogin)
        stack.addArrangedSubview(launchAtLogin)
        let help = NSTextField(wrappingLabelWithString: "Your token stays in macOS Keychain. The first stream will request Screen & System Audio Recording permission.")
        help.textColor = .secondaryLabelColor
        stack.addArrangedSubview(help)
        window?.contentView = root
    }
    @objc private func saveToken() { state.tokenDraft = tokenField.stringValue; state.saveToken() }
    @objc private func clearToken() { state.clearToken(); tokenField.stringValue = "" }
    @objc private func changeLaunchAtLogin() { state.setLaunchAtLogin(launchAtLogin.state == .on) }
}
