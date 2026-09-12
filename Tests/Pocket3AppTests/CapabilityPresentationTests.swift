import Foundation
import SwiftUI
import Testing
import Pocket3Core
@testable import Pocket3BridgeApp

@Suite("Capability graph presentation") struct CapabilityPresentationTests {
    @Test func presentationKeepsUSBHostBodyNativeAndLiveBoundariesVisible() throws {
        let uvc = UVCCaptureFormat(mode: .default1080p30, inputPixelFormat: .nv12,
                                   availability: .verified, evidence: .localReadOnly)
        let bodyEntry = CameraVideoFormatCapability(resolutionRaw: CameraVideoResolution.portrait3K.rawValue,
                                                     frameRateRaw: CameraFrameRate.fps30.rawValue)
        let body = BodyRecordingFormatCapability(capability: bodyEntry)
        let host = HostOutputCodecCapability(codec: .h264, requested: true,
                                             availability: .init(read: true, write: true, verified: false,
                                                                 reason: "No decoded sample"),
                                             evidence: .softwareFixture)
        let graph = Pocket3CapabilityGraph(
            uvcCaptureFormats: [uvc], hostOutputCodecs: [host], bodyRecordingFormats: [body],
            nativeSession: NativeSessionCapability(readiness: .commandReady,
                                                   availability: .init(read: true, write: true),
                                                   evidence: .localReadOnly),
            liveSession: .unavailable)

        #expect(CapabilityPresentation.usbCapture(graph).contains("NV12"))
        #expect(CapabilityPresentation.hostOutput(graph).contains("H.264"))
        #expect(CapabilityPresentation.bodyRecording(graph).contains("3K 9:16"))
        #expect(CapabilityPresentation.nativeSession(graph) == "Ready")
        #expect(CapabilityPresentation.liveSession(graph) == "Unavailable")
        let detail = CapabilityPresentation.graphDetail(graph)
        #expect(detail.contains("read=true,write=true,verified=false"))
        #expect(detail.contains("Evidence D"))
    }

    @Test func pendingBodyCatalogDoesNotPretendToHaveReadback() {
        let graph = Pocket3CapabilityGraph()
        #expect(CapabilityPresentation.bodyRecording(graph).contains("Readback pending"))
        #expect(CapabilityPresentation.bodyRecordingDetail(graph).contains("No current body readback"))
        #expect(graph.bodyRecordingFormats.contains { $0.format.resolution == .square3K })
    }

    @MainActor @Test func bodyCapabilitySectionFitsTheSettingsColumnWithoutOpeningHardware() async throws {
        let model = AppModel()
        model.status = await model.service.status()
        let renderer = ImageRenderer(content: BodyCapabilitySection(model: model).frame(width: 560))
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 560)
        #expect(image.size.height > 300 && image.size.height < 1_200)
        #expect(!model.wireless.bluetooth.isBluetoothInitialized)
    }
}
