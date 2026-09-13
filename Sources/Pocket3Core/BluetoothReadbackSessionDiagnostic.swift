import Foundation

public enum BluetoothReadbackDiagnosticPath: String, Codable, Sendable,
    Equatable, CaseIterable {
    case settings
    case pairedTapFocus = "paired_tap_focus"
    case nativeTapFocus = "native_tap_focus"
    case all
}

public enum BluetoothReadbackDiagnosticOutcome: String, Codable, Sendable,
    Equatable, CaseIterable {
    case noRoute = "no_route"
    case noReply = "no_reply"
    case wrongEnvelope = "wrong_envelope"
    case readback
}

public struct BluetoothReadbackSessionDiagnosticRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-wireless-readback-diagnostic"

    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let path: BluetoothReadbackDiagnosticPath

    public init(expectedSessionID: UUID, peripheralID: UUID,
                path: BluetoothReadbackDiagnosticPath = .all) {
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.path = path
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                  "expectedSessionID", "peripheralID", "path"
              ]),
              let session = fields["expectedSessionID"]?.string
                  .flatMap(UUID.init(uuidString:)),
              let peer = fields["peripheralID"]?.string
                  .flatMap(UUID.init(uuidString:)) else {
            throw BluetoothReadbackDiagnosticRequestError.invalidArguments
        }
        let path: BluetoothReadbackDiagnosticPath
        if let value = fields["path"] {
            guard let raw = value.string,
                  let parsed = BluetoothReadbackDiagnosticPath(rawValue: raw) else {
                throw BluetoothReadbackDiagnosticRequestError.invalidArguments
            }
            path = parsed
        } else {
            path = .all
        }
        self.init(expectedSessionID: session, peripheralID: peer, path: path)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        while index < cliArguments.count {
            let option = cliArguments[index]
            guard index + 1 < cliArguments.count else {
                throw BluetoothReadbackDiagnosticRequestError.invalidArguments
            }
            guard ["--session", "--peripheral", "--path"].contains(option) else {
                throw BluetoothReadbackDiagnosticRequestError.invalidArguments
            }
            let key: String
            switch option {
            case "--session": key = "expectedSessionID"
            case "--peripheral": key = "peripheralID"
            default: key = "path"
            }
            guard fields[key] == nil else {
                throw BluetoothReadbackDiagnosticRequestError.invalidArguments
            }
            fields[key] = .string(cliArguments[index + 1])
            index += 2
        }
        try self.init(arguments: .object(fields))
    }

    public var arguments: JSONValue {
        .object([
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "path": .string(path.rawValue)
        ])
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "expectedSessionID": .object([
                "type": .string("string"), "minLength": .number(1)
            ]),
            "peripheralID": .object([
                "type": .string("string"), "minLength": .number(1)
            ]),
            "path": .object([
                "type": .string("string"),
                "enum": .array(BluetoothReadbackDiagnosticPath.allCases.map {
                    .string($0.rawValue)
                })
            ])
        ]),
        "required": .array([
            .string("expectedSessionID"), .string("peripheralID")
        ]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }
}

public enum BluetoothReadbackDiagnosticRequestError: Error, Codable,
    Sendable, Equatable {
    case invalidArguments
}

/// The route facts used by a readback diagnostic. This is a snapshot only;
/// constructing it never creates CoreBluetooth or sends a subscription.
public struct BluetoothReadbackRouteSnapshot: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let peripheralID: UUID?
    public let phase: BluetoothDiscoveryPhase
    public let paired: Bool
    public let fff4NotificationEnabled: Bool
    public let fff5NotificationEnabled: Bool
    public let registrationAcknowledged: Bool

    public init(status: BluetoothDiscoveryStatus) {
        sessionID = status.sessionID
        peripheralID = status.selectedPeripheralID
        phase = status.phase
        paired = status.pairing?.peerReportedPaired == true
        fff4NotificationEnabled = status.fff4NotificationEnabled
        fff5NotificationEnabled = status.fff5NotificationEnabled
        registrationAcknowledged = status.registrationAcknowledgmentSubmitted
    }

    public var available: Bool {
        peripheralID != nil && phase == .gattPaired && paired &&
            fff4NotificationEnabled && fff5NotificationEnabled &&
            registrationAcknowledged
    }
}

public struct BluetoothReadbackDiagnosticEntry: Codable, Sendable,
    Equatable, Identifiable {
    public let id: String
    public let path: BluetoothReadbackDiagnosticPath
    public let key: String
    public let sessionID: UUID?
    public let peripheralID: UUID?
    public let requestSequence: UInt16?
    public let responseSequence: UInt16?
    public let notificationSequence: UInt16?
    public let transactionID: UInt32?
    public let submitted: Bool
    public let responseReceived: Bool
    public let readbackObserved: Bool
    public let outcome: BluetoothReadbackDiagnosticOutcome
    public let reason: String

    public init(path: BluetoothReadbackDiagnosticPath, key: String,
                sessionID: UUID?, peripheralID: UUID?,
                requestSequence: UInt16? = nil,
                responseSequence: UInt16? = nil,
                notificationSequence: UInt16? = nil,
                transactionID: UInt32? = nil,
                submitted: Bool = false,
                responseReceived: Bool = false,
                readbackObserved: Bool = false,
                outcome: BluetoothReadbackDiagnosticOutcome,
                reason: String) {
        self.id = "\(path.rawValue):\(key)"
        self.path = path
        self.key = key
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.requestSequence = requestSequence
        self.responseSequence = responseSequence
        self.notificationSequence = notificationSequence
        self.transactionID = transactionID
        self.submitted = submitted
        self.responseReceived = responseReceived
        self.readbackObserved = readbackObserved
        self.outcome = outcome
        self.reason = reason
    }
}

/// Counts every per-property result without collapsing a partial read into a
/// false all-good report. The legacy `outcome` remains the conservative
/// aggregate gate; this summary makes successful properties visible when a
/// different property times out.
public struct BluetoothReadbackDiagnosticSummary: Codable, Sendable,
    Equatable {
    public let total: Int
    public let submitted: Int
    public let readback: Int
    public let noReply: Int
    public let wrongEnvelope: Int
    public let noRoute: Int

    init(entries: [BluetoothReadbackDiagnosticEntry]) {
        total = entries.count
        submitted = entries.count(where: { $0.submitted })
        readback = entries.count(where: { $0.outcome == .readback })
        noReply = entries.count(where: { $0.outcome == .noReply })
        wrongEnvelope = entries.count(where: { $0.outcome == .wrongEnvelope })
        noRoute = entries.count(where: { $0.outcome == .noRoute })
    }

    public var complete: Bool { total > 0 && readback == total }
}

public struct BluetoothReadbackSessionDiagnosticReport: Codable, Sendable,
    Equatable {
    public static let currentVersion = 1
    public let version: Int
    public let operation: String
    public let expectedSessionID: UUID
    public let expectedPeripheralID: UUID
    public let path: BluetoothReadbackDiagnosticPath
    public let routeAvailable: Bool
    public let nativeRouteAvailable: Bool
    public let entries: [BluetoothReadbackDiagnosticEntry]
    /// Optional for decoding reports written before Phase26 added counts.
    /// New reports always populate it.
    public let summary: BluetoothReadbackDiagnosticSummary?
    public let outcome: BluetoothReadbackDiagnosticOutcome
    public let failureCode: String?
    public let bounded: Bool
    public let hardwareAccessed: Bool

    public init(expectedSessionID: UUID, expectedPeripheralID: UUID,
                path: BluetoothReadbackDiagnosticPath,
                routeAvailable: Bool, nativeRouteAvailable: Bool,
                entries: [BluetoothReadbackDiagnosticEntry]) {
        self.version = Self.currentVersion
        operation = BluetoothReadbackSessionDiagnosticRequest.operation
        self.expectedSessionID = expectedSessionID
        self.expectedPeripheralID = expectedPeripheralID
        self.path = path
        self.routeAvailable = routeAvailable
        self.nativeRouteAvailable = nativeRouteAvailable
        self.entries = entries
        summary = BluetoothReadbackDiagnosticSummary(entries: entries)
        outcome = Self.aggregate(entries)
        failureCode = outcome == .readback ? nil :
            "bluetooth_readback_\(outcome.rawValue)"
        bounded = true
        hardwareAccessed = false
    }

    private static func aggregate(
        _ entries: [BluetoothReadbackDiagnosticEntry]
    ) -> BluetoothReadbackDiagnosticOutcome {
        guard !entries.isEmpty else { return .noRoute }
        if entries.contains(where: { $0.outcome == .noRoute }) {
            return .noRoute
        }
        if entries.contains(where: { $0.outcome == .wrongEnvelope }) {
            return .wrongEnvelope
        }
        if entries.contains(where: { $0.outcome == .noReply }) {
            return .noReply
        }
        return .readback
    }
}

public enum BluetoothReadbackSessionDiagnostic {
    public static func make(
        request: BluetoothReadbackSessionDiagnosticRequest,
        bluetooth: BluetoothDiscoveryStatus,
        settingsQueries: [BluetoothCameraPropertyQueryResult],
        pairedTapFocus: BluetoothTapFocusResult?,
        nativeSession: NativeCameraSessionStatus,
        nativeTapFocus: NativeTapFocusValidationResult?
    ) -> BluetoothReadbackSessionDiagnosticReport {
        let route = BluetoothReadbackRouteSnapshot(status: bluetooth)
        var entries: [BluetoothReadbackDiagnosticEntry] = []
        if request.path == .settings || request.path == .all {
            entries.append(contentsOf: settingsEntries(
                request: request, route: route, queries: settingsQueries))
        }
        if request.path == .pairedTapFocus || request.path == .all {
            entries.append(contentsOf: pairedTapFocusEntries(
                request: request, route: route, result: pairedTapFocus))
        }
        if request.path == .nativeTapFocus || request.path == .all {
            entries.append(contentsOf: nativeTapFocusEntries(
                request: request, session: nativeSession,
                result: nativeTapFocus))
        }
        return BluetoothReadbackSessionDiagnosticReport(
            expectedSessionID: request.expectedSessionID,
            expectedPeripheralID: request.peripheralID, path: request.path,
            routeAvailable: route.available,
            nativeRouteAvailable: nativeSession.commandReady,
            entries: entries)
    }

    private static func settingsEntries(
        request: BluetoothReadbackSessionDiagnosticRequest,
        route: BluetoothReadbackRouteSnapshot,
        queries: [BluetoothCameraPropertyQueryResult]
    ) -> [BluetoothReadbackDiagnosticEntry] {
        guard route.available,
              route.sessionID == request.expectedSessionID,
              route.peripheralID == request.peripheralID else {
            return [entry(path: .settings, key: "route", request: request,
                          outcome: .noRoute, reason: "paired_settings_route_unavailable")]
        }
        return BluetoothCameraSettingsReadPlan.orderedProperties.map { property in
            guard let query = queries.last(where: { $0.property == property }) else {
                return entry(path: .settings, key: property.rawValue,
                             request: request, outcome: .noReply,
                             reason: "no_query_result")
            }
            return settingsEntry(query: query, request: request)
        }
    }

    private static func settingsEntry(
        query: BluetoothCameraPropertyQueryResult,
        request: BluetoothReadbackSessionDiagnosticRequest
    ) -> BluetoothReadbackDiagnosticEntry {
        let sessionMatches = query.binding.sessionID ==
            "ble:\(request.expectedSessionID.uuidString)"
        let malformedProperty = query.propertyReceived && query.observed == nil
        let wrongEnvelope = (query.wrongEnvelopeCount ?? 0) > 0 ||
            (query.wrongPropertyCount ?? 0) > 0 ||
            (query.wrongSequenceCount ?? 0) > 0 ||
            (query.foreignSessionNotificationCount ?? 0) > 0 ||
            !sessionMatches || malformedProperty
        let readback = query.propertyReceived && query.observed != nil &&
            sessionMatches
        let outcome: BluetoothReadbackDiagnosticOutcome
        let reason: String
        if wrongEnvelope {
            outcome = .wrongEnvelope
            reason = !sessionMatches ? "query_session_mismatch" :
                malformedProperty ? "unparseable_property_notification" :
                "rejected_notification_envelope"
        } else if readback {
            outcome = .readback
            reason = "matching_property_readback"
        } else {
            outcome = .noReply
            reason = query.ackReceived ? "ack_without_property_readback" :
                "no_correlated_reply"
        }
        return BluetoothReadbackDiagnosticEntry(
            path: .settings, key: query.property.rawValue,
            sessionID: request.expectedSessionID,
            peripheralID: request.peripheralID,
            requestSequence: query.querySequence,
            responseSequence: query.ackHeader?.sequence,
            notificationSequence: query.propertyHeader?.sequence,
            transactionID: query.propertyTransactionID ??
                query.subscriptionTransactionID,
            submitted: query.localSubmitted,
            responseReceived: query.ackReceived,
            readbackObserved: readback, outcome: outcome, reason: reason)
    }

    private static func pairedTapFocusEntries(
        request: BluetoothReadbackSessionDiagnosticRequest,
        route: BluetoothReadbackRouteSnapshot,
        result: BluetoothTapFocusResult?
    ) -> [BluetoothReadbackDiagnosticEntry] {
        guard route.available,
              route.sessionID == request.expectedSessionID,
              route.peripheralID == request.peripheralID else {
            return [entry(path: .pairedTapFocus, key: "route", request: request,
                          outcome: .noRoute, reason: "paired_tap_focus_route_unavailable")]
        }
        guard let result else {
            return [entry(path: .pairedTapFocus, key: "sequence",
                          request: request, outcome: .noReply,
                          reason: "no_tap_focus_result")]
        }
        var entries = result.steps.map { step in
            let sessionMatches = result.request.expectedSessionID ==
                request.expectedSessionID && result.request.peripheralID ==
                request.peripheralID
            let wrongEnvelope = !sessionMatches ||
                (result.wrongEnvelopeCount ?? 0) > 0 ||
                (result.wrongSequenceCount ?? 0) > 0 ||
                (result.foreignSessionNotificationCount ?? 0) > 0
            let readback = step.acknowledged &&
                step.ackHeader?.sequence == step.sequence && sessionMatches
            let outcome: BluetoothReadbackDiagnosticOutcome = wrongEnvelope
                ? .wrongEnvelope : readback ? .readback : .noReply
            let reason = wrongEnvelope ? "rejected_tap_focus_envelope" :
                readback ? "matching_step_ack" :
                step.locallySubmitted ? "no_correlated_step_reply" :
                "step_not_submitted"
            return BluetoothReadbackDiagnosticEntry(
                path: .pairedTapFocus, key: step.step.rawValue,
                sessionID: request.expectedSessionID,
                peripheralID: request.peripheralID,
                requestSequence: step.sequence,
                responseSequence: step.ackHeader?.sequence,
                submitted: step.locallySubmitted,
                responseReceived: step.ackHeader != nil,
                readbackObserved: readback, outcome: outcome, reason: reason)
        }
        entries.append(contentsOf: result.lensPoints.map { point in
            let matches = point.sessionID == request.expectedSessionID &&
                point.peripheralID == request.peripheralID
            return BluetoothReadbackDiagnosticEntry(
                path: .pairedTapFocus, key: "lens_state",
                sessionID: point.sessionID, peripheralID: point.peripheralID,
                notificationSequence: point.sequence,
                transactionID: point.propertyTransactionID,
                submitted: true, responseReceived: true,
                readbackObserved: matches,
                outcome: matches ? .readback : .wrongEnvelope,
                reason: matches ? "matching_lens_readback" :
                    "lens_readback_session_mismatch")
        })
        return entries
    }

    private static func nativeTapFocusEntries(
        request: BluetoothReadbackSessionDiagnosticRequest,
        session: NativeCameraSessionStatus,
        result: NativeTapFocusValidationResult?
    ) -> [BluetoothReadbackDiagnosticEntry] {
        guard session.commandReady,
              session.sessionID == request.expectedSessionID,
              session.peerID == request.peripheralID else {
            return [entry(path: .nativeTapFocus, key: "route", request: request,
                          outcome: .noRoute, reason: "native_tap_focus_route_unavailable")]
        }
        guard let result else {
            return [entry(path: .nativeTapFocus, key: "sequence",
                          request: request, outcome: .noReply,
                          reason: "no_native_tap_focus_result")]
        }
        return result.steps.map { step in
            let transaction = step.transaction
            let identityMatches = step.request.sessionID ==
                request.expectedSessionID &&
                step.request.generation == session.generation
            let transactionIdentityMismatch: Bool
            if let transaction {
                transactionIdentityMismatch =
                    transaction.sessionID != request.expectedSessionID ||
                    transaction.generation != session.generation
            } else {
                transactionIdentityMismatch = false
            }
            let wrongEnvelope = !identityMatches || transactionIdentityMismatch
            let readback = !wrongEnvelope && step.observed &&
                step.acknowledged
            let outcome: BluetoothReadbackDiagnosticOutcome = wrongEnvelope
                ? .wrongEnvelope : readback ? .readback : .noReply
            let reason = wrongEnvelope ? "native_session_or_generation_mismatch" :
                readback ? "native_step_ack_and_readback" :
                step.acknowledged ? "native_ack_without_readback" :
                "native_step_no_reply"
            return BluetoothReadbackDiagnosticEntry(
                path: .nativeTapFocus, key: step.step.rawValue,
                sessionID: request.expectedSessionID,
                peripheralID: request.peripheralID,
                requestSequence: transaction?.sequence,
                responseSequence: transaction?.sequence,
                transactionID: nil,
                submitted: step.submitted,
                responseReceived: transaction?.responseReceived == true,
                readbackObserved: step.observed, outcome: outcome, reason: reason)
        }
    }

    private static func entry(
        path: BluetoothReadbackDiagnosticPath,
        key: String,
        request: BluetoothReadbackSessionDiagnosticRequest,
        outcome: BluetoothReadbackDiagnosticOutcome,
        reason: String
    ) -> BluetoothReadbackDiagnosticEntry {
        BluetoothReadbackDiagnosticEntry(
            path: path, key: key, sessionID: request.expectedSessionID,
            peripheralID: request.peripheralID, outcome: outcome, reason: reason)
    }
}

public typealias Pocket3BluetoothReadbackSessionDiagnostic = BluetoothReadbackSessionDiagnostic
public typealias Pocket3BluetoothReadbackSessionDiagnosticReport = BluetoothReadbackSessionDiagnosticReport
