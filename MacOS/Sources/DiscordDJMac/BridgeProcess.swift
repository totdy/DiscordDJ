import Foundation

enum BridgeError: LocalizedError {
    case scriptNotFound
    case nodeNotFound
    case unexpectedExit(Int32)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "Bridge/index.js was not found. Run DiscordDJMac from the MacOS directory."
        case .nodeNotFound:
            return "Node.js was not found. Install Node 22 or set NODE_BINARY."
        case .unexpectedExit(let code):
            return "The Discord voice bridge exited with status \(code)."
        }
    }
}

struct BridgeCommand: Decodable {
    let action: String
    let application: String?
    let state: String?
    let message: String?
    let channel: String?
}

/// Runs the Discord voice transport and exposes its stdin as a PCM sink.
final class BridgeProcess {
    let pcmInput: FileHandle

    private let process = Process()
    private let inputPipe = Pipe()
    private let controlPipe = Pipe()
    private var bufferedControlData = Data()
    private var onCommand: ((BridgeCommand) -> Void)?

    init(token: String, captureSource: String?) throws {
        pcmInput = inputPipe.fileHandleForWriting

        let environment = ProcessInfo.processInfo.environment
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resourceDirectory = Bundle.main.resourceURL
        let bundledScript = resourceDirectory?.appendingPathComponent("Bridge/index.js")
        let developmentScript = currentDirectory.appendingPathComponent("Bridge/index.js")
        let script = bundledScript.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? developmentScript
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw BridgeError.scriptNotFound
        }

        let bundledNode = resourceDirectory?.appendingPathComponent("Runtime/node").path
        if let bundledNode, FileManager.default.isExecutableFile(atPath: bundledNode) {
            process.executableURL = URL(fileURLWithPath: bundledNode)
            process.arguments = [script.path]
        } else if let configuredNode = environment["NODE_BINARY"], !configuredNode.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: configuredNode) else {
                throw BridgeError.nodeNotFound
            }
            process.executableURL = URL(fileURLWithPath: configuredNode)
            process.arguments = [script.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", script.path]
        }

        process.environment = environment.merging([
            "DISCORD_TOKEN": token,
            "CAPTURE_SOURCE": captureSource ?? "",
        ]) { _, new in new }
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.standardInput = inputPipe
        process.standardOutput = controlPipe
        process.standardError = FileHandle.standardError
    }

    func run(onCommand: @escaping (BridgeCommand) -> Void) throws {
        self.onCommand = onCommand
        controlPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        process.terminationHandler = { process in
            if process.terminationStatus != 0 {
                FileHandle.standardError.write(
                    Data("Voice bridge exited with status \(process.terminationStatus).\n".utf8)
                )
            }
        }
        try process.run()
    }

    func terminate() {
        controlPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        bufferedControlData.append(data)

        while let newline = bufferedControlData.firstIndex(of: 0x0A) {
            let line = bufferedControlData[..<newline]
            bufferedControlData.removeSubrange(...newline)

            guard let command = try? JSONDecoder().decode(BridgeCommand.self, from: line) else {
                continue
            }
            onCommand?(command)
        }
    }
}
