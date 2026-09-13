import Foundation
import Testing
@testable import Pocket3Core

@Suite("Bluetooth readback session diagnostic")
struct BluetoothReadbackSessionDiagnosticTests {
    private let sessionID = UUID()
    private let peripheralID = UUID()
    private var binding: ContinuousGimbalBinding {
        .init(sessionID: "ble:\(sessionID.uuidString)", generation: 0)
    }

    private func readyStatus() -> BluetoothDiscoveryStatus {
        var status = BluetoothDiscoveryStatus(
            phase: .gattPaired, sessionID: sessionID, candidates: [],
            selectedPeripheralID: peripheralID, issueCode: nil,
            identityVerification: "unverified_candidate",
            authentication: "protocol_pair_confirmed",
            fff4NotificationEnabled: true, fff5NotificationEnabled: true,
            fff4Properties: nil, fff5Properties: nil, receivedFrames: 0,
            fragments: [:], pairing: .init(
                phase: .paired, peerReportedPaired: true,
                credentialsAvailable: true, issueCode: nil), recentHeaders: [])
        status.registrationAcknowledgmentSubmitted = true
        return status
    }

    private func packet(source: UInt8 = 0x28, destination: UInt8 = 0x02,
                        sequence: UInt16 = 7, flags: UInt8 = 0,
                        payload: Data = Data()) throws -> Data {
        try DUMLCodec.encode(DUMLFrame(
            source: source, destination: destination, sequence: sequence,
            flags: flags, commandSet: 0, commandID: 0x99, payload: payload))
    }

    private func propertyPayload(
        name: String, transaction: UInt32 = 77, value: Data
    ) -> Data {
        var bytes: [UInt8] = [2, 6, 0, 0]
        bytes += [UInt8(truncatingIfNeeded: transaction),
                  UInt8(truncatingIfNeeded: transaction >> 8),
                  UInt8(truncatingIfNeeded: transaction >> 16),
                  UInt8(truncatingIfNeeded: transaction >> 24)]
        bytes += [0, 0, 0]
        func append16(_ value: Int) {
            bytes += [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
        }
        append16(name.utf8.count + value.count + 10)
        append16(name.utf8.count)
        bytes += name.utf8
        bytes += [0, 0, 0, 0, 0, 0]
        append16(value.count)
        bytes += value
        return Data(bytes)
    }

    private func query(
        wrongEnvelope: Bool = false,
        readback: Bool = true
    ) throws -> BluetoothCameraPropertyQueryResult {
        var query = try BluetoothCameraPropertyQuery(
            property: .lensState, binding: binding, sequence: 7,
            transactionID: 99, startedUptime: 0)
        try query.submitted(at: 0.01)
        if wrongEnvelope {
            query.receive(try packet(source: 0x48, flags: 0xc0),
                          characteristic: "FFF4", binding: binding, at: 0.1)
        }
        if readback {
            query.receive(try packet(flags: 0xc0, payload: Data([0])),
                          characteristic: "FFF4", binding: binding, at: 0.2)
            let payload = propertyPayload(name: "cam_lens_state",
                                          value: Data([0xb2]))
            query.receive(try packet(sequence: 9, payload: payload),
                          characteristic: "FFF5", binding: binding, at: 0.3)
        }
        return query.finish(at: 2.1)
    }

    private func request(
        path: BluetoothReadbackDiagnosticPath = .settings
    ) throws -> BluetoothReadbackSessionDiagnosticRequest {
        .init(expectedSessionID: sessionID, peripheralID: peripheralID,
              path: path)
    }

    private func nativeSession(
        state: NativeCameraSessionState = .disconnected
    ) -> NativeCameraSessionStatus {
        .init(state: state, generation: state == .disconnected ? 0 : 1,
              sessionID: state == .disconnected ? nil : sessionID,
              peerID: state == .disconnected ? nil : peripheralID)
    }

    private func nativeReadySession() -> NativeCameraSessionStatus {
        .init(state: .commandReady, generation: 1,
              sessionID: sessionID, peerID: peripheralID)
    }

    private func nativeBaseline() -> [CameraSettingsObservation] {
        let nativeBinding = ContinuousGimbalBinding(
            sessionID: "ble:\(sessionID.uuidString)", generation: 0)
        return [
            .init(property: .lensState, value: .focus(.continuous),
                  exposureMode: nil, transactionID: 1,
                  binding: nativeBinding, receivedUptime: 10),
            .init(property: .exposure, value: .autoEV(thirdStops: 0),
                  exposureMode: .automatic, transactionID: 2,
                  binding: nativeBinding, receivedUptime: 10)
        ]
    }

    @Test func requestContractRequiresExactPeerAndRestrictsPath() throws {
        let request = try BluetoothReadbackSessionDiagnosticRequest(
            cliArguments: ["--session", sessionID.uuidString,
                           "--peripheral", peripheralID.uuidString,
                           "--path", "settings"])
        #expect(request.path == .settings)
        #expect(request.arguments["expectedSessionID"] ==
                .string(sessionID.uuidString))
        #expect(BluetoothReadbackSessionDiagnosticRequest.schema[
            "additionalProperties"] == .bool(false))
        #expect(throws: BluetoothReadbackDiagnosticRequestError.invalidArguments) {
            try BluetoothReadbackSessionDiagnosticRequest(arguments: .object([
                "expectedSessionID": .string(sessionID.uuidString),
                "peripheralID": .string(peripheralID.uuidString),
                "path": .string("writer")
            ]))
        }
    }

    @Test func noRouteAndNoReplyStayDistinct() throws {
        var disconnected = readyStatus()
        disconnected = BluetoothDiscoveryStatus(
            phase: .disconnected, sessionID: sessionID, candidates: [],
            selectedPeripheralID: nil, issueCode: nil,
            identityVerification: "unverified_candidate",
            authentication: "not_performed",
            fff4NotificationEnabled: false, fff5NotificationEnabled: false,
            fff4Properties: nil, fff5Properties: nil, receivedFrames: 0,
            fragments: [:], recentHeaders: [])
        let noRoute = BluetoothReadbackSessionDiagnostic.make(
            request: try request(), bluetooth: disconnected,
            settingsQueries: [], pairedTapFocus: nil,
            nativeSession: nativeSession(), nativeTapFocus: nil)
        #expect(noRoute.outcome == .noRoute)
        #expect(noRoute.failureCode == "bluetooth_readback_no_route")
        #expect(noRoute.entries.first?.reason ==
                "paired_settings_route_unavailable")

        let noReply = BluetoothReadbackSessionDiagnostic.make(
            request: try request(), bluetooth: readyStatus(),
            settingsQueries: [], pairedTapFocus: nil,
            nativeSession: nativeSession(), nativeTapFocus: nil)
        #expect(noReply.routeAvailable)
        #expect(noReply.outcome == .noReply)
        #expect(noReply.entries.allSatisfy { $0.outcome == .noReply })
    }

    @Test func partialSettingsKeepsSuccessfulPropertyInAggregateSummary() throws {
        let report = BluetoothReadbackSessionDiagnostic.make(
            request: try request(), bluetooth: readyStatus(),
            settingsQueries: [try query()], pairedTapFocus: nil,
            nativeSession: nativeSession(), nativeTapFocus: nil)
        #expect(report.outcome == .noReply)
        #expect(report.summary?.total == CameraSettingsProperty.allCases.count)
        #expect(report.summary?.readback == 1)
        #expect(report.summary?.noReply == CameraSettingsProperty.allCases.count - 1)
        #expect(report.summary?.submitted == 1)
        #expect(report.summary?.complete == false)
    }

    @Test func wrongEnvelopeRetainsSequenceAndPropertyCorrelation() throws {
        let result = try query(wrongEnvelope: true, readback: false)
        let report = BluetoothReadbackSessionDiagnostic.make(
            request: try request(), bluetooth: readyStatus(),
            settingsQueries: [result], pairedTapFocus: nil,
            nativeSession: nativeSession(), nativeTapFocus: nil)
        let entry = try #require(report.entries.first {
            $0.key == CameraSettingsProperty.lensState.rawValue
        })
        #expect(entry.outcome == .wrongEnvelope)
        #expect(entry.requestSequence == 7)
        #expect(entry.responseSequence == nil)
        #expect(entry.reason == "rejected_notification_envelope")
    }

    @Test func matchingReadbackCarriesRequestAckAndNotificationSequences() throws {
        let result = try query()
        let report = BluetoothReadbackSessionDiagnostic.make(
            request: try request(), bluetooth: readyStatus(),
            settingsQueries: [result], pairedTapFocus: nil,
            nativeSession: nativeSession(), nativeTapFocus: nil)
        let entry = try #require(report.entries.first {
            $0.key == CameraSettingsProperty.lensState.rawValue
        })
        #expect(entry.outcome == .readback)
        #expect(entry.submitted && entry.responseReceived && entry.readbackObserved)
        #expect(entry.requestSequence == 7)
        #expect(entry.responseSequence == 7)
        #expect(entry.notificationSequence == 9)
        #expect(entry.transactionID == 77)
        #expect(entry.reason == "matching_property_readback")
    }

    @Test func nativeTapFocusUsesTheSameSessionAndGenerationClassification() async throws {
        let nativeRequest = try NativeTapFocusValidationRequest(
            expectedSessionID: sessionID, peripheralID: peripheralID,
            generation: 1, x: 0.3, y: 0.7)
        var coordinator = try NativeTapFocusValidationCoordinator(
            session: nativeReadySession())
        try coordinator.prepare(nativeRequest, observations: nativeBaseline(),
                                nowUptime: 11)
        while let next = coordinator.nextRequest {
            var transaction = NativeCommandTransactionResult(
                id: next.id, command: .focusMode, generation: 1,
                sessionID: sessionID, end: .observed)
            transaction.sequence = 7
            transaction.submitted = true
            transaction.responseReceived = true
            transaction.acknowledged = true
            transaction.observed = true
            transaction.finishedUptime = 11.2
            let applied = coordinator.apply(transaction, nowUptime: 11.2)
            #expect(applied)
        }
        let nativeResult = coordinator.result(
            coordinateCalibration: .init(orientation: .landscape, verified: true),
            executeRequested: true)
        let report = BluetoothReadbackSessionDiagnostic.make(
            request: try request(path: .nativeTapFocus),
            bluetooth: readyStatus(), settingsQueries: [],
            pairedTapFocus: nil, nativeSession: nativeReadySession(),
            nativeTapFocus: nativeResult)
        #expect(report.outcome == .readback)
        #expect(report.entries.count == 4)
        #expect(report.entries.allSatisfy {
            $0.path == .nativeTapFocus && $0.outcome == .readback &&
                $0.readbackObserved
        })
    }
}
