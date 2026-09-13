import Foundation

/// Product-facing camera-body Video actions. Timelapse, panorama and photo
/// operations intentionally stay outside this small vertical slice.
public enum CameraBodyRecordingAction: String, Codable, Sendable,
    Equatable, CaseIterable {
    case start
    case stop
    case format
}

public enum CameraBodyRecordingRequestError: Error, Codable, Sendable,
    Equatable {
    case invalidArguments
    case invalidIdentity
    case invalidFormat
    case formatRequired
    case formatNotAllowed
}

/// One explicit body-recording request. Identity is required even for a dry
/// run so an IPC client cannot accidentally apply a stale request after a
/// reconnect. `execute` remains false unless the caller opts in.
public struct CameraBodyRecordingRequest: Codable, Sendable, Equatable {
    public static let operation = "camera-body-recording"
    public static let defaultTimeout: TimeInterval = 3
    public static let maximumTimeout: TimeInterval =
        NativeCommandTransactionRequest.maximumTimeout

    public let action: CameraBodyRecordingAction
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let format: CameraBodyRecordingFormatCommand?
    public let execute: Bool
    public let timeout: TimeInterval

    public init(action: CameraBodyRecordingAction,
                expectedSessionID: UUID,
                peripheralID: UUID,
                generation: UInt64,
                format: CameraBodyRecordingFormatCommand? = nil,
                execute: Bool = false,
                timeout: TimeInterval = Self.defaultTimeout) throws {
        guard generation > 0,
              timeout.isFinite, timeout > 0,
              timeout <= Self.maximumTimeout else {
            throw CameraBodyRecordingRequestError.invalidArguments
        }
        if action == .format {
            guard format != nil else {
                throw CameraBodyRecordingRequestError.formatRequired
            }
        } else if format != nil {
            throw CameraBodyRecordingRequestError.invalidFormat
        }
        self.action = action
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.format = format
        self.execute = execute
        self.timeout = timeout
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: [
                  "action", "session", "peripheral", "generation",
                  "resolution", "fps", "execute", "timeout"
              ]),
              let actionRaw = fields["action"]?.string,
              let action = CameraBodyRecordingAction(rawValue: actionRaw),
              let sessionRaw = fields["session"]?.string,
              let session = UUID(uuidString: sessionRaw),
              let peripheralRaw = fields["peripheral"]?.string,
              let peripheral = UUID(uuidString: peripheralRaw),
              let generation = Self.uint64(fields["generation"]),
              generation > 0 else {
            throw CameraBodyRecordingRequestError.invalidArguments
        }
        let execute = try Self.boolean(fields["execute"])
        let timeout = try Self.number(fields["timeout"],
                                      default: Self.defaultTimeout)
        let format: CameraBodyRecordingFormatCommand?
        if action == .format {
            guard let resolution = Self.resolution(fields["resolution"]),
                  let frameRate = Self.frameRate(fields["fps"]) else {
                throw CameraBodyRecordingRequestError.invalidFormat
            }
            format = CameraBodyRecordingFormatCommand(
                resolution: resolution, frameRate: frameRate)
        } else {
            guard fields["resolution"] == nil, fields["fps"] == nil else {
                throw CameraBodyRecordingRequestError.invalidFormat
            }
            format = nil
        }
        try self.init(action: action, expectedSessionID: session,
                      peripheralID: peripheral, generation: generation,
                      format: format, execute: execute, timeout: timeout)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        while index < cliArguments.count {
            let argument = cliArguments[index]
            if argument == "--execute" {
                guard fields["execute"] == nil else {
                    throw CameraBodyRecordingRequestError.invalidArguments
                }
                fields["execute"] = .bool(true)
                index += 1
                continue
            }
            guard index + 1 < cliArguments.count else {
                throw CameraBodyRecordingRequestError.invalidArguments
            }
            let key: String
            switch argument {
            case "--action": key = "action"
            case "--session": key = "session"
            case "--peripheral": key = "peripheral"
            case "--generation": key = "generation"
            case "--resolution": key = "resolution"
            case "--fps", "--frame-rate": key = "fps"
            case "--timeout": key = "timeout"
            default: throw CameraBodyRecordingRequestError.invalidArguments
            }
            guard fields[key] == nil else {
                throw CameraBodyRecordingRequestError.invalidArguments
            }
            let value = cliArguments[index + 1]
            switch key {
            case "generation":
                guard let number = Double(value), number.isFinite,
                      number.rounded() == number else {
                    throw CameraBodyRecordingRequestError.invalidArguments
                }
                fields[key] = .number(number)
            case "timeout":
                guard let number = Double(value), number.isFinite else {
                    throw CameraBodyRecordingRequestError.invalidArguments
                }
                fields[key] = .number(number)
            default:
                fields[key] = .string(value)
            }
            index += 2
        }
        try self.init(arguments: .object(fields))
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "action": .string(action.rawValue),
            "session": .string(expectedSessionID.uuidString),
            "peripheral": .string(peripheralID.uuidString),
            "generation": .number(Double(generation)),
            "execute": .bool(execute),
            "timeout": .number(timeout)
        ]
        if let format {
            fields["resolution"] = .string(Self.resolutionName(format.resolution))
            fields["fps"] = .string(Self.frameRateName(format.frameRate))
        }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "enum": .array(CameraBodyRecordingAction.allCases.map {
                    .string($0.rawValue)
                })
            ]),
            "session": .object(["type": .string("string"), "minLength": .number(1)]),
            "peripheral": .object(["type": .string("string"), "minLength": .number(1)]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "resolution": .object(["type": .string("string")]),
            "fps": .object(["type": .string("string")]),
            "execute": .object(["type": .string("boolean")]),
            "timeout": .object(["type": .string("number"),
                                 "exclusiveMinimum": .number(0),
                                 "maximum": .number(maximumTimeout)])
        ]),
        "required": .array([
            .string("action"), .string("session"), .string("peripheral"),
            .string("generation")
        ]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }

    public static func resolutionName(_ value: CameraVideoResolution) -> String {
        switch value {
        case .p1080: "1080p"
        case .p2_7K: "2.7K"
        case .p4K: "4K"
        case .square1080: "square1080"
        case .square2160: "square2160"
        case .square3K: "square3K"
        case .portrait1080: "portrait1080"
        case .portrait2_7K: "portrait2.7K"
        case .portrait3K: "portrait3K"
        }
    }

    public static func frameRateName(_ value: CameraFrameRate) -> String {
        switch value {
        case .fps24: "24"
        case .fps25: "25"
        case .fps30: "30"
        case .fps48: "48"
        case .fps50: "50"
        case .fps60: "60"
        case .fps120: "120"
        case .fps240: "240"
        }
    }

    private static func uint64(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.number, number.isFinite,
              number.rounded() == number, number >= 0,
              number <= Double(UInt64.max) else { return nil }
        return UInt64(number)
    }

    private static func boolean(_ value: JSONValue?) throws -> Bool {
        guard let value else { return false }
        guard let result = value.bool else {
            throw CameraBodyRecordingRequestError.invalidArguments
        }
        return result
    }

    private static func number(_ value: JSONValue?, default fallback: Double)
        throws -> Double {
        guard let value else { return fallback }
        guard let result = value.number, result.isFinite else {
            throw CameraBodyRecordingRequestError.invalidArguments
        }
        return result
    }

    private static func resolution(_ value: JSONValue?)
        -> CameraVideoResolution? {
        guard let raw = value?.string else { return nil }
        switch raw.lowercased().replacingOccurrences(of: " ", with: "") {
        case "1080p", "p1080", "16:9-1080": return .p1080
        case "2.7k", "2_7k", "p2.7k", "p2_7k": return .p2_7K
        case "4k", "p4k": return .p4K
        case "square1080", "1:1-1080": return .square1080
        case "square2160", "1:1-2160": return .square2160
        case "square3k", "1:1-3k": return .square3K
        case "portrait1080", "1080x1920", "9:16-1080": return .portrait1080
        case "portrait2.7k", "portrait2_7k", "1520x2704", "9:16-2.7k": return .portrait2_7K
        case "portrait3k", "1728x3072", "9:16-3k": return .portrait3K
        default: return nil
        }
    }

    private static func frameRate(_ value: JSONValue?) -> CameraFrameRate? {
        guard let raw = value?.string else { return nil }
        let value = raw.lowercased().replacingOccurrences(of: "fps", with: "")
        switch value {
        case "24": return .fps24
        case "25": return .fps25
        case "30": return .fps30
        case "48": return .fps48
        case "50": return .fps50
        case "60": return .fps60
        case "120": return .fps120
        case "240": return .fps240
        default: return nil
        }
    }
}

public typealias Pocket3CameraBodyRecordingRequest = CameraBodyRecordingRequest

/// Product result keeps the current scalar baselines beside the existing
/// coordinator evidence. No image, file path or credential is accepted.
public struct CameraBodyRecordingResult: Codable, Sendable, Equatable {
    public let request: CameraBodyRecordingRequest
    public let validation: NativeBodyValidationResult?
    public let recordingBaseline: NativeBodyRecordingLifecycleSample?
    public let formatBaseline: NativeBodyFormatReadback?
    public let legalFormatCapabilities: CameraVideoFormatCapabilities?
    public let videoMode: Pocket3ShootingMode?
    public let cleanupAttempted: Bool
    public let cleanupSucceeded: Bool
    public let failureCode: String?

    public init(request: CameraBodyRecordingRequest,
                validation: NativeBodyValidationResult?,
                recordingBaseline: NativeBodyRecordingLifecycleSample?,
                formatBaseline: NativeBodyFormatReadback?,
                legalFormatCapabilities: CameraVideoFormatCapabilities?,
                videoMode: Pocket3ShootingMode?,
                cleanupAttempted: Bool,
                cleanupSucceeded: Bool,
                failureCode: String? = nil) {
        self.request = request
        self.validation = validation
        self.recordingBaseline = recordingBaseline
        self.formatBaseline = formatBaseline
        self.legalFormatCapabilities = legalFormatCapabilities
        self.videoMode = videoMode
        self.cleanupAttempted = cleanupAttempted
        self.cleanupSucceeded = cleanupSucceeded
        self.failureCode = failureCode ?? validation?.failureCode
    }

    public var dryRun: Bool { !request.execute }
    public var submitted: Bool { validation?.submitted == true }
    public var acknowledged: Bool { validation?.acknowledged == true }
    public var observed: Bool { validation?.observed == true }
    public var completed: Bool { validation?.completed == true }
}

public enum CameraBodyRecordingServiceError: Error, Codable, Sendable,
    Equatable {
    case invalidRequestIdentity
    case commandNotReady
    case videoModeRequired
    case recordingBaselineRequired
    case formatBaselineRequired
    case legalCapabilityRequired
    case formatNotAllowed
}

/// Small product service around the existing body coordinators. It owns no
/// Bluetooth or LAN transport; the injected adapter remains the sole command
/// boundary. A failed execute invokes optional owner cleanup once and never
/// retries the record or format request.
public struct CameraBodyRecordingService: Sendable {
    public typealias Cleanup = @Sendable () async -> Bool

    private let adapter: NativeBodyValidationExecutorAdapter?
    private let cleanup: Cleanup?

    public init(adapter: NativeBodyValidationExecutorAdapter? = nil,
                cleanup: Cleanup? = nil) {
        self.adapter = adapter
        self.cleanup = cleanup
    }

    public func run(
        _ request: CameraBodyRecordingRequest,
        snapshot: NativeBodyValidationSnapshot
    ) async throws -> CameraBodyRecordingResult {
        guard snapshot.session.sessionID == request.expectedSessionID,
              snapshot.session.peerID == request.peripheralID,
              snapshot.session.generation == request.generation else {
            throw CameraBodyRecordingServiceError.invalidRequestIdentity
        }
        guard snapshot.session.isReady(for: .record) else {
            throw CameraBodyRecordingServiceError.commandNotReady
        }
        guard snapshot.videoMode == .video else {
            throw CameraBodyRecordingServiceError.videoModeRequired
        }
        guard let recording = snapshot.recordingBaseline,
              recording.sessionID == request.expectedSessionID,
              recording.generation == request.generation,
              recording.status.isKnown, !recording.status.transitioning,
              recording.isFresh(nowUptime: snapshot.nowUptime,
                                maximumAge: NativeBodyRecordingCoordinator.maximumReadbackAge) else {
            throw CameraBodyRecordingServiceError.recordingBaselineRequired
        }
        if request.action == .format {
            guard let baseline = snapshot.formatBaseline,
                  baseline.sessionID == request.expectedSessionID,
                  baseline.generation == request.generation,
                  baseline.isFresh(nowUptime: snapshot.nowUptime,
                                  maximumAge: NativeBodyFormatCoordinator.maximumReadbackAge) else {
                throw CameraBodyRecordingServiceError.formatBaselineRequired
            }
            guard let capabilities = snapshot.formatCapabilities else {
                throw CameraBodyRecordingServiceError.legalCapabilityRequired
            }
            guard let format = request.format,
                  format.isAllowed(by: capabilities) else {
                throw CameraBodyRecordingServiceError.formatNotAllowed
            }
        }

        let validationRequest = NativeBodyValidationRequest(
            operation: request.action == .format ? .format :
                request.action == .start ? .start : .stop,
            execute: request.execute, format: request.format,
            timeout: request.timeout)
        do {
            let validation = try await NativeBodyValidationService(
                adapter: adapter).run(validationRequest, snapshot: snapshot)
            var cleanupAttempted = false
            var cleanupSucceeded = true
            if request.execute && !validation.completed {
                cleanupAttempted = true
                cleanupSucceeded = await performCleanup()
            }
            return CameraBodyRecordingResult(
                request: request, validation: validation,
                recordingBaseline: snapshot.recordingBaseline,
                formatBaseline: snapshot.formatBaseline,
                legalFormatCapabilities: snapshot.formatCapabilities,
                videoMode: snapshot.videoMode,
                cleanupAttempted: cleanupAttempted,
                cleanupSucceeded: cleanupSucceeded)
        } catch {
            if request.execute {
                _ = await performCleanup()
            }
            throw error
        }
    }

    private func performCleanup() async -> Bool {
        guard let cleanup else { return true }
        return await Task.detached(priority: .userInitiated) {
            await cleanup()
        }.value
    }
}

public typealias Pocket3CameraBodyRecordingService = CameraBodyRecordingService
public typealias Pocket3CameraBodyRecordingResult = CameraBodyRecordingResult
