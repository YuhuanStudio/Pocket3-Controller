import SwiftUI
import Pocket3Core
import YunDesign

enum BluetoothCameraStatusPresentation {
    static func mode(_ observation: Pocket3CameraStatusObservation) -> String {
        guard let mode = observation.shootingMode else {
            return observation.shootingModeRaw.map { String(format: "0x%02X", $0) } ?? "—"
        }
        let key: String = switch mode {
        case .slowMotion: "Slow Motion"
        case .video: "Video"
        case .timelapse: "Timelapse"
        case .photo: "Photo"
        case .hyperlapse: "Hyperlapse"
        case .panorama: "Panorama"
        case .motionlapse: "Motionlapse"
        case .lowLight: "Low-Light"
        }
        return loc(key)
    }
    static func recordState(_ observation: Pocket3CameraStatusObservation) -> String {
        loc(observation.transitioning ? "Changing recording state" : observation.recording ? "Recording" : "Idle")
    }
    static func storage(_ observation: Pocket3CameraStatusObservation,
                        independent: Pocket3StorageObservation? = nil) -> String {
        let free = independent?.freeMiB ?? observation.storageFreeMiB
        let total = independent?.totalMiB ?? observation.storageTotalMiB
        guard let free, let total, total > 0 else { return "—" }
        return String(format: "%.1f / %.1f GB", Double(free) / 1024, Double(total) / 1024)
    }
    static func duration(_ seconds: UInt16?) -> String {
        guard let seconds else { return "—" }
        let value = Int(seconds)
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

struct BluetoothCameraStatusView: View {
    let observation: Pocket3CameraStatusObservation
    let storage: Pocket3StorageObservation?
    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            Text(loc("Pocket 3 camera status")).font(Yun.Text.label)
            row(loc("Shooting mode"), BluetoothCameraStatusPresentation.mode(observation))
            row(loc("Recording state"), BluetoothCameraStatusPresentation.recordState(observation))
            row(loc("SD free / total"), BluetoothCameraStatusPresentation.storage(observation, independent: storage))
            if observation.videoLike == true || observation.recording {
                row(loc("Remaining recording time"), BluetoothCameraStatusPresentation.duration(observation.remainingRecordSeconds))
                row(loc("Recorded time"), BluetoothCameraStatusPresentation.duration(observation.elapsedRecordSeconds))
            }
            Text(loc("Live read-only state reported by the paired Bluetooth peer."))
                .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: Yun.Space.sm) {
            Text(label).foregroundStyle(Yun.Palette.textSecondary)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(Yun.Palette.textPrimary).lineLimit(1)
        }.font(Yun.Text.caption)
    }
}
