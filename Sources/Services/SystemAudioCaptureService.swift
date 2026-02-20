import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum SystemAudioCaptureError: Error {
    case noDisplayFound
}

final class SystemAudioCaptureService: NSObject, SCStreamOutput {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let sampleQueue = DispatchQueue(label: "SystemAudioCaptureService.SampleQueue")
    private var writer: PCMFileWriter?
    private var stream: SCStream?

    private(set) var isRunning = false

    func start(outputURL: URL) async throws {
        guard !isRunning else {
            return
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayFound
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: ())
            }
        }

        writer = PCMFileWriter(url: outputURL)
        self.stream = stream
        isRunning = true
    }

    func stop() async {
        guard let stream else {
            return
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stream.stopCapture { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    continuation.resume(returning: ())
                }
            }
        } catch {
            NSLog("Failed to stop system stream: %@", error.localizedDescription)
        }

        self.stream = nil
        writer?.close()
        writer = nil
        isRunning = false
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              let pcmBuffer = sampleBuffer.toPCMBuffer()
        else {
            return
        }

        writer?.append(pcmBuffer)
        onBuffer?(pcmBuffer)
    }
}
