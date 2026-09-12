import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native action evidence classification")
struct Pocket3NativeActionEvidenceTests {
    @Test func reviewedCenterAndFlipCandidatesKeepExactDistinctEnvelopes()
        throws {
        let center = Pocket3NativeGimbalShortcutEvidence.candidate(.recenter)
        let flip = Pocket3NativeGimbalShortcutEvidence.candidate(.flip)

        #expect(center.commandSet == 0x04 && center.commandID == 0x4c)
        #expect(center.requestPayload == Data([0xfe, 0x08]))
        #expect(flip.commandSet == 0x04 && flip.commandID == 0x4c)
        #expect(flip.requestPayload == Data([0xfe, 0x09]))
        #expect(center.level == .notAttempted && flip.level == .notAttempted)
        #expect(center.commandAccepted == nil && flip.commandAccepted == nil)

        let centerFrame = Pocket3GimbalShortcut.recenter.frame(sequence: 7)
        let flipFrame = Pocket3GimbalShortcut.flip.frame(sequence: 8)
        #expect(Pocket3NativeGimbalShortcutEvidence.decodeCandidate(centerFrame)
                == .recenter)
        #expect(Pocket3NativeGimbalShortcutEvidence.decodeCandidate(flipFrame)
                == .flip)
        let wrongRoute = DUMLFrame(source: 1, destination: 4, sequence: 7,
            flags: 0x40, commandSet: 4, commandID: 0x4c,
            payload: Data([0xfe, 0x08]))
        #expect(Pocket3NativeGimbalShortcutEvidence.decodeCandidate(wrongRoute)
                == nil)
    }

    @Test func classifierDistinguishesNoReplyNackAckOnlyAndPhysicalEvidence() {
        #expect(Pocket3NativeActionEvidenceReport.classify(
            submitted: false, responseReceived: false,
            responseStatusRaw: nil, acknowledged: false,
            physicalEvidence: false) == .notAttempted)
        #expect(Pocket3NativeActionEvidenceReport.classify(
            submitted: true, responseReceived: false,
            responseStatusRaw: nil, acknowledged: false,
            physicalEvidence: false) == .noCorrelatedReply)
        #expect(Pocket3NativeActionEvidenceReport.classify(
            submitted: true, responseReceived: true,
            responseStatusRaw: 0xFE, acknowledged: false,
            physicalEvidence: false) == .commandRejected)
        #expect(Pocket3NativeActionEvidenceReport.classify(
            submitted: true, responseReceived: true,
            responseStatusRaw: 0, acknowledged: true,
            physicalEvidence: false) == .acknowledgedNoPhysicalEvidence)
        #expect(Pocket3NativeActionEvidenceReport.classify(
            submitted: true, responseReceived: false,
            responseStatusRaw: nil, acknowledged: false,
            physicalEvidence: true) == .physicalEvidenceWithoutReply)
        #expect(Pocket3NativeActionEvidenceReport.classify(
            submitted: true, responseReceived: true,
            responseStatusRaw: 0, acknowledged: true,
            physicalEvidence: true) == .physicalEvidence)
        #expect(Pocket3NativeActionEvidenceReport.classify(
            submitted: true, responseReceived: true,
            responseStatusRaw: nil, acknowledged: false,
            physicalEvidence: false) == .invalidReply)
        #expect(Pocket3NativeActionEvidenceReport.classify(
            submitted: true, responseReceived: false,
            responseStatusRaw: nil, acknowledged: false,
            physicalEvidence: false, cancelled: true) == .cancelled)
        #expect(Pocket3NativeActionEvidenceReport.classify(
            submitted: true, responseReceived: false,
            responseStatusRaw: nil, acknowledged: false,
            physicalEvidence: false, connectionChanged: true)
                == .connectionChanged)
    }

    @Test func recenterProbeRetainsUnknownReplyStatusAndSeparatesMovement()
        throws {
        var result = BluetoothNativeRecenterResult(
            sequence: 0x1234, startedUptime: 0)
        result.registrationAcknowledgmentSubmitted = true
        result.localSubmitted = true
        result.submittedUptime = 1
        result.responseReceived = true
        result.responseStatusRaw = 0xFE
        #expect(result.actionEvidence.level == .commandRejected)
        #expect(result.actionEvidence.responseStatusRaw == 0xFE)

        result.responseStatusRaw = 0
        result.movementObserved = false
        #expect(result.actionEvidence.level ==
                .acknowledgedNoPhysicalEvidence)
        result.movementObserved = true
        #expect(result.actionEvidence.level == .physicalEvidence)
    }

    @Test func tapFocusStepEvidenceUsesCorrelatedTransactionOnly() throws {
        let sessionID = UUID()
        let frame = try NativeCommandFrame(
            source: 2, destination: 1, flags: 0x40,
            commandSet: 2, commandID: 0x30,
            payload: Data(repeating: 0, count: 21))
        let request = try NativeCommandTransactionRequest(
            command: .focusMode, generation: 3, sessionID: sessionID,
            frame: frame, timeout: 1)
        let evidenceRequest = NativeTapFocusStepRequestEvidence(
            step: .point, request: request)

        var noReply = NativeCommandTransactionResult(
            id: request.id, command: .focusMode, generation: 3,
            sessionID: sessionID, end: .timedOut)
        noReply.submitted = true
        let noReplyStep = NativeTapFocusStepResult(
            step: .point, commandID: 0x30, request: evidenceRequest,
            transaction: noReply, submitted: true, acknowledged: false,
            observed: false, failureCode: "native_command_timeout")
        #expect(noReplyStep.actionEvidence.level == .noCorrelatedReply)

        var nack = noReply
        nack.responseReceived = true
        nack.responseStatus = 0xFE
        nack.end = .rejected
        let nackStep = NativeTapFocusStepResult(
            step: .point, commandID: 0x30, request: evidenceRequest,
            transaction: nack, submitted: true, acknowledged: false,
            observed: false, failureCode: "native_command_nack")
        #expect(nackStep.actionEvidence.level == .commandRejected)
        #expect(nackStep.actionEvidence.responseStatusRaw == 0xFE)
    }
}
