import Foundation
import CoreMedia
import CoreVideo
import Testing
@testable import Pocket3Core

@Suite struct CaptureSampleDiagnosticsTests {
    @Test func nonImageCallbacksAreVisibleEvenWhenNoFrameCanBeDelivered() throws {
        let store = FrameStore()
        store.reset(deviceID: "test")
        #expect(store.sampleDiagnostics().videoSampleCount == 0)

        store.recordVideoSample(hasImageBuffer: false, hasBlockBuffer: true,
            mediaSubType: kCMVideoCodecType_H264, inputMediaSubType: kCVPixelFormatType_422YpCbCr8)
        store.recordVideoSample(hasImageBuffer: false, hasBlockBuffer: false,
            mediaSubType: kCMVideoCodecType_H264, inputMediaSubType: kCVPixelFormatType_422YpCbCr8)
        let diagnostics = store.sampleDiagnostics()
        #expect(diagnostics.videoSampleCount == 2)
        #expect(diagnostics.pixelBufferCount == 0)
        #expect(diagnostics.nonImageVideoSampleCount == 2)
        #expect(diagnostics.nonImageVideoBlockBufferCount == 1)
        #expect(diagnostics.lastVideoSampleFourCC == "avc1")
        #expect(diagnostics.lastVideoInputFourCC == "2vuy")
        #expect(store.stats().frames == 0)
        #expect(throws: BridgeFailure.self) { try store.latest() }
    }

    @Test func imageCallbacksAndNonImageCallbacksRemainSeparate() {
        let store = FrameStore()
        store.recordVideoSample(hasImageBuffer: false, hasBlockBuffer: true,
            mediaSubType: kCMVideoCodecType_JPEG, inputMediaSubType: nil)
        store.recordVideoSample(hasImageBuffer: true, hasBlockBuffer: false,
            mediaSubType: kCVPixelFormatType_32BGRA, inputMediaSubType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let diagnostics = store.sampleDiagnostics()
        #expect(diagnostics.videoSampleCount == 2)
        #expect(diagnostics.pixelBufferCount == 1 && diagnostics.nonImageVideoSampleCount == 1)
        #expect(diagnostics.lastVideoSampleFourCC == "BGRA")
        #expect(diagnostics.lastVideoInputFourCC == "420v")
    }

    @Test func copiedAttemptSurvivesStoreCleanupWithoutRetainingMedia() throws {
        let store = FrameStore()
        store.recordVideoSample(hasImageBuffer: false, hasBlockBuffer: true,
            mediaSubType: kCMVideoCodecType_H264, inputMediaSubType: nil)
        store.recordRuntimeError(avFoundationCode: -11800)
        store.recordInterruption(active: true)
        store.recordInterruption(active: false)
        let failedAttempt = store.sampleDiagnostics()
        store.reset()
        #expect(store.sampleDiagnostics() == CaptureSampleDiagnostics())
        #expect(failedAttempt.videoSampleCount == 1)
        #expect(failedAttempt.runtimeErrorCount == 1 && failedAttempt.lastAVFoundationErrorCode == -11800)
        #expect(failedAttempt.interruptionCount == 1 && failedAttempt.interruptionEndedCount == 1)
        #expect(!failedAttempt.interrupted)
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(failedAttempt))
        #expect(payload.values.allSatisfy { value in
            switch value { case .number, .string, .bool, .null: true; default: false }
        })
        #expect(!payload.keys.contains("frame") && !payload.keys.contains("image") && !payload.keys.contains("data"))
    }

    @Test func unknownSampleDescriptionsAndRuntimeErrorsDoNotInventCodes() {
        let store = FrameStore()
        store.recordVideoSample(hasImageBuffer: false, hasBlockBuffer: false,
            mediaSubType: nil, inputMediaSubType: nil)
        store.recordRuntimeError(avFoundationCode: nil)
        #expect(store.sampleDiagnostics().lastVideoSampleFourCC == nil)
        #expect(store.sampleDiagnostics().lastVideoInputFourCC == nil)
        #expect(store.sampleDiagnostics().lastAVFoundationErrorCode == nil)
        #expect(store.sampleDiagnostics().runtimeErrorCount == 1)
    }

    @Test func outputChoicesAreRecordedAsNamesWithoutImplyingAnySamplesArrived() throws {
        let store = FrameStore()
        store.recordOutputConfiguration(policy: "native",
            pixelFormats: [kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_32BGRA], codecs: ["avc1", "jpeg"])
        let diagnostics = store.sampleDiagnostics()
        #expect(diagnostics.requestedOutputPolicy == "native")
        #expect(diagnostics.availableVideoOutputPixelFormats == ["2vuy", "BGRA"])
        #expect(diagnostics.availableVideoOutputCodecs == ["avc1", "jpeg"])
        #expect(diagnostics.videoSampleCount == 0 && diagnostics.pixelBufferCount == 0)
        #expect(try JSONDecoder().decode(CaptureSampleDiagnostics.self, from: JSONEncoder().encode(diagnostics)) == diagnostics)
        store.reset()
        #expect(store.sampleDiagnostics().requestedOutputPolicy == nil)
        #expect(store.sampleDiagnostics().availableVideoOutputPixelFormats == nil)
        #expect(store.sampleDiagnostics().availableVideoOutputCodecs == nil)
    }

    @Test func legacySampleDiagnosticsDecodeWithoutNewOptionalOutputFields() throws {
        let legacy = Data(#"{"videoSampleCount":0,"pixelBufferCount":0,"nonImageVideoSampleCount":0,"nonImageVideoBlockBufferCount":0,"runtimeErrorCount":0,"interruptionCount":0,"interruptionEndedCount":0,"interrupted":false}"#.utf8)
        let decoded = try JSONDecoder().decode(CaptureSampleDiagnostics.self, from: legacy)
        #expect(decoded.requestedOutputPolicy == nil && decoded.availableVideoOutputPixelFormats == nil
            && decoded.availableVideoOutputCodecs == nil)
    }
}
