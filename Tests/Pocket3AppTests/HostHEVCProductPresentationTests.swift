import Foundation
import Pocket3Core
import Testing
@testable import Pocket3BridgeApp

@Suite("Host HEVC product presentation")
struct HostHEVCProductPresentationTests {
    @MainActor @Test
    func hevcSelectionPresentsAnExplicitLocalSessionWithNoExternalConsumer()
        async throws {
        let configuration = try HostVideoEncoderConfiguration(
            width: 2, height: 2, frameRate: 30, maximumPendingFrames: 1)
        let product = try HostHEVCProductOutputService(
            configuration: configuration)
        _ = try await product.select(.hostHEVC)

        let model = AppModel()
        var status = await model.service.status()
        status.requestedOutputPolicy = .hevc
        status.hostHEVCOutput = await product.status()
        model.status = status

        let hostStatus = try #require(model.status?.hostHEVCOutput)
        #expect(hostStatus.phase == .idle)
        #expect(hostStatus.capability.observedSampleCount == 0)
        #expect(hostStatus.consumer == .localSampleEvidence)
        #expect(hostStatus.capability.usbWireCodecClaim == nil)
        #expect(model.outputPolicyStatus != nil)
        #expect(model.outputPolicyStatus?.contains("0") == true)
    }
}
