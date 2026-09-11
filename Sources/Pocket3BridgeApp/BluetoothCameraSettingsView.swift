import SwiftUI
import Pocket3Core
import YunDesign

struct BluetoothCameraSettingsView: View {
    let observations: [CameraSettingsObservation]
    let reading: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Yun.Space.sm) {
            HStack {
                Text(loc("Bluetooth camera settings")).font(Yun.Text.label)
                Spacer(minLength: 0)
                if reading { ProgressView().controlSize(.mini) }
                Button(loc("Read settings"), action: refresh)
                    .buttonStyle(YunButtonStyle(.secondary, small: true)).disabled(reading)
            }
            row(loc("White balance"), whiteBalance)
            row(loc("Focus mode"), focus)
            row(loc("Exposure"), exposure)
            if let value = video { row(loc("Camera recording format"), value) }
            if let value = orientation { row(loc("Effective orientation"), value) }
            if let value = color { row(loc("Color profile"), value) }
            if let value = photo { row(loc("Photo settings"), value) }
            if let value = lapse { row(loc("Timelapse settings"), value) }
            if let value = motionlapse { row(loc("Motionlapse settings"), value) }
            if let value = panorama { row(loc("Panorama settings"), value) }
            Text(loc("Read-only values reported by the paired Bluetooth camera."))
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
    private func observation(_ property: CameraSettingsProperty) -> CameraSettingsObservation? {
        observations.first { $0.property == property && $0.isFresh(now: ProcessInfo.processInfo.systemUptime) }
    }
    private var whiteBalance: String {
        guard let stored = observation(.imageEffect)?.value, case .whiteBalance(let value) = stored else { return "—" }
        switch value {
        case .automatic: return loc("Auto")
        case .customKelvin(let kelvin): return "\(kelvin) K"
        }
    }
    private var focus: String {
        guard let stored = observation(.lensState)?.value, case .focus(let value) = stored else { return "—" }
        return value == .single ? loc("Single AF") : loc("Continuous AF")
    }
    private var exposure: String {
        guard let observed = observation(.exposure), let mode = observed.exposureMode else { return "—" }
        if mode == .manual { return loc("Manual exposure") }
        guard let stored = observed.value, case .autoEV(let thirds) = stored else { return loc("Auto") }
        return loc("Auto") + " · " + String(format: "%+.1f EV", Double(thirds) / 3)
    }
    private var video: String? {
        guard let observed = observation(.videoParameters)?.readOnlyValue,
              case .videoParameters(let value) = observed else { return nil }
        let resolution = switch value.resolution {
        case .p1080: "1080p"; case .p2_7K: "2.7K"; case .p4K: "4K"
        case .square1080: "1080p 1:1"; case .square2160: "2160p 1:1"; case .square3K: "3K 1:1"
        case .portrait1080: "1080p 9:16"; case .portrait2_7K: "2.7K 9:16"; case .portrait3K: "3K 9:16"
        case nil: String(format: "0x%02X", value.resolutionRaw)
        }
        let fps: String = switch value.frameRate {
        case .fps24: "24"; case .fps25: "25"; case .fps30: "30"; case .fps48: "48"
        case .fps50: "50"; case .fps60: "60"; case .fps120: "120"; case .fps240: "240"
        case nil: String(format: "0x%02X", value.frameRateRaw)
        }
        let codec = value.compression == .h264Compatibility ? "H.264" :
            value.compression == .hevcEfficiency ? "HEVC" : String(format: "0x%02X", value.compressionRaw)
        return "\(resolution) · \(fps) fps · \(codec)"
    }
    private var orientation: String? {
        guard let observed = observation(.sensorAspectRatio)?.readOnlyValue,
              case .sensorAspectRatio(let value) = observed else { return nil }
        return value.aspectRatio == .landscape ? loc("Landscape") :
            value.aspectRatio == .portrait ? loc("Portrait") : String(format: "0x%02X", value.rawValue)
    }
    private var color: String? {
        guard let observed = observation(.imageEffect)?.readOnlyValue,
              case .imageEffect(let value) = observed else { return nil }
        return switch value.colorProfile {
        case .normal: "Normal"; case .hlg: "HLG"; case .dLogM: "D-Log M"
        case nil: String(format: "0x%02X", value.colorRaw)
        }
    }
    private var photo: String? {
        guard let observed = observation(.photoParameters)?.readOnlyValue,
              case .photoParameters(let value) = observed else { return nil }
        let frame = value.frame == .sixteenByNine ? "16:9" : value.frame == .oneByOne ? "1:1" : String(format: "0x%02X", value.frameRaw)
        let format = value.format == .jpeg ? "JPEG" : value.format == .jpegAndRaw ? "JPEG+RAW" : String(format: "0x%02X", value.formatRaw)
        let countdown: String = switch value.countdown {
        case .off: loc("Off"); case .seconds3: "3 s"; case .seconds5: "5 s"; case .seconds7: "7 s"
        case nil: String(format: "0x%02X", value.countdownRaw)
        }
        return "\(frame) · \(format) · \(countdown)"
    }
    private var lapse: String? {
        guard let observed = observation(.lapseParameters)?.readOnlyValue,
              case .lapseParameters(let value) = observed else { return nil }
        let interval = String(format: "%.1f s", Double(value.intervalTenths) / 10)
        let duration = value.durationSeconds == 0 ? "∞" : "\(value.durationSeconds) s"
        let speed: String = switch value.hyperlapseSpeed {
        case .auto: loc("Auto"); case .x2: "2×"; case .x5: "5×"; case .x10: "10×"; case .x15: "15×"; case .x30: "30×"
        case nil: "—"
        }
        return "\(interval) · \(duration) · \(speed)"
    }
    private var motionlapse: String? {
        guard let observed = observation(.motionlapseParameters)?.readOnlyValue,
              case .motionlapseParameters(let value) = observed else { return nil }
        let direction: String = switch value.direction {
        case .custom: loc("Custom"); case .leftToRight: loc("Left to right"); case .rightToLeft: loc("Right to left")
        case nil: String(format: "0x%02X", value.directionRaw)
        }
        let points = value.waypointCount.map { String(format: loc("%d points"), Int($0)) } ?? "—"
        return value.previewActive == true ? "\(direction) · \(points) · \(loc("Previewing"))" : "\(direction) · \(points)"
    }
    private var panorama: String? {
        guard let observed = observation(.panoramaParameters)?.readOnlyValue,
              case .panoramaParameters(let value) = observed else { return nil }
        let type = value.panoramaType == .degrees180 ? "180°" : value.panoramaType == .grid3x3 ? "3×3" : String(format: "0x%02X", value.panoramaTypeRaw)
        let format = value.photoFormat == .jpeg ? "JPEG" : value.photoFormat == .raw ? "RAW" : String(format: "0x%02X", value.photoFormatRaw)
        return "\(type) · \(format)"
    }
}
