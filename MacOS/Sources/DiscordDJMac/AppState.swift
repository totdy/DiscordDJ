import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

struct CaptureApp: Identifiable, Hashable {
    let name: String
    let bundleIdentifier: String

    var id: String { bundleIdentifier }
}

final class AppState {
    var applications: [CaptureApp] = [] { didSet { changed() } }
    var selectedSource: CaptureApp? { didSet { changed() } }
    var bridgeStatus = "Set your Discord bot token to get started" { didSet { changed() } }
    var isStreaming = false { didSet { changed() } }
    var activeChannel: String? { didSet { changed() } }
    var tokenDraft = "" { didSet { changed() } }
    var launchAtLogin = false { didSet { changed() } }
    var onChange: (() -> Void)?

    private let sourceKey = "captureSourceBundleIdentifier"
    private var bridge: BridgeProcess?
    private var capture: AppAudioCapture?

    init() {
        tokenDraft = KeychainStore.readToken() ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshApplications()
        restoreSource()
        connectBridge()
    }

    func refreshApplications() {
        applications = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.localizedName, let bundleIdentifier = app.bundleIdentifier,
                  !app.isTerminated else { return nil }
            return CaptureApp(name: name, bundleIdentifier: bundleIdentifier)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let source = selectedSource,
           !applications.contains(source) {
            selectedSource = nil
            UserDefaults.standard.removeObject(forKey: sourceKey)
        }
    }

    func selectSource(_ source: CaptureApp) {
        selectedSource = source
        UserDefaults.standard.set(source.bundleIdentifier, forKey: sourceKey)
        requestCapturePermissionIfNeeded()
        reconnectBridge()
    }

    func requestCapturePermissionIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        bridgeStatus = "Allow Screen & System Audio Recording, then restart DiscordDJ"
        _ = CGRequestScreenCaptureAccess()
    }

    func saveToken() {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            bridgeStatus = "Enter a bot token first"
            return
        }
        do {
            try KeychainStore.saveToken(token)
            reconnectBridge()
        } catch {
            bridgeStatus = "Could not save token: \(error.localizedDescription)"
        }
    }

    func clearToken() {
        stopStreaming()
        KeychainStore.clearToken()
        tokenDraft = ""
        bridgeStatus = "Token removed"
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            bridgeStatus = "Could not update launch at login: \(error.localizedDescription)"
        }
    }

    func stopStreaming() {
        bridge?.terminate()
        bridge = nil
        Task { [weak self] in
            await self?.endCapture()
            self?.connectBridge()
        }
    }

    private func restoreSource() {
        guard let identifier = UserDefaults.standard.string(forKey: sourceKey) else { return }
        selectedSource = applications.first { $0.bundleIdentifier == identifier }
    }

    private func reconnectBridge() {
        bridge?.terminate()
        bridge = nil
        Task { [weak self] in
            await self?.endCapture()
            self?.connectBridge()
        }
    }

    private func connectBridge() {
        guard let token = KeychainStore.readToken(), !token.isEmpty else { return }
        do {
            let newBridge = try BridgeProcess(token: token, captureSource: selectedSource?.bundleIdentifier)
            try newBridge.run { [weak self] command in
                DispatchQueue.main.async { [weak self] in
                    Task { await self?.handle(command) }
                }
            }
            bridge = newBridge
            bridgeStatus = "Connecting to Discord…"
        } catch {
            bridgeStatus = error.localizedDescription
        }
    }

    private func handle(_ command: BridgeCommand) async {
        switch command.action {
        case "start":
            guard let selectedSource, let bridge else {
                bridgeStatus = "Select an app before streaming"
                return
            }
            do {
                let newCapture = AppAudioCapture(output: bridge.pcmInput)
                capture = newCapture
                _ = try await newCapture.start(matching: selectedSource.bundleIdentifier)
                isStreaming = true
                activeChannel = command.channel
                bridgeStatus = "Streaming \(selectedSource.name)"
            } catch {
                bridgeStatus = "Could not capture \(selectedSource.name): \(error.localizedDescription)"
            }
        case "stop":
            await endCapture()
        case "status":
            bridgeStatus = command.message ?? command.state ?? bridgeStatus
        default:
            break
        }
    }

    private func endCapture() async {
        await capture?.stop()
        capture = nil
        isStreaming = false
        activeChannel = nil
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }
}
