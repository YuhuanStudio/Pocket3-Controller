import Foundation

/// Signed 16-bit UVC raw roll values. No physical-angle calibration is implied.
public struct USBRollCapabilities: Codable, Sendable, Equatable {
    public var current: Int
    public var minimum: Int?
    public var maximum: Int?
    public var step: Int?
    public var defaultValue: Int?
    public var writable: Bool
    public init(current: Int, minimum: Int?, maximum: Int?, step: Int?, defaultValue: Int?, writable: Bool) {
        self.current = current; self.minimum = minimum; self.maximum = maximum
        self.step = step; self.defaultValue = defaultValue; self.writable = writable
    }
}

/// Narrow release admission profile backed by the reviewed Pocket 3 moving
/// Roll Stop evidence. It describes the USB identity and raw control shape;
/// it does not calibrate a physical angle or direction.
public struct USBRollReleaseCapabilityProfile: Codable, Sendable,
    Equatable, Hashable, Identifiable {
    public let id: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let uvcVersion: Int
    public let rollMinimum: Int
    public let rollMaximum: Int
    public let rollStep: Int
    public let rollDefault: Int

    public init(id: String, vendorID: UInt16, productID: UInt16,
                uvcVersion: Int, rollMinimum: Int, rollMaximum: Int,
                rollStep: Int, rollDefault: Int) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.uvcVersion = uvcVersion
        self.rollMinimum = rollMinimum
        self.rollMaximum = rollMaximum
        self.rollStep = rollStep
        self.rollDefault = rollDefault
    }

    /// The exact VID/PID, UVC bcdVersion and signed Roll shape from the
    /// completed development acceptance evidence.
    public static let pocket3Verified = Self(
        id: "pocket3-usb-roll-stop-v1", vendorID: 0x2CA3,
        productID: 0x0023, uvcVersion: 0x0100,
        rollMinimum: -30, rollMaximum: 30, rollStep: 1,
        rollDefault: 0)

    public var rawUnitsDescription: String {
        "signed UVC raw units; physical Roll angle and direction remain unknown"
    }

    public func matchesIdentity(deviceID: String, uvcVersion: Int) -> Bool {
        guard let identity = Self.vendorProduct(from: deviceID) else {
            return false
        }
        return identity.vendorID == vendorID &&
            identity.productID == productID && uvcVersion == self.uvcVersion
    }

    public func matches(deviceID: String, uvcVersion: Int,
                        capabilities: USBRollCapabilities) -> Bool {
        guard matchesIdentity(deviceID: deviceID, uvcVersion: uvcVersion),
              let identity = Self.vendorProduct(from: deviceID) else {
            return false
        }
        return matches(vendorID: identity.vendorID, productID: identity.productID,
                       uvcVersion: uvcVersion, capabilities: capabilities)
    }

    public func matches(vendorID: UInt16, productID: UInt16,
                        uvcVersion: Int,
                        capabilities: USBRollCapabilities) -> Bool {
        guard vendorID == self.vendorID, productID == self.productID,
              uvcVersion == self.uvcVersion,
              capabilities.writable,
              capabilities.minimum == rollMinimum,
              capabilities.maximum == rollMaximum,
              capabilities.step == rollStep,
              capabilities.defaultValue == rollDefault,
              (rollMinimum...rollMaximum).contains(capabilities.current) else {
            return false
        }
        return true
    }

    public static func vendorProduct(from deviceID: String)
        -> (vendorID: UInt16, productID: UInt16)? {
        guard deviceID.hasPrefix("0x"),
              let raw = UInt64(deviceID.dropFirst(), radix: 16) else {
            return nil
        }
        let usbIdentity = UInt32(truncatingIfNeeded: raw)
        return (vendorID: UInt16((usbIdentity >> 16) & 0xffff),
                productID: UInt16(usbIdentity & 0xffff))
    }
}

public typealias Pocket3USBRollReleaseProfile = USBRollReleaseCapabilityProfile

public struct USBRollResult: Codable, Sendable, Equatable {
    public let target: Int
    public let observed: Int
    public let accepted: Bool
    public let completed: Bool
    public let verified: Bool
    public let verification: String
    public let capabilities: USBRollCapabilities
    public let message: String
    public let toleranceRaw: Int
    public let sampleCount: Int
    public let stableDurationSeconds: TimeInterval
    public init(target: Int, observed: Int, accepted: Bool, completed: Bool, verified: Bool,
                verification: String, capabilities: USBRollCapabilities, message: String,
                sampleCount: Int = 0, stableDurationSeconds: TimeInterval = 0) {
        self.target = target; self.observed = observed; self.accepted = accepted
        self.completed = completed; self.verified = verified; self.verification = verification
        self.capabilities = capabilities; self.message = message; toleranceRaw = 0
        self.sampleCount = sampleCount; self.stableDurationSeconds = stableDurationSeconds
    }
}

enum USBRollPolicy {
    static let rawRange = Int(Int16.min)...Int(Int16.max)
    static func arguments(_ arguments: JSONValue, requiresValue: Bool) throws -> (rawValue: Int?, sessionID: String?) {
        guard case .object(let fields) = arguments,
              Set(fields.keys).isSubset(of: requiresValue ? ["rawValue", "expectedSessionID"] : ["expectedSessionID"]) else {
            throw BridgeFailure("invalid_roll_arguments", "Roll 不接受額外參數或非物件參數")
        }
        let sessionID: String?
        if let value = fields["expectedSessionID"] {
            guard let string = value.string, !string.isEmpty else { throw BridgeFailure("session_required", "請提供非空 expectedSessionID") }
            sessionID = string
        } else { sessionID = nil }
        guard requiresValue else { return (nil, sessionID) }
        guard let number = fields["rawValue"]?.number else { throw BridgeFailure("invalid_roll_value", "請提供整數 Roll rawValue") }
        let raw = try rawValue(number)
        guard sessionID != nil else { throw BridgeFailure("session_required", "請提供目前相機的 expectedSessionID") }
        return (raw, sessionID)
    }
    static func rawValue(_ number: Double) throws -> Int {
        guard number.isFinite, number.rounded() == number,
              number >= Double(Int16.min), number <= Double(Int16.max) else {
            throw BridgeFailure("invalid_roll_value", "Roll 須為 signed-16 整數原始值，不接受小數或截斷")
        }
        return Int(number)
    }
    static func validate(_ rawValue: Int, capabilities: USBRollCapabilities) throws {
        guard capabilities.writable else { throw BridgeFailure("uvc_roll_read_only", "此 USB Roll 控制不可寫入") }
        guard let low = capabilities.minimum, let high = capabilities.maximum,
              rawRange.contains(low), rawRange.contains(high), low <= high,
              rawRange.contains(capabilities.current), (low...high).contains(capabilities.current),
              capabilities.defaultValue == nil || (rawRange.contains(capabilities.defaultValue!) && (low...high).contains(capabilities.defaultValue!)) else {
            throw BridgeFailure("uvc_roll_limits_unavailable", "裝置未提供有效的 Roll 原始值範圍或回讀")
        }
        guard let step = capabilities.step, (1...Int(Int16.max)).contains(step) else {
            throw BridgeFailure("uvc_roll_step_unavailable", "裝置未提供有效的 Roll 正值步進")
        }
        guard rawRange.contains(rawValue), (low...high).contains(rawValue) else {
            throw BridgeFailure("uvc_roll_out_of_range", "Roll 原始值超出裝置宣告範圍")
        }
        guard (rawValue - low).isMultiple(of: step) else {
            throw BridgeFailure("uvc_roll_step_mismatch", "Roll 原始值不符合裝置步進，不會自動取整")
        }
    }
    static func authorize(origin: RequestOrigin, access: AccessMode, rollStopValidated: Bool) throws {
        guard origin == .manual || access == .control else { throw BridgeFailure("roll_denied", "請在 App 開放 AI 控制權限") }
        guard origin == .manual || rollStopValidated else {
            throw BridgeFailure("roll_not_validated", "Roll 尚未完成獨立的移動中停止實機驗證；Pan/Tilt 驗證不代表 Roll 已通過")
        }
    }
}

struct USBRollReadbackVerifier: Sendable {
    let target: Int
    private let baseline: USBRollCapabilities
    private let minimumDuration: TimeInterval
    private var lastTime: TimeInterval?
    private var windowStart: TimeInterval?
    private var stableSamples = 0
    private(set) var sampleCount = 0
    private(set) var stableDurationSeconds: TimeInterval = 0
    init(target: Int, capabilities: USBRollCapabilities, minimumDuration: TimeInterval = 0.2) throws {
        try USBRollPolicy.validate(target, capabilities: capabilities)
        guard minimumDuration.isFinite, minimumDuration >= 0 else { throw BridgeFailure("roll_verification_time", "Roll 驗證時間無效") }
        self.target = target; baseline = capabilities; self.minimumDuration = minimumDuration
    }
    mutating func observe(_ capabilities: USBRollCapabilities, at time: TimeInterval) throws -> Bool {
        guard time.isFinite, lastTime == nil || time > lastTime! else { throw BridgeFailure("roll_feedback_stale", "Roll 回讀時間沒有前進") }
        guard capabilities.minimum == baseline.minimum, capabilities.maximum == baseline.maximum,
              capabilities.step == baseline.step, capabilities.defaultValue == baseline.defaultValue,
              capabilities.writable, let low = baseline.minimum, let high = baseline.maximum,
              (low...high).contains(capabilities.current) else {
            throw BridgeFailure("roll_capabilities_changed", "Roll 能力或回讀已改變")
        }
        lastTime = time; sampleCount += 1
        guard capabilities.current == target else {
            windowStart = nil; stableSamples = 0; stableDurationSeconds = 0
            return false
        }
        if windowStart == nil { windowStart = time }
        stableSamples += 1; stableDurationSeconds = time - windowStart!
        return stableSamples >= 3 && stableDurationSeconds + 1e-9 >= minimumDuration
    }
}

/// Exactly one SET followed by bounded reads; never resends an uncertain SET.
/// The service owns its pending-hold marker and retains it across errors.
enum USBRollSetOperation {
    static func perform(rawValue: Int, before: USBRollCapabilities, permit: OperationPermit,
        validate: @escaping @Sendable () async throws -> Void,
        read: @escaping @Sendable () async throws -> USBRollCapabilities,
        write: @escaping @Sendable (Int, TimeInterval, OperationPermit) async throws -> Void,
        clock: any ContinuousGimbalClock = SystemContinuousGimbalClock()) async throws -> USBRollResult {
        var verifier = try USBRollReadbackVerifier(target: rawValue, capabilities: before)
        try Task.checkCancellation(); try await validate(); try permit.perform {}
        let writeStarted = clock.now
        guard writeStarted.isFinite else { throw BridgeFailure("roll_timing", "Roll 時間無效") }
        try await write(rawValue, writeStarted + 0.25, permit)
        let deadline = writeStarted + 3
        var observed = before
        for _ in 0..<40 {
            try Task.checkCancellation(); try await validate()
            try await clock.sleep(until: clock.now + 0.08)
            guard clock.now.isFinite, clock.now >= writeStarted, clock.now <= deadline else { break }
            let readStarted = clock.now
            observed = try await read()
            try Task.checkCancellation(); try await validate()
            guard clock.now.isFinite, clock.now >= readStarted, clock.now - readStarted <= 0.10,
                  clock.now <= deadline else { throw BridgeFailure("roll_feedback_stale", "Roll 回讀已過期") }
            if try verifier.observe(observed, at: readStarted) {
                return USBRollResult(target: rawValue, observed: observed.current, accepted: true, completed: true, verified: true,
                    verification: "stable_exact_uvc_roll_raw_readback", capabilities: observed,
                    message: "Roll 原始值已精確回讀並穩定；未校準物理角度或驗證移動中停止",
                    sampleCount: verifier.sampleCount, stableDurationSeconds: verifier.stableDurationSeconds)
            }
        }
        return USBRollResult(target: rawValue, observed: observed.current, accepted: true, completed: false, verified: false,
            verification: "uvc_roll_raw_readback_unconfirmed", capabilities: observed,
            message: "Roll 目標已送出，但精確穩定回讀未確認，請勿自動重送",
            sampleCount: verifier.sampleCount, stableDurationSeconds: verifier.stableDurationSeconds)
    }
}
