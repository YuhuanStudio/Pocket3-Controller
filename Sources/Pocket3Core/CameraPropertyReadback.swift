import Foundation

public enum CameraPropertyCodecError: Error, Equatable, Sendable {
    case invalidSize, malformedLayout, invalidName
}
public struct CameraPropertyPush: Sendable, Equatable {
    public let property: CameraSettingsProperty
    /// Preserved wire metadata. Echo/correlation with setter sequence is not
    /// established by the pinned source and is never assumed here.
    public let transactionID: UInt32
    public let value: Data
}

/// 00/99 named-property records, based on fixed Kaze captures and decoder facts.
/// Provenance: research/2026-09-08/camera-settings/PROVENANCE.md.
/// The property name is restricted to the complete read-only allowlist.  The
/// value decoder separately enforces each property's capture-confirmed size.
public enum CameraPropertyCodec {
    public static func subscription(_ property: CameraSettingsProperty, transactionID: UInt32, sequence: UInt16) -> DUMLFrame {
        let name = Array(property.rawValue.utf8)
        var bytes: [UInt8] = [2,2,0,0]
        append32(transactionID, to: &bytes)
        bytes += [0,0,0]
        append16(UInt16(name.count + 6), to: &bytes)
        append16(UInt16(name.count), to: &bytes)
        bytes += name; bytes += [0,0,0,0]
        return DUMLFrame(source: 0x02, destination: 0x28, sequence: sequence, flags: 0x40,
                         commandSet: 0x00, commandID: 0x99, payload: Data(bytes))
    }

    public static func decodeFrame(_ data: Data) throws -> CameraPropertyPush? {
        try decodePush(from: DUMLCodec.decode(data))
    }
    /// Accepts an already CRC-validated frame. Live callers must separately
    /// validate transport peer/session binding and any established reply route.
    /// No unknown incoming sender or flags mapping is guessed from the payload.
    public static func decodePush(from frame: DUMLFrame) throws -> CameraPropertyPush? {
        guard frame.commandSet == 0x00, frame.commandID == 0x99 else { return nil }
        return try decodePayload(frame.payload)
    }
    public static func decodePayload(_ data: Data) throws -> CameraPropertyPush? {
        guard data.count <= DUMLCodec.maximumPayloadLength else { throw CameraPropertyCodecError.invalidSize }
        guard data.count >= 4 else { throw CameraPropertyCodecError.malformedLayout }
        let bytes = Array(data) // Normalize Data slices before indexed access.
        guard Array(bytes.prefix(4)) == [2,6,0,0] else { return nil }
        guard bytes.count >= 23 else { throw CameraPropertyCodecError.malformedLayout }
        let nameLength = Int(read16(bytes, 13)), nameStart = 15
        guard nameLength > 0, nameLength <= bytes.count - nameStart - 8 else { throw CameraPropertyCodecError.malformedLayout }
        let nameEnd = nameStart + nameLength
        let nameBytes = bytes[nameStart..<nameEnd]
        guard nameBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { throw CameraPropertyCodecError.invalidName }
        let valueStart = nameEnd + 8, valueLength = Int(read16(bytes, nameEnd + 6))
        guard valueLength <= bytes.count - valueStart else { throw CameraPropertyCodecError.malformedLayout }
        guard let property = CameraSettingsProperty(rawValue: String(decoding: nameBytes, as: UTF8.self)) else { return nil }
        return CameraPropertyPush(property: property, transactionID: read32(bytes, 4),
                                  value: Data(bytes[valueStart..<(valueStart + valueLength)]))
    }

    private static func append16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes += [UInt8(value & 0xff), UInt8(value >> 8)]
    }
    private static func append32(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes += [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]
    }
    private static func read16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    private static func read32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}

public struct CameraSettingsObservation: Codable, Sendable, Equatable {
    public let property: CameraSettingsProperty
    /// Nil means an unrecognized setting code, not an optimistic requested value.
    public let value: CameraSettingValue?
    /// Typed readback for both writer-backed and read-only properties.  The
    /// associated value retains the complete raw property bytes and any
    /// unknown enum codes.
    public let readOnlyValue: CameraReadOnlyValue?
    public let exposureMode: CameraExposureMode?
    public let transactionID: UInt32
    public let binding: ContinuousGimbalBinding
    public let receivedUptime: TimeInterval

    /// Backwards-compatible initializer for callers that only know the
    /// original writer-backed value API.
    public init(property: CameraSettingsProperty, value: CameraSettingValue?,
                exposureMode: CameraExposureMode?, transactionID: UInt32,
                binding: ContinuousGimbalBinding, receivedUptime: TimeInterval) {
        self.init(property: property, value: value, readOnlyValue: nil,
                  exposureMode: exposureMode, transactionID: transactionID,
                  binding: binding, receivedUptime: receivedUptime)
    }

    public init(property: CameraSettingsProperty, value: CameraSettingValue?,
                readOnlyValue: CameraReadOnlyValue?, exposureMode: CameraExposureMode?,
                transactionID: UInt32, binding: ContinuousGimbalBinding,
                receivedUptime: TimeInterval) {
        self.property = property
        self.value = value
        self.readOnlyValue = readOnlyValue
        self.exposureMode = exposureMode
        self.transactionID = transactionID
        self.binding = binding
        self.receivedUptime = receivedUptime
    }

    public func isFresh(now: TimeInterval, maximumAge: TimeInterval = 5) -> Bool {
        now.isFinite && receivedUptime.isFinite && receivedUptime >= 0 && maximumAge.isFinite && maximumAge > 0
            && now >= receivedUptime && now - receivedUptime <= maximumAge
    }

    static func decode(_ push: CameraPropertyPush, binding: ContinuousGimbalBinding, receivedUptime: TimeInterval) -> Self? {
        guard push.value.count <= DUMLCodec.maximumPayloadLength else { return nil }
        let readOnlyValue = CameraReadOnlyPropertyDecoder.decode(push.property, value: push.value)
        guard let readOnlyValue else { return nil }
        let value: CameraSettingValue?
        var exposureMode: CameraExposureMode?
        switch readOnlyValue {
        case .imageEffect(let observation):
            if let balance = observation.whiteBalance { value = .whiteBalance(balance) }
            else { value = nil }
        case .lensState(let observation):
            if let focus = observation.focusMode { value = .focus(focus) }
            else { value = nil }
        case .exposure(let observation):
            if let thirds = observation.evThirdStops { value = .autoEV(thirdStops: thirds) }
            else { value = nil }
            exposureMode = observation.exposureMode
        default:
            value = nil
        }
        return Self(property: push.property, value: value, readOnlyValue: readOnlyValue,
                    exposureMode: exposureMode,
                    transactionID: push.transactionID, binding: binding, receivedUptime: receivedUptime)
    }
}
