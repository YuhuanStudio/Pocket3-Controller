import Foundation

/// The only Phase29 write candidate: a reversible S-AF/C-AF mode change.
/// This is a dry-run contract, not a writer. Kaze and OpenPocketCine provide
/// the command shape, while the local audit records no BLE-only successful
/// Camera01 writer, so execution remains explicitly unsupported.
public enum BluetoothReversibleSettingCandidate: String, Codable, Sendable,
    Equatable, CaseIterable {
    case focusMode = "focus_mode"

    public var property: CameraSettingsProperty { .lensState }
    public var commandSet: UInt8 { 0x02 }
    public var commandID: UInt8 { 0x24 }
    public var route: String {
        "FFF5 withoutResponse source02->destination01 flags40"
    }
}

public enum BluetoothReversibleSettingCandidateOutcome: String, Codable,
    Sendable, Equatable {
    /// The exact command is admitted for future validation, but no write is
    /// exposed by this route.
    case candidate
    case noOp = "no_op"
    case unsupported
    case invalidBaseline = "invalid_baseline"
}

/// Developer-only input for the pure candidate gate. `execute` is accepted so
/// a caller gets an explicit unsupported report instead of accidentally
/// falling through to the existing hardware writer.
public struct BluetoothReversibleSettingCandidateRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-wireless-setting-candidate"

    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let expectedCaptureSessionID: String
    public let target: CameraFocusMode
    public let sequence: UInt16
    public let nowUptime: TimeInterval
    public let baseline: CameraSettingsObservation
    public let execute: Bool

    public init(expectedSessionID: UUID, peripheralID: UUID,
                expectedCaptureSessionID: String, target: CameraFocusMode,
                sequence: UInt16, nowUptime: TimeInterval,
                baseline: CameraSettingsObservation,
                execute: Bool = false) throws {
        guard UUID(uuidString: expectedCaptureSessionID) != nil,
              nowUptime.isFinite, nowUptime >= 0 else {
            throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
        }
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.expectedCaptureSessionID = expectedCaptureSessionID
        self.target = target
        self.sequence = sequence
        self.nowUptime = nowUptime
        self.baseline = baseline
        self.execute = execute
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                  "expectedSessionID", "peripheralID", "expectedCaptureSessionID",
                  "target", "sequence", "nowUptime", "baseline", "execute"
              ]),
              let session = fields["expectedSessionID"]?.string
                  .flatMap(UUID.init(uuidString:)),
              let peer = fields["peripheralID"]?.string
                  .flatMap(UUID.init(uuidString:)),
              let capture = fields["expectedCaptureSessionID"]?.string,
              let targetRaw = fields["target"]?.string,
              let target = Self.focusMode(targetRaw),
              let sequenceNumber = fields["sequence"]?.number,
              sequenceNumber.isFinite, sequenceNumber.rounded() == sequenceNumber,
              (0...Double(UInt16.max)).contains(sequenceNumber),
              let now = fields["nowUptime"]?.number,
              let baselineValue = fields["baseline"],
              let baseline = try? baselineValue.decode(CameraSettingsObservation.self) else {
            throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
        }
        guard fields["execute"] == nil || fields["execute"]?.bool != nil else {
            throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
        }
        try self.init(expectedSessionID: session, peripheralID: peer,
                      expectedCaptureSessionID: capture, target: target,
                      sequence: UInt16(sequenceNumber), nowUptime: now,
                      baseline: baseline, execute: fields["execute"]?.bool ?? false)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        while index < cliArguments.count {
            let option = cliArguments[index]
            if option == "--execute" {
                guard fields["execute"] == nil else {
                    throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
                }
                fields["execute"] = .bool(true)
                index += 1
                continue
            }
            guard index + 1 < cliArguments.count else {
                throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
            }
            let key: String
            switch option {
            case "--session": key = "expectedSessionID"
            case "--peripheral": key = "peripheralID"
            case "--capture-session": key = "expectedCaptureSessionID"
            case "--target": key = "target"
            case "--sequence": key = "sequence"
            case "--now": key = "nowUptime"
            case "--baseline-json": key = "baseline"
            default:
                throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
            }
            guard fields[key] == nil else {
                throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
            }
            let value = cliArguments[index + 1]
            guard value.utf8.count <= 8192 else {
                throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
            }
            if key == "sequence" {
                guard let number = Double(value), number.isFinite,
                      number.rounded() == number else {
                    throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
                }
                fields[key] = .number(number)
            } else if key == "nowUptime" {
                guard let number = Double(value), number.isFinite else {
                    throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
                }
                fields[key] = .number(number)
            } else if key == "baseline" {
                guard let data = value.data(using: .utf8),
                      let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                    throw BluetoothReversibleSettingCandidateRequestError.invalidArguments
                }
                fields[key] = json
            } else {
                fields[key] = .string(value)
            }
            index += 2
        }
        try self.init(arguments: .object(fields))
    }

    public var arguments: JSONValue {
        .object([
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "expectedCaptureSessionID": .string(expectedCaptureSessionID),
            "target": .string(Self.targetName(target)),
            "sequence": .number(Double(sequence)),
            "nowUptime": .number(nowUptime),
            "baseline": (try? .encode(baseline)) ?? .null,
            "execute": .bool(execute)
        ])
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "expectedSessionID": .object(["type": .string("string"), "minLength": .number(1)]),
            "peripheralID": .object(["type": .string("string"), "minLength": .number(1)]),
            "expectedCaptureSessionID": .object(["type": .string("string"), "minLength": .number(1)]),
            "target": .object(["type": .string("string"), "enum": .array([.string("single"), .string("continuous")])]),
            "sequence": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(Double(UInt16.max))]),
            "nowUptime": .object(["type": .string("number"), "minimum": .number(0)]),
            "baseline": .object(["type": .string("object")]),
            "execute": .object(["type": .string("boolean")])
        ]),
        "required": .array([
            .string("expectedSessionID"), .string("peripheralID"),
            .string("expectedCaptureSessionID"), .string("target"),
            .string("sequence"), .string("nowUptime"), .string("baseline")
        ]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }

    private static func focusMode(_ raw: String) -> CameraFocusMode? {
        switch raw.lowercased() {
        case "single", "s-af", "af-s": .single
        case "continuous", "c-af", "af-c": .continuous
        default: nil
        }
    }

    private static func targetName(_ mode: CameraFocusMode) -> String {
        mode == .single ? "single" : "continuous"
    }
}

public enum BluetoothReversibleSettingCandidateRequestError: Error, Codable,
    Sendable, Equatable {
    case invalidArguments
}

public struct BluetoothReversibleSettingCandidateReport: Codable, Sendable,
    Equatable {
    public static let currentVersion = 1
    public let version: Int
    public let operation: String
    public let candidate: BluetoothReversibleSettingCandidate
    public let property: CameraSettingsProperty
    public let expectedSessionID: UUID
    public let expectedPeripheralID: UUID
    public let expectedCaptureSessionID: String
    public let sequence: UInt16
    public let target: CameraFocusMode
    public let baselineMode: CameraFocusMode?
    public let restoreTarget: CameraFocusMode?
    public let baselineRaw: Data?
    public let baselineRawLength: Int?
    public let commandSet: UInt8
    public let commandID: UInt8
    public let commandFlags: UInt8
    public let commandPayload: Data
    public let commandPayloadHex: String
    public let restorePayload: Data?
    public let restorePayloadHex: String?
    public let route: String
    public let admissionGranted: Bool
    public let dryRun: Bool
    public let hardwareAccessed: Bool
    public let executeRequested: Bool
    public let executeAllowed: Bool
    public let setterIssued: Bool
    public let restoreIssued: Bool
    public let followUpGetIssued: Bool
    public let outcome: BluetoothReversibleSettingCandidateOutcome
    public let reason: String
    public let nextCaptureFlow: [String]
    public let evidence: String

    public init(request: BluetoothReversibleSettingCandidateRequest) {
        version = Self.currentVersion
        operation = BluetoothReversibleSettingCandidateRequest.operation
        candidate = .focusMode
        property = candidate.property
        expectedSessionID = request.expectedSessionID
        expectedPeripheralID = request.peripheralID
        expectedCaptureSessionID = request.expectedCaptureSessionID
        sequence = request.sequence
        target = request.target

        let expectedBinding = ContinuousGimbalBinding(
            sessionID: "ble:\(request.expectedSessionID.uuidString)", generation: 0)
        let baselineMode = Self.baselineMode(request.baseline)
        self.baselineMode = baselineMode
        restoreTarget = baselineMode
        baselineRaw = request.baseline.readOnlyValue?.raw
        baselineRawLength = baselineRaw?.count
        commandSet = candidate.commandSet
        commandID = candidate.commandID
        commandFlags = 0x40
        commandPayload = Data([request.target.rawValue])
        commandPayloadHex = commandPayload.map { String(format: "%02x", $0) }.joined()
        restorePayload = baselineMode.map { Data([$0.rawValue]) }
        restorePayloadHex = restorePayload?.map {
            String(format: "%02x", $0)
        }.joined()
        route = candidate.route
        executeRequested = request.execute
        dryRun = true
        hardwareAccessed = false
        executeAllowed = false
        setterIssued = false
        restoreIssued = false
        followUpGetIssued = false

        let baselineValueMatches = baselineMode.map {
            request.baseline.value == .focus($0)
        } ?? false
        let baselineValid = request.baseline.binding == expectedBinding &&
            request.baseline.property == .lensState &&
            request.baseline.receivedUptime.isFinite &&
            request.baseline.receivedUptime >= 0 &&
            request.baseline.isFresh(now: request.nowUptime) &&
            baselineMode != nil && baselineValueMatches
        admissionGranted = baselineValid
        if !baselineValid {
            outcome = .invalidBaseline
            reason = Self.baselineFailure(request: request,
                                          expectedBinding: expectedBinding,
                                          baselineMode: baselineMode)
        } else if baselineMode == request.target {
            outcome = .noOp
            reason = "target_matches_fresh_readback_baseline"
        } else if request.execute {
            outcome = .unsupported
            reason = "local_writer_unverified"
        } else {
            outcome = .candidate
            reason = "dry_run_only_local_writer_unverified"
        }
        nextCaptureFlow = [
            "fresh paired BLE session/peripheral and capture session",
            "fresh cam_lens_state readback with raw B1/B2 baseline",
            "one 02/24 SET using the single transport-owner sequence",
            "matching 02/24 ACK and post-submit cam_lens_state 00/99/06 readback",
            "one exact restore SET to the captured baseline and matching readback",
            "abort on session, peer, sequence, ACK or readback mismatch; never retry"
        ]
        evidence = "Kaze@341a35de18493ff61f97c93b8b10161a7512aa36 " +
            "02/24 focus mode + cam_lens_state B1/B2; " +
            "OpenPocketCine@9c4e7334ca4d935c5d467abecaf8f968f7927d84 " +
            "02/24 builder; local BLE-only writer evidence remains 0 " +
            "(research/2026-09-09/ble-camera-write-route.md)"
    }

    public static func dryRun(
        _ request: BluetoothReversibleSettingCandidateRequest
    ) -> Self {
        Self(request: request)
    }

    private static func baselineMode(
        _ observation: CameraSettingsObservation
    ) -> CameraFocusMode? {
        guard case .lensState(let value) = observation.readOnlyValue,
              let typedMode = value.focusMode else {
            return nil
        }
        switch value.focusModeRaw {
        case 0xB1 where typedMode == .single: return .single
        case 0xB2 where typedMode == .continuous: return .continuous
        default: return nil
        }
    }

    private static func baselineFailure(
        request: BluetoothReversibleSettingCandidateRequest,
        expectedBinding: ContinuousGimbalBinding,
        baselineMode: CameraFocusMode?
    ) -> String {
        if request.baseline.binding != expectedBinding {
            return "baseline_session_mismatch"
        }
        if request.baseline.property != .lensState {
            return "baseline_property_mismatch"
        }
        if !request.baseline.isFresh(now: request.nowUptime) {
            return "baseline_stale_or_clock_invalid"
        }
        if baselineMode == nil {
            return "baseline_focus_readback_unknown"
        }
        return "baseline_value_does_not_match_raw_readback"
    }
}

public typealias Pocket3BluetoothReversibleSettingCandidate =
    BluetoothReversibleSettingCandidate

extension BluetoothReversibleSettingCandidate {
    public static func dryRun(
        _ request: BluetoothReversibleSettingCandidateRequest
    ) -> BluetoothReversibleSettingCandidateReport {
        BluetoothReversibleSettingCandidateReport(request: request)
    }
}
