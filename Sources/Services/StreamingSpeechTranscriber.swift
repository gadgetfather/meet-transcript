import AVFoundation
import Foundation
import Speech

final class StreamingSpeechTranscriber {
    enum TranscriberError: Error {
        case recognizerUnavailable
        case notAuthorized
    }

    let speaker: String
    var onEvent: ((TranscriptionEvent) -> Void)?
    var onError: ((Error) -> Void)?

    private let queue: DispatchQueue
    private let recognizer: SFSpeechRecognizer?

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var lastPartialText = ""
    private var lastFinalText = ""

    init(speaker: String, locale: Locale = Locale(identifier: "en-US")) {
        self.speaker = speaker
        queue = DispatchQueue(label: "StreamingSpeechTranscriber.\(speaker)")
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start() throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriberError.notAuthorized
        }

        guard let recognizer else {
            throw TranscriberError.recognizerUnavailable
        }

        queue.sync {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                self?.handleRecognitionResult(result: result, error: error)
            }

            self.request = request
            lastPartialText = ""
            lastFinalText = ""
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copied = buffer.deepCopy() else {
            return
        }

        queue.async { [weak self] in
            self?.request?.append(copied)
        }
    }

    func stop() {
        queue.sync {
            request?.endAudio()
            recognitionTask?.cancel()
            request = nil
            recognitionTask = nil
            lastPartialText = ""
            lastFinalText = ""
        }
    }

    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error {
            onError?(error)
            return
        }

        guard let result else {
            return
        }

        let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }

        if result.isFinal {
            guard text != lastFinalText else {
                return
            }

            lastFinalText = text
            lastPartialText = ""

            onEvent?(
                TranscriptionEvent(
                    speaker: speaker,
                    text: text,
                    timestamp: Date(),
                    isFinal: true
                )
            )

            return
        }

        guard text != lastPartialText else {
            return
        }

        lastPartialText = text

        onEvent?(
            TranscriptionEvent(
                speaker: speaker,
                text: text,
                timestamp: Date(),
                isFinal: false
            )
        )
    }
}
