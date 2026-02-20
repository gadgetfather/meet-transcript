import AVFoundation
import Foundation

extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ) else {
            return nil
        }

        copy.frameLength = frameLength

        let channels = Int(format.channelCount)
        let frames = Int(frameLength)

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let source = floatChannelData, let destination = copy.floatChannelData else {
                return nil
            }
            for channel in 0 ..< channels {
                memcpy(destination[channel], source[channel], frames * MemoryLayout<Float>.size)
            }
        case .pcmFormatInt16:
            guard let source = int16ChannelData, let destination = copy.int16ChannelData else {
                return nil
            }
            for channel in 0 ..< channels {
                memcpy(destination[channel], source[channel], frames * MemoryLayout<Int16>.size)
            }
        case .pcmFormatInt32:
            guard let source = int32ChannelData, let destination = copy.int32ChannelData else {
                return nil
            }
            for channel in 0 ..< channels {
                memcpy(destination[channel], source[channel], frames * MemoryLayout<Int32>.size)
            }
        default:
            return nil
        }

        return copy
    }
}
