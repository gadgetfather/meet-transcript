import AVFoundation
import CoreAudio
import Foundation

struct MicrophoneDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String
}

enum MicrophoneDeviceResolver {
    static func availableInputDevices() -> [MicrophoneDeviceOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = discovery.devices
        let options = devices.map { device in
            MicrophoneDeviceOption(id: device.uniqueID, name: device.localizedName)
        }

        return Array(Set(options))
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func defaultInputDeviceUniqueID() -> String? {
        var deviceID = AudioDeviceID(0)
        var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0,
            nil,
            &deviceIDSize,
            &deviceID
        )

        guard deviceStatus == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        var deviceUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let uidStatus = withUnsafeMutablePointer(to: &deviceUID) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                &uidSize,
                pointer
            )
        }

        guard uidStatus == noErr else {
            return nil
        }

        return deviceUID as String
    }

    static func builtInMicrophoneID() -> String? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        )

        return discovery.devices.first(where: { $0.deviceType == .builtInMicrophone })?.uniqueID
    }

    static func isLikelyBluetoothMicrophone(name: String) -> Bool {
        let lower = name.lowercased()
        let hints = [
            "airpods",
            "bluetooth",
            "wh-",
            "headset",
            "buds",
            "sony"
        ]

        return hints.contains { lower.contains($0) }
    }

    static func deviceName(for uniqueID: String?) -> String {
        guard let uniqueID else {
            return "Unknown microphone"
        }

        let match = availableInputDevices().first { $0.id == uniqueID }
        return match?.name ?? "Unknown microphone"
    }
}
