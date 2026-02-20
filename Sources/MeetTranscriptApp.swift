import SwiftUI

@main
struct MeetTranscriptApp: App {
    @StateObject private var coordinator = RecordingCoordinator()

    var body: some Scene {
        WindowGroup("Meet Transcript") {
            ContentView()
                .environmentObject(coordinator)
                .frame(minWidth: 860, minHeight: 620)
        }
    }
}
