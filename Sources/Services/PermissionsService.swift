import AVFoundation
import CoreGraphics
import Foundation
import Speech

struct PermissionSnapshot {
    let microphoneGranted: Bool
    let speechGranted: Bool
    let screenCaptureGranted: Bool
}

final class PermissionsService {
    func requestPrimaryPermissions() async -> PermissionSnapshot {
        let microphone = await requestMicrophoneAccess()
        let speech = SFSpeechRecognizer.authorizationStatus() == .authorized

        return PermissionSnapshot(
            microphoneGranted: microphone,
            speechGranted: speech,
            screenCaptureGranted: false
        )
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                var didResume = false
                let lock = NSLock()

                func resumeOnce(_ value: Bool) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else {
                        return
                    }
                    didResume = true
                    continuation.resume(returning: value)
                }

                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    resumeOnce(granted)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    resumeOnce(false)
                }
            }
        default:
            return false
        }
    }

    private func requestSpeechAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                var didResume = false
                let lock = NSLock()

                func resumeOnce(_ value: Bool) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else {
                        return
                    }
                    didResume = true
                    continuation.resume(returning: value)
                }

                SFSpeechRecognizer.requestAuthorization { status in
                    resumeOnce(status == .authorized)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    resumeOnce(false)
                }
            }
        default:
            return false
        }
    }

    func requestScreenCaptureAccess() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }
}
