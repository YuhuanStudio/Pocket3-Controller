import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: JSONEncoder().encode(self))
    }
    public var pretty: String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: e.encode(self), encoding: .utf8)) ?? "null"
    }
}

public struct BridgeFailure: Error, Codable, Sendable, LocalizedError, Equatable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public init(_ code: String, _ message: String, retryable: Bool = false) { self.code = code; self.message = message; self.retryable = retryable }
    public var errorDescription: String? { message }
}
public struct CameraDevice: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var location: UInt32?
    public init(id: String, name: String, location: UInt32?) { self.id = id; self.name = name; self.location = location }
    public static func location(from uniqueID: String) -> UInt32? {
        guard uniqueID.hasPrefix("0x"), let raw = UInt64(uniqueID.dropFirst(2), radix: 16), raw & 0xffffffff == 0x2ca30023 else { return nil }
        return UInt32(truncatingIfNeeded: raw >> 32)
    }
}
public struct GimbalPosition: Codable, Sendable, Equatable {
    public var pan: Int32
    public var tilt: Int32
    public init(pan: Int32, tilt: Int32) { self.pan = pan; self.tilt = tilt }
    public func distance(to other: Self) -> Int64 { max(abs(Int64(pan)-Int64(other.pan)), abs(Int64(tilt)-Int64(other.tilt))) }
}
public struct UVCCapabilities: Codable, Sendable {
    public var location: UInt32
    public var position: GimbalPosition
    public var minimum: GimbalPosition?
    public var maximum: GimbalPosition?
    public var step: GimbalPosition?
    public var writable: Bool
    public var controls: [String]
    public var uvcVersion: Int
    public var registryID: String?
    public var bootSessionID: String?
    public var defaultPosition: GimbalPosition? = nil
}
public enum AccessMode: String, Codable, Sendable, CaseIterable {
    case manual, observe, control
    public var title: String { switch self { case .manual: "Manual only"; case .observe: "Observe only"; case .control: "Observe and move" } }
}
public enum RequestOrigin: Sendable { case manual, automation }
public struct FrameInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sessionID: String
    public var deviceID: String
    public var receivedAt: Date
    public var receivedUptime: Double
    public var presentationTime: Double
    public var width: Int
    public var height: Int
    public var timestampSource: String = "host_callback_and_avfoundation_pts"
    public var mirrored: Bool = false
    public var rotationDegrees: Int = 0
    public var sourceWidth: Int?
    public var sourceHeight: Int?
    /// Observed on AVCaptureConnection's video input port, before output conversion.
    public var inputPixelFormat: CapturePixelFormat? = nil
    public var inputPixelFormatFourCC: String? = nil
    /// The delivered representation, for example BGRA for buffers or JPEG for snapshots.
    public var outputPixelFormat: String? = nil
}
public struct MotionResult: Codable, Sendable {
    public var id: String
    public var accepted: Bool
    public var completed: Bool
    public var verified: Bool
    public var verification: String
    public var target: GimbalPosition?
    public var observed: GimbalPosition?
    public var message: String
    public var nativeStop: NativeControlStopStatus? = nil
    public var zoomStop: USBZoomStopResult? = nil
    public var rollStop: USBRollStopResult? = nil
    public init(id: String = UUID().uuidString, accepted: Bool, completed: Bool, verified: Bool, verification: String, target: GimbalPosition?, observed: GimbalPosition?, message: String, nativeStop: NativeControlStopStatus? = nil, zoomStop: USBZoomStopResult? = nil, rollStop: USBRollStopResult? = nil) {
        self.id = id; self.accepted = accepted; self.completed = completed; self.verified = verified
        self.verification = verification; self.target = target; self.observed = observed; self.message = message
        self.nativeStop = nativeStop
        self.zoomStop = zoomStop
        self.rollStop = rollStop
    }

}
public struct Activity: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var time = Date()
    public var operation: String
    public var message: String
    public var isError = false
    /// Optional structured event for App localization. Original diagnostic
    /// prose is retained independently; older records omit this field.
    public var presentationKey: String? = nil
    public init(_ operation: String, _ message: String, isError: Bool = false, presentationKey: String? = nil) {
        self.operation = operation; self.message = message; self.isError = isError; self.presentationKey = presentationKey
    }
}
/// Self-reported transport metadata for display only; it grants no permissions.
public enum ServiceRequestSource: String, Codable, Sendable { case mcp }
public struct ServiceRequest: Codable, Sendable {
    public var version = 1
    public var id = UUID().uuidString
    public var token: String
    public var operation: String
    public var arguments: JSONValue
    public var source: ServiceRequestSource?
    public init(token: String, operation: String, arguments: JSONValue = .object([:]), source: ServiceRequestSource? = nil) { self.token = token; self.operation = operation; self.arguments = arguments; self.source = source }
}
public struct ServiceReply: Codable, Sendable {
    public var version = 1
    public var id: String
    public var result: JSONValue?
    public var imageJPEG: Data?
    public var error: BridgeFailure?
    public init(id: String, result: JSONValue? = nil, imageJPEG: Data? = nil, error: BridgeFailure? = nil) { self.id = id; self.result = result; self.imageJPEG = imageJPEG; self.error = error }
}
