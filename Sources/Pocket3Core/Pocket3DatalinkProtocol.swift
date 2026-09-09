import Foundation

/// Pocket 3-specific constants from the pinned Kaze capture reference. This
/// code constructs packets only; it neither pairs nor opens network sockets.
enum Pocket3DatalinkProtocol {
    static let appPresence = Data([0x17, 0x00, 0x46, 0x23, 0x7c, 0x41, 0x50, 0x50, 0, 0, 0, 0, 0, 2])
    static let heartbeat = Data([1, 4, 5])
    static let initialization = Data([5, 0xff, 0xff, 0xff, 0xff])
    static var appDeviceInfo: Data {
        var bytes = [UInt8](repeating: 0, count: 62)
        bytes[1] = 0x41; bytes[2] = 0x50; bytes[3] = 0x50
        bytes[41] = 2; bytes[50] = 2; bytes[51] = 8
        return Data(bytes)
    }
    static func handshake(baseSequence: UInt16) -> Data {
        var bytes: [UInt8] = [0, 0, 0x64, 0, 0x64, 0, 0xc0, 5, 0x14, 0, 0, 0x64, 0, 0, 1, 0x90,
                             1, 0xc0, 5, 0x14, 0, 0, 0x64, 0, 0x14, 0, 0x64, 0, 0xc0, 5, 0x14, 0,
                             0, 0x64, 0, 1, 1, 4, 1, 2]
        bytes[0] = UInt8(baseSequence & 0xff); bytes[1] = UInt8(baseSequence >> 8)
        return Data(bytes)
    }
    static func pairingFrame(clientIdentifier: String) throws -> Data {
        let identifier = Array(clientIdentifier.utf8)
        guard !identifier.isEmpty, identifier.count <= 128, identifier.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw BridgeFailure("native_identifier", "無線連接識別碼無效")
        }
        var payload = Data([UInt8(identifier.count)]); payload.append(contentsOf: identifier)
        payload.append(contentsOf: [4, 0x6f, 0x73, 0x6d, 0x6f])
        return try DUMLCodec.encode(DUMLFrame(source: 2, destination: 7, sequence: 0x8092,
            flags: 0x40, commandSet: 7, commandID: 0x45, payload: payload))
    }

    /// Compatibility extraction is confined to validated non-video type 03/05
    /// packets. The reference scans all bytes, including video; this version
    /// never does that. Header/routing variations are not assigned new fields.
    static func controlFrames(in datagram: DJIUDPDatagram) -> [DUMLFrame] {
        guard datagram.quality.permitsStateUpdates,
              datagram.header.packetType == .channel3 || datagram.header.packetType == .command else { return [] }
        let bytes = Array(datagram.payload)
        var found: [DUMLFrame] = [], offset = 0, candidates = 0
        while offset + DUMLCodec.minimumFrameLength <= bytes.count && found.count < 32 && candidates < 128 {
            guard bytes[offset] == 0x55 else { offset += 1; continue }
            let length = Int(bytes[offset + 1]) | (Int(bytes[offset + 2] & 3) << 8)
            guard bytes[offset + 2] >> 2 == 1, (13...1023).contains(length), length <= bytes.count - offset else { offset += 1; continue }
            candidates += 1
            guard let frame = try? DUMLCodec.decode(Data(bytes[offset..<(offset + length)])) else { offset += 1; continue }
            found.append(frame); offset += length // Do not recursively interpret a validated frame's payload.
        }
        return found
    }
}
