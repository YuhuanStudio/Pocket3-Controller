import Foundation

/// Limits for the pure Pocket 3 pktType-02 media assembler. These limits are
/// applied before a fragment or completed message changes stream state.
public struct Pocket3LiveViewMediaLimits: Codable, Sendable, Equatable {
    public static let defaultMaximumMessageBytes = 8 * 1024 * 1024
    public static let defaultMaximumFragmentBytes = 16 * 1024
    public static let defaultMaximumPartialAge: TimeInterval = 1.5
    public static let defaultMaximumQueuedMessages = 8
    public static let defaultMaximumQueuedBytes = 16 * 1024 * 1024
    public static let defaultMaximumMetadataBytes = 16

    public let maximumMessageBytes: Int
    public let maximumFragmentBytes: Int
    public let maximumPartialAge: TimeInterval
    public let maximumQueuedMessages: Int
    public let maximumQueuedBytes: Int
    public let maximumMetadataBytes: Int

    public static let `default` = Self()

    public init(
        maximumMessageBytes: Int = Self.defaultMaximumMessageBytes,
        maximumFragmentBytes: Int = Self.defaultMaximumFragmentBytes,
        maximumPartialAge: TimeInterval = Self.defaultMaximumPartialAge,
        maximumQueuedMessages: Int = Self.defaultMaximumQueuedMessages,
        maximumQueuedBytes: Int = Self.defaultMaximumQueuedBytes,
        maximumMetadataBytes: Int = Self.defaultMaximumMetadataBytes
    ) {
        self.maximumMessageBytes = maximumMessageBytes
        self.maximumFragmentBytes = maximumFragmentBytes
        self.maximumPartialAge = maximumPartialAge
        self.maximumQueuedMessages = maximumQueuedMessages
        self.maximumQueuedBytes = maximumQueuedBytes
        self.maximumMetadataBytes = maximumMetadataBytes
    }

    fileprivate var isValid: Bool {
        maximumMessageBytes > 0 &&
            maximumFragmentBytes >= Pocket3LiveViewFirstFragmentHeader.length &&
            maximumPartialAge.isFinite && maximumPartialAge > 0 &&
            maximumQueuedMessages > 0 && maximumQueuedBytes > 0 &&
            maximumMetadataBytes >= Pocket3LiveViewFirstFragmentHeader.metadataLength
    }
}

public enum Pocket3LiveViewMediaError: Error, Codable, Sendable, Equatable {
    case invalidLimits
    case terminated
    case wrongPacketType
    case invalidSession
    case invalidGeneration
    case invalidHeader
    case malformedFragment
    case declaredLengthInvalid
    case fragmentTooLarge
    case fragmentOverrun
    case invalidClock
}

/// The capture-confirmed 16-byte first-fragment header. The eight metadata
/// bytes are preserved verbatim; only the little-endian declared length and
/// timestamp-like counter are exposed as typed fields.
public struct Pocket3LiveViewFirstFragmentHeader: Codable, Sendable,
    Equatable {
    public static let marker = Data([0x00, 0x00, 0x01, 0xFF])
    public static let length = 16
    public static let metadataLength = 8

    public let raw: Data
    public let declaredLength: UInt32
    public let metadata: Data
    public let timestampCounter: UInt32

    public init(fragment: Data) throws {
        guard fragment.count >= Self.length,
              Data(fragment.prefix(4)) == Self.marker else {
            throw Pocket3LiveViewMediaError.invalidHeader
        }
        let bytes = Array(fragment.prefix(Self.length))
        let declared = Self.readUInt32(bytes, at: 4)
        let metadata = Data(bytes[8..<16])
        self.raw = Data(bytes)
        self.declaredLength = declared
        self.metadata = metadata
        self.timestampCounter = Self.readUInt32(bytes, at: 12)
    }

    public init(fragment: [UInt8]) throws {
        try self.init(fragment: Data(fragment))
    }

    public static func parse(_ fragment: Data) throws -> Self {
        try Self(fragment: fragment)
    }

    public init(raw: Data, declaredLength: UInt32,
                metadata: Data, timestampCounter: UInt32) throws {
        guard raw.count == Self.length,
              metadata.count == Self.metadataLength else {
            throw Pocket3LiveViewMediaError.invalidHeader
        }
        self.raw = Data(raw)
        self.declaredLength = declaredLength
        self.metadata = Data(metadata)
        self.timestampCounter = timestampCounter
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) |
            UInt32(bytes[index + 1]) << 8 |
            UInt32(bytes[index + 2]) << 16 |
            UInt32(bytes[index + 3]) << 24
    }
}

/// One accepted pktType-02 fragment after the DJI UDP and routing headers have
/// been validated. Continuations contain only media bytes; a first fragment
/// carries the 16-byte declared-length header.
public struct Pocket3LiveViewVideoFragment: Codable, Sendable,
    Equatable {
    public let sessionID: UInt16
    public let generation: UInt64
    public let transportSequence: UInt16
    public let routingSequence: UInt16
    public let groupID: UInt32?
    public let isFirst: Bool
    public let firstHeader: Pocket3LiveViewFirstFragmentHeader?
    public let metadata: Data?
    public let timestampCounter: UInt32?
    public let data: Data

    init(sessionID: UInt16, generation: UInt64,
         transportSequence: UInt16, routingSequence: UInt16,
         groupID: UInt32?, isFirst: Bool,
         firstHeader: Pocket3LiveViewFirstFragmentHeader?,
         data: Data) {
        self.sessionID = sessionID
        self.generation = generation
        self.transportSequence = transportSequence
        self.routingSequence = routingSequence
        self.groupID = groupID
        self.isFirst = isFirst
        self.firstHeader = firstHeader
        metadata = firstHeader?.metadata
        timestampCounter = firstHeader?.timestampCounter
        self.data = data
    }
}

/// One complete declared-length media message. data remains Annex-B input
/// exactly as assembled; normalizedData is optional and uses the existing
/// H264/HEVC normalizer's four-byte length-prefixed contract.
public struct Pocket3LiveViewMediaMessage: Codable, Sendable, Equatable {
    public let sessionID: UInt16
    public let generation: UInt64
    public let messageID: UInt64
    public let declaredLength: UInt32
    public let data: Data
    public let firstHeader: Pocket3LiveViewFirstFragmentHeader
    public let firstTransportSequence: UInt16
    public let lastTransportSequence: UInt16
    public let fragmentCount: Int
    public let groupIDs: [UInt32]
    public let crossedGroupBoundary: Bool
    public let codec: VideoToolboxCodec?
    public let normalizedData: Data?
    public let decodeReadiness: Pocket3LiveViewDecodeReadiness
    public let nalTypes: [UInt8]
    public let containsIDR: Bool
    public let containsIRAP: Bool
    public let parameterSetsChanged: Bool
    public let videoToolboxInputValidated: Bool
    public let normalizationError: String?

    public var raw: Data { data }
    public var metadata: Data { firstHeader.metadata }
    public var rawMetadata: Data { firstHeader.metadata }
    public var declaredLengthBytes: UInt32 { declaredLength }
    public var normalizedAccessUnit: Data? { normalizedData }
    public var readiness: Pocket3LiveViewDecodeReadiness { decodeReadiness }
    public var containsRandomAccessPoint: Bool { containsIDR || containsIRAP }
    public var isDecoderReady: Bool { decodeReadiness == .ready }
    public var byteCount: Int { data.count }
    public var timestampCounter: UInt32 { firstHeader.timestampCounter }

    var memoryCost: Int {
        data.count + (normalizedData?.count ?? 0)
    }
}

public enum Pocket3LiveViewDecodeReadiness: String, Codable, Sendable,
    Equatable, CaseIterable {
    case unknown
    case waitingForParameterSets
    case waitingForRandomAccess
    case ready
}

public struct Pocket3LiveViewMediaStatistics: Codable, Sendable,
    Equatable {
    public let receivedPacketCount: UInt64
    public let completedMessageCount: UInt64
    public let droppedPartialMessageCount: UInt64
    public let replacedPartialMessageCount: UInt64
    public let joinedMidMessageCount: UInt64
    public let lostPacketCount: UInt64
    public let reorderedPacketCount: UInt64
    public let malformedPacketCount: UInt64
    public let oversizedMessageCount: UInt64
    public let fragmentOverrunCount: UInt64
    public let codecDetectionFailureCount: UInt64
    public let normalizationFailureCount: UInt64
    public let queueDropCount: UInt64
    public let crossGroupContinuationCount: UInt64
    public let pendingMessage: Bool
    public let pendingByteCount: Int
    public let queuedMessageCount: Int
    public let queuedByteCount: Int
}

/// Pure pktType-02 assembler and codec readiness gate. It accepts an already
/// decoded DJI UDP datagram and owns no socket, live-view command, or decoder
/// session. Transport sequence gaps reset the partial message and mark cached
/// codec state as waiting for a random-access point.
public struct Pocket3LiveViewMediaAssembler: Sendable {
    public let sessionID: UInt16
    public private(set) var generation: UInt64
    public let limits: Pocket3LiveViewMediaLimits
    public private(set) var currentCodec: VideoToolboxCodec?
    public private(set) var isTerminated = false

    private var h264Normalizer: H264AccessUnitNormalizer
    private var hevcNormalizer: HEVCAccessUnitNormalizer
    private var expectedLength: Int?
    private var partial = Data()
    private var partialStartedUptime: TimeInterval?
    private var firstHeader: Pocket3LiveViewFirstFragmentHeader?
    private var firstTransportSequence: UInt16?
    private var lastTransportSequence: UInt16?
    private var lastRoutingSequence: UInt16?
    private var fragmentCount = 0
    private var groupIDs: [UInt32] = []
    private var crossedGroupBoundary = false
    private var nextMessageID: UInt64 = 1
    private var queue: [Pocket3LiveViewMediaMessage] = []
    private var queueBytes = 0

    private var receivedPacketCount: UInt64 = 0
    private var completedMessageCount: UInt64 = 0
    private var droppedPartialMessageCount: UInt64 = 0
    private var replacedPartialMessageCount: UInt64 = 0
    private var joinedMidMessageCount: UInt64 = 0
    private var lostPacketCount: UInt64 = 0
    private var reorderedPacketCount: UInt64 = 0
    private var malformedPacketCount: UInt64 = 0
    private var oversizedMessageCount: UInt64 = 0
    private var fragmentOverrunCount: UInt64 = 0
    private var codecDetectionFailureCount: UInt64 = 0
    private var normalizationFailureCount: UInt64 = 0
    private var queueDropCount: UInt64 = 0
    private var crossGroupContinuationCount: UInt64 = 0

    public init(sessionID: UInt16, generation: UInt64 = 1,
                limits: Pocket3LiveViewMediaLimits = .default) throws {
        guard limits.isValid else {
            throw Pocket3LiveViewMediaError.invalidLimits
        }
        guard generation != 0 else {
            throw Pocket3LiveViewMediaError.invalidGeneration
        }
        self.sessionID = sessionID
        self.generation = generation
        self.limits = limits
        h264Normalizer = H264AccessUnitNormalizer(limits: H264AccessUnitLimits(
            maxInputBytes: limits.maximumMessageBytes,
            maxOutputBytes: limits.maximumMessageBytes))
        hevcNormalizer = HEVCAccessUnitNormalizer(limits: HEVCAccessUnitLimits(
            maxInputBytes: limits.maximumMessageBytes,
            maxOutputBytes: limits.maximumMessageBytes))
    }

    public var hasPartialMessage: Bool { expectedLength != nil }
    public var partialByteCount: Int { partial.count }
    public var pendingAccessUnitCount: Int { queue.count }
    public var pendingAccessUnits: [Pocket3LiveViewMediaMessage] { queue }

    public var statistics: Pocket3LiveViewMediaStatistics {
        Pocket3LiveViewMediaStatistics(
            receivedPacketCount: receivedPacketCount,
            completedMessageCount: completedMessageCount,
            droppedPartialMessageCount: droppedPartialMessageCount,
            replacedPartialMessageCount: replacedPartialMessageCount,
            joinedMidMessageCount: joinedMidMessageCount,
            lostPacketCount: lostPacketCount,
            reorderedPacketCount: reorderedPacketCount,
            malformedPacketCount: malformedPacketCount,
            oversizedMessageCount: oversizedMessageCount,
            fragmentOverrunCount: fragmentOverrunCount,
            codecDetectionFailureCount: codecDetectionFailureCount,
            normalizationFailureCount: normalizationFailureCount,
            queueDropCount: queueDropCount,
            crossGroupContinuationCount: crossGroupContinuationCount,
            pendingMessage: expectedLength != nil,
            pendingByteCount: partial.count,
            queuedMessageCount: queue.count,
            queuedByteCount: queueBytes)
    }

    /// Consume one already decoded UDP datagram. The datagram must be a
    /// capture-confirmed video packet for this assembler's 16-bit session.
    /// A completed message is returned and also placed in the bounded queue.
    @discardableResult
    public mutating func consume(
        _ datagram: DJIUDPDatagram,
        receivedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        groupID: UInt32? = nil,
        expectedGeneration: UInt64? = nil
    ) throws -> Pocket3LiveViewMediaMessage? {
        guard !isTerminated else {
            throw Pocket3LiveViewMediaError.terminated
        }
        guard limits.isValid else {
            throw Pocket3LiveViewMediaError.invalidLimits
        }
        guard receivedUptime.isFinite, receivedUptime >= 0 else {
            malformedPacketCount &+= 1
            throw Pocket3LiveViewMediaError.invalidClock
        }
        guard expectedGeneration == nil || expectedGeneration == generation else {
            throw Pocket3LiveViewMediaError.invalidGeneration
        }
        receivedPacketCount &+= 1
        guard datagram.header.sessionID == sessionID else {
            malformedPacketCount &+= 1
            throw Pocket3LiveViewMediaError.invalidSession
        }
        guard datagram.quality.permitsStateUpdates else {
            malformedPacketCount &+= 1
            throw Pocket3LiveViewMediaError.invalidHeader
        }
        guard datagram.header.packetType == .video else {
            malformedPacketCount &+= 1
            throw Pocket3LiveViewMediaError.wrongPacketType
        }
        guard datagram.payload.count >= DJIUDPFraming.routingLength else {
            malformedPacketCount &+= 1
            throw Pocket3LiveViewMediaError.malformedFragment
        }

        let routing: DJIUDPRoutingHeader
        do {
            routing = try DJIUDPFraming.decodeRoutingHeader(
                Data(datagram.payload.prefix(DJIUDPFraming.routingLength)))
        } catch {
            malformedPacketCount &+= 1
            throw Pocket3LiveViewMediaError.invalidHeader
        }
        let fragmentData = Data(datagram.payload.dropFirst(
            DJIUDPFraming.routingLength))
        guard fragmentData.count <= limits.maximumFragmentBytes else {
            oversizedMessageCount &+= 1
            clearPartial()
            throw Pocket3LiveViewMediaError.fragmentTooLarge
        }
        let first = Data(fragmentData.prefix(
            Pocket3LiveViewFirstFragmentHeader.marker.count)) ==
            Pocket3LiveViewFirstFragmentHeader.marker

        if let last = lastTransportSequence {
            let delta = datagram.header.sequence &- last
            if delta == 0 || delta >= 0x8000 {
                reorderedPacketCount &+= 1
                return nil
            }
            if delta != 8 {
                lostPacketCount &+= UInt64(max(1, Int(delta / 8) - 1))
                markLossAfterSequenceGap()
                // A first fragment can restart the stream after loss. A
                // continuation cannot safely fill the missing bytes.
                lastTransportSequence = datagram.header.sequence
                if !first { joinedMidMessageCount &+= 1; return nil }
            }
        }
        lastTransportSequence = datagram.header.sequence
        lastRoutingSequence = routing.sequence

        if let started = partialStartedUptime,
           receivedUptime >= started,
           receivedUptime - started > limits.maximumPartialAge {
            dropPartial()
            if !first {
                joinedMidMessageCount &+= 1
                return nil
            }
        }

        if first {
            if expectedLength != nil {
                replacedPartialMessageCount &+= 1
                dropPartial()
            }
            let header: Pocket3LiveViewFirstFragmentHeader
            do {
                header = try Pocket3LiveViewFirstFragmentHeader(
                    fragment: fragmentData)
            } catch {
                malformedPacketCount &+= 1
                clearPartial()
                throw Pocket3LiveViewMediaError.invalidHeader
            }
            guard header.declaredLength > 0,
                  header.declaredLength <= UInt32(limits.maximumMessageBytes) else {
                oversizedMessageCount &+= 1
                clearPartial()
                throw Pocket3LiveViewMediaError.declaredLengthInvalid
            }
            guard header.metadata.count <= limits.maximumMetadataBytes else {
                malformedPacketCount &+= 1
                clearPartial()
                throw Pocket3LiveViewMediaError.malformedFragment
            }
            expectedLength = Int(header.declaredLength)
            partial.removeAll(keepingCapacity: true)
            partialStartedUptime = receivedUptime
            firstHeader = header
            firstTransportSequence = datagram.header.sequence
            fragmentCount = 0
            groupIDs.removeAll(keepingCapacity: true)
            crossedGroupBoundary = false
            if let groupID { groupIDs.append(groupID) }
            appendFragmentBody(Data(fragmentData.dropFirst(
                Pocket3LiveViewFirstFragmentHeader.length)))
        } else {
            guard expectedLength != nil else {
                joinedMidMessageCount &+= 1
                return nil
            }
            guard !fragmentData.isEmpty else {
                malformedPacketCount &+= 1
                throw Pocket3LiveViewMediaError.malformedFragment
            }
            if let groupID {
                if let previous = groupIDs.last, previous != groupID {
                    crossedGroupBoundary = true
                    crossGroupContinuationCount &+= 1
                }
                if groupIDs.last != groupID { groupIDs.append(groupID) }
            }
            appendFragmentBody(fragmentData)
        }
        fragmentCount += 1

        guard let expectedLength else { return nil }
        if partial.count < expectedLength { return nil }
        guard partial.count == expectedLength else {
            fragmentOverrunCount &+= 1
            clearPartial()
            throw Pocket3LiveViewMediaError.fragmentOverrun
        }
        guard let header = firstHeader,
              let firstSequence = firstTransportSequence else {
            malformedPacketCount &+= 1
            clearPartial()
            throw Pocket3LiveViewMediaError.malformedFragment
        }

        let message = makeMessage(header: header,
            firstSequence: firstSequence,
            lastSequence: datagram.header.sequence)
        completedMessageCount &+= 1
        clearPartial()
        let processed = process(message)
        enqueue(processed)
        return processed
    }

    /// Convenience overload for a raw, complete DJI UDP datagram. It performs
    /// only framing decode; no socket or network operation is started.
    @discardableResult
    public mutating func consume(
        _ data: Data,
        receivedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        groupID: UInt32? = nil,
        expectedGeneration: UInt64? = nil
    ) throws -> Pocket3LiveViewMediaMessage? {
        let datagram: DJIUDPDatagram
        do {
            datagram = try DJIUDPFraming.decode(data, expectedSessionID: sessionID)
        } catch let error as DJIUDPFramingError {
            malformedPacketCount &+= 1
            switch error {
            case .wrongSession: throw Pocket3LiveViewMediaError.invalidSession
            default: throw Pocket3LiveViewMediaError.invalidHeader
            }
        }
        return try consume(datagram, receivedUptime: receivedUptime,
                           groupID: groupID,
                           expectedGeneration: expectedGeneration)
    }

    /// Remove and return the oldest completed message from the bounded queue.
    public mutating func dequeue() -> Pocket3LiveViewMediaMessage? {
        guard !queue.isEmpty else { return nil }
        let value = queue.removeFirst()
        queueBytes -= value.memoryCost
        return value
    }

    public func peek() -> Pocket3LiveViewMediaMessage? { queue.first }

    /// Mark an externally observed packet loss. Cached parameter sets remain
    /// available, but the next random-access NAL is required before decode
    /// readiness can return.
    public mutating func markLoss() {
        lostPacketCount &+= 1
        markLossAfterSequenceGap()
    }

    /// Reset the partial message, parameter-set gates, queue and sequence
    /// admission. A supplied generation fences callbacks from an old owner.
    public mutating func reset(to generation: UInt64? = nil) throws {
        let next = generation ?? (self.generation == UInt64.max
            ? 1 : self.generation + 1)
        guard next != 0 else {
            throw Pocket3LiveViewMediaError.invalidGeneration
        }
        self.generation = next
        clearPartial()
        queue.removeAll(keepingCapacity: false)
        queueBytes = 0
        currentCodec = nil
        h264Normalizer.reset()
        hevcNormalizer.reset()
        lastTransportSequence = nil
        lastRoutingSequence = nil
        nextMessageID = 1
        receivedPacketCount = 0
        completedMessageCount = 0
        droppedPartialMessageCount = 0
        replacedPartialMessageCount = 0
        joinedMidMessageCount = 0
        lostPacketCount = 0
        reorderedPacketCount = 0
        malformedPacketCount = 0
        oversizedMessageCount = 0
        fragmentOverrunCount = 0
        codecDetectionFailureCount = 0
        normalizationFailureCount = 0
        queueDropCount = 0
        crossGroupContinuationCount = 0
        isTerminated = false
    }

    /// Convenience reset that starts the next generation and cannot fail for
    /// the assembler's valid nonzero generation state.
    public mutating func reset() {
        try? reset(to: nil)
    }

    /// Permanently close this value for late callbacks. A caller must create
    /// or explicitly reset a fresh generation before accepting more packets.
    public mutating func teardown() {
        clearPartial()
        queue.removeAll(keepingCapacity: false)
        queueBytes = 0
        isTerminated = true
    }

    private mutating func clearPartial() {
        expectedLength = nil
        partial.removeAll(keepingCapacity: true)
        partialStartedUptime = nil
        firstHeader = nil
        firstTransportSequence = nil
        fragmentCount = 0
        groupIDs.removeAll(keepingCapacity: true)
        crossedGroupBoundary = false
    }

    private mutating func dropPartial() {
        guard expectedLength != nil else { return }
        droppedPartialMessageCount &+= 1
        clearPartial()
    }

    private mutating func markLossAfterSequenceGap() {
        dropPartial()
        h264Normalizer.markLoss()
        hevcNormalizer.markLoss()
        queue.removeAll(keepingCapacity: false)
        queueBytes = 0
        lastTransportSequence = nil
        lastRoutingSequence = nil
    }

    private mutating func appendFragmentBody(_ body: Data) {
        partial.append(body)
    }

    private func makeMessage(
        header: Pocket3LiveViewFirstFragmentHeader,
        firstSequence: UInt16,
        lastSequence: UInt16
    ) -> Pocket3LiveViewMediaMessage {
        Pocket3LiveViewMediaMessage(
            sessionID: sessionID, generation: generation,
            messageID: nextMessageID, declaredLength: header.declaredLength,
            data: partial, firstHeader: header,
            firstTransportSequence: firstSequence,
            lastTransportSequence: lastSequence,
            fragmentCount: fragmentCount,
            groupIDs: groupIDs,
            crossedGroupBoundary: crossedGroupBoundary,
            codec: nil, normalizedData: nil,
            decodeReadiness: .unknown, nalTypes: [],
            containsIDR: false, containsIRAP: false,
            parameterSetsChanged: false,
            videoToolboxInputValidated: false,
            normalizationError: nil)
    }

    private mutating func process(
        _ message: Pocket3LiveViewMediaMessage
    ) -> Pocket3LiveViewMediaMessage {
        var result = message
        let detected = Self.detectCodec(message.data) ?? currentCodec
        guard let detected else {
            codecDetectionFailureCount &+= 1
            result = with(result, codec: nil, normalizedData: nil,
                          decodeReadiness: .unknown, nalTypes: [],
                          containsIDR: false, containsIRAP: false,
                          parameterSetsChanged: false,
                          videoToolboxInputValidated: false,
                          normalizationError: "codec_unknown")
            nextMessageID = nextMessageID == UInt64.max
                ? 1 : nextMessageID + 1
            return result
        }

        if currentCodec != detected {
            currentCodec = detected
            switch detected {
            case .h264: h264Normalizer.reset()
            case .hevc: hevcNormalizer.reset()
            }
        }
        switch detected {
        case .h264:
            do {
                let normalized = try h264Normalizer.normalize(message.data)
                let validated = (try? VideoToolboxAccessUnit(
                    codec: .h264, data: normalized.data,
                    limits: VideoToolboxDecoderLimits(
                        maxAccessUnitBytes: limits.maximumMessageBytes,
                        maxNALBytes: limits.maximumMessageBytes)))
                    != nil
                result = with(result, codec: .h264,
                    normalizedData: normalized.data,
                    decodeReadiness: map(normalized.readiness),
                    nalTypes: normalized.nalUnits.map(\.type),
                    containsIDR: normalized.containsIDR,
                    containsIRAP: false,
                    parameterSetsChanged: normalized.parameterSetsChanged,
                    videoToolboxInputValidated: validated,
                    normalizationError: validated ? nil : "videotoolbox_input_invalid")
                if !validated { normalizationFailureCount &+= 1 }
            } catch {
                normalizationFailureCount &+= 1
                result = with(result, codec: .h264,
                    normalizedData: nil,
                    decodeReadiness: map(h264Normalizer.decodeReadiness),
                    nalTypes: [],
                    containsIDR: false, containsIRAP: false,
                    parameterSetsChanged: false,
                    videoToolboxInputValidated: false,
                    normalizationError: String(describing: error))
            }
        case .hevc:
            do {
                let normalized = try hevcNormalizer.normalize(message.data)
                let validated = (try? VideoToolboxAccessUnit(
                    codec: .hevc, data: normalized.data,
                    limits: VideoToolboxDecoderLimits(
                        maxAccessUnitBytes: limits.maximumMessageBytes,
                        maxNALBytes: limits.maximumMessageBytes)))
                    != nil
                result = with(result, codec: .hevc,
                    normalizedData: normalized.data,
                    decodeReadiness: map(normalized.readiness),
                    nalTypes: normalized.nalUnits.map(\.type),
                    containsIDR: false,
                    containsIRAP: normalized.containsIRAP,
                    parameterSetsChanged: normalized.parameterSetsChanged,
                    videoToolboxInputValidated: validated,
                    normalizationError: validated ? nil : "videotoolbox_input_invalid")
                if !validated { normalizationFailureCount &+= 1 }
            } catch {
                normalizationFailureCount &+= 1
                result = with(result, codec: .hevc,
                    normalizedData: nil,
                    decodeReadiness: map(hevcNormalizer.decodeReadiness),
                    nalTypes: [],
                    containsIDR: false, containsIRAP: false,
                    parameterSetsChanged: false,
                    videoToolboxInputValidated: false,
                    normalizationError: String(describing: error))
            }
        }
        nextMessageID = nextMessageID == UInt64.max
            ? 1 : nextMessageID + 1
        return result
    }

    private func with(
        _ value: Pocket3LiveViewMediaMessage,
        codec: VideoToolboxCodec?,
        normalizedData: Data?,
        decodeReadiness: Pocket3LiveViewDecodeReadiness,
        nalTypes: [UInt8],
        containsIDR: Bool,
        containsIRAP: Bool,
        parameterSetsChanged: Bool,
        videoToolboxInputValidated: Bool,
        normalizationError: String?
    ) -> Pocket3LiveViewMediaMessage {
        Pocket3LiveViewMediaMessage(
            sessionID: value.sessionID, generation: value.generation,
            messageID: value.messageID, declaredLength: value.declaredLength,
            data: value.data, firstHeader: value.firstHeader,
            firstTransportSequence: value.firstTransportSequence,
            lastTransportSequence: value.lastTransportSequence,
            fragmentCount: value.fragmentCount, groupIDs: value.groupIDs,
            crossedGroupBoundary: value.crossedGroupBoundary,
            codec: codec, normalizedData: normalizedData,
            decodeReadiness: decodeReadiness, nalTypes: nalTypes,
            containsIDR: containsIDR, containsIRAP: containsIRAP,
            parameterSetsChanged: parameterSetsChanged,
            videoToolboxInputValidated: videoToolboxInputValidated,
            normalizationError: normalizationError)
    }

    private func map(_ readiness: H264DecodeReadiness)
        -> Pocket3LiveViewDecodeReadiness {
        switch readiness {
        case .waitingForParameterSets: .waitingForParameterSets
        case .waitingForIDR: .waitingForRandomAccess
        case .ready: .ready
        }
    }

    private func map(_ readiness: HEVCDecodeReadiness)
        -> Pocket3LiveViewDecodeReadiness {
        switch readiness {
        case .waitingForParameterSets: .waitingForParameterSets
        case .waitingForIRAP: .waitingForRandomAccess
        case .ready: .ready
        }
    }

    private mutating func enqueue(_ message: Pocket3LiveViewMediaMessage) {
        let cost = message.memoryCost
        guard cost <= limits.maximumQueuedBytes else {
            queueDropCount &+= 1
            return
        }
        while !queue.isEmpty &&
              (queue.count >= limits.maximumQueuedMessages ||
               queueBytes > limits.maximumQueuedBytes - cost) {
            let removed = queue.removeFirst()
            queueBytes -= removed.memoryCost
            queueDropCount &+= 1
        }
        queue.append(message)
        queueBytes += cost
    }

    public static func detectCodec(_ data: Data) -> VideoToolboxCodec? {
        let units = annexBNALUnits(data)
        guard !units.isEmpty else { return nil }
        let h264Types = units.compactMap { unit -> UInt8? in
            guard let first = unit.first, first & 0x80 == 0 else { return nil }
            let type = first & 0x1F
            return (1...23).contains(type) ? type : nil
        }
        let hevcTypes = units.compactMap { unit -> UInt8? in
            guard unit.count >= 2, unit[0] & 0x80 == 0,
                  unit[1] & 0x07 != 0 else { return nil }
            let type = (unit[0] & 0x7E) >> 1
            return (0...47).contains(type) ? type : nil
        }
        let h264Parameter = h264Types.contains(7) || h264Types.contains(8)
        let hevcParameter = hevcTypes.contains(32) || hevcTypes.contains(33) ||
            hevcTypes.contains(34)
        if h264Parameter && !hevcParameter { return .h264 }
        if hevcParameter && !h264Parameter { return .hevc }
        if h264Types.contains(5) && !hevcTypes.contains(where: { (16...23).contains($0) }) {
            return .h264
        }
        if hevcTypes.contains(where: { (16...23).contains($0) }) &&
           !h264Types.contains(5) {
            return .hevc
        }
        return nil
    }

    private static func annexBNALUnits(_ data: Data) -> [Data] {
        let bytes = Array(data)
        guard let first = startCodeLength(bytes, at: 0) else { return [] }
        var result: [Data] = []
        var start = first
        while start < bytes.count {
            var next: Int?
            var cursor = start
            while cursor < bytes.count {
                if startCodeLength(bytes, at: cursor) != nil {
                    next = cursor
                    break
                }
                cursor += 1
            }
            let end = next ?? bytes.count
            guard end > start else { return [] }
            result.append(Data(bytes[start..<end]))
            guard let next else { break }
            guard let code = startCodeLength(bytes, at: next) else { return [] }
            start = next + code
        }
        return result
    }

    private static func startCodeLength(_ bytes: [UInt8], at index: Int)
        -> Int? {
        guard index >= 0, index + 3 <= bytes.count,
              bytes[index] == 0, bytes[index + 1] == 0 else { return nil }
        if index + 4 <= bytes.count, bytes[index + 2] == 0,
           bytes[index + 3] == 1 { return 4 }
        if bytes[index + 2] == 1 { return 3 }
        return nil
    }
}

public typealias Pocket3VideoFragment = Pocket3LiveViewVideoFragment
public typealias Pocket3LiveViewFragmentAssembler = Pocket3LiveViewMediaAssembler
public typealias Pocket3LiveViewVideoAssembler = Pocket3LiveViewMediaAssembler
public typealias Pocket3DatalinkVideoAssembler = Pocket3LiveViewMediaAssembler
public typealias Pocket3LiveViewMessage = Pocket3LiveViewMediaMessage

public typealias Pocket3VideoMediaAssembler = Pocket3LiveViewMediaAssembler
public typealias Pocket3VideoMediaMessage = Pocket3LiveViewMediaMessage

public enum Pocket3LiveViewCodecDetector {
    public static func detect(_ data: Data) -> VideoToolboxCodec? {
        Pocket3LiveViewMediaAssembler.detectCodec(data)
    }
}
