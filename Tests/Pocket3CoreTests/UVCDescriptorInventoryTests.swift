import Foundation
import Testing
@testable import Pocket3Core

@Suite struct UVCDescriptorInventoryTests {
    private let control: [UInt8] = [9, 4, 0, 0, 0, 14, 1, 0, 0]
    private let stream: [UInt8] = [9, 4, 1, 0, 1, 14, 2, 0, 0]
    private let bulkIN: [UInt8] = [7, 5, 0x82, 2, 0, 2, 0]

    @Test func pocket3StyleDescriptorFindsVCVSCodecsAndBulkEndpoint() throws {
        let mjpeg: [UInt8] = [4, 0x24, 0x06, 1]
        let h264: [UInt8] = [4, 0x24, 0x13, 2]
        let inventory = try UVCDescriptorInventoryDecoder.decode(Data(control + stream + mjpeg + h264 + bulkIN))
        #expect(inventory.videoControlInterfaces.map(\.number) == [0])
        let vs = try #require(inventory.videoStreamingInterfaces.first)
        #expect(vs.number == 1 && vs.alternateSetting == 0 && vs.declaredEndpointCount == 1)
        #expect(vs.codecNames == ["H264", "MJPEG"] && inventory.hasMJPEG && inventory.hasH264)
        let endpoint = try #require(vs.endpoints.first)
        #expect(endpoint.address == 0x82 && endpoint.isIN && endpoint.isBulk && endpoint.maximumPacketSize == 512)
    }

    @Test func alternateInterfacesStaySeparateAndUnknownDescriptorsDoNotInventCapabilities() throws {
        let unknown: [UInt8] = [5, 0x24, 0x99, 0, 0]
        let alt: [UInt8] = [9, 4, 1, 1, 0, 14, 2, 0, 0]
        let inventory = try UVCDescriptorInventoryDecoder.decode(Data(stream + unknown + alt))
        #expect(inventory.videoStreamingInterfaces.count == 2)
        #expect(inventory.videoStreamingInterfaces.allSatisfy { $0.codecNames.isEmpty })
        #expect(!inventory.hasMJPEG && !inventory.hasH264)
    }

    @Test func malformedDescriptorsFailClosed() {
        #expect(throws: UVCDescriptorInventoryError.truncated(offset: 0)) {
            try UVCDescriptorInventoryDecoder.decode(Data([9, 4, 1]))
        }
        #expect(throws: UVCDescriptorInventoryError.invalidLength(offset: 0, length: 1)) {
            try UVCDescriptorInventoryDecoder.decode(Data([1, 4]))
        }
        #expect(throws: UVCDescriptorInventoryError.endpointWithoutInterface(offset: 0)) {
            try UVCDescriptorInventoryDecoder.decode(Data(bulkIN))
        }
        #expect(throws: UVCDescriptorInventoryError.invalidLength(offset: 0, length: 7)) {
            try UVCDescriptorInventoryDecoder.decode(Data([7, 4, 1, 0, 1, 14, 2]))
        }
    }
}
