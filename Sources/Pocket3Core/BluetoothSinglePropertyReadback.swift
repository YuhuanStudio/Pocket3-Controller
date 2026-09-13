import Foundation

/// The two read-only named properties needed for AF/exposure investigation.
/// Keeping the allowlist closed prevents this probe from becoming a second
/// arbitrary property reader or a place to guess undocumented GET commands.
public enum BluetoothSinglePropertyReadbackProperty: String, Codable, Sendable,
    Equatable, CaseIterable {
    case lensState = "cam_lens_state"
    case exposure = "cam_expo_param"

    public var cameraProperty: CameraSettingsProperty {
        switch self {
        case .lensState: .lensState
        case .exposure: .exposure
        }
    }

    public init?(cameraProperty: CameraSettingsProperty) {
        switch cameraProperty {
        case .lensState: self = .lensState
        case .exposure: self = .exposure
        default: return nil
        }
    }
}

/// Developer-only request for one bounded 00/99 named-property subscription.
/// The caller must bind both the BLE session and the selected peer.  There is
/// deliberately no command field for a setter or a follow-up GET.
public struct BluetoothSinglePropertyReadbackRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-wireless-single-property-readback"

    public let property: BluetoothSinglePropertyReadbackProperty
    public let expectedSessionID: UUID
    public let peripheralID: UUID

    public init(property: BluetoothSinglePropertyReadbackProperty,
                expectedSessionID: UUID, peripheralID: UUID) {
        self.property = property
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys) == ["property", "expectedSessionID", "peripheralID"],
              let propertyRaw = fields["property"]?.string,
              let property = BluetoothSinglePropertyReadbackProperty(rawValue: propertyRaw),
              let session = fields["expectedSessionID"]?.string
                  .flatMap(UUID.init(uuidString:)),
              let peer = fields["peripheralID"]?.string
                  .flatMap(UUID.init(uuidString:)) else {
            throw BluetoothSinglePropertyReadbackRequestError.invalidArguments
        }
        self.init(property: property, expectedSessionID: session,
                  peripheralID: peer)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        while index < cliArguments.count {
            guard index + 1 < cliArguments.count else {
                throw BluetoothSinglePropertyReadbackRequestError.invalidArguments
            }
            let option = cliArguments[index]
            let key: String
            switch option {
            case "--property": key = "property"
            case "--session": key = "expectedSessionID"
            case "--peripheral": key = "peripheralID"
            default:
                throw BluetoothSinglePropertyReadbackRequestError.invalidArguments
            }
            guard fields[key] == nil else {
                throw BluetoothSinglePropertyReadbackRequestError.invalidArguments
            }
            fields[key] = .string(cliArguments[index + 1])
            index += 2
        }
        try self.init(arguments: .object(fields))
    }

    public var arguments: JSONValue {
        .object([
            "property": .string(property.rawValue),
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString)
        ])
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "property": .object([
                "type": .string("string"),
                "enum": .array(BluetoothSinglePropertyReadbackProperty.allCases.map {
                    .string($0.rawValue)
                })
            ]),
            "expectedSessionID": .object([
                "type": .string("string"), "minLength": .number(1)
            ]),
            "peripheralID": .object([
                "type": .string("string"), "minLength": .number(1)
            ])
        ]),
        "required": .array([
            .string("property"), .string("expectedSessionID"),
            .string("peripheralID")
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

public enum BluetoothSinglePropertyReadbackRequestError: Error, Codable,
    Sendable, Equatable {
    case invalidArguments
}

public enum BluetoothSinglePropertyReadbackSource: String, Codable, Sendable,
    Equatable {
    /// The state notification on the 00/99 named-property bus, rather than an
    /// ACK body or an inferred response to an undocumented GET.
    case namedPropertyNotification = "00/99/06_notification"
}

public enum BluetoothSinglePropertyReadbackTerminalStep: String, Codable,
    Sendable, Equatable {
    case complete
    case stopWithoutGet = "stop_without_get"
}

/// Result for one exact-session, one-property probe.  `rawValue` is the
/// complete bounded value when it fits the reader limit, otherwise it is the
/// retained prefix and `rawValueTruncated` stays true.  `typedValue` is the
/// property-specific read-only schema; its associated value also retains the
/// raw bytes and unknown enum codes.
public struct BluetoothSinglePropertyReadbackReport: Codable, Sendable,
    Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let operation: String
    public let property: CameraSettingsProperty
    public let propertyName: String
    public let expectedSessionID: UUID
    public let expectedPeripheralID: UUID
    public let observedBinding: ContinuousGimbalBinding
    public let querySequence: UInt16
    public let subscriptionTransactionID: UInt32
    public let submitted: Bool
    public let subscriptionCount: Int
    public let acknowledgmentReceived: Bool
    public let acknowledgmentSequence: UInt16?
    public let notificationReceived: Bool
    public let notificationSequence: UInt16?
    public let notificationTransactionID: UInt32?
    public let rawValue: Data?
    public let rawValueLength: Int?
    public let rawValueTruncated: Bool
    public let typedValue: CameraReadOnlyValue?
    public let settingValue: CameraSettingValue?
    public let readbackSource: BluetoothSinglePropertyReadbackSource?
    public let terminalStep: BluetoothSinglePropertyReadbackTerminalStep
    public let setterIssued: Bool
    public let followUpGetIssued: Bool
    public let outcome: BluetoothReadbackDiagnosticOutcome
    public let reason: String
    public let evidence: String

    public init(request: BluetoothSinglePropertyReadbackRequest,
                query: BluetoothCameraPropertyQueryResult) {
        version = Self.currentVersion
        operation = BluetoothSinglePropertyReadbackRequest.operation
        property = request.property.cameraProperty
        propertyName = request.property.rawValue
        expectedSessionID = request.expectedSessionID
        expectedPeripheralID = request.peripheralID
        observedBinding = query.binding
        querySequence = query.querySequence
        subscriptionTransactionID = query.subscriptionTransactionID
        submitted = query.localSubmitted
        subscriptionCount = query.localSubmitted ? 1 : 0
        acknowledgmentReceived = query.ackReceived
        acknowledgmentSequence = query.ackHeader?.sequence
        notificationReceived = query.propertyReceived
        notificationSequence = query.propertyHeader?.sequence
        notificationTransactionID = query.propertyTransactionID
        rawValue = query.valueRaw
        rawValueLength = query.valueLength
        rawValueTruncated = query.valueTruncated
        typedValue = query.observed?.readOnlyValue
        settingValue = query.observed?.value
        readbackSource = query.propertyReceived
            ? .namedPropertyNotification : nil
        terminalStep = typedValue != nil ? .complete : .stopWithoutGet
        setterIssued = false
        followUpGetIssued = false

        let sessionMatches = query.binding.sessionID ==
            "ble:\(request.expectedSessionID.uuidString)"
        let propertyMatches = query.property == request.property.cameraProperty
        let rejectedEnvelope = (query.wrongEnvelopeCount ?? 0) > 0 ||
            (query.wrongPropertyCount ?? 0) > 0 ||
            (query.wrongSequenceCount ?? 0) > 0 ||
            (query.foreignSessionNotificationCount ?? 0) > 0 ||
            !sessionMatches || !propertyMatches
        if rejectedEnvelope {
            outcome = .wrongEnvelope
            if !sessionMatches {
                reason = "query_session_mismatch"
            } else if !propertyMatches {
                reason = "query_property_mismatch"
            } else {
                reason = "rejected_named_property_notification"
            }
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
            "one 00/99 subscription and local Pocket 3 " + request.property.rawValue +
            " schema; same BLE session/peer; 00/99/06 notification only; " +
            "no setter or follow-up GET"
    }
}

/// Pure adapter around `BluetoothCameraPropertyQuery`.  The transport owns
/// the single subscription and feeds only exact-session notifications here.
public enum BluetoothSinglePropertyReadbackProbe {
    public static let properties =
        BluetoothSinglePropertyReadbackProperty.allCases

    public static func report(
        request: BluetoothSinglePropertyReadbackRequest,
        query: BluetoothCameraPropertyQueryResult
    ) -> BluetoothSinglePropertyReadbackReport {
        BluetoothSinglePropertyReadbackReport(request: request, query: query)
    }
}
