import AppKit
import AVFoundation
import Foundation

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var transcriptSegments: [TranscriptSegment] = []
    @Published private(set) var liveSpeakerText: [String: String] = [:]
    @Published private(set) var latestSessionPath: String?
    @Published private(set) var microphoneDeviceName = "Unknown microphone"
    @Published private(set) var availableMicrophones: [MicrophoneDeviceOption] = []

    @Published var captureSystemAudio = false
    @Published var selectedMicrophoneID = "" {
        didSet {
            updateSelectedMicrophoneName()
        }
    }

    private let permissionsService = PermissionsService()
    private let transcriptStore = TranscriptStore()
    private let whisperTranscriber = WhisperTranscriberService()
    private let speakerDiarizationService = SpeakerDiarizationService()
    private let audioMixdownService = AudioMixdownService()
    private let meetingInsightsService = MeetingInsightsService()

    private let microphoneCapture = MicrophoneCaptureService()
    private let systemAudioCapture = SystemAudioCaptureService()

    private let microphoneTranscriber = StreamingSpeechTranscriber(speaker: "You")

    private var currentSessionDirectory: URL?
    private var activeCaptureSystemAudio = false
    private var recordingStartedAt: Date?

    init() {
        wirePipeline()
        refreshMicrophoneList()
    }

    deinit {
        microphoneCapture.stop()
    }

    func toggleRecording() {
        Task {
            if isRecording {
                await stopRecording()
                return
            }

            await startRecording()
        }
    }

    func openLatestSessionInFinder() {
        guard let latestSessionPath else {
            return
        }

        NSWorkspace.shared.open(URL(fileURLWithPath: latestSessionPath))
    }

    func refreshMicrophoneDevice() {
        refreshMicrophoneList()
    }

    func refreshMicrophoneList() {
        availableMicrophones = MicrophoneDeviceResolver.availableInputDevices()

        if let selected = availableMicrophones.first(where: { $0.id == selectedMicrophoneID }) {
            microphoneDeviceName = selected.name
            return
        }

        if let defaultID = MicrophoneDeviceResolver.defaultInputDeviceUniqueID(),
           availableMicrophones.contains(where: { $0.id == defaultID })
        {
            selectedMicrophoneID = defaultID
            microphoneDeviceName = MicrophoneDeviceResolver.deviceName(for: defaultID)
            return
        }

        if let first = availableMicrophones.first {
            selectedMicrophoneID = first.id
            microphoneDeviceName = first.name
            return
        }

        selectedMicrophoneID = ""
        microphoneDeviceName = "Unknown microphone"
    }

    private func wirePipeline() {
        microphoneCapture.onBuffer = { [weak self] buffer in
            self?.microphoneTranscriber.append(buffer)
        }

        microphoneTranscriber.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.consume(event: event)
            }
        }

        microphoneTranscriber.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                let message = error.localizedDescription
                if message.localizedCaseInsensitiveContains("no speech detected") {
                    return
                }
                self?.statusMessage = "Mic transcriber error: \(error.localizedDescription)"
            }
        }
    }

    private func startRecording() async {
        guard !isRecording else {
            return
        }

        refreshMicrophoneList()
        statusMessage = "Checking permissions..."

        let permissions = await permissionsService.requestPrimaryPermissions()
        guard permissions.microphoneGranted else {
            statusMessage = "Microphone permission is required."
            return
        }

        let useSystemAudio = captureSystemAudio
        if useSystemAudio {
            let screenCaptureGranted = await permissionsService.requestScreenCaptureAccess()
            guard screenCaptureGranted else {
                statusMessage = "Screen Recording permission is required for system audio mode."
                return
            }
        }

        do {
            let sessionDirectory = try transcriptStore.createSessionDirectory()
            currentSessionDirectory = sessionDirectory
            latestSessionPath = sessionDirectory.path
            activeCaptureSystemAudio = useSystemAudio
            recordingStartedAt = Date()

            transcriptSegments = []
            liveSpeakerText = [:]

            // Keep live mic-only captions for quick feedback when Speech permission exists.
            if !useSystemAudio {
                if permissions.speechGranted {
                    try microphoneTranscriber.start()
                }
            }

            let requestedMicID = selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID
            let resolvedMicID = resolveRecordingMicrophoneID(
                requestedMicrophoneID: requestedMicID,
                useSystemAudio: useSystemAudio
            )
            let autoSwitchedMic = requestedMicID != nil && resolvedMicID != requestedMicID

            let activeMicName = try microphoneCapture.start(
                outputURL: sessionDirectory.appendingPathComponent("microphone.caf"),
                preferredDeviceUniqueID: resolvedMicID
            )
            microphoneDeviceName = activeMicName
            if let resolvedMicID {
                selectedMicrophoneID = resolvedMicID
            }

            if useSystemAudio {
                try await systemAudioCapture.start(
                    outputURL: sessionDirectory.appendingPathComponent("system.caf")
                )
            }

            isRecording = true
            statusMessage = useSystemAudio
                ? (autoSwitchedMic
                    ? "Recording mic + system (auto-switched to built-in mic to avoid media pause)"
                    : "Recording microphone + system audio (Whisper at stop)")
                : (permissions.speechGranted
                    ? "Recording microphone only"
                    : "Recording microphone only (live captions off)")
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
            await rollbackSession()
        }
    }

    private func stopRecording() async {
        guard isRecording else {
            return
        }

        statusMessage = "Stopping..."

        microphoneCapture.stop()
        microphoneTranscriber.stop()

        if activeCaptureSystemAudio {
            await systemAudioCapture.stop()
        }

        flushLiveTranscriptToSegments()

        let usedSystemAudio = activeCaptureSystemAudio
        let recordingStart = recordingStartedAt ?? Date()

        isRecording = false
        activeCaptureSystemAudio = false
        recordingStartedAt = nil
        liveSpeakerText = [:]

        guard let currentSessionDirectory else {
            statusMessage = "Stopped"
            return
        }

        await transcribeWithWhisper(
            sessionDirectory: currentSessionDirectory,
            usedSystemAudio: usedSystemAudio,
            recordingStartedAt: recordingStart
        )

        transcriptSegments.sort { $0.timestamp < $1.timestamp }
        deduplicateTranscriptSegments()

        let insights = meetingInsightsService.generate(from: transcriptSegments)

        do {
            try transcriptStore.saveTranscript(transcriptSegments, in: currentSessionDirectory)
            try transcriptStore.saveInsights(insights, in: currentSessionDirectory)
            statusMessage = "Saved transcript to \(currentSessionDirectory.path)"
        } catch {
            statusMessage = "Stopped, but failed to save outputs: \(error.localizedDescription)"
        }
    }

    private func rollbackSession() async {
        microphoneCapture.stop()
        microphoneTranscriber.stop()

        if activeCaptureSystemAudio {
            await systemAudioCapture.stop()
        }

        isRecording = false
        activeCaptureSystemAudio = false
        recordingStartedAt = nil
    }

    private func consume(event: TranscriptionEvent) {
        if event.isFinal {
            liveSpeakerText[event.speaker] = nil
            transcriptSegments.append(
                TranscriptSegment(
                    speaker: event.speaker,
                    text: event.text,
                    timestamp: event.timestamp,
                    isFinal: true
                )
            )
            return
        }

        liveSpeakerText[event.speaker] = event.text
    }

    private func flushLiveTranscriptToSegments() {
        let now = Date()
        for (speaker, text) in liveSpeakerText {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                continue
            }

            transcriptSegments.append(
                TranscriptSegment(
                    speaker: speaker,
                    text: cleaned,
                    timestamp: now,
                    isFinal: true
                )
            )
        }
    }

    private func transcribeWithWhisper(
        sessionDirectory: URL,
        usedSystemAudio: Bool,
        recordingStartedAt: Date
    ) async {
        let microphoneURL = sessionDirectory.appendingPathComponent("microphone.caf")
        let systemURL = sessionDirectory.appendingPathComponent("system.caf")
        var systemDiarization: [DiarizationSegment] = []

        if FileManager.default.fileExists(atPath: microphoneURL.path) {
            statusMessage = "Whisper: transcribing microphone..."
            if let micResult = await whisperWithRetry(audioURL: microphoneURL),
               let micSegments = makeSegments(
                   from: micResult,
                   speaker: "You",
                   recordingStartedAt: recordingStartedAt,
                   diarizationSegments: []
               )
            {
                replaceSegments(where: { $0.speaker == "You" }, with: micSegments)
            }
        }

        guard usedSystemAudio else {
            return
        }

        if FileManager.default.fileExists(atPath: systemURL.path) {
            statusMessage = "Whisper: diarizing system audio..."
            systemDiarization = await diarizeSystemAudioWithRetry(audioURL: systemURL) ?? []

            statusMessage = "Whisper: transcribing system audio..."
            if let systemResult = await whisperWithRetry(audioURL: systemURL),
               let systemSegments = makeSegments(
                   from: systemResult,
                   speaker: "Others",
                   recordingStartedAt: recordingStartedAt,
                   diarizationSegments: systemDiarization
               )
            {
                replaceSegments(
                    where: { $0.speaker == "Others" || $0.speaker == "Mixed" || $0.speaker.hasPrefix("Participant ") },
                    with: systemSegments
                )
            }
        }

        let hasMic = transcriptSegments.contains { $0.speaker == "You" }
        let hasSystem = transcriptSegments.contains { $0.speaker == "Others" || $0.speaker.hasPrefix("Participant ") }

        if !(hasMic && hasSystem),
           FileManager.default.fileExists(atPath: microphoneURL.path),
           FileManager.default.fileExists(atPath: systemURL.path)
        {
            statusMessage = "Whisper: transcribing mixed fallback..."

            let mixedURL: URL
            do {
                mixedURL = try audioMixdownService.mixToTemporaryFile(urls: [microphoneURL, systemURL])
            } catch {
                return
            }
            defer { try? FileManager.default.removeItem(at: mixedURL) }

            if let mixedResult = await whisperWithRetry(audioURL: mixedURL),
               let mixedSegments = makeSegments(
                   from: mixedResult,
                   speaker: "Mixed",
                   recordingStartedAt: recordingStartedAt,
                   diarizationSegments: []
               )
            {
                replaceSegments(where: { $0.speaker == "Mixed" }, with: mixedSegments)
            }
        }
    }

    private func whisperWithRetry(audioURL: URL, attempts: Int = 2) async -> WhisperTranscriptionResult? {
        for attempt in 0 ..< attempts {
            do {
                let result = try await whisperTranscriber.transcribe(audioURL: audioURL)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty || !result.segments.isEmpty {
                    return result
                }
            } catch {
                statusMessage = "Whisper error: \(error.localizedDescription)"
            }

            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }

        return nil
    }

    private func diarizeSystemAudioWithRetry(audioURL: URL, attempts: Int = 2) async -> [DiarizationSegment]? {
        for attempt in 0 ..< attempts {
            do {
                let result = try await speakerDiarizationService.diarize(
                    audioURL: audioURL,
                    minSpeakers: 1,
                    maxSpeakers: 4
                )
                if !result.segments.isEmpty {
                    return result.segments
                }
            } catch {
                statusMessage = "Diarization warning: \(error.localizedDescription)"
            }

            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }

        return nil
    }

    private func makeSegments(
        from result: WhisperTranscriptionResult,
        speaker: String,
        recordingStartedAt: Date,
        diarizationSegments: [DiarizationSegment]
    ) -> [TranscriptSegment]? {
        if !result.segments.isEmpty {
            let segments = result.segments.flatMap { segment in
                whisperSegmentToTranscriptSegments(
                    segment,
                    speaker: speaker,
                    recordingStartedAt: recordingStartedAt,
                    diarizationSegments: diarizationSegments
                )
            }

            return segments.isEmpty ? nil : segments
        }

        let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return nil
        }
        let speakerLabel = resolvedSpeaker(
            defaultSpeaker: speaker,
            at: 0,
            diarizationSegments: diarizationSegments
        )

        return [
            TranscriptSegment(
                speaker: speakerLabel,
                text: cleaned,
                timestamp: recordingStartedAt,
                isFinal: true
            )
        ]
    }

    private func whisperSegmentToTranscriptSegments(
        _ segment: WhisperSegment,
        speaker: String,
        recordingStartedAt: Date,
        diarizationSegments: [DiarizationSegment]
    ) -> [TranscriptSegment] {
        let timedWords = (segment.words ?? [])
            .filter { !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in lhs.start < rhs.start }

        guard !timedWords.isEmpty else {
            let cleaned = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                return []
            }
            let speakerLabel = resolvedSpeaker(
                defaultSpeaker: speaker,
                at: segment.start,
                diarizationSegments: diarizationSegments
            )

            return [
                TranscriptSegment(
                    speaker: speakerLabel,
                    text: cleaned,
                    timestamp: recordingStartedAt.addingTimeInterval(segment.start),
                    isFinal: true
                )
            ]
        }

        let pauseSplitThresholdSeconds = 1.2
        var groups: [[WhisperWord]] = []
        var currentGroup: [WhisperWord] = []

        for word in timedWords {
            if let previousWord = currentGroup.last {
                let pause = word.start - previousWord.end
                if pause >= pauseSplitThresholdSeconds || tokenEndsSentence(previousWord.word) {
                    if !currentGroup.isEmpty {
                        groups.append(currentGroup)
                    }
                    currentGroup = []
                }
            }

            currentGroup.append(word)
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }

        return groups.compactMap { group -> TranscriptSegment? in
            guard let firstWord = group.first else {
                return nil
            }

            let text = normalizedWhisperWordText(group.map(\.word).joined())
            guard !text.isEmpty else {
                return nil
            }
            let speakerLabel = resolvedSpeaker(
                defaultSpeaker: speaker,
                at: firstWord.start,
                diarizationSegments: diarizationSegments
            )

            return TranscriptSegment(
                speaker: speakerLabel,
                text: text,
                timestamp: recordingStartedAt.addingTimeInterval(firstWord.start),
                isFinal: true
            )
        }
    }

    private func resolvedSpeaker(
        defaultSpeaker: String,
        at timeOffset: Double,
        diarizationSegments: [DiarizationSegment]
    ) -> String {
        guard !diarizationSegments.isEmpty else {
            return defaultSpeaker
        }

        if let exact = diarizationSegments.first(where: { timeOffset >= $0.start && timeOffset <= $0.end }) {
            return exact.speaker
        }

        if let nearest = diarizationSegments.min(by: { lhs, rhs in
            distanceFrom(segment: lhs, to: timeOffset) < distanceFrom(segment: rhs, to: timeOffset)
        }),
           distanceFrom(segment: nearest, to: timeOffset) <= 1.6
        {
            return nearest.speaker
        }

        return defaultSpeaker
    }

    private func distanceFrom(segment: DiarizationSegment, to timeOffset: Double) -> Double {
        if timeOffset < segment.start {
            return segment.start - timeOffset
        }
        if timeOffset > segment.end {
            return timeOffset - segment.end
        }
        return 0
    }

    private func normalizedWhisperWordText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.;!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenEndsSentence(_ token: String) -> Bool {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: "[.!?…][\"'”’)]*$", options: .regularExpression) != nil
    }

    private func deduplicateTranscriptSegments() {
        var deduplicated: [TranscriptSegment] = []
        let duplicateWindow: TimeInterval = 8

        for segment in transcriptSegments {
            let normalizedText = normalizedComparisonText(segment.text)

            if let previous = deduplicated.last {
                let previousNormalized = normalizedComparisonText(previous.text)
                let closeInTime = abs(segment.timestamp.timeIntervalSince(previous.timestamp)) <= duplicateWindow
                if previous.speaker == segment.speaker,
                   closeInTime,
                   previousNormalized == normalizedText
                {
                    continue
                }
            }

            deduplicated.append(segment)
        }

        transcriptSegments = deduplicated
    }

    private func normalizedComparisonText(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func updateSelectedMicrophoneName() {
        microphoneDeviceName = MicrophoneDeviceResolver.deviceName(for: selectedMicrophoneID)
    }

    private func resolveRecordingMicrophoneID(
        requestedMicrophoneID: String?,
        useSystemAudio: Bool
    ) -> String? {
        guard useSystemAudio else {
            return requestedMicrophoneID
        }

        if let requestedMicrophoneID {
            let requestedName = MicrophoneDeviceResolver.deviceName(for: requestedMicrophoneID)
            if MicrophoneDeviceResolver.isLikelyBluetoothMicrophone(name: requestedName),
               let builtInID = MicrophoneDeviceResolver.builtInMicrophoneID()
            {
                return builtInID
            }
            return requestedMicrophoneID
        }

        return MicrophoneDeviceResolver.builtInMicrophoneID()
    }

    private func replaceSegments(
        where predicate: (TranscriptSegment) -> Bool,
        with newSegments: [TranscriptSegment]
    ) {
        transcriptSegments.removeAll(where: predicate)
        transcriptSegments.append(contentsOf: newSegments)
    }
}
