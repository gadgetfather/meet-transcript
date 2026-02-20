import AVFoundation
import Foundation

enum MicrophoneCaptureError: Error {
    case inputDeviceUnavailable
    case unableToCreateInput
    case unableToAddInput
    case unableToAddOutput
}

final class MicrophoneCaptureService: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let sampleQueue = DispatchQueue(label: "MicrophoneCaptureService.SampleQueue")
    private var writer: PCMFileWriter?
    private var session: AVCaptureSession?

    private(set) var isRunning = false

    func start(outputURL: URL, preferredDeviceUniqueID: String?) throws -> String {
        guard !isRunning else {
            return MicrophoneDeviceResolver.deviceName(for: preferredDeviceUniqueID)
        }

        guard let device = resolveInputDevice(preferredDeviceUniqueID: preferredDeviceUniqueID) else {
            throw MicrophoneCaptureError.inputDeviceUnavailable
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MicrophoneCaptureError.unableToCreateInput
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MicrophoneCaptureError.unableToAddInput
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneCaptureError.unableToAddOutput
        }
        session.addOutput(output)

        session.commitConfiguration()

        writer = PCMFileWriter(url: outputURL)
        self.session = session
        session.startRunning()
        isRunning = true
        return device.localizedName
    }

    func stop() {
        guard let session else {
            return
        }

        session.stopRunning()
        self.session = nil

        writer?.close()
        writer = nil
        isRunning = false
    }

    private func resolveInputDevice(preferredDeviceUniqueID: String?) -> AVCaptureDevice? {
        if let preferredDeviceUniqueID,
           let selected = AVCaptureDevice(uniqueID: preferredDeviceUniqueID)
        {
            return selected
        }

        return AVCaptureDevice.default(for: .audio)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            return
        }

        writer?.append(pcmBuffer)
        onBuffer?(pcmBuffer)
    }
}
