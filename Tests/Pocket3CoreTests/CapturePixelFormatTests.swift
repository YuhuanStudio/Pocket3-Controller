import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Testing
@testable import Pocket3Core

@Suite struct CapturePixelFormatTests {
    @Test func explicitInputChoicesNeverAcceptTheOtherFormat() throws {
        let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let uyvy = kCVPixelFormatType_422YpCbCr8
        #expect(CapturePixelFormat.nv12.fourCC == "420v")
        #expect(CapturePixelFormat.uyvy.fourCC == "2vuy")
        #expect(CapturePixelFormat.nv12.accepts(mediaSubType: nv12))
        #expect(!CapturePixelFormat.nv12.accepts(mediaSubType: uyvy))
        #expect(CapturePixelFormat.uyvy.accepts(mediaSubType: uyvy))
        #expect(!CapturePixelFormat.uyvy.accepts(mediaSubType: nv12))
        #expect(CapturePixelFormat.automatic.accepts(mediaSubType: nv12))
        #expect(CapturePixelFormat.automatic.accepts(mediaSubType: uyvy))
        #expect(CapturePixelFormat(mediaSubType: kCVPixelFormatType_32BGRA) == nil)
        for value in CapturePixelFormat.allCases {
            #expect(try JSONDecoder().decode(CapturePixelFormat.self, from: JSONEncoder().encode(value)) == value)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CapturePixelFormat.self, from: Data(#""mjpeg""#.utf8))
        }
    }

    @Test func inputMetadataSurvivesBGRAToJPEGConversion() throws {
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let bytes = CVPixelBufferGetBaseAddress(buffer) {
            bytes.initializeMemory(as: UInt8.self, repeating: 0, count: CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let store = FrameStore()
        store.reset(deviceID: "test-camera")
        store.receive(buffer, pts: 1, inputMediaSubType: kCVPixelFormatType_422YpCbCr8)
        let packet = try store.latest()
        #expect(packet.info.inputPixelFormat == .uyvy)
        #expect(packet.info.inputPixelFormatFourCC == "2vuy")
        #expect(packet.info.outputPixelFormat == "BGRA")
        let (jpeg, bytes) = try packet.jpegWithInfo(maxDimension: 16)
        #expect(!bytes.isEmpty)
        #expect(jpeg.inputPixelFormat == .uyvy && jpeg.inputPixelFormatFourCC == "2vuy")
        #expect(jpeg.outputPixelFormat == "JPEG")
        #expect(jpeg.width == 16 && jpeg.height == 8)
        #expect(jpeg.sourceWidth == 32 && jpeg.sourceHeight == 16)

        store.reset(deviceID: "another-session")
        store.receive(buffer, pts: 2)
        let next = try store.latest()
        #expect(next.info.inputPixelFormat == nil && next.info.inputPixelFormatFourCC == nil)
        #expect(next.info.outputPixelFormat == "BGRA")
    }

    @Test func invalidRPCPixelFormatIsRejectedBeforeConnecting() async {
        let service = CameraService(validationEnabled: true)
        for invalid in [JSONValue.string("mjpeg"), .number(1)] {
            let reply = await service.handle(ServiceRequest(token: "test", operation: "validation-connect",
                arguments: .object(["pixelFormat": invalid])))
            #expect(reply.error?.code == "invalid_input_format")
        }
    }

    @Test func nativeOutputRequiresBothDevelopmentFlagAndExactEnvironmentOptIn() throws {
        #expect(CaptureOutputPolicy.selected(environment: [:], arguments: []) == .bgra)
        #expect(CaptureOutputPolicy.selected(environment: ["POCKET3_CAPTURE_OUTPUT":"native"], arguments: []) == .bgra)
        #expect(CaptureOutputPolicy.selected(environment: [:], arguments: ["app", "--hardware-validation"]) == .bgra)
        #expect(CaptureOutputPolicy.selected(environment: ["POCKET3_CAPTURE_OUTPUT":"native"], arguments: ["app", "--hardware-validation"]) == .native)
        #expect(CaptureOutputPolicy.selected(environment: ["POCKET3_CAPTURE_OUTPUT":"unknown"], arguments: ["app", "--hardware-validation"]) == .bgra)
        #expect(CaptureOutputPolicy.native.settings(width: 1080, height: 1920)?.isEmpty == true)
        #expect(CaptureOutputPolicy.selected(environment: ["POCKET3_CAPTURE_OUTPUT":"system_default"], arguments: []) == .bgra)
        #expect(CaptureOutputPolicy.selected(environment: ["POCKET3_CAPTURE_OUTPUT":"system_default"], arguments: ["--hardware-validation"]) == .systemDefault)
        #expect(CaptureOutputPolicy.systemDefault.settings() == nil)
        let normal = try #require(CaptureOutputPolicy.bgra.settings(width: 1080, height: 1920))
        #expect(normal[kCVPixelBufferPixelFormatTypeKey as String] as? UInt32 == kCVPixelFormatType_32BGRA)
        #expect(normal[kCVPixelBufferWidthKey as String] as? Int == 1080)
        #expect(normal[kCVPixelBufferHeightKey as String] as? Int == 1920)
    }

    @Test func nativePixelBufferMetadataReportsActualOutputInsteadOfBGRA() throws {
        for (type, name) in [(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "420v"),
                             (kCVPixelFormatType_422YpCbCr8, "2vuy")] {
            var pixel: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, type, nil, &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            let store = FrameStore()
            store.reset(deviceID: "native-output-fixture")
            // Input and output representation are intentionally independent.
            store.receive(buffer, pts: 1, inputMediaSubType: kCVPixelFormatType_422YpCbCr8)
            let packet = try store.latest()
            #expect(packet.info.inputPixelFormatFourCC == "2vuy")
            #expect(packet.info.outputPixelFormat == name)
            #expect(packet.info.width == 32 && packet.info.height == 16)
        }
    }

    @Test func explicitH264OutputRequiresDevelopmentOptInAndAdvertisedCodec() throws {
        let environment = ["POCKET3_CAPTURE_OUTPUT": "h264"]
        #expect(CaptureOutputPolicy.selected(environment: environment, arguments: []) == .bgra)
        #expect(CaptureOutputPolicy.selected(environment: environment, arguments: ["--hardware-validation"]) == .h264)
        #expect(CaptureOutputPolicy.h264.settings() == nil) // Not configured before an input format is attached.
        try CaptureOutputPolicy.h264.validateAvailableCodecs(["avc1", "jpeg"])
        #expect(throws: BridgeFailure.self) { try CaptureOutputPolicy.h264.validateAvailableCodecs(["jpeg"]) }
        try CaptureOutputPolicy.bgra.validateAvailableCodecs([])
        let settings = try #require(CaptureOutputPolicy.h264.settings(width: 1080, height: 1920))
        #expect(settings[AVVideoCodecKey] as? String == AVVideoCodecType.h264.rawValue)
        #expect(settings[AVVideoWidthKey] as? Int == 1080 && settings[AVVideoHeightKey] as? Int == 1920)
        #expect(settings[kCVPixelBufferPixelFormatTypeKey as String] == nil)
        #expect(settings[kCVPixelBufferWidthKey as String] == nil && settings[kCVPixelBufferHeightKey as String] == nil)
    }

    @Test func h264OutputDiagnosticsKeepInputAndCompressedSamplesDistinct() throws {
        let store = FrameStore()
        store.reset(deviceID: "synthetic-codec-output")
        store.recordOutputConfiguration(policy: CaptureOutputPolicy.h264.rawValue, pixelFormats: [], codecs: ["avc1"])
        store.recordVideoSample(hasImageBuffer: false, hasBlockBuffer: true,
            mediaSubType: kCMVideoCodecType_H264, inputMediaSubType: kCVPixelFormatType_422YpCbCr8)
        let diagnostics = store.sampleDiagnostics()
        #expect(diagnostics.requestedOutputPolicy == "h264")
        #expect(diagnostics.videoSampleCount == 1 && diagnostics.nonImageVideoBlockBufferCount == 1)
        #expect(diagnostics.nonImageVideoSampleCount == 1 && diagnostics.pixelBufferCount == 0)
        #expect(diagnostics.lastVideoSampleFourCC == "avc1" && diagnostics.lastVideoInputFourCC == "2vuy")
        #expect(store.stats().frames == 0) // Encoded samples are not yet decoded preview frames.
    }
}
