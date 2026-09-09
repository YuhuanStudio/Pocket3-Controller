import Foundation

/// Candidate fields from cam_lens_state, not a calibrated preview point or
/// evidence that an autofocus operation succeeded. See docs/FOCUS_READBACK.md.
public struct LensPointCandidate: Codable, Sendable, Equatable {
    public enum Calibration: String, Codable, Sendable {
        case unverified = "unverified_dji_normalized_candidate"
    }
    public let rawModeCode: UInt8
    public let xCandidate: Double
    public let yCandidate: Double
    public let valueLength: Int
    public let valuePrefixHex: String
    public let calibration: Calibration

    /// The schema needs nine bytes, not exactly the upstream capture's 67.
    /// Preserve the original length and only the necessary nine-byte prefix.
    public static func decode(_ value: Data) -> Self? {
        make(prefix: Array(value.prefix(9)), valueLength: value.count)
    }

    private static func make(prefix: [UInt8], valueLength: Int) -> Self? {
        guard prefix.count == 9, (9...DUMLCodec.maximumPayloadLength).contains(valueLength) else { return nil }
        func float(_ offset: Int) -> Double {
            let bits = UInt32(prefix[offset]) | UInt32(prefix[offset + 1]) << 8
                | UInt32(prefix[offset + 2]) << 16 | UInt32(prefix[offset + 3]) << 24
            return Double(Float(bitPattern: bits))
        }
        let x = float(1), y = float(5)
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        return Self(rawModeCode: prefix[0], xCandidate: x, yCandidate: y,
                    valueLength: valueLength, valuePrefixHex: prefix.map { String(format: "%02x", $0) }.joined(),
                    calibration: .unverified)
    }

    private init(rawModeCode: UInt8, xCandidate: Double, yCandidate: Double,
                 valueLength: Int, valuePrefixHex: String, calibration: Calibration) {
        self.rawModeCode = rawModeCode; self.xCandidate = xCandidate; self.yCandidate = yCandidate
        self.valueLength = valueLength; self.valuePrefixHex = valuePrefixHex; self.calibration = calibration
    }

    private enum CodingKeys: String, CodingKey {
        case rawModeCode, xCandidate, yCandidate, valueLength, valuePrefixHex, calibration
    }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let hex = try fields.decode(String.self, forKey: .valuePrefixHex)
        let text = Array(hex.utf8)
        guard text.count == 18, text.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DecodingError.dataCorruptedError(forKey: .valuePrefixHex, in: fields, debugDescription: "Expected nine lowercase hexadecimal bytes")
        }
        let bytes = stride(from: 0, to: text.count, by: 2).compactMap {
            UInt8(String(decoding: text[$0..<($0 + 2)], as: UTF8.self), radix: 16)
        }
        guard let value = Self.make(prefix: bytes, valueLength: try fields.decode(Int.self, forKey: .valueLength)),
              value.rawModeCode == (try fields.decode(UInt8.self, forKey: .rawModeCode)),
              value.xCandidate == (try fields.decode(Double.self, forKey: .xCandidate)),
              value.yCandidate == (try fields.decode(Double.self, forKey: .yCandidate)),
              try fields.decode(Calibration.self, forKey: .calibration) == .unverified else {
            throw DecodingError.dataCorruptedError(forKey: .valuePrefixHex, in: fields, debugDescription: "Invalid or inconsistent lens-point candidate")
        }
        self = value
    }
}

/// Read-only data belonging to one explicitly paired Bluetooth peer/session.
/// Host receipt freshness does not associate the peer with a USB camera.
public struct BluetoothFocusPointObservation: Codable, Sendable, Equatable {
    public static let maximumAge: TimeInterval = 5
    public let sessionID: UUID
    public let peripheralID: UUID
    public let sequence: UInt16
    public let propertyTransactionID: UInt32
    public let candidate: LensPointCandidate
    public let hostReceivedAt: Date
    public let receivedUptime: TimeInterval

    public func isFresh(sessionID: UUID, peripheralID: UUID?, paired: Bool, nowUptime: TimeInterval) -> Bool {
        paired && self.sessionID == sessionID && self.peripheralID == peripheralID
            && hostReceivedAt.timeIntervalSinceReferenceDate.isFinite
            && receivedUptime.isFinite && receivedUptime >= 0
            && nowUptime.isFinite && nowUptime >= receivedUptime
            && nowUptime - receivedUptime <= Self.maximumAge
    }
}
