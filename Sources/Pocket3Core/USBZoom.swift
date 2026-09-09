import Foundation

/// Device-advertised UVC raw values. No zoom ratio or optical calibration is
/// implied by a current value, range, or resolution.
public struct USBZoomCapabilities: Codable, Sendable, Equatable {
    public var current: Int
    public var minimum: Int?
    public var maximum: Int?
    public var step: Int?
    public var writable: Bool
    public init(current: Int, minimum: Int?, maximum: Int?, step: Int?, writable: Bool) {
        self.current = current; self.minimum = minimum; self.maximum = maximum
        self.step = step; self.writable = writable
    }
}

public struct USBZoomResult: Codable, Sendable {
    public let target: Int
    public let observed: Int
    public let accepted: Bool
    public let completed: Bool
    public let verified: Bool
    public let verification: String
    public let capabilities: USBZoomCapabilities
    public let message: String
    /// Optional for compatibility with older saved replies. New verification
    /// replies always report their actual raw tolerance and observation window.
    public let toleranceRaw: Int?
    public let sampleCount: Int?
    public let stableDurationSeconds: TimeInterval?

    public init(target: Int, observed: Int, accepted: Bool, completed: Bool, verified: Bool,
                verification: String, capabilities: USBZoomCapabilities, message: String,
                toleranceRaw: Int? = nil, sampleCount: Int? = nil, stableDurationSeconds: TimeInterval? = nil) {
        self.target = target; self.observed = observed; self.accepted = accepted
        self.completed = completed; self.verified = verified; self.verification = verification
        self.capabilities = capabilities; self.message = message; self.toleranceRaw = toleranceRaw
        self.sampleCount = sampleCount; self.stableDurationSeconds = stableDurationSeconds
    }
}

enum USBZoomPolicy {
    /// No inferred precision: absent/zero step means exact equality. The
    /// integer floor prevents a tolerance from exceeding 1% of the raw range.
    static func readbackTolerance(capabilities: USBZoomCapabilities) -> Int {
        guard let low = capabilities.minimum, let high = capabilities.maximum,
              let step = capabilities.step, (0...65535).contains(low), (0...65535).contains(high),
              low < high, (1...65535).contains(step) else { return 0 }
        return min(step, (high - low) / 100)
    }
    static func rawValue(_ number: Double) throws -> Int {
        guard number.isFinite, (0...65535).contains(number), number.rounded() == number else {
            throw BridgeFailure("invalid_zoom_value", "縮放須為 0–65535 的整數 UVC 原始值")
        }
        return Int(number)
    }
    static func validate(_ rawValue: Int, capabilities: USBZoomCapabilities) throws {
        guard capabilities.writable else { throw BridgeFailure("uvc_zoom_read_only", "相機的 USB 縮放控制不可寫入") }
        guard let low = capabilities.minimum, let high = capabilities.maximum,
              (0...65535).contains(low), (0...65535).contains(high), low <= high,
              capabilities.step == nil || (0...65535).contains(capabilities.step!) else {
            throw BridgeFailure("uvc_zoom_limits_unavailable", "相機尚未提供有效的 USB 縮放範圍")
        }
        guard (low...high).contains(rawValue) else { throw BridgeFailure("uvc_zoom_out_of_range", "縮放值超出相機宣告的範圍") }
        if let step = capabilities.step, step > 0, !(rawValue - low).isMultiple(of: step) {
            throw BridgeFailure("uvc_zoom_step_mismatch", "縮放值不符合相機宣告的步進")
        }
    }
}

/// A bounded settled window, not a sum of small adjacent differences. Samples
/// must be in target±tolerance AND their entire window span <= tolerance.
/// This accepts the measured 147→146 quantization shift (step1/range300), while
/// a continuing ramp cannot accumulate several individually small deviations.
struct USBZoomReadbackVerifier: Sendable {
    let target: Int
    let toleranceRaw: Int
    private let minimum: Int?
    private let maximum: Int?
    private let step: Int?
    private let minimumDuration: TimeInterval
    private var lastTime: TimeInterval?
    private var windowStart: TimeInterval?
    private var lowest = 0, highest = 0
    private(set) var sampleCount = 0
    private(set) var stableSampleCount = 0
    private(set) var stableDurationSeconds: TimeInterval = 0

    init(target: Int, capabilities: USBZoomCapabilities, minimumDuration: TimeInterval = 0.20) throws {
        try USBZoomPolicy.validate(target, capabilities: capabilities)
        guard minimumDuration.isFinite, minimumDuration >= 0 else { throw BridgeFailure("zoom_verification_time", "縮放驗證時間無效") }
        self.target = target; toleranceRaw = USBZoomPolicy.readbackTolerance(capabilities: capabilities)
        minimum = capabilities.minimum; maximum = capabilities.maximum; step = capabilities.step
        self.minimumDuration = minimumDuration
    }

    mutating func observe(_ capabilities: USBZoomCapabilities, at time: TimeInterval) throws -> Bool {
        guard time.isFinite, lastTime == nil || time > lastTime! else { throw BridgeFailure("zoom_feedback_stale", "縮放回讀時間沒有前進") }
        guard capabilities.minimum == minimum, capabilities.maximum == maximum, capabilities.step == step,
              capabilities.writable, let low = minimum, let high = maximum,
              (low...high).contains(capabilities.current) else { throw BridgeFailure("zoom_capabilities_changed", "縮放能力或回讀已改變") }
        lastTime = time; sampleCount += 1
        let current = capabilities.current
        guard abs(current - target) <= toleranceRaw else {
            windowStart = nil; stableSampleCount = 0; stableDurationSeconds = 0
            return false
        }
        if windowStart == nil || max(highest, current) - min(lowest, current) > toleranceRaw {
            windowStart = time; lowest = current; highest = current; stableSampleCount = 1
        } else {
            lowest = min(lowest, current); highest = max(highest, current); stableSampleCount += 1
        }
        stableDurationSeconds = time - windowStart!
        return stableSampleCount >= 3 && stableDurationSeconds + 1e-9 >= minimumDuration
    }
}
