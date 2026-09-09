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
/// Only the three properties needed by WB, AF mode and AUTO EV are exposed.
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
    public let exposureMode: CameraExposureMode?
    public let transactionID: UInt32
    public let binding: ContinuousGimbalBinding
    public let receivedUptime: TimeInterval

    public func isFresh(now: TimeInterval, maximumAge: TimeInterval = 5) -> Bool {
        now.isFinite && receivedUptime.isFinite && receivedUptime >= 0 && maximumAge.isFinite && maximumAge > 0
            && now >= receivedUptime && now - receivedUptime <= maximumAge
    }

    static func decode(_ push: CameraPropertyPush, binding: ContinuousGimbalBinding, receivedUptime: TimeInterval) -> Self? {
        guard push.value.count <= DUMLCodec.maximumPayloadLength else { return nil }
        let bytes = Array(push.value)
        let value: CameraSettingValue?
        var exposureMode: CameraExposureMode?
        switch push.property {
        case .imageEffect:
            guard bytes.count >= 6 else { return nil }
            switch bytes[4] {
            case 0: value = .whiteBalance(.automatic)
            case 6:
                let kelvin = Int(bytes[5]) * 100
                value = (2000...10000).contains(kelvin) ? .whiteBalance(.customKelvin(kelvin)) : nil
            default: value = nil
            }
        case .lensState:
            guard let code = bytes.first else { return nil }
            switch code {
            case 0xb1: value = .focus(.single)
            case 0xb2: value = .focus(.continuous)
            default: value = nil
            }
        case .exposure:
            guard bytes.count >= 20 else { return nil }
            value = (0x07...0x19).contains(bytes[6]) ? .autoEV(thirdStops: Int(bytes[6]) - 0x10) : nil
            exposureMode = CameraExposureMode(rawValue: bytes[7])
        }
        return Self(property: push.property, value: value, exposureMode: exposureMode,
                    transactionID: push.transactionID, binding: binding, receivedUptime: receivedUptime)
    }
}
