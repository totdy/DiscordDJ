import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case appNotFound(String)
    case noDisplay
    case invalidAudioFormat
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name):
            return "No running app matched '\(name)'. Start the app and play audio first."
        case .noDisplay:
            return "macOS did not expose a display to ScreenCaptureKit."
        case .invalidAudioFormat:
            return "ScreenCaptureKit returned an unsupported audio format."
        case .conversionFailed(let message):
            return "Audio conversion failed: \(message)"
        }
    }
}

/// Captures one macOS application's output and writes Discord-ready
/// 48 kHz, signed 16-bit, interleaved stereo PCM to a file handle.
final class AppAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let output: FileHandle
    private let sampleQueue = DispatchQueue(label: "DiscordDJMac.audio", qos: .userInteractive)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(output: FileHandle) {
        self.output = output
        super.init()
    }

    func start(matching requestedName: String) async throws -> String {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        let needle = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let app = content.applications.first(where: { candidate in
            candidate.applicationName.lowercased() == needle
                || candidate.bundleIdentifier.lowercased() == needle
                || candidate.applicationName.lowercased().contains(needle)
                || candidate.bundleIdentifier.lowercased().contains(needle)
        }) else {
            throw CaptureError.appNotFound(requestedName)
        }

        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(
            display: display,
            including: [app],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 3

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        stateLock.withLock {
            stream = newStream
            converter = nil
            converterInputFormat = nil
        }

        do {
            try await newStream.startCapture()
        } catch {
            stateLock.withLock {
                stream = nil
            }
            throw error
        }

        return "\(app.applicationName) (\(app.bundleIdentifier))"
    }

    func stop() async {
        let oldStream = stateLock.withLock {
            let oldStream = stream
            stream = nil
            converter = nil
            converterInputFormat = nil
            return oldStream
        }

        try? await oldStream?.stopCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("Capture stopped: \(error.localizedDescription)\n".utf8))
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else {
            return
        }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let description = sampleBuffer.formatDescription else {
                    throw CaptureError.invalidAudioFormat
                }
                let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
                guard
                      let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: inputFormat,
                        bufferListNoCopy: audioBufferList.unsafePointer
                      ) else {
                    throw CaptureError.invalidAudioFormat
                }

                inputBuffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
                try convertAndWrite(inputBuffer)
            }
        } catch {
            FileHandle.standardError.write(Data("Audio frame dropped: \(error.localizedDescription)\n".utf8))
        }
    }

    private func convertAndWrite(_ input: AVAudioPCMBuffer) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            throw CaptureError.invalidAudioFormat
        }

        if converter == nil || converterInputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
            converterInputFormat = input.format
        }
        guard let converter else {
            throw CaptureError.invalidAudioFormat
        }

        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw CaptureError.invalidAudioFormat
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }

        if status == .error {
            throw CaptureError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
        }

        let audioBuffer = converted.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
            return
        }
        output.write(Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize)))
    }
}
