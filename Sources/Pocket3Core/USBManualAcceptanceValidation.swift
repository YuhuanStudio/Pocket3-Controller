import Foundation

/// Developer-only IPC/CLI request for the bounded manual USB acceptance
/// collector. Dry-run is the default; an executing request must carry the
/// exact current device and capture session observed by the caller.
public struct USBManualAcceptanceRequest: Codable, Sendable, Equatable {
    public static let operation = "validation-usb-manual-acceptance"
    public static let defaultHoldSeconds: TimeInterval = 0.6
    public static let maximumHoldSeconds: TimeInterval = 1.2
    public static let maximumTimeout: TimeInterval = 45

    public let expectedDeviceID: String?
    public let expectedSessionID: String?
    public let holdSeconds: TimeInterval
    public let timeout: TimeInterval
    public let execute: Bool

    public init(expectedDeviceID: String? = nil,
                expectedSessionID: String? = nil,
                holdSeconds: TimeInterval = Self.defaultHoldSeconds,
                timeout: TimeInterval = Self.maximumTimeout,
                execute: Bool = false) throws {
        guard holdSeconds.isFinite, holdSeconds > 0,
              holdSeconds <= Self.maximumHoldSeconds,
              timeout.isFinite, timeout > 0, timeout <= Self.maximumTimeout
        else { throw USBManualAcceptanceRequestError.invalidArguments }
        if execute {
            guard let expectedDeviceID, !expectedDeviceID.isEmpty,
                  let expectedSessionID, !expectedSessionID.isEmpty else {
                throw USBManualAcceptanceRequestError.identityRequired
            }
        }
        self.expectedDeviceID = expectedDeviceID
        self.expectedSessionID = expectedSessionID
        self.holdSeconds = holdSeconds
        self.timeout = timeout
        self.execute = execute
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                  "device", "session", "holdSeconds", "timeout", "execute"
              ]) else {
            throw USBManualAcceptanceRequestError.invalidArguments
        }
        let device = try Self.string(fields["device"])
        let session = try Self.string(fields["session"])
        let hold = try Self.number(fields["holdSeconds"], default: Self.defaultHoldSeconds)
        let timeout = try Self.number(fields["timeout"], default: Self.maximumTimeout)
        let execute = try Self.boolean(fields["execute"])
        try self.init(expectedDeviceID: device, expectedSessionID: session,
                      holdSeconds: hold, timeout: timeout, execute: execute)
    }

    public init(cliArguments: [String]) throws {
        var device: String?
        var session: String?
        var hold = Self.defaultHoldSeconds
        var timeout = Self.maximumTimeout
        var execute = false
        var index = 0
        while index < cliArguments.count {
            let argument = cliArguments[index]
            if argument == "--execute" {
                guard !execute else { throw USBManualAcceptanceRequestError.invalidArguments }
                execute = true; index += 1; continue
            }
            guard index + 1 < cliArguments.count else {
                throw USBManualAcceptanceRequestError.invalidArguments
            }
            let value = cliArguments[index + 1]
            switch argument {
            case "--device": guard device == nil else { throw USBManualAcceptanceRequestError.invalidArguments }; device = value
            case "--session": guard session == nil else { throw USBManualAcceptanceRequestError.invalidArguments }; session = value
            case "--hold-seconds":
                guard let parsed = Double(value), parsed.isFinite else { throw USBManualAcceptanceRequestError.invalidArguments }
                hold = parsed
            case "--timeout":
                guard let parsed = Double(value), parsed.isFinite else { throw USBManualAcceptanceRequestError.invalidArguments }
                timeout = parsed
            default: throw USBManualAcceptanceRequestError.invalidArguments
            }
            index += 2
        }
        try self.init(expectedDeviceID: device, expectedSessionID: session,
                      holdSeconds: hold, timeout: timeout, execute: execute)
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "holdSeconds": .number(holdSeconds),
            "timeout": .number(timeout),
            "execute": .bool(execute)
        ]
        if let expectedDeviceID { fields["device"] = .string(expectedDeviceID) }
        if let expectedSessionID { fields["session"] = .string(expectedSessionID) }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "device": .object(["type": .string("string"), "minLength": .number(1)]),
            "session": .object(["type": .string("string"), "minLength": .number(1)]),
            "holdSeconds": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(maximumHoldSeconds)]),
            "timeout": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(maximumTimeout)]),
            "execute": .object(["type": .string("boolean")])
        ]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }

    private static func string(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        guard let result = value.string, !result.isEmpty else {
            throw USBManualAcceptanceRequestError.invalidArguments
        }
        return result
    }

    private static func number(_ value: JSONValue?, default fallback: Double) throws -> Double {
        guard let value else { return fallback }
        guard let result = value.number, result.isFinite else {
            throw USBManualAcceptanceRequestError.invalidArguments
        }
        return result
    }

    private static func boolean(_ value: JSONValue?) throws -> Bool {
        guard let value else { return false }
        guard let result = value.bool else {
            throw USBManualAcceptanceRequestError.invalidArguments
        }
        return result
    }
}

public enum USBManualAcceptanceRequestError: Error, Codable, Sendable,
    Equatable {
    case invalidArguments
    case identityRequired
}

public typealias Pocket3USBManualAcceptanceRequest = USBManualAcceptanceRequest
