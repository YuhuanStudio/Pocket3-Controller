import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import Pocket3Core

private final class CompressionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var sample: CMSampleBuffer?
    private var status: OSStatus = noErr

    func receive(status: OSStatus, sample: CMSampleBuffer?) {
        lock.withLock { self.status = status; self.sample = sample }
        semaphore.signal()
    }

    func wait() throws -> CMSampleBuffer {
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw BridgeFailure("video_encoder_timeout", "Synthetic H.264 encoder did not finish")
        }
        return try lock.withLock {
            guard status == noErr, let sample else {
                throw BridgeFailure("video_encoder_failed", "Synthetic H.264 encoder returned \(status)")
            }
            return sample
        }
    }
}

private let h264CompressionCallback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
    guard let refcon else { return }
    Unmanaged<CompressionCapture>.fromOpaque(refcon).takeUnretainedValue().receive(status: status, sample: sampleBuffer)
}

private func syntheticBGRA(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                              [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
                              &buffer) == kCVReturnSuccess,
          let buffer else { throw BridgeFailure("synthetic_pixels", "Cannot allocate test pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * stride + x * 4
            base[offset] = UInt8((x * 7) & 0xff)
            base[offset + 1] = UInt8((y * 11) & 0xff)
            base[offset + 2] = 220
            base[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

private func encodedSample(codec: CMVideoCodecType, width: Int, height: Int) throws -> CMSampleBuffer {
    let capture = CompressionCapture()
    var session: VTCompressionSession?
    let create = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
        codecType: codec, encoderSpecification: nil, imageBufferAttributes: nil,
        compressedDataAllocator: nil, outputCallback: h264CompressionCallback,
        refcon: Unmanaged.passUnretained(capture).toOpaque(), compressionSessionOut: &session)
    guard create == noErr, let session else {
        throw BridgeFailure("video_encoder_unavailable", "VideoToolbox encoder unavailable: \(create)")
    }
    defer { VTCompressionSessionInvalidate(session) }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1 as CFTypeRef)
    guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
        throw BridgeFailure("video_encoder_prepare", "VideoToolbox encoder could not prepare")
    }
    let source = try syntheticBGRA(width: width, height: height)
    let encoded = VTCompressionSessionEncodeFrame(session, imageBuffer: source, presentationTimeStamp: .zero,
        duration: CMTime(value: 1, timescale: 30), frameProperties: nil, sourceFrameRefcon: nil,
        infoFlagsOut: nil)
    guard encoded == noErr else { throw BridgeFailure("video_encoder_encode", "VideoToolbox encode failed: \(encoded)") }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    return try capture.wait()
}

private func h264ParameterSets(from format: CMVideoFormatDescription) throws -> VideoToolboxParameterSetBundle {
    var sets: [Data] = []
    for index in 0..<2 {
        var pointer: UnsafePointer<UInt8>?
        var length = 0, count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
            parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        guard status == noErr, let pointer, length > 0, count == 2, headerLength == 4 else {
            throw BridgeFailure("h264_parameter_sets", "Cannot read H.264 parameter set \(index): \(status)")
        }
        sets.append(Data(bytes: pointer, count: length))
    }
    return try VideoToolboxParameterSetBundle(codec: .h264, parameterSets: sets)
}

private func hevcParameterSets(from format: CMVideoFormatDescription) throws -> VideoToolboxParameterSetBundle {
    var sets: [Data] = []
    for index in 0..<3 {
        var pointer: UnsafePointer<UInt8>?
        var length = 0, count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
            parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        guard status == noErr, let pointer, length > 0, count == 3, headerLength == 4 else {
            throw BridgeFailure("hevc_parameter_sets", "Cannot read HEVC parameter set \(index): \(status)")
        }
        sets.append(Data(bytes: pointer, count: length))
    }
    return try VideoToolboxParameterSetBundle(codec: .hevc, parameterSets: sets)
}

private func encodedBytes(from sample: CMSampleBuffer) throws -> Data {
    guard let block = CMSampleBufferGetDataBuffer(sample) else {
        throw BridgeFailure("h264_sample_buffer", "Encoded sample has no block buffer")
    }
    let count = CMBlockBufferGetDataLength(block)
    var result = Data(count: count)
    let status = result.withUnsafeMutableBytes { raw in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: raw.baseAddress!)
    }
    guard status == kCMBlockBufferNoErr else {
        throw BridgeFailure("h264_sample_buffer", "Cannot copy encoded bytes: \(status)")
    }
    return result
}

@Suite("Synthetic VideoToolbox round trip", .serialized)
struct VideoToolboxRoundTripTests {
    @Test func avc1SampleAdapterCopiesAndDecodesH264WithoutCameraAccess() throws {
        let width = 64, height = 48
        let sample = try encodedSample(codec: kCMVideoCodecType_H264, width: width, height: height)
        let extracted = try AVC1SampleAdapter.extract(sample)
        #expect(extracted.parameterSets.codec == .h264 && !extracted.accessUnit.isEmpty)
        #expect(extracted.dimensions.width == width && extracted.dimensions.height == height)
        let decoder = AVC1SampleDecoder()
        let result = try decoder.decode(sample)
        let buffer = try #require(result.pixelBuffer)
        #expect(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height)
        decoder.invalidate()
    }

    @Test func h264SyntheticFrameRoundTripsToBGRA() throws {
        let width = 64, height = 48
        let sample = try encodedSample(codec: kCMVideoCodecType_H264, width: width, height: height)
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        let parameterSets = try h264ParameterSets(from: format)
        let bytes = try encodedBytes(from: sample)
        let decoder = try VideoToolboxAccessUnitDecoder(codec: .h264, parameterSets: parameterSets,
            width: width, height: height)
        let result = try decoder.decode(bytes, presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 30))
        let buffer = try #require(result.pixelBuffer)
        #expect(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        #expect(result.generation == decoder.currentGeneration)
        decoder.invalidate()
        #expect(throws: VideoToolboxDecoderError.invalidated) { try decoder.decode(bytes) }
    }

    @Test func hevcSyntheticFrameRoundTripsToBGRA() throws {
        let width = 64, height = 48
        let sample = try encodedSample(codec: kCMVideoCodecType_HEVC, width: width, height: height)
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        let parameterSets = try hevcParameterSets(from: format)
        let bytes = try encodedBytes(from: sample)
        let decoder = try VideoToolboxAccessUnitDecoder(codec: .hevc, parameterSets: parameterSets,
            width: width, height: height)
        let result = try decoder.decode(bytes, presentationTimeStamp: .zero,
            duration: CMTime(value: 1, timescale: 30))
        let buffer = try #require(result.pixelBuffer)
        #expect(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        decoder.invalidate()
    }

    @Test func hvc1SampleAdapterCopiesAndDecodesHEVCWithoutCameraAccess() throws {
        let width = 64, height = 48
        let sample = try encodedSample(codec: kCMVideoCodecType_HEVC, width: width, height: height)
        let extracted = try HEVC1SampleAdapter.extract(sample)
        #expect(extracted.parameterSets.codec == .hevc && !extracted.accessUnit.isEmpty)
        #expect(extracted.dimensions.width == width && extracted.dimensions.height == height)
        let decoder = HEVC1SampleDecoder()
        let result = try decoder.decode(sample)
        let buffer = try #require(result.pixelBuffer)
        #expect(CVPixelBufferGetWidth(buffer) == width && CVPixelBufferGetHeight(buffer) == height)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        decoder.invalidate()
    }
}
