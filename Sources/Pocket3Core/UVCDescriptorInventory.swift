import Foundation

/// Safe, descriptor-only information used to select a future UVC transport.
/// It does not open a device, interface, pipe, or control request.
public struct UVCStreamingEndpoint: Codable, Sendable, Equatable {
    public let address: UInt8
    public let transferType: UInt8
    public let maximumPacketSize: UInt16
    public var isIN: Bool { address & 0x80 != 0 }
    public var isBulk: Bool { transferType == 0x02 }
}

public struct UVCInterfaceInventory: Codable, Sendable, Equatable {
    public let number: UInt8
    public let alternateSetting: UInt8
    public let interfaceClass: UInt8
    public let interfaceSubclass: UInt8
    public let interfaceProtocol: UInt8
    public let declaredEndpointCount: UInt8
    public let endpoints: [UVCStreamingEndpoint]
    public let codecNames: [String]
    public var isVideoControl: Bool { interfaceClass == 14 && interfaceSubclass == 1 }
    public var isVideoStreaming: Bool { interfaceClass == 14 && interfaceSubclass == 2 }
}

public struct UVCDescriptorInventory: Codable, Sendable, Equatable {
    public let interfaces: [UVCInterfaceInventory]
    public var videoControlInterfaces: [UVCInterfaceInventory] { interfaces.filter(\.isVideoControl) }
    public var videoStreamingInterfaces: [UVCInterfaceInventory] { interfaces.filter(\.isVideoStreaming) }
    public var hasMJPEG: Bool { interfaces.contains { $0.codecNames.contains("MJPEG") } }
    public var hasH264: Bool { interfaces.contains { $0.codecNames.contains("H264") } }
}

public enum UVCDescriptorInventoryError: Error, Equatable, Sendable {
    case truncated(offset: Int)
    case invalidLength(offset: Int, length: Int)
    case endpointWithoutInterface(offset: Int)
}

public enum UVCDescriptorInventoryDecoder {
    private static let interfaceDescriptor: UInt8 = 0x04
    private static let endpointDescriptor: UInt8 = 0x05
    private static let classSpecificInterface: UInt8 = 0x24
    private static let mjpegFormat: UInt8 = 0x06
    private static let frameBasedFormat: UInt8 = 0x13

    /// Decodes only standard interface/endpoint descriptors and the two UVC
    /// format descriptors relevant to Pocket 3. Unknown descriptors are
    /// skipped by their declared bounded length.
    public static func decode(_ data: Data) throws -> UVCDescriptorInventory {
        let bytes = Array(data)
        var offset = 0
        var interfaces: [MutableInterface] = []
        while offset < bytes.count {
            guard bytes.count - offset >= 2 else { throw UVCDescriptorInventoryError.truncated(offset: offset) }
            let length = Int(bytes[offset])
            guard length >= 2 else { throw UVCDescriptorInventoryError.invalidLength(offset: offset, length: length) }
            guard length <= bytes.count - offset else { throw UVCDescriptorInventoryError.truncated(offset: offset) }
            let type = bytes[offset + 1]
            switch type {
            case interfaceDescriptor:
                guard length >= 9 else { throw UVCDescriptorInventoryError.invalidLength(offset: offset, length: length) }
                interfaces.append(.init(number: bytes[offset + 2], alternate: bytes[offset + 3],
                    interfaceClass: bytes[offset + 5], subclass: bytes[offset + 6], protocol: bytes[offset + 7],
                    endpointCount: bytes[offset + 4]))
            case endpointDescriptor:
                guard length >= 7 else { throw UVCDescriptorInventoryError.invalidLength(offset: offset, length: length) }
                guard !interfaces.isEmpty else { throw UVCDescriptorInventoryError.endpointWithoutInterface(offset: offset) }
                let attributes = bytes[offset + 3] & 0x03
                let size = UInt16(bytes[offset + 4]) | UInt16(bytes[offset + 5]) << 8
                interfaces[interfaces.count - 1].endpoints.append(.init(address: bytes[offset + 2], transferType: attributes,
                    maximumPacketSize: size & 0x07ff))
            case classSpecificInterface:
                guard !interfaces.isEmpty else { offset += length; continue }
                guard length >= 3 else { throw UVCDescriptorInventoryError.invalidLength(offset: offset, length: length) }
                switch bytes[offset + 2] {
                case mjpegFormat: interfaces[interfaces.count - 1].codecNames.insert("MJPEG")
                case frameBasedFormat: interfaces[interfaces.count - 1].codecNames.insert("H264")
                default: break
                }
            default: break
            }
            offset += length
        }
        return .init(interfaces: interfaces.map(\.value))
    }

    private struct MutableInterface {
        let number: UInt8
        let alternate: UInt8
        let interfaceClass: UInt8
        let subclass: UInt8
        let `protocol`: UInt8
        let endpointCount: UInt8
        var endpoints: [UVCStreamingEndpoint] = []
        var codecNames = Set<String>()
        var value: UVCInterfaceInventory {
            .init(number: number, alternateSetting: alternate, interfaceClass: interfaceClass,
                interfaceSubclass: subclass, interfaceProtocol: `protocol`, declaredEndpointCount: endpointCount,
                endpoints: endpoints, codecNames: codecNames.sorted())
        }
    }
}
