import Foundation

/// Developer-only camera capture actions. The action vocabulary is deliberately
/// narrower than the wire protocol: every value is converted to a known typed
/// `Pocket3NativeCameraCaptureOperation` before a command can be prepared.
public enum NativeCameraCaptureValidationOperation: String, Codable, Sendable,
    Equatable, CaseIterable {
    case mode
    case photoFrame = "photo-frame"
    case photoFormat = "photo-format"
    case photoCountdown = "photo-countdown"
    case photoShutter = "photo-shutter"
    case panoramaType = "panorama-type"
    case panoramaFormat = "panorama-format"
    case panoramaShutter = "panorama-shutter"
    case timelapseConfiguration = "timelapse-config"
    case hyperlapseSpeed = "hyperlapse-speed"
    case motionlapseConfiguration = "motionlapse-config"
    case motionlapseDirection = "motionlapse-direction"
    case startTimelapse = "start-timelapse"
    case stopTimelapse = "stop-timelapse"
    case startHyperlapse = "start-hyperlapse"
    case stopHyperlapse = "stop-hyperlapse"
    case startMotionlapse = "start-motionlapse"
    case stopMotionlapse = "stop-motionlapse"

    public static let setMode = Self.mode
    public static let photo = Self.photoShutter
    public static let panorama = Self.panoramaShutter
    public static let timelapse = Self.timelapseConfiguration
    public static let motionlapse = Self.motionlapseConfiguration
}

public enum NativeCameraCaptureValidationError: Error, Codable, Sendable,
    Equatable {
    case invalidArguments
    case invalidAction
    case invalidValue
    case invalidRequestIdentity
    case invalidTimeout
    case sessionNotReady
    case missingSessionIdentity
    case baselineRequired
    case invalidBaseline
    case alreadyAtTarget
    case operationInFlight
    case staleTransaction
}

/// Strict JSON/CLI request for one native capture validation attempt. The
/// typed `target` is the only representation consumed by the coordinator;
/// arbitrary command IDs and unknown enum values cannot enter this API.
public struct NativeCameraCaptureValidationRequest: Codable, Sendable,
    Equatable {
    public static let operation = "validation-wireless-native-camera-capture"

    public let action: NativeCameraCaptureValidationOperation
    public let expectedSessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let target: Pocket3NativeCameraCaptureOperation
    public let execute: Bool
    public let timeout: TimeInterval

    public var operation: NativeCameraCaptureValidationOperation { action }
    public var captureOperation: Pocket3NativeCameraCaptureOperation { target }

    public init(action: NativeCameraCaptureValidationOperation,
                expectedSessionID: UUID, peripheralID: UUID,
                generation: UInt64,
                target: Pocket3NativeCameraCaptureOperation,
                execute: Bool = false, timeout: TimeInterval = 3) throws {
        guard generation > 0, timeout.isFinite, timeout > 0,
              timeout <= NativeCommandTransactionRequest.maximumTimeout else {
            throw NativeCameraCaptureValidationError.invalidTimeout
        }
        guard Self.action(for: target) == action else {
            throw NativeCameraCaptureValidationError.invalidArguments
        }
        self.action = action
        self.expectedSessionID = expectedSessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.target = target
        self.execute = execute
        self.timeout = timeout
    }

    public init(arguments: JSONValue) throws {
        guard case .object(let fields) = arguments else {
            throw NativeCameraCaptureValidationError.invalidArguments
        }
        let allowed = Set([
            "action", "expectedSessionID", "peripheralID", "generation",
            "value", "output", "intervalTenths", "durationSeconds", "slot",
            "pitchTenths", "rollTenths", "yawTenths", "execute", "timeout"
        ])
        guard Set(fields.keys).isSubset(of: allowed),
              let actionRaw = fields["action"]?.string,
              let action = Self.parseAction(actionRaw),
              let sessionText = fields["expectedSessionID"]?.string,
              let expectedSessionID = UUID(uuidString: sessionText),
              let peripheralText = fields["peripheralID"]?.string,
              let peripheralID = UUID(uuidString: peripheralText),
              let generation = Self.parseUInt64(fields["generation"],
                                                minimum: 1) else {
            throw NativeCameraCaptureValidationError.invalidArguments
        }
        let execute: Bool
        if let value = fields["execute"] {
            guard let parsed = value.bool else {
                throw NativeCameraCaptureValidationError.invalidArguments
            }
            execute = parsed
        } else {
            execute = false
        }
        let timeout: TimeInterval
        if let value = fields["timeout"] {
            guard let parsed = value.number else {
                throw NativeCameraCaptureValidationError.invalidTimeout
            }
            timeout = parsed
        } else {
            timeout = 3
        }
        let target = try Self.parseTarget(action: action, fields: fields)
        try self.init(action: action, expectedSessionID: expectedSessionID,
                      peripheralID: peripheralID, generation: generation,
                      target: target, execute: execute, timeout: timeout)
    }

    public init(cliArguments: [String]) throws {
        var fields: [String: JSONValue] = [:]
        var index = 0
        let names = [
            "--action": "action", "--session": "expectedSessionID",
            "--peripheral": "peripheralID", "--generation": "generation",
            "--value": "value", "--output": "output",
            "--interval": "intervalTenths", "--interval-tenths": "intervalTenths",
            "--duration": "durationSeconds", "--duration-seconds": "durationSeconds",
            "--slot": "slot", "--pitch": "pitchTenths",
            "--roll": "rollTenths", "--yaw": "yawTenths",
            "--timeout": "timeout"
        ]
        while index < cliArguments.count {
            let argument = cliArguments[index]
            if argument == "--execute" {
                guard fields["execute"] == nil else {
                    throw BridgeFailure("usage", "Duplicate --execute")
                }
                fields["execute"] = .bool(true)
                index += 1
                continue
            }
            guard let key = names[argument], index + 1 < cliArguments.count,
                  fields[key] == nil else {
                throw BridgeFailure("usage",
                    "Unknown, duplicate or incomplete native camera capture option")
            }
            let value = cliArguments[index + 1]
            switch key {
            case "action", "expectedSessionID", "peripheralID", "value", "output":
                fields[key] = .string(value)
            case "generation", "intervalTenths", "durationSeconds", "slot",
                 "pitchTenths", "rollTenths", "yawTenths", "timeout":
                guard let number = Self.parseNumber(value) else {
                    throw BridgeFailure("usage",
                        "Native camera capture numeric options must be finite")
                }
                fields[key] = .number(number)
            default:
                throw BridgeFailure("usage",
                    "Unknown native camera capture option")
            }
            index += 2
        }
        do {
            try self.init(arguments: .object(fields))
        } catch let error as NativeCameraCaptureValidationError {
            throw BridgeFailure("invalid_native_camera_capture_request",
                                String(describing: error))
        }
    }

    public var value: JSONValue? {
        switch target {
        case .setMode(let mode): return .string(Self.modeName(mode))
        case .photoFrame(let frame): return .string(Self.photoFrameName(frame))
        case .photoFormat(let format): return .string(Self.photoFormatName(format))
        case .photoCountdown(let countdown): return .string(Self.countdownName(countdown))
        case .photoShutter: return nil
        case .panoramaType(let type): return .string(Self.panoramaTypeName(type))
        case .panoramaFormat(let format): return .string(Self.panoramaFormatName(format))
        case .panoramaShutter: return nil
        case .timelapseConfiguration, .motionlapseConfiguration: return nil
        case .hyperlapseSpeed(let speed): return .string(Self.hyperlapseSpeedName(speed))
        case .motionlapseDirection(let direction): return .string(Self.motionDirectionName(direction))
        case .startTimelapse, .stopTimelapse, .startHyperlapse, .stopHyperlapse,
             .startMotionlapse, .stopMotionlapse: return nil
        }
    }

    public var arguments: JSONValue {
        var fields: [String: JSONValue] = [
            "action": .string(action.rawValue),
            "expectedSessionID": .string(expectedSessionID.uuidString),
            "peripheralID": .string(peripheralID.uuidString),
            "generation": .number(Double(generation)),
            "execute": .bool(execute), "timeout": .number(timeout)
        ]
        switch target {
        case .timelapseConfiguration(let value):
            fields["output"] = .string(Self.timelapseOutputName(value.output))
            fields["intervalTenths"] = .number(Double(value.intervalTenths))
            fields["durationSeconds"] = .number(Double(value.durationSeconds))
        case .motionlapseConfiguration(let value):
            fields["slot"] = .number(Double(value.slot))
            fields["intervalTenths"] = .number(Double(value.intervalTenths))
            fields["durationSeconds"] = .number(Double(value.durationSeconds))
            fields["pitchTenths"] = .number(Double(value.pitchTenths))
            fields["rollTenths"] = .number(Double(value.rollTenths))
            fields["yawTenths"] = .number(Double(value.yawTenths))
        default:
            if let value { fields["value"] = value }
        }
        return .object(fields)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "action": .object(["type": .string("string"),
                "enum": .array(NativeCameraCaptureValidationOperation.allCases.map { .string($0.rawValue) })]),
            "expectedSessionID": .object(["type": .string("string"), "minLength": .number(1)]),
            "peripheralID": .object(["type": .string("string"), "minLength": .number(1)]),
            "generation": .object(["type": .string("integer"), "minimum": .number(1)]),
            "value": .object(["oneOf": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("integer")])
            ])]),
            "output": .object(["type": .string("string")]),
            "intervalTenths": .object(["type": .string("integer"), "minimum": .number(5), "maximum": .number(600)]),
            "durationSeconds": .object(["type": .string("integer"), "minimum": .number(0), "maximum": .number(18_000)]),
            "slot": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(4)]),
            "pitchTenths": .object(["type": .string("integer")]),
            "rollTenths": .object(["type": .string("integer")]),
            "yawTenths": .object(["type": .string("integer")]),
            "execute": .object(["type": .string("boolean")]),
            "timeout": .object(["type": .string("number"), "exclusiveMinimum": .number(0), "maximum": .number(5)])
        ]),
        "required": .array([.string("action"), .string("expectedSessionID"),
                             .string("peripheralID"), .string("generation")]),
        "additionalProperties": .bool(false)
    ])

    public init(from decoder: Decoder) throws {
        try self.init(arguments: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try arguments.encode(to: encoder)
    }

    private static func action(for target: Pocket3NativeCameraCaptureOperation)
        -> NativeCameraCaptureValidationOperation {
        switch target {
        case .setMode: .mode
        case .photoFrame: .photoFrame
        case .photoFormat: .photoFormat
        case .photoCountdown: .photoCountdown
        case .photoShutter: .photoShutter
        case .panoramaType: .panoramaType
        case .panoramaFormat: .panoramaFormat
        case .panoramaShutter: .panoramaShutter
        case .timelapseConfiguration: .timelapseConfiguration
        case .hyperlapseSpeed: .hyperlapseSpeed
        case .motionlapseConfiguration: .motionlapseConfiguration
        case .motionlapseDirection: .motionlapseDirection
        case .startTimelapse: .startTimelapse
        case .stopTimelapse: .stopTimelapse
        case .startHyperlapse: .startHyperlapse
        case .stopHyperlapse: .stopHyperlapse
        case .startMotionlapse: .startMotionlapse
        case .stopMotionlapse: .stopMotionlapse
        }
    }

    private static func parseTarget(
        action: NativeCameraCaptureValidationOperation,
        fields: [String: JSONValue]
    ) throws -> Pocket3NativeCameraCaptureOperation {
        switch action {
        case .mode:
            try requireOnly(fields, action, keys: ["value"])
            return .setMode(try parseMode(fields["value"]))
        case .photoFrame:
            try requireOnly(fields, action, keys: ["value"])
            return .photoFrame(try parsePhotoFrame(fields["value"]))
        case .photoFormat:
            try requireOnly(fields, action, keys: ["value"])
            return .photoFormat(try parsePhotoFormat(fields["value"]))
        case .photoCountdown:
            try requireOnly(fields, action, keys: ["value"])
            return .photoCountdown(try parseCountdown(fields["value"]))
        case .photoShutter:
            try requireOnly(fields, action, keys: [])
            return .photoShutter
        case .panoramaType:
            try requireOnly(fields, action, keys: ["value"])
            return .panoramaType(try parsePanoramaType(fields["value"]))
        case .panoramaFormat:
            try requireOnly(fields, action, keys: ["value"])
            return .panoramaFormat(try parsePanoramaFormat(fields["value"]))
        case .panoramaShutter:
            try requireOnly(fields, action, keys: [])
            return .panoramaShutter
        case .timelapseConfiguration:
            try requireOnly(fields, action,
                           keys: ["output", "intervalTenths", "durationSeconds"])
            return .timelapseConfiguration(try Pocket3TimelapseConfiguration(
                intervalTenths: try parseUInt16(fields["intervalTenths"], minimum: 5, maximum: 600),
                durationSeconds: try parseUInt32(fields["durationSeconds"], minimum: 0, maximum: 18_000),
                output: try parseTimelapseOutput(fields["output"])))
        case .hyperlapseSpeed:
            try requireOnly(fields, action, keys: ["value"])
            return .hyperlapseSpeed(try parseHyperlapseSpeed(fields["value"]))
        case .motionlapseConfiguration:
            try requireOnly(fields, action,
                           keys: ["slot", "intervalTenths", "durationSeconds",
                                  "pitchTenths", "rollTenths", "yawTenths"])
            return .motionlapseConfiguration(try Pocket3MotionlapseConfiguration(
                slot: try parseUInt8(fields["slot"], minimum: 1, maximum: 4),
                intervalTenths: try parseUInt16(fields["intervalTenths"], minimum: 5, maximum: 600),
                durationSeconds: try parseUInt32(fields["durationSeconds"], minimum: 0, maximum: 18_000),
                pitchTenths: try parseInt16(fields["pitchTenths"]),
                rollTenths: try parseInt16(fields["rollTenths"]),
                yawTenths: try parseInt16(fields["yawTenths"])))
        case .motionlapseDirection:
            try requireOnly(fields, action, keys: ["value"])
            return .motionlapseDirection(try parseMotionDirection(fields["value"]))
        case .startTimelapse: try requireOnly(fields, action, keys: []); return .startTimelapse
        case .stopTimelapse: try requireOnly(fields, action, keys: []); return .stopTimelapse
        case .startHyperlapse: try requireOnly(fields, action, keys: []); return .startHyperlapse
        case .stopHyperlapse: try requireOnly(fields, action, keys: []); return .stopHyperlapse
        case .startMotionlapse: try requireOnly(fields, action, keys: []); return .startMotionlapse
        case .stopMotionlapse: try requireOnly(fields, action, keys: []); return .stopMotionlapse
        }
    }

    private static func requireOnly(_ fields: [String: JSONValue],
                                    _ action: NativeCameraCaptureValidationOperation,
                                    keys: Set<String>) throws {
        let base = Set(["action", "expectedSessionID", "peripheralID", "generation",
                        "execute", "timeout"])
        guard Set(fields.keys).subtracting(base).isSubset(of: keys),
              keys.allSatisfy({ fields[$0] != nil }) else {
            throw NativeCameraCaptureValidationError.invalidArguments
        }
        _ = action
    }

    private static func parseAction(_ raw: String)
        -> NativeCameraCaptureValidationOperation? {
        if let action = NativeCameraCaptureValidationOperation(rawValue: raw) { return action }
        switch raw.lowercased() {
        case "set-mode", "setmode", "shooting-mode": return .mode
        case "photo", "shutter", "photo-shutter": return .photoShutter
        case "pano", "pano-shutter", "panorama-shutter": return .panoramaShutter
        case "timelapse", "timelapse-configuration": return .timelapseConfiguration
        case "hyperlapse": return .hyperlapseSpeed
        case "motionlapse", "motionlapse-configuration": return .motionlapseConfiguration
        default: return nil
        }
    }

    private static func parseMode(_ value: JSONValue?) throws -> Pocket3ShootingMode {
        if let raw = value?.string {
            switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "slow-motion", "slowmotion", "0", "0x00": return .slowMotion
            case "video", "1", "0x01": return .video
            case "timelapse", "time-lapse", "2", "0x02": return .timelapse
            case "photo", "5", "0x05": return .photo
            case "hyperlapse", "10", "0x0a": return .hyperlapse
            case "panorama", "pano", "12", "0x0c": return .panorama
            case "motionlapse", "motion-lapse", "24", "0x18": return .motionlapse
            case "low-light", "lowlight", "40", "0x28": return .lowLight
            default: throw NativeCameraCaptureValidationError.invalidValue
            }
        }
        let raw = try parseUInt8(value, minimum: 0, maximum: 255)
        guard let mode = Pocket3ShootingMode(rawValue: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return mode
    }

    private static func parsePhotoFrame(_ value: JSONValue?) throws -> CameraPhotoFrame {
        if let raw = value?.string {
            switch raw.lowercased() {
            case "16:9", "16x9", "sixteen-by-nine", "1", "0x01": return .sixteenByNine
            case "1:1", "1x1", "one-by-one", "3", "0x03": return .oneByOne
            default: throw NativeCameraCaptureValidationError.invalidValue
            }
        }
        let raw = try parseUInt8(value, minimum: 0, maximum: 255)
        guard let result = CameraPhotoFrame(rawValue: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parsePhotoFormat(_ value: JSONValue?) throws -> CameraPhotoFormat {
        if let raw = value?.string {
            switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "jpeg", "jpg", "1", "0x01": return .jpeg
            case "jpeg+raw", "jpeg-and-raw", "jpegraw", "2", "0x02": return .jpegAndRaw
            default: throw NativeCameraCaptureValidationError.invalidValue
            }
        }
        let raw = try parseUInt8(value, minimum: 0, maximum: 255)
        guard let result = CameraPhotoFormat(rawValue: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parseCountdown(_ value: JSONValue?) throws -> CameraPhotoCountdown {
        if let raw = value?.string {
            switch raw.lowercased() {
            case "off", "none", "0", "0x00": return .off
            case "3", "3s", "0x03": return .seconds3
            case "5", "5s", "0x05": return .seconds5
            case "7", "7s", "0x07": return .seconds7
            default: throw NativeCameraCaptureValidationError.invalidValue
            }
        }
        let raw = try parseUInt8(value, minimum: 0, maximum: 255)
        guard let result = CameraPhotoCountdown(rawValue: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parsePanoramaType(_ value: JSONValue?) throws -> CameraPanoramaType {
        if let raw = value?.string {
            switch raw.lowercased() {
            case "180", "180-degree", "180-degrees", "degrees180", "5", "0x05": return .degrees180
            case "3x3", "grid3x3", "grid-3x3", "7", "0x07": return .grid3x3
            default: throw NativeCameraCaptureValidationError.invalidValue
            }
        }
        let raw = try parseUInt8(value, minimum: 0, maximum: 255)
        guard let result = CameraPanoramaType(rawValue: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parsePanoramaFormat(_ value: JSONValue?) throws -> CameraPanoramaPhotoFormat {
        if let raw = value?.string {
            switch raw.lowercased() {
            case "raw", "1", "0x01": return .raw
            case "jpeg", "jpg", "3", "0x03": return .jpeg
            default: throw NativeCameraCaptureValidationError.invalidValue
            }
        }
        let raw = try parseUInt8(value, minimum: 0, maximum: 255)
        guard let result = CameraPanoramaPhotoFormat(rawValue: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parseTimelapseOutput(_ value: JSONValue?) throws -> CameraTimelapseOutput {
        if let raw = value?.string {
            switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "video", "0", "0x00": return .video
            case "jpeg+video", "jpeg-and-video", "2", "0x02": return .jpegAndVideo
            case "raw+video", "raw-and-video", "3", "0x03": return .rawAndVideo
            default: throw NativeCameraCaptureValidationError.invalidValue
            }
        }
        let raw = try parseUInt8(value, minimum: 0, maximum: 255)
        guard let result = CameraTimelapseOutput(rawValue: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parseHyperlapseSpeed(_ value: JSONValue?) throws -> CameraHyperlapseSpeed {
        if let raw = value?.string {
            let normalized = raw.lowercased()
            switch normalized {
            case "auto", "0", "0x00": return .auto
            case "2", "2x", "0x02": return .x2
            case "5", "5x", "0x05": return .x5
            case "10", "10x", "0x0a": return .x10
            case "15", "15x", "0x0f": return .x15
            case "30", "30x", "0x1e": return .x30
            default: throw NativeCameraCaptureValidationError.invalidValue
            }
        }
        let raw = try parseUInt16(value, minimum: 0, maximum: UInt16.max)
        guard let result = CameraHyperlapseSpeed(rawValue: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parseMotionDirection(_ value: JSONValue?) throws -> CameraMotionlapseDirection {
        if let raw = value?.string {
            switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
            case "custom", "0", "0x00": return .custom
            case "left", "left-to-right", "1", "0x01": return .leftToRight
            case "right", "right-to-left", "2", "0x02": return .rightToLeft
            default: throw NativeCameraCaptureValidationError.invalidValue
            }
        }
        let raw = try parseUInt8(value, minimum: 0, maximum: 255)
        guard let result = CameraMotionlapseDirection(rawValue: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parseNumber(_ value: String) -> Double? {
        if value.lowercased().hasPrefix("0x"),
           let raw = UInt64(value.dropFirst(2), radix: 16) {
            return Double(raw)
        }
        return Double(value)
    }

    private static func parseUInt8(_ value: JSONValue?, minimum: UInt8,
                                   maximum: UInt8) throws -> UInt8 {
        guard let raw = integer(value), raw >= Int64(minimum), raw <= Int64(maximum),
              let result = UInt8(exactly: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parseUInt16(_ value: JSONValue?, minimum: UInt16,
                                    maximum: UInt16) throws -> UInt16 {
        guard let raw = integer(value), raw >= Int64(minimum), raw <= Int64(maximum),
              let result = UInt16(exactly: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parseUInt32(_ value: JSONValue?, minimum: UInt32,
                                    maximum: UInt32) throws -> UInt32 {
        guard let raw = integer(value), raw >= Int64(minimum), raw <= Int64(maximum),
              let result = UInt32(exactly: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func parseUInt64(_ value: JSONValue?, minimum: UInt64) -> UInt64? {
        guard let raw = integer(value), raw >= Int64(minimum),
              let result = UInt64(exactly: raw) else { return nil }
        return result
    }

    private static func parseInt16(_ value: JSONValue?) throws -> Int16 {
        guard let raw = integer(value), let result = Int16(exactly: raw) else {
            throw NativeCameraCaptureValidationError.invalidValue
        }
        return result
    }

    private static func integer(_ value: JSONValue?) -> Int64? {
        if let number = value?.number, number.isFinite,
           number.rounded() == number, let result = Int64(exactly: number) {
            return result
        }
        if let raw = value?.string {
            if raw.lowercased().hasPrefix("0x"),
               let result = UInt64(raw.dropFirst(2), radix: 16),
               result <= UInt64(Int64.max) { return Int64(result) }
            return Int64(raw)
        }
        return nil
    }

    private static func modeName(_ mode: Pocket3ShootingMode) -> String {
        switch mode {
        case .slowMotion: "slow-motion"
        case .video: "video"
        case .timelapse: "timelapse"
        case .photo: "photo"
        case .hyperlapse: "hyperlapse"
        case .panorama: "panorama"
        case .motionlapse: "motionlapse"
        case .lowLight: "low-light"
        }
    }
    private static func photoFrameName(_ value: CameraPhotoFrame) -> String {
        switch value { case .sixteenByNine: "16:9"; case .oneByOne: "1:1" }
    }
    private static func photoFormatName(_ value: CameraPhotoFormat) -> String {
        switch value { case .jpeg: "jpeg"; case .jpegAndRaw: "jpeg+raw" }
    }
    private static func countdownName(_ value: CameraPhotoCountdown) -> String {
        switch value { case .off: "off"; case .seconds3: "3"; case .seconds5: "5"; case .seconds7: "7" }
    }
    private static func panoramaTypeName(_ value: CameraPanoramaType) -> String {
        switch value { case .degrees180: "180"; case .grid3x3: "3x3" }
    }
    private static func panoramaFormatName(_ value: CameraPanoramaPhotoFormat) -> String {
        switch value { case .raw: "raw"; case .jpeg: "jpeg" }
    }
    private static func timelapseOutputName(_ value: CameraTimelapseOutput) -> String {
        switch value { case .video: "video"; case .jpegAndVideo: "jpeg+video"; case .rawAndVideo: "raw+video" }
    }
    private static func hyperlapseSpeedName(_ value: CameraHyperlapseSpeed) -> String {
        switch value { case .auto: "auto"; case .x2: "2x"; case .x5: "5x"; case .x10: "10x"; case .x15: "15x"; case .x30: "30x" }
    }
    private static func motionDirectionName(_ value: CameraMotionlapseDirection) -> String {
        switch value { case .custom: "custom"; case .leftToRight: "left-to-right"; case .rightToLeft: "right-to-left" }
    }
}

/// Readback snapshot supplied by the existing BLE/native owner. The service
/// does not perform a baseline GET and does not create a transport.
public struct NativeCameraCaptureValidationSnapshot: Codable, Sendable,
    Equatable {
    public let session: NativeCameraSessionStatus
    public let baseline: Pocket3NativeCameraReadback?
    public let nowUptime: TimeInterval

    public init(session: NativeCameraSessionStatus,
                baseline: Pocket3NativeCameraReadback? = nil,
                nowUptime: TimeInterval) {
        self.session = session
        self.baseline = baseline
        self.nowUptime = nowUptime
    }
}

public struct NativeCameraCaptureValidationRequestEvidence: Codable,
    Sendable, Equatable {
    public let id: UUID
    public let command: NativeCameraSessionCommand
    public let sessionID: UUID?
    public let generation: UInt64
    public let frame: NativeCommandFrame
    public let timeout: TimeInterval

    init(_ request: NativeCommandTransactionRequest) {
        id = request.id
        command = request.command
        sessionID = request.sessionID
        generation = request.generation
        frame = request.frame
        timeout = request.timeout
    }
}

/// `sideEffect` describes a possible camera media/file effect implied by the
/// requested command. It never claims that a file was actually created.
public enum NativeCameraCaptureSideEffect: String, Codable, Sendable,
    Equatable, CaseIterable {
    case none
    case shutterMayCreateMedia = "shutter_may_create_media"
    case recordingStartMayCreateMedia = "recording_start_may_create_media"
    case recordingStopMayCreateMedia = "recording_stop_may_create_media"
}

public struct NativeCameraCaptureValidationResult: Codable, Sendable,
    Equatable {
    public let action: NativeCameraCaptureValidationOperation
    public let executeRequested: Bool
    public let request: NativeCameraCaptureValidationRequestEvidence?
    public let capture: Pocket3NativeCameraCaptureResult?
    public let sideEffect: NativeCameraCaptureSideEffect
    public let phase: Pocket3NativeCameraCaptureCoordinatorPhase?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let failureCode: String?

    public var dryRun: Bool { !executeRequested }
}

public struct NativeCameraCaptureValidationExecutorAdapter: Sendable {
    public typealias Execute = @Sendable (
        _ request: NativeCommandTransactionRequest,
        _ readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult

    private let body: Execute

    public init(_ body: @escaping Execute) { self.body = body }

    public func execute(_ request: NativeCommandTransactionRequest,
                        readiness: NativeCameraSessionStatus) async throws
        -> NativeCommandTransactionResult {
        try await body(request, readiness)
    }
}

/// Developer-only service for one typed native camera capture action. An
/// injected adapter is the existing single datalink owner and is called at
/// most once. Dry-run remains the default and preserves a prepared request as
/// reviewable evidence without submitting it.
public struct NativeCameraCaptureValidationService: Sendable {
    public static let defaultTimeout: TimeInterval = 3

    private let executor: NativeCameraCaptureValidationExecutorAdapter?

    public typealias Executor = @Sendable (
        _ request: NativeCommandTransactionRequest,
        _ readiness: NativeCameraSessionStatus
    ) async throws -> NativeCommandTransactionResult

    public init(adapter: NativeCameraCaptureValidationExecutorAdapter? = nil) {
        executor = adapter
    }

    public init(executor: Executor?) {
        if let executor {
            self.executor = NativeCameraCaptureValidationExecutorAdapter(executor)
        } else {
            self.executor = nil
        }
    }

    public func run(_ request: NativeCameraCaptureValidationRequest,
                    snapshot: NativeCameraCaptureValidationSnapshot) async throws
        -> NativeCameraCaptureValidationResult {
        guard request.expectedSessionID == snapshot.session.sessionID,
              request.peripheralID == snapshot.session.peerID,
              request.generation == snapshot.session.generation else {
            throw NativeCameraCaptureValidationError.invalidRequestIdentity
        }
        guard snapshot.nowUptime.isFinite else {
            throw NativeCameraCaptureValidationError.invalidTimeout
        }
        guard let baseline = snapshot.baseline else {
            throw NativeCameraCaptureValidationError.baselineRequired
        }

        var coordinator: Pocket3NativeCameraCaptureCoordinator
        do {
            coordinator = try Pocket3NativeCameraCaptureCoordinator(
                session: snapshot.session)
        } catch let error as Pocket3NativeCameraProtocolError {
            throw map(error)
        }

        let nativeRequest: NativeCommandTransactionRequest
        do {
            nativeRequest = try coordinator.prepare(request.target,
                baseline: baseline, nowUptime: snapshot.nowUptime,
                timeout: request.timeout)
        } catch Pocket3NativeCameraProtocolError.alreadyAtTarget {
            return result(request: request, coordinator: coordinator)
        } catch let error as Pocket3NativeCameraProtocolError {
            throw map(error)
        } catch NativeCommandTransactionError.invalidTimeout {
            throw NativeCameraCaptureValidationError.invalidTimeout
        } catch {
            throw NativeCameraCaptureValidationError.invalidArguments
        }

        guard request.execute else {
            return result(request: request, coordinator: coordinator)
        }
        guard let executor else {
            _ = coordinator.blockExecution(
                reason: "native_camera_capture_executor_unavailable")
            return result(request: request, coordinator: coordinator)
        }

        do {
            // This is the sole executor invocation. There is deliberately no
            // retry or fallback transport after a partial result.
            let transaction = try await executor.execute(nativeRequest,
                readiness: snapshot.session)
            let now = transaction.finishedUptime
                ?? transaction.observedUptime ?? snapshot.nowUptime
            _ = coordinator.apply(transaction, nowUptime: now)
        } catch is CancellationError {
            _ = coordinator.apply(partial(nativeRequest, end: .cancelled,
                                           failureCode: "cancelled"),
                                  nowUptime: nil)
        } catch let error as NativeCommandTransactionError {
            let end: NativeCommandTransactionEnd = error == .staleGeneration
                ? .generationChanged : .failed
            _ = coordinator.apply(partial(nativeRequest, end: end,
                                           failureCode: captureFailureCode(error)),
                                  nowUptime: nil)
        } catch {
            _ = coordinator.apply(partial(nativeRequest, end: .failed,
                                           failureCode: "native_camera_capture_executor_failed"),
                                  nowUptime: nil)
        }
        return result(request: request, coordinator: coordinator)
    }

    private func result(
        request: NativeCameraCaptureValidationRequest,
        coordinator: Pocket3NativeCameraCaptureCoordinator
    ) -> NativeCameraCaptureValidationResult {
        let capture = coordinator.result
        return NativeCameraCaptureValidationResult(
            action: request.action, executeRequested: request.execute,
            request: coordinator.request.map(NativeCameraCaptureValidationRequestEvidence.init),
            capture: capture, sideEffect: sideEffect(for: request.target),
            phase: capture?.phase, requested: capture?.requested == true,
            submitted: capture?.submitted == true,
            acknowledged: capture?.acknowledged == true,
            observed: capture?.observed == true,
            completed: capture?.completed == true,
            noOp: capture?.noOp == true, failureCode: capture?.failureCode)
    }

    private func partial(_ request: NativeCommandTransactionRequest,
                         end: NativeCommandTransactionEnd,
                         failureCode: String)
        -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(id: request.id,
            command: request.command, generation: request.generation,
            sessionID: request.sessionID, end: end)
        result.failureCode = failureCode
        return result
    }

    private func map(_ error: Pocket3NativeCameraProtocolError)
        -> NativeCameraCaptureValidationError {
        switch error {
        case .invalidLapseConfiguration: .invalidValue
        case .unsupportedModeWrite: .invalidValue
        case .invalidModeCombination: .invalidValue
        case .invalidBaseline: .invalidBaseline
        case .sessionNotReady: .sessionNotReady
        case .missingSessionIdentity: .missingSessionIdentity
        case .alreadyAtTarget: .alreadyAtTarget
        case .operationInFlight: .operationInFlight
        case .staleTransaction: .staleTransaction
        case .invalidClock: .invalidTimeout
        }
    }

    private func captureFailureCode(_ error: NativeCommandTransactionError)
        -> String {
        switch error {
        case .invalidPayload: "native_camera_capture_invalid_payload"
        case .invalidTimeout: "native_camera_capture_invalid_timeout"
        case .commandNotReady: "native_camera_capture_command_not_ready"
        case .staleGeneration: "native_camera_capture_generation_changed"
        case .datalinkUnavailable: "native_camera_capture_datalink_unavailable"
        case .nativeBusy: "native_camera_capture_busy"
        }
    }

    private func sideEffect(
        for target: Pocket3NativeCameraCaptureOperation
    ) -> NativeCameraCaptureSideEffect {
        switch target {
        case .photoShutter, .panoramaShutter:
            return .shutterMayCreateMedia
        case .startTimelapse, .startHyperlapse, .startMotionlapse:
            return .recordingStartMayCreateMedia
        case .stopTimelapse, .stopHyperlapse, .stopMotionlapse:
            return .recordingStopMayCreateMedia
        default: return .none
        }
    }
}

public typealias Pocket3NativeCameraCaptureValidationRequest =
    NativeCameraCaptureValidationRequest
public typealias Pocket3NativeCameraCaptureValidationResult =
    NativeCameraCaptureValidationResult
public typealias Pocket3NativeCameraCaptureValidationService =
    NativeCameraCaptureValidationService
