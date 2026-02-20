import AVFoundation
import Foundation

final class AudioMixdownService {
    enum MixdownError: Error {
        case noInputFiles
        case cannotCreateTargetFormat
        case cannotCreateOutputFormat
        case cannotCreateConverter
    }

    private let targetReadFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )

    private let outputWriteFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )

    func mixToTemporaryFile(urls: [URL]) throws -> URL {
        guard !urls.isEmpty else {
            throw MixdownError.noInputFiles
        }

        guard let targetReadFormat else {
            throw MixdownError.cannotCreateTargetFormat
        }

        guard let outputWriteFormat else {
            throw MixdownError.cannotCreateOutputFormat
        }

        let tracks = try urls.map { try readNormalizedSamples(from: $0, targetFormat: targetReadFormat) }
        let maxCount = tracks.map(\.count).max() ?? 0
        var mixed = Array(repeating: Float(0), count: maxCount)

        for index in 0 ..< maxCount {
            var sum: Float = 0
            var contributors: Float = 0

            for track in tracks where index < track.count {
                sum += track[index]
                contributors += 1
            }

            if contributors > 0 {
                mixed[index] = clamp(sum / contributors)
            }
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("meet-transcript-mix-\(UUID().uuidString).caf")

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputWriteFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        let writeChunkSize = 4096
        var cursor = 0
        while cursor < mixed.count {
            let count = min(writeChunkSize, mixed.count - cursor)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: outputWriteFormat,
                frameCapacity: AVAudioFrameCount(count)
            ) else {
                break
            }

            buffer.frameLength = AVAudioFrameCount(count)
            if let channel = buffer.int16ChannelData?[0] {
                for sampleIndex in 0 ..< count {
                    let value = clamp(mixed[cursor + sampleIndex])
                    channel[sampleIndex] = Int16(value * Float(Int16.max))
                }
            }

            try outputFile.write(from: buffer)
            cursor += count
        }

        return outputURL
    }

    private func readNormalizedSamples(from url: URL, targetFormat: AVAudioFormat) throws -> [Float] {
        let source = try AVAudioFile(forReading: url)

        if source.processingFormat.commonFormat == .pcmFormatFloat32,
           source.processingFormat.sampleRate == targetFormat.sampleRate,
           source.processingFormat.channelCount == targetFormat.channelCount
        {
            return try readFloatSamplesDirect(from: source)
        }

        guard let converter = AVAudioConverter(from: source.processingFormat, to: targetFormat) else {
            throw MixdownError.cannotCreateConverter
        }

        var samples: [Float] = []
        let sourceChunkFrames = AVAudioFrameCount(max(1024, Int(source.processingFormat.sampleRate * 1.5)))

        while true {
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat,
                frameCapacity: sourceChunkFrames
            ) else {
                break
            }

            try source.read(into: inputBuffer, frameCount: sourceChunkFrames)
            guard inputBuffer.frameLength > 0 else {
                break
            }

            let ratio = targetFormat.sampleRate / source.processingFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(max(512, Int(Double(inputBuffer.frameLength) * ratio) + 512))

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputCapacity
            ) else {
                continue
            }

            var consumedInput = false
            var conversionError: NSError?

            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if consumedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                consumedInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if status == .error, let conversionError {
                throw conversionError
            }

            guard outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] else {
                continue
            }

            let buffer = UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))
            samples.append(contentsOf: buffer.map(clamp))
        }

        return samples
    }

    private func readFloatSamplesDirect(from file: AVAudioFile) throws -> [Float] {
        var samples: [Float] = []
        let chunkFrames = AVAudioFrameCount(8192)

        while true {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: chunkFrames
            ) else {
                break
            }

            try file.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
                break
            }

            let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            samples.append(contentsOf: chunk.map(clamp))
        }

        return samples
    }

    private func clamp(_ value: Float) -> Float {
        max(-1, min(1, value))
    }
}
