import Foundation

@main
enum DiscordDJMac {
    static func main() {
        do {
            let bridge = try BridgeProcess()
            let capture = AppAudioCapture(output: bridge.pcmInput)

            try bridge.run { command in
                Task {
                    switch command.action {
                    case "start":
                        let requestedApp = command.application ?? "DuckDuckGo"
                        do {
                            let matchedApp = try await capture.start(matching: requestedApp)
                            FileHandle.standardError.write(Data("Capturing \(matchedApp).\n".utf8))
                        } catch {
                            FileHandle.standardError.write(
                                Data("Could not start capture: \(error.localizedDescription)\n".utf8)
                            )
                        }
                    case "stop":
                        await capture.stop()
                        FileHandle.standardError.write(Data("Capture stopped.\n".utf8))
                    default:
                        break
                    }
                }
            }

            FileHandle.standardError.write(Data("DiscordDJ macOS v2 is running.\n".utf8))
            RunLoop.main.run()
            bridge.terminate()
        } catch {
            FileHandle.standardError.write(Data("Fatal error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
