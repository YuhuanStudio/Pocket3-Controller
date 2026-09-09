#if DEBUG
import CoreImage
import Foundation
import Testing
import Pocket3Core
@testable import Pocket3Intelligence

@Test func barcodeToolReturnsDataFromItsOwnFreshFrame() async throws {
    let payload = "POCKET3-QR-4826"
    let filter = try #require(CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage":Data(payload.utf8),"inputCorrectionLevel":"M"]))
    let qr = try #require(filter.outputImage).transformed(by: .init(scaleX: 10, y: 10))
    let extent = qr.extent.insetBy(dx: -40, dy: -40)
    let white = CIImage(color: CIColor.white).cropped(to: extent)
    let image = qr.composited(over: white)
    let data = try #require(CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
    let frame = try FramePacket.fixture(data: data)
    let camera = SimulatedObservationCamera(before: frame, after: frame, access: .observe)
    let start = try await camera.beginObservation(origin: .manual)
    let context = ObservationContext(service: camera, origin: .manual, stamp: start.stamp, frame: try await camera.frame(origin: .manual, after: 0), canMove: false, deadline: ProcessInfo.processInfo.systemUptime+10)
    let result = try await context.readBarcodes()
    #expect(result.contains(payload))
    #expect(result.contains("simulated-"))
    #expect(await camera.report()["directions"] == .array([]))
}
#endif
