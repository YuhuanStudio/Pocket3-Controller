import Foundation
import Testing
@testable import Pocket3Core

@Suite struct ReadOnlyCameraPropertiesTests {
    private let binding = ContinuousGimbalBinding(sessionID: "read-only-property-session", generation: 1)

    private func observation(_ property: CameraSettingsProperty, value: Data) -> CameraSettingsObservation? {
        CameraSettingsObservation.decode(
            CameraPropertyPush(property: property, transactionID: 42, value: value),
            binding: binding, receivedUptime: 1)
    }

    private func exposure(_ ev: UInt8 = 0x10, mode: UInt8 = 0x01, iso: UInt32 = 100) -> Data {
        var value = Data(repeating: 0, count: 20)
        value[6] = ev
        value[7] = mode
        value.replaceSubrange(16..<20, with: [
            UInt8(iso & 0xff), UInt8((iso >> 8) & 0xff),
            UInt8((iso >> 16) & 0xff), UInt8((iso >> 24) & 0xff)
        ])
        return value
    }

    @Test func everyCaptureConfirmedPropertyDecodesWithTypedFields() throws {
        let video = try #require(observation(.videoParameters,
            value: Data([0x0a, 0x03, 0, 0, 0, 0, 0, 0, 0x01])))
        guard case .videoParameters(let videoValue) = video.readOnlyValue else { Issue.record("video value missing"); return }
        #expect(videoValue.resolution == .p1080 && videoValue.frameRate == .fps30)
        #expect(videoValue.compression == .hevcEfficiency && videoValue.raw.count == 9)

        let aspect = try #require(observation(.sensorAspectRatio, value: Data([0x01])))
        guard case .sensorAspectRatio(let aspectValue) = aspect.readOnlyValue else { Issue.record("aspect value missing"); return }
        #expect(aspectValue.aspectRatio == .portrait && aspectValue.orientation == .portrait)

        let effect = try #require(observation(.imageEffect, value: Data([0, 0, 0x3d, 0, 0x06, 0x38])))
        guard case .imageEffect(let effectValue) = effect.readOnlyValue else { Issue.record("effect value missing"); return }
        #expect(effectValue.colorProfile == .dLogM)
        #expect(effectValue.whiteBalance == .customKelvin(5600) && effectValue.whiteBalanceKelvinRaw == 0x38)
        #expect(effect.value == .whiteBalance(.customKelvin(5600)))

        let exposureValue = try #require(observation(.exposure, value: exposure(0x13, mode: 0x01, iso: 6400)))
        guard case .exposure(let exposureReadback) = exposureValue.readOnlyValue else { Issue.record("exposure value missing"); return }
        #expect(exposureReadback.evThirdStops == 3 && exposureReadback.exposureMode == .automatic)
        #expect(exposureReadback.effectiveISO == 6400 && exposureValue.value == .autoEV(thirdStops: 3))

        let lens = try #require(observation(.lensState, value: Data([0xb2])))
        guard case .lensState(let lensValue) = lens.readOnlyValue else { Issue.record("lens value missing"); return }
        #expect(lensValue.focusMode == .continuous && lens.value == .focus(.continuous))

        var photoBytes = Data(repeating: 0, count: 13)
        photoBytes[1] = 0x03; photoBytes[3] = 0x02; photoBytes[7] = 0x05
        let photo = try #require(observation(.photoParameters, value: photoBytes))
        guard case .photoParameters(let photoValue) = photo.readOnlyValue else { Issue.record("photo value missing"); return }
        #expect(photoValue.frame == .oneByOne && photoValue.format == .jpegAndRaw)
        #expect(photoValue.countdown == .seconds5 && photoValue.raw == photoBytes)

        var lapseBytes = Data(repeating: 0, count: 21)
        lapseBytes[0] = 0x02
        lapseBytes[1] = 50; lapseBytes[2] = 0
        lapseBytes[5] = 0x2c; lapseBytes[6] = 0x01 // 300 seconds
        lapseBytes[9] = 5; lapseBytes[10] = 0; lapseBytes[11] = 5; lapseBytes[12] = 0
        let lapse = try #require(observation(.lapseParameters, value: lapseBytes))
        guard case .lapseParameters(let lapseValue) = lapse.readOnlyValue else { Issue.record("lapse value missing"); return }
        #expect(lapseValue.output == .jpegAndVideo && lapseValue.intervalTenths == 50)
        #expect(lapseValue.durationSeconds == 300 && lapseValue.hyperlapseSpeed == .x5)

        var motionBytes = Data(repeating: 0, count: 8)
        motionBytes[2] = 0; motionBytes[3] = 0x80; motionBytes[7] = 4
        let motion = try #require(observation(.motionlapseParameters, value: motionBytes))
        guard case .motionlapseParameters(let motionValue) = motion.readOnlyValue else { Issue.record("motionlapse value missing"); return }
        #expect(motionValue.direction == .custom && motionValue.previewActive == true)
        #expect(motionValue.waypointCount == 4 && motionValue.motionlapseWaypointCount == 4)

        let pano = try #require(observation(.panoramaParameters, value: Data([0x07, 0x01, 0])))
        guard case .panoramaParameters(let panoValue) = pano.readOnlyValue else { Issue.record("panorama value missing"); return }
        #expect(panoValue.panoramaType == .grid3x3 && panoValue.photoFormat == .raw)
    }

    @Test func unknownEnumCodesKeepRawBytesAndDoNotBecomeKnownValues() throws {
        let videoBytes = Data([0xfe, 0xff, 0, 0, 0, 0, 0, 0, 0xfd])
        guard case .videoParameters(let video) = CameraReadOnlyPropertyDecoder.decode(.videoParameters, value: videoBytes) else {
            Issue.record("unknown video did not decode"); return
        }
        #expect(video.resolution == nil && video.frameRate == nil && video.compression == nil)
        #expect(video.resolutionRaw == 0xfe && video.frameRateRaw == 0xff && video.compressionRaw == 0xfd)
        #expect(video.raw == videoBytes)

        let aspect = try #require(observation(.sensorAspectRatio, value: Data([0xfe])))
        guard case .sensorAspectRatio(let aspectValue) = aspect.readOnlyValue else { Issue.record("unknown aspect missing"); return }
        #expect(aspectValue.aspectRatio == nil && aspectValue.rawValue == 0xfe)

        let effect = try #require(observation(.imageEffect, value: Data([0, 0xfe, 0xfe, 0, 0xfe, 0xff])))
        guard case .imageEffect(let effectValue) = effect.readOnlyValue else { Issue.record("unknown effect missing"); return }
        #expect(effectValue.colorProfile == nil && effectValue.whiteBalance == nil)
        #expect(effectValue.colorRaw == 0xfe && effectValue.whiteBalanceRaw == 0xfe)
        #expect(effect.value == nil)

        let unknownExposure = try #require(observation(.exposure, value: exposure(0xff, mode: 0xfe, iso: 1600)))
        guard case .exposure(let exposureValue) = unknownExposure.readOnlyValue else { Issue.record("unknown exposure missing"); return }
        #expect(exposureValue.evThirdStops == nil && exposureValue.evRaw == 0xff)
        #expect(exposureValue.exposureMode == nil && exposureValue.exposureModeRaw == 0xfe)
        #expect(exposureValue.effectiveISO == 1600 && unknownExposure.value == nil)

        let lens = try #require(observation(.lensState, value: Data([0xfe])))
        guard case .lensState(let lensValue) = lens.readOnlyValue else { Issue.record("unknown lens missing"); return }
        #expect(lensValue.focusMode == nil && lensValue.focusModeRaw == 0xfe && lens.value == nil)
        for writerCode in [UInt8(0x01), UInt8(0x02)] {
            let writerLens = try #require(observation(.lensState, value: Data([writerCode])))
            guard case .lensState(let value) = writerLens.readOnlyValue else {
                Issue.record("writer code lens readback missing"); continue
            }
            #expect(value.focusMode == nil && value.focusModeRaw == writerCode && writerLens.value == nil)
        }

        var photoBytes = Data(repeating: 0, count: 13)
        photoBytes[1] = 0xfe; photoBytes[3] = 0xfd; photoBytes[7] = 0xfc
        guard case .photoParameters(let photo) = CameraReadOnlyPropertyDecoder.decode(.photoParameters, value: photoBytes) else {
            Issue.record("unknown photo did not decode"); return
        }
        #expect(photo.frame == nil && photo.format == nil && photo.countdown == nil)
        #expect(photo.frameRaw == 0xfe && photo.formatRaw == 0xfd && photo.countdownRaw == 0xfc)

        var lapseBytes = Data(repeating: 0, count: 21)
        lapseBytes[0] = 0xfe; lapseBytes[9] = 1; lapseBytes[11] = 2
        guard case .lapseParameters(let lapse) = CameraReadOnlyPropertyDecoder.decode(.lapseParameters, value: lapseBytes) else {
            Issue.record("unknown lapse did not decode"); return
        }
        #expect(lapse.output == nil && lapse.hyperlapseSpeed == nil)
        #expect(lapse.outputRaw == 0xfe && lapse.hyperlapseSpeedRaw == 1 && lapse.mirroredHyperlapseSpeedRaw == 2)

        let motionBytes = Data([0, 0, 0xfe, 0x7f, 0, 0, 0, 5])
        guard case .motionlapseParameters(let motion) = CameraReadOnlyPropertyDecoder.decode(.motionlapseParameters, value: motionBytes) else {
            Issue.record("unknown motionlapse did not decode"); return
        }
        #expect(motion.direction == nil && motion.previewActive == nil && motion.waypointCount == nil)
        #expect(motion.directionRaw == 0xfe && motion.previewActiveRaw == 0x7f && motion.waypointCountRaw == 5)

        guard case .panoramaParameters(let pano) = CameraReadOnlyPropertyDecoder.decode(.panoramaParameters, value: Data([0xfe, 0xfd, 0xfc])) else {
            Issue.record("unknown panorama did not decode"); return
        }
        #expect(pano.panoramaType == nil && pano.photoFormat == nil)
        #expect(pano.panoramaTypeRaw == 0xfe && pano.photoFormatRaw == 0xfd)
    }

    @Test func truncatedValuesAreRejectedAtEachCaptureConfirmedMinimum() {
        let minimums: [(CameraSettingsProperty, Int)] = [
            (.videoParameters, 9), (.sensorAspectRatio, 1), (.imageEffect, 6),
            (.exposure, 20), (.lensState, 1), (.photoParameters, 13),
            (.lapseParameters, 21), (.motionlapseParameters, 8), (.panoramaParameters, 3)
        ]
        for (property, minimum) in minimums {
            for count in 0..<minimum {
                #expect(CameraReadOnlyPropertyDecoder.decode(property, value: Data(repeating: 0, count: count)) == nil)
                #expect(observation(property, value: Data(repeating: 0, count: count)) == nil)
            }
        }
    }

    @Test func legacyObservationJSONDecodesWithoutTheOptionalReadOnlyValue() throws {
        let original = CameraSettingsObservation(
            property: .imageEffect, value: .whiteBalance(.automatic),
            exposureMode: nil, transactionID: 7, binding: binding, receivedUptime: 1)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "readOnlyValue")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CameraSettingsObservation.self, from: legacy)
        #expect(decoded.value == .whiteBalance(.automatic) && decoded.readOnlyValue == nil)

        let modern = CameraSettingsObservation(
            property: .photoParameters, value: nil,
            readOnlyValue: .photoParameters(CameraPhotoParameters(raw: Data([1, 0, 0]), frameRaw: 0,
                formatRaw: 0, countdownRaw: 0)), exposureMode: nil, transactionID: 8,
            binding: binding, receivedUptime: 2)
        let roundTrip = try JSONDecoder().decode(CameraSettingsObservation.self, from: JSONEncoder().encode(modern))
        #expect(roundTrip.readOnlyValue == modern.readOnlyValue && roundTrip.value == nil)
    }

    @Test func AllPropertiesAreQueryableButNewPropertiesCannotBecomeWriterValues() throws {
        #expect(CameraSettingsProperty.allCases.count == 9)
        for property in CameraSettingsProperty.allCases {
            let query = try BluetoothCameraPropertyQuery(property: property, binding: binding,
                sequence: 1, transactionID: 2, startedUptime: 0)
            #expect(query.result.property == property)
        }

        let writerValues: [CameraSettingValue] = [
            .whiteBalance(.automatic), .focus(.single), .autoEV(thirdStops: 0)
        ]
        let writerProperties = Set(writerValues.map(\.property))
        #expect(writerProperties == Set([CameraSettingsProperty.imageEffect, .lensState, .exposure]))
        for property in CameraSettingsProperty.allCases where !writerProperties.contains(property) {
            #expect(!writerValues.contains { $0.property == property })
        }
    }
}
