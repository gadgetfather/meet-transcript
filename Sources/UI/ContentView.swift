import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @State private var shouldPulseStatus = false

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < 980

            ZStack {
                backgroundLayer

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        heroCard

                        if isCompact {
                            VStack(alignment: .leading, spacing: 14) {
                                controlsCard
                                transcriptCard
                                sessionsCard
                            }
                        } else {
                            HStack(alignment: .top, spacing: 14) {
                                VStack(alignment: .leading, spacing: 14) {
                                    controlsCard
                                    sessionsCard
                                }
                                .frame(width: min(max(340, proxy.size.width * 0.34), 410))

                                transcriptCard
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .onAppear {
                shouldPulseStatus = true
            }
        }
    }

    private var heroCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meet Transcript")
                            .font(.custom("Avenir Next Condensed", size: 38))
                            .fontWeight(.bold)
                            .foregroundStyle(Palette.title)

                        Text("Capture mic + meeting audio with local transcripts")
                            .font(.custom("Avenir Next", size: 14))
                            .foregroundStyle(Palette.subtitle)
                    }

                    Spacer()

                    statusPill
                }

                if let latest = coordinator.latestSessionPath {
                    Text("Last Session: \(latest)")
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var controlsCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Recording Controls")

                HStack(spacing: 8) {
                    Button(coordinator.isRecording ? "Stop Recording" : "Start Recording") {
                        coordinator.toggleRecording()
                    }
                    .buttonStyle(PanelButtonStyle(tone: .primary, isEmphasized: coordinator.isRecording))
                    .keyboardShortcut(.space, modifiers: [])

                    if coordinator.latestSessionPath != nil {
                        Button("Open Session") {
                            coordinator.openLatestSessionInFinder()
                        }
                        .buttonStyle(PanelButtonStyle(tone: .secondary))
                    }

                    Button("Refresh Mic") {
                        coordinator.refreshMicrophoneList()
                    }
                    .buttonStyle(PanelButtonStyle(tone: .ghost))
                    .disabled(coordinator.isRecording)
                }

                Toggle("Include system audio (requires Screen Recording)", isOn: $coordinator.captureSystemAudio)
                    .toggleStyle(.switch)
                    .font(.custom("Avenir Next", size: 14))
                    .disabled(coordinator.isRecording)

                Divider()
                    .overlay(Palette.divider)

                if coordinator.availableMicrophones.isEmpty {
                    Text("Microphone: \(coordinator.microphoneDeviceName)")
                        .font(.custom("Avenir Next", size: 13))
                        .foregroundStyle(Palette.subtitle)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Microphone", selection: $coordinator.selectedMicrophoneID) {
                            ForEach(coordinator.availableMicrophones) { microphone in
                                Text(microphone.name).tag(microphone.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(coordinator.isRecording)

                        Text("Current mic: \(coordinator.microphoneDeviceName)")
                            .font(.custom("Avenir Next", size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                }

                Text(coordinator.statusMessage)
                    .font(.custom("Avenir Next", size: 13))
                    .foregroundStyle(Palette.subtitle)
                    .lineLimit(2)
            }
        }
    }

    private var transcriptCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionLabel("Transcript")
                    Spacer()
                    Text("\(coordinator.transcriptSegments.count) entries")
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(Palette.muted)
                }

                if coordinator.transcriptSegments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No transcript yet")
                            .font(.custom("Avenir Next", size: 16))
                            .fontWeight(.semibold)
                            .foregroundStyle(Palette.title)

                        Text("Start recording to capture transcription from your meeting audio.")
                            .font(.custom("Avenir Next", size: 13))
                            .foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Palette.rowBackground)
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(coordinator.transcriptSegments) { segment in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        Capsule()
                                            .fill(speakerColor(for: segment.speaker))
                                            .frame(width: 8, height: 8)

                                        Text(segment.speaker)
                                            .font(.custom("Avenir Next", size: 12))
                                            .fontWeight(.semibold)
                                            .foregroundStyle(Palette.title)

                                        Spacer()

                                        Text(dateFormatter.string(from: segment.timestamp))
                                            .font(.custom("Avenir Next", size: 11))
                                            .foregroundStyle(Palette.muted)
                                    }

                                    Text(segment.text)
                                        .font(.custom("Avenir Next", size: 15))
                                        .foregroundStyle(Palette.text)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Palette.rowBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(speakerColor(for: segment.speaker).opacity(0.16), lineWidth: 1)
                                        )
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var sessionsCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionLabel("Session Files")
                    Spacer()
                    Text("\(coordinator.sessionFiles.count) sessions")
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(Palette.muted)
                }

                HStack(spacing: 8) {
                    Button("Refresh Files") {
                        coordinator.refreshSessionFiles()
                    }
                    .buttonStyle(PanelButtonStyle(tone: .ghost))

                    Button("Select Missing") {
                        coordinator.selectAllMissingTranscripts()
                    }
                    .buttonStyle(PanelButtonStyle(tone: .secondary))
                    .disabled(
                        coordinator.isRecording ||
                            !coordinator.sessionFiles.contains(where: \.needsTranscriptGeneration)
                    )

                    Button("Clear") {
                        coordinator.clearSelectedTranscripts()
                    }
                    .buttonStyle(PanelButtonStyle(tone: .ghost))
                    .disabled(coordinator.selectedSessionPaths.isEmpty)
                }

                HStack(spacing: 8) {
                    Text("\(coordinator.selectedSessionPaths.count) selected")
                        .font(.custom("Avenir Next", size: 12))
                        .foregroundStyle(Palette.muted)

                    Spacer()

                    Button("Generate Selected") {
                        coordinator.regenerateSelectedTranscripts()
                    }
                    .buttonStyle(PanelButtonStyle(tone: .secondary))
                    .disabled(
                        coordinator.isRecording ||
                            coordinator.isRegeneratingSessionBatch ||
                            coordinator.selectedSessionPaths.isEmpty
                    )
                }

                if coordinator.sessionFiles.isEmpty {
                    Text("No session folders found yet.")
                        .font(.custom("Avenir Next", size: 13))
                        .foregroundStyle(Palette.muted)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(coordinator.sessionFiles) { session in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(session.sessionName)
                                        .font(.custom("Avenir Next", size: 13))
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Palette.title)
                                        .lineLimit(1)

                                    if let recordedAt = session.recordedAt {
                                        Text(sessionDateFormatter.string(from: recordedAt))
                                            .font(.custom("Avenir Next", size: 11))
                                            .foregroundStyle(Palette.muted)
                                    }

                                    Text(session.fileSummary)
                                        .font(.custom("Avenir Next", size: 12))
                                        .foregroundStyle(Palette.subtitle)
                                        .lineLimit(2)
                                        .truncationMode(.middle)

                                    if session.needsTranscriptGeneration {
                                        HStack(spacing: 8) {
                                            Button(
                                                coordinator.selectedSessionPaths.contains(session.sessionDirectory.path)
                                                    ? "Selected"
                                                    : "Select"
                                            ) {
                                                coordinator.toggleSessionSelection(for: session.sessionDirectory.path)
                                            }
                                            .buttonStyle(PanelButtonStyle(tone: .ghost))
                                            .disabled(
                                                coordinator.isRecording || coordinator.isRegeneratingSessionBatch
                                            )

                                            Button("Generate transcript") {
                                                coordinator.regenerateMissingTranscript(for: session.sessionDirectory.path)
                                            }
                                            .buttonStyle(PanelButtonStyle(tone: .secondary))
                                            .disabled(
                                                coordinator.isRecording ||
                                                    coordinator.activeSessionRegenerations.contains(session.sessionDirectory.path)
                                            )
                                        }
                                    } else {
                                        Text("Transcript already generated")
                                            .font(.custom("Avenir Next", size: 11))
                                            .foregroundStyle(Palette.muted)
                                    }
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Palette.rowBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(Palette.cardStroke, lineWidth: 1)
                                        )
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(coordinator.isRecording ? Palette.recording : Palette.idle)
                .frame(width: 10, height: 10)
                .scaleEffect(coordinator.isRecording && shouldPulseStatus ? 1.22 : 1.0)
                .opacity(coordinator.isRecording && shouldPulseStatus ? 0.66 : 1.0)
                .animation(
                    coordinator.isRecording
                        ? .easeInOut(duration: 0.95).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.2),
                    value: shouldPulseStatus && coordinator.isRecording
                )

            Text(coordinator.isRecording ? "RECORDING" : "IDLE")
                .font(.custom("Avenir Next", size: 11))
                .fontWeight(.bold)
                .foregroundStyle(Palette.title)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Palette.rowBackground)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke((coordinator.isRecording ? Palette.recording : Palette.idle).opacity(0.35), lineWidth: 1)
                )
        )
    }

    private var backgroundLayer: some View {
        Palette.backgroundSolid
            .ignoresSafeArea()
    }

    @ViewBuilder
    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Palette.cardStroke, lineWidth: 1)
                    )
            )
            .shadow(color: Palette.shadow, radius: 16, x: 0, y: 10)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.custom("Avenir Next", size: 11))
            .fontWeight(.bold)
            .tracking(1)
            .foregroundStyle(Palette.muted)
    }

    private func speakerColor(for speaker: String) -> Color {
        if speaker == "You" {
            return Palette.you
        }
        if speaker.hasPrefix("Participant") {
            return Palette.participant
        }
        if speaker == "Mixed" {
            return Palette.mixed
        }
        return Palette.others
    }
}

private enum Palette {
    static let backgroundSolid = Color(red: 0.09, green: 0.11, blue: 0.14)

    static let cardBackground = Color.white.opacity(0.09)
    static let rowBackground = Color.white.opacity(0.08)
    static let cardStroke = Color.white.opacity(0.17)
    static let divider = Color.white.opacity(0.14)
    static let shadow = Color.black.opacity(0.22)

    static let title = Color.white.opacity(0.95)
    static let subtitle = Color.white.opacity(0.78)
    static let text = Color.white.opacity(0.92)
    static let muted = Color.white.opacity(0.6)

    static let recording = Color(red: 0.98, green: 0.37, blue: 0.33)
    static let idle = Color(red: 0.58, green: 0.67, blue: 0.78)

    static let you = Color(red: 0.93, green: 0.62, blue: 0.24)
    static let participant = Color(red: 0.38, green: 0.84, blue: 0.75)
    static let others = Color(red: 0.74, green: 0.8, blue: 0.9)
    static let mixed = Color(red: 0.87, green: 0.8, blue: 0.33)
}

private struct PanelButtonStyle: ButtonStyle {
    enum Tone {
        case primary
        case secondary
        case ghost
    }

    let tone: Tone
    var isEmphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Avenir Next", size: 13))
            .fontWeight(.semibold)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(foregroundColor(configuration: configuration))
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(backgroundColor(configuration: configuration))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(borderColor(configuration: configuration), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }

    private func foregroundColor(configuration: Configuration) -> Color {
        switch tone {
        case .primary:
            return .white.opacity(configuration.isPressed ? 0.9 : 1)
        case .secondary, .ghost:
            return Palette.title.opacity(configuration.isPressed ? 0.8 : 1)
        }
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        let pressed = configuration.isPressed
        switch tone {
        case .primary:
            let base = isEmphasized ? Palette.recording : Palette.you
            return base.opacity(pressed ? 0.78 : 0.95)
        case .secondary:
            return Color.white.opacity(pressed ? 0.11 : 0.16)
        case .ghost:
            return Color.white.opacity(pressed ? 0.06 : 0.09)
        }
    }

    private func borderColor(configuration: Configuration) -> Color {
        let pressed = configuration.isPressed
        switch tone {
        case .primary:
            return Color.white.opacity(pressed ? 0.25 : 0.3)
        case .secondary:
            return Color.white.opacity(pressed ? 0.18 : 0.24)
        case .ghost:
            return Color.white.opacity(pressed ? 0.12 : 0.16)
        }
    }
}
