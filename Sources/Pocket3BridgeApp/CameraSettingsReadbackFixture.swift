import SwiftUI
import Pocket3Core
import YunDesign

@MainActor enum CameraSettingsReadbackFixture {
    static func view(state: String) throws -> AnyView {
        guard ["available", "stale", "manual"].contains(state) else {
            throw BridgeFailure("invalid_fixture", "Choose a known readback presentation fixture")
        }
        let binding = ContinuousGimbalBinding(sessionID: "ble:interface-fixture", generation: 0)
        let uptime = ProcessInfo.processInfo.systemUptime - (state == "stale" ? 10 : 0)
        let values: [(CameraSettingsProperty, CameraSettingValue?, CameraReadOnlyValue, CameraExposureMode?)] = [
            (.imageEffect, .whiteBalance(.customKelvin(5600)), .imageEffect(.init(raw: Data(), colorRaw: 0, whiteBalanceRaw: 6,
                whiteBalanceKelvinRaw: 56, colorProfile: .normal, whiteBalance: .customKelvin(5600))), nil),
            (.lensState, .focus(.continuous), .lensState(.init(raw: Data(), focusModeRaw: 0xB2, focusMode: .continuous)), nil),
            (.exposure, .autoEV(thirdStops: 1), .exposure(.init(raw: Data(), evRaw: 0x11, exposureModeRaw: state == "manual" ? 4 : 1,
                effectiveISO: 400, evThirdStops: 1, exposureMode: state == "manual" ? .manual : .automatic)), state == "manual" ? .manual : .automatic),
            (.videoParameters, nil, .videoParameters(.init(raw: Data(), resolutionRaw: 0x10, frameRateRaw: 0x06,
                compressionRaw: 1, resolution: .p4K, frameRate: .fps60, compression: .hevcEfficiency)), nil),
            (.sensorAspectRatio, nil, .sensorAspectRatio(.init(raw: Data(), rawValue: 1, aspectRatio: .portrait)), nil),
            (.photoParameters, nil, .photoParameters(.init(raw: Data(), frameRaw: 1, formatRaw: 2, countdownRaw: 3,
                frame: .sixteenByNine, format: .jpegAndRaw, countdown: .seconds3)), nil),
            (.lapseParameters, nil, .lapseParameters(.init(raw: Data(), outputRaw: 2, intervalTenths: 25,
                durationSeconds: 600, hyperlapseSpeedRaw: 10, mirroredHyperlapseSpeedRaw: 10,
                output: .jpegAndVideo, hyperlapseSpeed: .x10)), nil),
            (.motionlapseParameters, nil, .motionlapseParameters(.init(raw: Data(), directionRaw: 1,
                previewActiveRaw: 1, waypointCountRaw: 3, direction: .leftToRight, previewActive: true, waypointCount: 3)), nil),
            (.panoramaParameters, nil, .panoramaParameters(.init(raw: Data(), panoramaTypeRaw: 7,
                photoFormatRaw: 3, panoramaType: .grid3x3, photoFormat: .jpeg)), nil)
        ]
        let rows = values.enumerated().map { index, entry in
            CameraSettingsObservation(property: entry.0, value: entry.1, readOnlyValue: entry.2,
                exposureMode: entry.3, transactionID: UInt32(index), binding: binding, receivedUptime: uptime)
        }
        return AnyView(BluetoothCameraSettingsView(observations: rows, reading: false, refresh: {})
            .padding(Yun.Space.lg).frame(width: 340).background(Yun.Palette.background))
    }
}
