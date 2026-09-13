import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 native gimbal acceptance IPC contract")
struct Pocket3NativeGimbalAcceptanceValidationTests {
    private let sessionID = UUID()
    private let peripheralID = UUID()

    private func cli() -> [String] {
        [
            "--session", sessionID.uuidString,
            "--peripheral", peripheralID.uuidString,
            "--station-generation", "4",
            "--native-session", "lan-owner-42",
            "--native-generation", "9"
        ]
    }

    @Test func CLIAndJSONRoundTripDefaultsToDryRun() throws {
        let request = try Pocket3NativeGimbalAcceptanceValidationRequest(
            cliArguments: cli())
        #expect(request.expectedSessionID == sessionID)
        #expect(request.peripheralID == peripheralID)
        #expect(request.stationGeneration == 4)
        #expect(request.nativeSessionID == "lan-owner-42")
        #expect(request.nativeGeneration == 9)
        #expect(!request.execute)
        let decoded = try Pocket3NativeGimbalAcceptanceValidationRequest(
            arguments: request.arguments)
        #expect(decoded == request)
        let encoded = try JSONEncoder().encode(request)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("password"))
    }

    @Test func ExecuteAndBoundedTimingOptionsAreExplicit() throws {
        let request = try Pocket3NativeGimbalAcceptanceValidationRequest(
            cliArguments: cli() + [
                "--hold-seconds", "0.25",
                "--pump-interval", "0.05",
                "--telemetry-timeout", "0.6",
                "--execute"
            ])
        #expect(request.execute)
        #expect(request.holdSeconds == 0.25)
        #expect(request.pumpInterval == 0.05)
        #expect(request.telemetryTimeout == 0.6)
        #expect(request.arguments["execute"] == .bool(true))
    }

    @Test func UnknownFieldsAndMissingNativeFenceAreRejected() throws {
        let encoded = try Pocket3NativeGimbalAcceptanceValidationRequest(
            cliArguments: cli()).arguments
        guard case .object(var fields) = encoded else {
            Issue.record("The request arguments must be an object")
            return
        }
        fields["ssid"] = .string("must-not-be-accepted")
        #expect(throws: Pocket3NativeGimbalAcceptanceError.invalidRequest) {
            try Pocket3NativeGimbalAcceptanceValidationRequest(
                arguments: .object(fields))
        }

        guard case .object(var missingNativeGeneration) = encoded else {
            Issue.record("The request arguments must be an object")
            return
        }
        missingNativeGeneration.removeValue(forKey: "nativeGeneration")
        #expect(throws: Pocket3NativeGimbalAcceptanceError.invalidRequest) {
            try Pocket3NativeGimbalAcceptanceValidationRequest(
                arguments: .object(missingNativeGeneration))
        }
    }

    @Test func InvalidBoundsAndDuplicateCLIOptionsAreRejected() {
        #expect(throws: Pocket3NativeGimbalAcceptanceError.invalidRequest) {
            try Pocket3NativeGimbalAcceptanceValidationRequest(
                expectedSessionID: sessionID, peripheralID: peripheralID,
                stationGeneration: 4, nativeSessionID: "owner",
                nativeGeneration: 9, holdSeconds: 0.1,
                pumpInterval: 0.2)
        }
        #expect(throws: BridgeFailure.self) {
            try Pocket3NativeGimbalAcceptanceValidationRequest(
                cliArguments: cli() + ["--execute", "--execute"])
        }
    }
}
