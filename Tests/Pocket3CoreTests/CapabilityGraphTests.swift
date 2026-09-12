import Foundation
import Testing
@testable import Pocket3Core

@Suite struct CapabilityGraphTests {
    @Test func evidenceRanksSourcesWithoutChangingAccess() {
        #expect(CapabilityEvidenceLevel.officialSpecification < .publicReverseEngineering)
        #expect(CapabilityEvidenceLevel.publicReverseEngineering < .softwareFixture)
        #expect(CapabilityEvidenceLevel.softwareFixture < .localReadOnly)
        #expect(CapabilityEvidenceLevel.localReadOnly < .localVerifiedWrite)

        let unconfirmed = CapabilityAvailability(read: true, write: true, verified: false,
                                                  reason: "No matching readback")
        #expect(unconfirmed.read && unconfirmed.write && !unconfirmed.verified)
        #expect(unconfirmed.readAvailable && unconfirmed.writeAvailable && !unconfirmed.verifiedAvailable)
        #expect(unconfirmed.reason == "No matching readback")
    }

    @Test func uvcHostAndBodyFormatsRemainDistinct() throws {
        let uvc = UVCCaptureFormat(
            mode: .default1080p30, inputPixelFormat: .nv12, wireCodec: .mjpeg,
            availability: .verified, evidence: .localReadOnly)
        let bodyParameters = CameraVideoParameters(
            raw: Data([0x6B, 0x03, 0, 0, 0, 0, 0, 0, 0x01]),
            resolutionRaw: CameraVideoResolution.square3K.rawValue,
            frameRateRaw: CameraFrameRate.fps30.rawValue,
            compressionRaw: CameraVideoCompression.hevcEfficiency.rawValue,
            resolution: .square3K, frameRate: .fps30, compression: .hevcEfficiency)
        let body = BodyRecordingFormatCapability(readback: bodyParameters)
        let host = HostOutputCodecCapability(codec: .h264, requested: true,
            observedSampleCount: 10, availability: .verified, evidence: .localReadOnly)
        let graph = Pocket3CapabilityGraph(uvcCaptureFormats: [uvc], hostOutputCodecs: [host],
            bodyRecordingFormats: [body])

        #expect(uvc.mode == .default1080p30 && uvc.inputPixelFormat == .nv12)
        #expect(uvc.wireCodec == .mjpeg)
        #expect(body.format.resolution == .square3K)
        #expect(body.format.aspectRatio == .oneByOne)
        #expect(body.format.compression == .hevcEfficiency)
        #expect(body.format.id != uvc.id)
        #expect(graph.nodes.first(where: { $0.id == .hostOutput })?.dependsOn == [.uvcCapture])
        #expect(graph.nodes.first(where: { $0.id == .bodyRecording })?.dependsOn == [.nativeSession])
    }

    @Test func unknownBodyEnumValuesRemainUnknownAndRoundTrip() throws {
        let format = BodyRecordingFormat(resolutionRaw: 0xFE, frameRateRaw: 0xFD,
                                         compressionRaw: 0xFC, raw: Data([0xFE, 0xFD, 0xFC]))
        #expect(format.resolution == nil && format.frameRate == nil && format.compression == nil)
        #expect(format.aspectRatio == .unknown)
        #expect(format.id == "fe:fd:fc")
        let encoded = try JSONEncoder().encode(format)
        let decoded = try JSONDecoder().decode(BodyRecordingFormat.self, from: encoded)
        #expect(decoded == format)
    }

    @Test func runtimeGraphUsesObservedCaptureForHostReadiness() {
        let now = ProcessInfo.processInfo.systemUptime
        let frame = FrameInfo(id: "frame", sessionID: "session", deviceID: "device",
                              receivedAt: Date(), receivedUptime: now,
                              presentationTime: 1, width: 1920, height: 1080,
                              inputPixelFormat: .nv12, inputPixelFormatFourCC: "420v",
                              outputPixelFormat: "BGRA")
        var diagnostics = CaptureSampleDiagnostics()
        diagnostics.requestedOutputPolicy = "h264"
        diagnostics.availableVideoOutputCodecs = ["avc1", "jpeg"]
        diagnostics.decodedH264FrameCount = 5
        let capture = CaptureStats(sessionID: "session", frames: 5, recentFPS: 29.97,
                                   frame: frame, age: 0.1, audio: AudioStats(),
                                   sampleDiagnostics: diagnostics)
        let graph = Pocket3CapabilityGraph.from(
            phase: "ready", capture: capture,
            requestedMode: .default1080p30, requestedPixelFormat: .automatic,
            requestedOutputPolicy: .h264)

        let uvc = graph.uvcCaptureFormats.first
        #expect(uvc?.mode == .default1080p30)
        #expect(uvc?.inputPixelFormat == .nv12)
        #expect(uvc?.availability.read == true && uvc?.availability.write == true)
        #expect(uvc?.availability.verified == true)

        let h264 = graph.hostOutputCodecs.first(where: { $0.codec == .h264 })
        #expect(h264?.requested == true && h264?.observedSampleCount == 5)
        #expect(h264?.availability.read == true && h264?.availability.write == true && h264?.availability.verified == true)
        #expect(h264?.evidence == .localReadOnly)

        let hevc = graph.hostOutputCodecs.first(where: { $0.codec == .hevc })
        #expect(hevc?.availability.read == false && hevc?.availability.write == false)
        #expect(hevc?.availability.verified == false && hevc?.availability.reason != nil)
        #expect(graph.bodyRecordingFormats.contains { $0.format.resolution == .square3K })
        #expect(graph.liveSession.readiness == .unavailable)
    }

    @Test func nativeCommandReadinessDoesNotImplyLiveReadiness() {
        let binding = ContinuousGimbalBinding(sessionID: "native", generation: 1)
        var transport = Pocket3DatalinkStatus()
        transport.phase = .ready
        transport.binding = binding
        transport.lastTelemetryAge = 0.1
        transport.lastHeartbeatAge = 0.2
        let status = NativeControlStatus(transport: transport, expectedBinding: binding,
                                         controlsAvailable: true)
        let native = NativeSessionCapability.from(status)
        #expect(native.readiness == .commandReady)
        #expect(native.availability.read && native.availability.write)
        #expect(native.evidence == .localReadOnly)
        #expect(native.commandReady)
        #expect(LiveSessionCapability.unavailable.readiness == .unavailable)
    }

    @Test func serviceStatusPublishesGraphWithoutStartingAConnection() async {
        let status = await CameraService().status()
        #expect(status.capabilities != nil)
        #expect(status.capabilityGraph == status.capabilities)
        #expect(status.capabilities?.nativeSession.readiness == .disconnected)
        #expect(status.capabilities?.liveSession.readiness == .unavailable)
        #expect(status.capabilities?.uvcCaptureFormats.isEmpty == true)
        #expect(status.capabilities?.bodyRecordingFormats.contains { $0.format.resolution == .square3K } == true)
    }

    @Test func serviceContextPublishesWirelessReadinessAndSparseBodyFormats() async {
        let entry = CameraVideoFormatCapability(resolutionRaw: CameraVideoResolution.portrait3K.rawValue,
                                                frameRateRaw: CameraFrameRate.fps30.rawValue)
        let body = BodyRecordingFormatCapability(capability: entry)
        let service = CameraService()
        await service.updateCapabilityContext(
            nativeSession: NativeSessionCapability(readiness: .credentialsAvailable,
                                                   availability: .init(read: true, reason: "Handshake pending"),
                                                   evidence: .localReadOnly),
            bodyRecordingFormats: [body])

        let status = await service.status()
        let graph = status.capabilities
        #expect(graph?.nativeSession.readiness == .credentialsAvailable)
        #expect(graph?.nativeSession.availability.read == true)
        #expect(graph?.bodyRecordingFormats.contains { $0.format.resolution == .portrait3K && $0.format.frameRate == .fps30 } == true)
        #expect(graph?.bodyRecordingFormats.contains { $0.format.resolution == .square3K } == true)
    }
}
