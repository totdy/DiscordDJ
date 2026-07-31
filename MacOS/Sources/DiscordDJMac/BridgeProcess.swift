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
}

/// Runs the Discord voice transport and exposes its stdin as a PCM sink.
final class BridgeProcess {
    let pcmInput: FileHandle

    private let process = Process()
    private let inputPipe = Pipe()
    private let controlPipe = Pipe()
    private var bufferedControlData = Data()
    private var onCommand: ((BridgeCommand) -> Void)?

    init() throws {
        pcmInput = inputPipe.fileHandleForWriting

        let environment = ProcessInfo.processInfo.environment
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = currentDirectory.appendingPathComponent("Bridge/index.js")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw BridgeError.scriptNotFound
        }

        if let configuredNode = environment["NODE_BINARY"], !configuredNode.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: configuredNode) else {
                throw BridgeError.nodeNotFound
            }
            process.executableURL = URL(fileURLWithPath: configuredNode)
            process.arguments = [script.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", script.path]
        }

        process.currentDirectoryURL = currentDirectory
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
            CFRunLoopStop(CFRunLoopGetMain())
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
