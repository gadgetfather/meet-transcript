import AVFoundation
import Foundation

final class PCMFileWriter {
    private let url: URL
    private var audioFile: AVAudioFile?
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            }

            try audioFile?.write(from: buffer)
        } catch {
            NSLog("PCM writer error for %@: %@", url.path, error.localizedDescription)
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
    }
}
