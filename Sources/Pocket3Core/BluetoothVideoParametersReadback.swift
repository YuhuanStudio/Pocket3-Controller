import Foundation

/// The first property-specific BLE readback route.  The pinned Kaze source
/// proves this property on the 00/99 named-property bus, while the local
/// Pocket 3 captures prove the same 9-byte field layout.  Keeping this route
/// separate lets the developer validate the known property without making an
/// opaque capability subscription block all later reads.
public struct BluetoothVideoParametersReadbackRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-wireless-video-parameters-readback"

    public let expectedSessionID: UUID
    public let peripheralID: UUID

    public init(expectedSessionID: UUID, peripheralID: UUID) {
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys) == ["expectedSessionID", "peripheralID"],
              let session = fields["expectedSessionID"]?.string
                  .flatMap(UUID.init(uuidString:)),
              let peer = fields["peripheralID"]?.string
                  .flatMap(UUID.init(uuidString:)) else {
            throw BluetoothVideoParametersReadbackRequestError.invalidArguments
        }
        self.init(expectedSessionID: session, peripheralID: peer)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        while index < cliArguments.count {
            guard index + 1 < cliArguments.count,
                  ["--session", "--peripheral"].contains(cliArguments[index]) else {
                throw BluetoothVideoParametersReadbackRequestError.invalidArguments
            }
            let key = cliArguments[index] == "--session"
                ? "expectedSessionID" : "peripheralID"
            guard fields[key] == nil else {
                throw BluetoothVideoParametersReadbackRequestError.invalidArguments
            }
            fields[key] = .string(cliArguments[index + 1])
            index += 2
        }
        try self.init(arguments: .object(fields))
    }

    public var arguments: JSONValue {
        .object([
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString)
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

public enum BluetoothVideoParametersReadbackRequestError: Error, Codable,
    Sendable, Equatable {
    case invalidArguments
}

public enum BluetoothVideoParametersReadbackSource: String, Codable, Sendable,
    Equatable {
    /// The operation 0x06 named-property notification, not an ACK body.
    case namedPropertyNotification = "00/99/06_notification"
}

public enum BluetoothVideoParametersReadbackTerminalStep: String, Codable,
    Sendable, Equatable {
    case complete
    /// The bounded reader stopped after its notification window.  It never
    /// invents a 00/01 GET because that command is only documented for the
    /// separate 02/8E keyed-parameter store.
    case stopWithoutGet = "stop_without_get"
}

/// A developer-only report for one Kaze-backed named property.  All bytes in
/// `rawValue` are the bounded value prefix from the notification, including
/// unknown enum and reserved bytes.  The report contains no setter payload or
/// follow-up GET request.
public struct BluetoothVideoParametersReadbackReport: Codable, Sendable,
    Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let operation: String
    public let property: CameraSettingsProperty
    public let expectedSessionID: UUID
    public let expectedPeripheralID: UUID
    public let querySequence: UInt16
    public let subscriptionTransactionID: UInt32
    public let submitted: Bool
    public let acknowledgmentReceived: Bool
    public let acknowledgmentSequence: UInt16?
    public let notificationReceived: Bool
    public let notificationSequence: UInt16?
    public let notificationTransactionID: UInt32?
    public let rawValue: Data?
    public let rawValueLength: Int?
    public let rawValueTruncated: Bool
    public let typedValue: CameraVideoParameters?
    public let readbackSource: BluetoothVideoParametersReadbackSource?
    public let terminalStep: BluetoothVideoParametersReadbackTerminalStep
    public let followUpGetIssued: Bool
    public let outcome: BluetoothReadbackDiagnosticOutcome
    public let reason: String
    public let evidence: String

    public init(request: BluetoothVideoParametersReadbackRequest,
                query: BluetoothCameraPropertyQueryResult) {
        version = Self.currentVersion
        operation = BluetoothVideoParametersReadbackRequest.operation
        property = .videoParameters
        expectedSessionID = request.expectedSessionID
        expectedPeripheralID = request.peripheralID
        querySequence = query.querySequence
        subscriptionTransactionID = query.subscriptionTransactionID
        submitted = query.localSubmitted
        acknowledgmentReceived = query.ackReceived
        acknowledgmentSequence = query.ackHeader?.sequence
        notificationReceived = query.propertyReceived
        notificationSequence = query.propertyHeader?.sequence
        notificationTransactionID = query.propertyTransactionID
        rawValue = query.valueRaw
        rawValueLength = query.valueLength
        rawValueTruncated = query.valueTruncated
        if case .videoParameters(let value) = query.observed?.readOnlyValue {
            typedValue = value
        } else {
            typedValue = nil
        }
        readbackSource = query.propertyReceived
            ? .namedPropertyNotification : nil
        terminalStep = typedValue != nil
            ? .complete : .stopWithoutGet
        followUpGetIssued = false

        let sessionMatches = query.binding.sessionID ==
            "ble:\(request.expectedSessionID.uuidString)"
        let rejectedEnvelope = (query.wrongEnvelopeCount ?? 0) > 0 ||
            (query.wrongPropertyCount ?? 0) > 0 ||
            (query.wrongSequenceCount ?? 0) > 0 ||
            (query.foreignSessionNotificationCount ?? 0) > 0 ||
            !sessionMatches
        if rejectedEnvelope {
            outcome = .wrongEnvelope
            reason = !sessionMatches ? "query_session_mismatch" :
                "rejected_named_property_notification"
        } else if query.propertyReceived, typedValue != nil {
            outcome = .readback
            reason = "matching_named_property_notification"
        } else if query.propertyReceived {
            outcome = .wrongEnvelope
            reason = "named_property_value_short_or_unparseable"
        } else {
            outcome = .noReply
            reason = query.ackReceived
                ? "ack_without_named_property_notification"
                : "no_named_property_notification"
        }
        evidence = "Kaze@341a35de18493ff61f97c93b8b10161a7512aa36 " +
            "00/99 subscription then 00/99/06 notification; " +
            "00/01 GET is only documented for 02/8E keyed parameters"
    }
}

/// Pure adapter around the existing one-submission query.  It deliberately
/// exposes no `get` or setter operation: callers submit the existing 00/99
/// subscription once, then feed the exact-session BLE notifications to the
/// query and build a report after its bounded window.
public enum BluetoothVideoParametersReadbackProbe {
    public static let property = CameraSettingsProperty.videoParameters

    public static func report(
        request: BluetoothVideoParametersReadbackRequest,
        query: BluetoothCameraPropertyQueryResult
    ) -> BluetoothVideoParametersReadbackReport {
        BluetoothVideoParametersReadbackReport(request: request, query: query)
    }
}
