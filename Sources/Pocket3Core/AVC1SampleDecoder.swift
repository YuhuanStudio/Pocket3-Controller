import CoreMedia
import CoreVideo
import Foundation

/// A bounded adapter from an AVFoundation `avc1` CMSampleBuffer to the
/// project's owned H.264/VideoToolbox path. It owns copied parameter sets and
/// access-unit bytes; it never retains an AVCapture sample buffer.
public enum AVC1SampleAdapterError: Error, Sendable, Equatable {
    case missingFormat, notH264, missingParameterSets, invalidParameterSets
    case missingBlockBuffer, emptyAccessUnit, accessUnitTooLarge, blockCopyFailed(OSStatus)
    case invalidDimensions
}

public struct AVC1CompressedSample: Sendable {
    public let parameterSets: VideoToolboxParameterSetBundle
    public let accessUnit: Data
    public let dimensions: CMVideoDimensions
    public let presentationTimeStamp: CMTime
    public let duration: CMTime
}

public enum AVC1SampleAdapter {
    public static func extract(_ sample: CMSampleBuffer,
                               limits: VideoToolboxDecoderLimits = .default) throws -> AVC1CompressedSample {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { throw AVC1SampleAdapterError.missingFormat }
        guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264 else { throw AVC1SampleAdapterError.notH264 }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width > 0, dimensions.height > 0,
              Int(dimensions.width) <= limits.maxWidth, Int(dimensions.height) <= limits.maxHeight else {
            throw AVC1SampleAdapterError.invalidDimensions
        }
        var sets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?, length = 0, count = 0
            var headerLength: Int32 = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &length,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            guard status == noErr, let pointer, length > 0, count == 2, headerLength == 4 else {
                throw AVC1SampleAdapterError.missingParameterSets
            }
            sets.append(Data(bytes: pointer, count: length))
        }
        let bundle: VideoToolboxParameterSetBundle
        do { bundle = try .init(codec: .h264, parameterSets: sets, limits: limits) }
        catch { throw AVC1SampleAdapterError.invalidParameterSets }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw AVC1SampleAdapterError.missingBlockBuffer }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { throw AVC1SampleAdapterError.emptyAccessUnit }
        guard length <= limits.maxAccessUnitBytes else { throw AVC1SampleAdapterError.accessUnitTooLarge }
        var accessUnit = Data(count: length)
        let copied = accessUnit.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { throw AVC1SampleAdapterError.blockCopyFailed(copied) }
        return AVC1CompressedSample(parameterSets: bundle, accessUnit: accessUnit, dimensions: dimensions,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), duration: CMSampleBufferGetDuration(sample))
    }
}

/// Queue-confined decoder for AVFoundation's H.264 encoded-output policy.
/// Parameter-set or dimension changes replace the VideoToolbox session before
/// decoding the new sample, preventing cross-format reuse.
final class AVC1SampleDecoder {
    private let limits: VideoToolboxDecoderLimits
    private var decoder: VideoToolboxAccessUnitDecoder?
    private var bundle: VideoToolboxParameterSetBundle?
    private var dimensions: CMVideoDimensions?

    init(limits: VideoToolboxDecoderLimits = .default) { self.limits = limits }
    deinit { decoder?.invalidate() }

    func decode(_ sample: CMSampleBuffer) throws -> VideoToolboxDecodeResult {
        let input = try AVC1SampleAdapter.extract(sample, limits: limits)
        let dimensionsChanged = dimensions.map { $0.width != input.dimensions.width || $0.height != input.dimensions.height } ?? true
        if bundle != input.parameterSets || dimensionsChanged {
            decoder?.invalidate()
            decoder = try VideoToolboxAccessUnitDecoder(codec: .h264, parameterSets: input.parameterSets,
                dimensions: input.dimensions, limits: limits)
            bundle = input.parameterSets; dimensions = input.dimensions
        }
        guard let decoder else { throw VideoToolboxDecoderError.invalidated }
        return try decoder.decode(input.accessUnit, presentationTimeStamp: input.presentationTimeStamp, duration: input.duration)
    }

    func invalidate() { decoder?.invalidate(); decoder = nil; bundle = nil; dimensions = nil }
}
