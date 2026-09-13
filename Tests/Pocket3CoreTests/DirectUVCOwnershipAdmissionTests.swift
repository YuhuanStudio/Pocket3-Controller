import Foundation
import Testing
@testable import Pocket3Core

@Suite("Direct UVC ownership admission")
struct DirectUVCOwnershipAdmissionTests {
    private let location: UInt32 = 0x0110_0000
    private let registryID = "registry-1"
    private let bootSessionID = "boot-1"

    private func request() throws -> DirectUVCOwnershipAdmissionRequest {
        try DirectUVCOwnershipAdmissionRequest(
            location: location, expectedRegistryID: registryID,
            expectedBootSessionID: bootSessionID)
    }

    private func opened(
        result: String = "opened",
        opened: Bool = true,
        owned: Bool = true,
        interface: UInt8 = 1,
        alternate: UInt8 = 0,
        endpoint: UInt8 = 0x82,
        location: UInt32? = 0x0110_0000,
        registry: String? = "registry-1",
        boot: String? = "boot-1"
    ) -> DirectUVCOpenObservation {
        DirectUVCOpenObservation(
            location: location,
            interfaceNumber: interface,
            alternateSetting: alternate,
            endpointAddress: endpoint,
            endpointCount: 1,
            endpoints: [DirectUVCEndpointObservation(
                pipe: 1, address: endpoint, direction: 0x80,
                transferType: 0x02, maximumPacketSize: 512, interval: 0)],
            opened: opened, ownedOpen: owned, result: result,
            openIOReturn: result == "busy" ? 0xE000_02C7 : 0,
            registryID: registry, bootSessionID: boot,
            access: "normal_open_no_seize_no_pipe")
    }

    private func host(_ expected: Bool) throws -> DirectUVCHostOutputObservation {
        try DirectUVCHostOutputObservation(
            selectedInputFourCC: "2vuy", inputPortFourCC: "420v",
            callbackCount: 0, expectedZeroCallbacks: expected)
    }

    private func evidence(
        stop: AVFoundationStopEvidence = .complete,
        attempted: Bool = true,
        open: DirectUVCOpenObservation? = nil,
        host: DirectUVCHostOutputObservation? = nil,
        seize: Bool = false,
        alternate: Bool = false,
        probe: Bool = false,
        pipeRead: Bool = false
    ) -> DirectUVCOwnershipAdmissionEvidence {
        DirectUVCOwnershipAdmissionEvidence(
            avFoundationStop: stop, normalOpenAttempted: attempted,
            openObservation: open, hostOutput: host,
            seizeAttempted: seize, alternateSettingChanged: alternate,
            probeOrCommitSubmitted: probe, bulkPipeReadAttempted: pipeRead)
    }

    @Test func reviewedRequestRoundTripsAndRejectsUnsafeIdentityShape() throws {
        let value = try request()
        let decoded = try JSONDecoder().decode(
            DirectUVCOwnershipAdmissionRequest.self,
            from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(value.inputFourCC == "2vuy" && value.width == 3840 &&
                value.height == 2160 && value.frameRate == 60)
        #expect(throws: DirectUVCOwnershipAdmissionError.invalidRequest) {
            try DirectUVCOwnershipAdmissionRequest(
                location: location, endpointAddress: 0x02)
        }
        #expect(throws: DirectUVCOwnershipAdmissionError.invalidRequest) {
            try DirectUVCOwnershipAdmissionRequest(
                location: location, frameRate: 0)
        }

        var altered = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(value)) as? [String: Any])
        altered["profile"] = "unreviewed"
        #expect(throws: DirectUVCOwnershipAdmissionError.invalidRequest) {
            try JSONDecoder().decode(
                DirectUVCOwnershipAdmissionRequest.self,
                from: JSONSerialization.data(withJSONObject: altered))
        }
    }

    @Test func systemOwnerBusyIsTypedAndKeepsHostZeroCallbackSeparate() throws {
        let report = DirectUVCOwnershipAdmission.evaluate(
            request: try request(),
            evidence: try evidence(open: opened(
                result: "busy", opened: false, owned: false),
                host: host(true)))
        #expect(report.state == .blockedBySystemOwner)
        #expect(report.failureCode == "direct_uvc_blocked_by_system_owner")
        #expect(report.hostOutputStatus == .expectedZeroCallbacks)
        #expect(!report.directStreamReady)
        #expect(report.checks["avfoundation_stopped_and_drained"] == true)
        #expect(report.checks["normal_open_owned"] == false)
        #expect(report.checks["no_unsafe_operations"] == true)
        #expect(report.conditions.contains(.normalOpenAfterOwnerRelease))
        #expect(report.conditions.contains(.preserveNoSeize))
    }

    @Test func incompleteAVFoundationStopBlocksBeforeAnyOpen() throws {
        let report = DirectUVCOwnershipAdmission.evaluate(
            request: try request(),
            evidence: evidence(
                stop: AVFoundationStopEvidence(
                    avfoundationStopped: true, frameQueueDrained: false),
                attempted: false))
        #expect(report.state == .blockedByAVFoundationOwner)
        #expect(report.failureCode ==
                "direct_uvc_avfoundation_owner_not_released")
        #expect(report.checks["normal_open_attempted"] == false)
        #expect(report.conditions == [.stopAndDrainAVFoundation])
    }

    @Test func normalOpenOnlyAdmitsFutureNegotiationAndNeverStreamReady()
        throws {
        let report = DirectUVCOwnershipAdmission.evaluate(
            request: try request(),
            evidence: try evidence(open: opened(), host: host(true)))
        #expect(report.state == .readyForNegotiation)
        #expect(report.failureCode == nil)
        #expect(report.hostOutputStatus == .expectedZeroCallbacks)
        #expect(report.directStreamReady == false)
        #expect(report.checks.values.filter { $0 }.count == 7)
        #expect(report.checks["bulk_read_ready"] == false)
        #expect(report.conditions.contains(.boundedNegotiationReview))
        #expect(report.conditions.contains(
            .releaseDirectResourcesBeforeAVFoundationRestart))
    }

    @Test func unexpectedZeroCallbackAndUnsafeOperationFailClosed() throws {
        let hostReport = DirectUVCOwnershipAdmission.evaluate(
            request: try request(),
            evidence: try evidence(open: opened(), host: host(false)))
        #expect(hostReport.hostOutputStatus == .unexpectedZeroCallbacks)
        #expect(hostReport.state == .readyForNegotiation)

        let unsafeReport = DirectUVCOwnershipAdmission.evaluate(
            request: try request(),
            evidence: evidence(open: opened(), seize: true))
        #expect(unsafeReport.state == .blockedByUnsafeOperation)
        #expect(unsafeReport.failureCode ==
                "direct_uvc_unsafe_operation_observed")
        #expect(unsafeReport.checks["no_unsafe_operations"] == false)
        #expect(!unsafeReport.directStreamReady)
    }

    @Test func endpointOrAttachmentMismatchCannotBecomeAdmission() throws {
        let endpoint = DirectUVCOwnershipAdmission.evaluate(
            request: try request(),
            evidence: evidence(open: opened(endpoint: 0x02)))
        #expect(endpoint.state == .blockedByInvalidEvidence)
        #expect(endpoint.failureCode == "direct_uvc_open_evidence_mismatch")
        #expect(endpoint.checks["descriptor_endpoint_match"] == false)

        let identity = DirectUVCOwnershipAdmission.evaluate(
            request: try request(),
            evidence: evidence(open: opened(registry: "other-registry")))
        #expect(identity.state == .blockedByInvalidEvidence)
        #expect(identity.checks["exact_attachment_identity"] == false)
        #expect(!identity.directStreamReady)
    }
}
