import Foundation
import Testing
@testable import Pocket3Core

@Suite("Bluetooth reversible setting candidate")
struct BluetoothReversibleSettingCandidateTests {
    private let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let peripheralID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let captureSessionID = "33333333-3333-3333-3333-333333333333"

    private var binding: ContinuousGimbalBinding {
        .init(sessionID: "ble:\(sessionID.uuidString)", generation: 0)
    }

    private func baseline(
        mode: CameraFocusMode = .continuous,
        raw: Data? = nil,
        receivedUptime: TimeInterval = 9
    ) -> CameraSettingsObservation {
        let bytes = raw ?? Data([0xb2, 0xff, 0x00])
        let lens = CameraLensStateReadback(
            raw: bytes, focusModeRaw: bytes[0], focusMode: mode)
        return CameraSettingsObservation(
            property: .lensState, value: .focus(mode),
            readOnlyValue: .lensState(lens), exposureMode: nil,
            transactionID: 77, binding: binding,
            receivedUptime: receivedUptime)
    }

    private func request(
        target: CameraFocusMode = .single,
        nowUptime: TimeInterval = 10,
        baseline: CameraSettingsObservation? = nil,
        execute: Bool = false
    ) throws -> BluetoothReversibleSettingCandidateRequest {
        try BluetoothReversibleSettingCandidateRequest(
            expectedSessionID: sessionID, peripheralID: peripheralID,
            expectedCaptureSessionID: captureSessionID, target: target,
            sequence: 51779, nowUptime: nowUptime,
            baseline: baseline ?? self.baseline(), execute: execute)
    }

    @Test func requestIsDeveloperOnlyAndClosedToFocusModeFields() throws {
        let request = try request()
        #expect(request.target == .single)
        #expect(request.arguments["target"] == .string("single"))
        #expect(request.arguments["sequence"] == .number(51779))
        #expect(BluetoothReversibleSettingCandidateRequest.schema[
            "additionalProperties"] == .bool(false))
        #expect(BluetoothReversibleSettingCandidate.allCases == [.focusMode])
        #expect(throws: BluetoothReversibleSettingCandidateRequestError.invalidArguments) {
            try BluetoothReversibleSettingCandidateRequest(arguments: .object([
                "expectedSessionID": .string(sessionID.uuidString),
                "peripheralID": .string(peripheralID.uuidString),
                "expectedCaptureSessionID": .string(captureSessionID),
                "target": .string("single"), "sequence": .number(51779),
                "nowUptime": .number(10),
                "baseline": try .encode(self.baseline()),
                "setter": .bool(true)
            ]))
        }
    }

    @Test func freshRawBaselineAdmitsCandidateButNeverIssuesWriter() throws {
        let report = BluetoothReversibleSettingCandidate.dryRun(
            try request())
        #expect(report.candidate == .focusMode)
        #expect(report.property == .lensState)
        #expect(report.expectedSessionID == sessionID)
        #expect(report.expectedPeripheralID == peripheralID)
        #expect(report.sequence == 51779)
        #expect(report.admissionGranted)
        #expect(report.outcome == .candidate)
        #expect(report.reason == "dry_run_only_local_writer_unverified")
        #expect(report.baselineMode == .continuous)
        #expect(report.restoreTarget == .continuous)
        #expect(report.baselineRaw == Data([0xb2, 0xff, 0x00]))
        #expect(report.baselineRawLength == 3)
        #expect(report.commandSet == 0x02 && report.commandID == 0x24)
        #expect(report.commandFlags == 0x40)
        #expect(report.commandPayload == Data([0x01]))
        #expect(report.commandPayloadHex == "01")
        #expect(report.restorePayload == Data([0x02]))
        #expect(report.restorePayloadHex == "02")
        #expect(report.route.contains("FFF5 withoutResponse"))
        #expect(report.dryRun && !report.hardwareAccessed)
        #expect(!report.executeRequested && !report.executeAllowed)
        #expect(!report.setterIssued && !report.restoreIssued)
        #expect(!report.followUpGetIssued)
        #expect(report.nextCaptureFlow.count == 6)
        #expect(report.evidence.contains(
            "Kaze@341a35de18493ff61f97c93b8b10161a7512aa36"))
        #expect(report.evidence.contains(
            "OpenPocketCine@9c4e7334ca4d935c5d467abecaf8f968f7927d84"))
        _ = try JSONEncoder().encode(report)
    }

    @Test func executeRequestIsExplicitlyUnsupportedAndNoOpHasNoWrite() throws {
        let execute = BluetoothReversibleSettingCandidate.dryRun(
            try request(execute: true))
        #expect(execute.admissionGranted)
        #expect(execute.executeRequested && !execute.executeAllowed)
        #expect(execute.outcome == .unsupported)
        #expect(execute.reason == "local_writer_unverified")
        #expect(!execute.setterIssued && !execute.restoreIssued)

        let noOp = BluetoothReversibleSettingCandidate.dryRun(
            try request(target: .continuous))
        #expect(noOp.admissionGranted)
        #expect(noOp.outcome == .noOp)
        #expect(noOp.reason == "target_matches_fresh_readback_baseline")
        #expect(!noOp.setterIssued && !noOp.restoreIssued)
    }

    @Test func staleOrUnknownBaselineIsRejectedWithoutGuessingMode() throws {
        let stale = BluetoothReversibleSettingCandidate.dryRun(
            try request(baseline: baseline(receivedUptime: 1)))
        #expect(!stale.admissionGranted)
        #expect(stale.outcome == .invalidBaseline)
        #expect(stale.reason == "baseline_stale_or_clock_invalid")

        let unknownRaw = CameraLensStateReadback(
            raw: Data([0x7f, 0xaa]), focusModeRaw: 0x7f,
            focusMode: nil)
        let unknown = CameraSettingsObservation(
            property: .lensState, value: nil, readOnlyValue: .lensState(unknownRaw),
            exposureMode: nil, transactionID: 1, binding: binding,
            receivedUptime: 9)
        let rejected = BluetoothReversibleSettingCandidate.dryRun(
            try request(baseline: unknown))
        #expect(!rejected.admissionGranted)
        #expect(rejected.outcome == .invalidBaseline)
        #expect(rejected.reason == "baseline_focus_readback_unknown")
        #expect(rejected.baselineRaw == Data([0x7f, 0xaa]))
        #expect(!rejected.setterIssued && !rejected.restoreIssued)

        let inconsistent = CameraSettingsObservation(
            property: .lensState, value: .focus(.continuous),
            readOnlyValue: .lensState(CameraLensStateReadback(
                raw: Data([0xb2]), focusModeRaw: 0xb2, focusMode: .single)),
            exposureMode: nil, transactionID: 2, binding: binding,
            receivedUptime: 9)
        let mismatch = BluetoothReversibleSettingCandidate.dryRun(
            try request(baseline: inconsistent))
        #expect(!mismatch.admissionGranted)
        #expect(mismatch.reason == "baseline_focus_readback_unknown")
    }
}
