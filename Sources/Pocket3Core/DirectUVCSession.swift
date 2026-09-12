import Foundation

// These conformances keep the public diagnostic plan serializable without
// adding any IOKit or private UVC framework dependency.
extension UVCVideoStreamingRequest: Codable {}
extension UVCVideoStreamingControlBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case bmHint, formatIndex, frameIndex, frameInterval, keyFrameRate,
             pFrameRate, compressionQuality, compressionWindowSize, delay,
             maxVideoFrameSize, maxPayloadTransferSize
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bmHint: try values.decode(UInt16.self, forKey: .bmHint),
            formatIndex: try values.decode(UInt8.self, forKey: .formatIndex),
            frameIndex: try values.decode(UInt8.self, forKey: .frameIndex),
            frameInterval: try values.decode(UInt32.self, forKey: .frameInterval),
            keyFrameRate: try values.decode(UInt16.self, forKey: .keyFrameRate),
            pFrameRate: try values.decode(UInt16.self, forKey: .pFrameRate),
            compressionQuality: try values.decode(UInt16.self, forKey: .compressionQuality),
            compressionWindowSize: try values.decode(UInt16.self, forKey: .compressionWindowSize),
            delay: try values.decode(UInt16.self, forKey: .delay),
            maxVideoFrameSize: try values.decode(UInt32.self, forKey: .maxVideoFrameSize),
            maxPayloadTransferSize: try values.decode(UInt32.self, forKey: .maxPayloadTransferSize))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(bmHint, forKey: .bmHint)
        try values.encode(formatIndex, forKey: .formatIndex)
        try values.encode(frameIndex, forKey: .frameIndex)
        try values.encode(frameInterval, forKey: .frameInterval)
        try values.encode(keyFrameRate, forKey: .keyFrameRate)
        try values.encode(pFrameRate, forKey: .pFrameRate)
        try values.encode(compressionQuality, forKey: .compressionQuality)
        try values.encode(compressionWindowSize, forKey: .compressionWindowSize)
        try values.encode(delay, forKey: .delay)
        try values.encode(maxVideoFrameSize, forKey: .maxVideoFrameSize)
        try values.encode(maxPayloadTransferSize, forKey: .maxPayloadTransferSize)
    }
}

public enum DirectUVCVideoCodec: String, Codable, Sendable, Equatable,
    CaseIterable {
    case h264
    case hevc
}

/// Descriptor-backed selection for one future direct VideoStreaming owner.
/// `endpointAddress == 0` is not allowed in a final plan; callers may use it
/// only in the configuration before the planner resolves a descriptor.
public struct DirectUVCStreamConfiguration: Codable, Sendable, Equatable {
    public let codec: DirectUVCVideoCodec
    public let controlInterfaceNumber: UInt8
    public let streamingInterfaceNumber: UInt8
    public let alternateSetting: UInt8
    public let endpointAddress: UInt8
    public let formatIndex: UInt8
    public let frameIndex: UInt8
    public let width: UInt16
    public let height: UInt16
    public let supportedIntervals100ns: [UInt32]
    public let frameInterval100ns: UInt32

    public init(
        codec: DirectUVCVideoCodec,
        controlInterfaceNumber: UInt8 = 0,
        streamingInterfaceNumber: UInt8 = 1,
        alternateSetting: UInt8 = 0,
        endpointAddress: UInt8 = 0x82,
        formatIndex: UInt8,
        frameIndex: UInt8,
        width: UInt16,
        height: UInt16,
        supportedIntervals100ns: [UInt32],
        frameInterval100ns: UInt32
    ) throws {
        guard streamingInterfaceNumber != controlInterfaceNumber,
              endpointAddress & 0x80 != 0,
              !supportedIntervals100ns.isEmpty,
              supportedIntervals100ns.contains(frameInterval100ns),
              width > 0, height > 0 else {
            throw DirectUVCError.invalidConfiguration
        }
        self.codec = codec
        self.controlInterfaceNumber = controlInterfaceNumber
        self.streamingInterfaceNumber = streamingInterfaceNumber
        self.alternateSetting = alternateSetting
        self.endpointAddress = endpointAddress
        self.formatIndex = formatIndex
        self.frameIndex = frameIndex
        self.width = width
        self.height = height
        self.supportedIntervals100ns = supportedIntervals100ns
        self.frameInterval100ns = frameInterval100ns
    }

    public init(
        mode: Pocket3H264Mode,
        interval100ns: UInt32 = Pocket3H264ModeCatalog.frame2.defaultFrameInterval100ns,
        endpointAddress: UInt8 = 0x82,
        alternateSetting: UInt8 = 0
    ) throws {
        try self.init(
            codec: .h264,
            streamingInterfaceNumber: Pocket3H264Mode.streamingInterfaceNumber,
            alternateSetting: alternateSetting,
            endpointAddress: endpointAddress,
            formatIndex: mode.formatIndex,
            frameIndex: mode.frameIndex,
            width: mode.width,
            height: mode.height,
            supportedIntervals100ns: mode.frameIntervals100ns,
            frameInterval100ns: interval100ns)
    }
}

public struct DirectUVCDescriptorSelection: Codable, Sendable, Equatable {
    public let controlInterface: UVCInterfaceInventory
    public let streamingInterface: UVCInterfaceInventory
    public let endpoint: UVCStreamingEndpoint

    public init(controlInterface: UVCInterfaceInventory,
                streamingInterface: UVCInterfaceInventory,
                endpoint: UVCStreamingEndpoint) {
        self.controlInterface = controlInterface
        self.streamingInterface = streamingInterface
        self.endpoint = endpoint
    }
}

public struct DirectUVCStreamPlan: Codable, Sendable, Equatable {
    public let configuration: DirectUVCStreamConfiguration
    public let selection: DirectUVCDescriptorSelection
    public let desiredProbe: UVCVideoStreamingControlBlock
    public let negotiationRequests: [UVCVideoStreamingRequest]

    public init(configuration: DirectUVCStreamConfiguration,
                selection: DirectUVCDescriptorSelection,
                desiredProbe: UVCVideoStreamingControlBlock,
                negotiationRequests: [UVCVideoStreamingRequest] = [
                    .getMaxProbe, .setCurProbe, .getCurProbe, .setCurCommit
                ]) {
        self.configuration = configuration
        self.selection = selection
        self.desiredProbe = desiredProbe
        self.negotiationRequests = negotiationRequests
    }
}

public enum DirectUVCError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration
    case controlInterfaceUnavailable
    case streamingInterfaceUnavailable
    case codecUnavailable(DirectUVCVideoCodec)
    case endpointUnavailable
    case endpointNotIN
    case endpointNotBulk
    case endpointPacketSizeInvalid
    case unsupportedMode
    case negotiationFailed(String)
    case transportUnavailable
    case invalidState(String)
    case staleGeneration
    case ownershipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "direct UVC stream configuration is invalid"
        case .controlInterfaceUnavailable: return "UVC VideoControl interface is unavailable"
        case .streamingInterfaceUnavailable: return "UVC VideoStreaming interface is unavailable"
        case .codecUnavailable(let codec): return "UVC descriptor does not advertise " + codec.rawValue
        case .endpointUnavailable: return "UVC bulk IN endpoint is unavailable"
        case .endpointNotIN: return "UVC streaming endpoint is not bulk IN"
        case .endpointNotBulk: return "UVC streaming endpoint is not bulk"
        case .endpointPacketSizeInvalid: return "UVC streaming endpoint packet size is invalid"
        case .unsupportedMode: return "direct UVC mode is not descriptor-backed"
        case .negotiationFailed(let reason): return "direct UVC negotiation failed: " + reason
        case .transportUnavailable: return "direct UVC transport is unavailable"
        case .invalidState(let state): return "direct UVC session is in " + state
        case .staleGeneration: return "direct UVC ownership generation changed"
        case .ownershipFailed(let reason): return "direct UVC ownership failed: " + reason
        }
    }
}

/// Pure descriptor selection. It never opens a USB device or interface and it
/// never turns a descriptor claim into a stream capability claim.
public enum DirectUVCStreamPlanner {
    public static func plan(
        inventory: UVCDescriptorInventory,
        configuration: DirectUVCStreamConfiguration
    ) throws -> DirectUVCStreamPlan {
        guard let control = inventory.videoControlInterfaces.first(where: {
            $0.number == configuration.controlInterfaceNumber
        }) else {
            throw DirectUVCError.controlInterfaceUnavailable
        }
        guard let streaming = inventory.videoStreamingInterfaces.first(where: {
            $0.number == configuration.streamingInterfaceNumber &&
                $0.alternateSetting == configuration.alternateSetting
        }) else {
            throw DirectUVCError.streamingInterfaceUnavailable
        }
        let codecName = configuration.codec == .h264 ? "H264" : "HEVC"
        guard streaming.codecNames.contains(codecName) else {
            throw DirectUVCError.codecUnavailable(configuration.codec)
        }
        guard configuration.supportedIntervals100ns.contains(
            configuration.frameInterval100ns) else {
            throw DirectUVCError.unsupportedMode
        }
        guard let endpoint = streaming.endpoints.first(where: {
            $0.address == configuration.endpointAddress
        }) else {
            throw DirectUVCError.endpointUnavailable
        }
        guard endpoint.isIN else { throw DirectUVCError.endpointNotIN }
        guard endpoint.isBulk else { throw DirectUVCError.endpointNotBulk }
        guard endpoint.maximumPacketSize > 0 else {
            throw DirectUVCError.endpointPacketSizeInvalid
        }

        let desired = UVCVideoStreamingControlBlock(
            formatIndex: configuration.formatIndex,
            frameIndex: configuration.frameIndex,
            frameInterval: configuration.frameInterval100ns)
        return DirectUVCStreamPlan(
            configuration: configuration,
            selection: DirectUVCDescriptorSelection(
                controlInterface: control,
                streamingInterface: streaming,
                endpoint: endpoint),
            desiredProbe: desired)
    }

    public static func pocket3H264(
        inventory: UVCDescriptorInventory,
        mode: Pocket3H264Mode = Pocket3H264ModeCatalog.frame2,
        interval100ns: UInt32? = nil,
        endpointAddress: UInt8 = 0x82
    ) throws -> DirectUVCStreamPlan {
        let interval = interval100ns ?? mode.defaultFrameInterval100ns
        let configuration = try DirectUVCStreamConfiguration(
            mode: mode, interval100ns: interval,
            endpointAddress: endpointAddress)
        return try plan(inventory: inventory, configuration: configuration)
    }
}

/// One negotiation step. Payload bytes are represented by their count and the
/// accepted probe is retained as typed fields in the result; raw USB bytes are
/// not retained by this coordinator.
public struct DirectUVCNegotiationStep: Codable, Sendable, Equatable {
    public let request: UVCVideoStreamingRequest
    public let payloadByteCount: Int
    public let responseByteCount: Int
    public let submitted: Bool
    public let validated: Bool
    public let failureCode: String?

    public init(request: UVCVideoStreamingRequest,
                payloadByteCount: Int = 0,
                responseByteCount: Int = 0,
                submitted: Bool,
                validated: Bool,
                failureCode: String? = nil) {
        self.request = request
        self.payloadByteCount = payloadByteCount
        self.responseByteCount = responseByteCount
        self.submitted = submitted
        self.validated = validated
        self.failureCode = failureCode.map { String($0.prefix(128)) }
    }
}

public struct DirectUVCNegotiationResult: Codable, Sendable, Equatable {
    public let phase: String
    public let requested: Bool
    public let submittedCount: Int
    public let probeMaximum: UVCVideoStreamingControlBlock?
    public let probeAccepted: UVCVideoStreamingControlBlock?
    public let committed: Bool
    public let steps: [DirectUVCNegotiationStep]
    public let failureCode: String?

    public init(phase: String = "idle", requested: Bool = false,
                submittedCount: Int = 0,
                probeMaximum: UVCVideoStreamingControlBlock? = nil,
                probeAccepted: UVCVideoStreamingControlBlock? = nil,
                committed: Bool = false,
                steps: [DirectUVCNegotiationStep] = [],
                failureCode: String? = nil) {
        self.phase = phase
        self.requested = requested
        self.submittedCount = submittedCount
        self.probeMaximum = probeMaximum
        self.probeAccepted = probeAccepted
        self.committed = committed
        self.steps = steps
        self.failureCode = failureCode.map { String($0.prefix(128)) }
    }

    public var completed: Bool { committed && failureCode == nil }
}

/// Injectable public-API boundary for a future VS interface implementation.
/// No implementation in this target opens an interface, seizes an endpoint,
/// changes an alternate setting, or reads a bulk pipe.
public protocol DirectUVCStreamHandle: AnyObject, Sendable {
    func control(_ request: UVCVideoStreamingRequest,
                 payload: Data?) async throws -> Data?
    func release() async throws -> DirectCaptureReleaseEvidence
}

public protocol DirectUVCStreamTransport: Sendable {
    func acquire(plan: DirectUVCStreamPlan) async throws
        -> any DirectUVCStreamHandle
}

public enum DirectUVCNegotiator {
    public static func run(
        plan: DirectUVCStreamPlan,
        handle: any DirectUVCStreamHandle
    ) async -> DirectUVCNegotiationResult {
        var steps: [DirectUVCNegotiationStep] = []
        var submittedCount = 0
        var maximum: UVCVideoStreamingControlBlock?
        var accepted: UVCVideoStreamingControlBlock?

        func failure(_ request: UVCVideoStreamingRequest,
                     payloadBytes: Int = 0,
                     responseBytes: Int = 0,
                     reason: String) -> DirectUVCNegotiationResult {
            var all = steps
            all.append(DirectUVCNegotiationStep(
                request: request, payloadByteCount: payloadBytes,
                responseByteCount: responseBytes, submitted: false,
                validated: false, failureCode: reason))
            return DirectUVCNegotiationResult(
                phase: "failed", requested: true,
                submittedCount: submittedCount,
                probeMaximum: maximum, probeAccepted: accepted,
                steps: all, failureCode: reason)
        }

        do {
            guard plan.negotiationRequests == [
                .getMaxProbe, .setCurProbe, .getCurProbe, .setCurCommit
            ] else {
                return DirectUVCNegotiationResult(
                    phase: "failed", requested: true,
                    failureCode: "direct_uvc_negotiation_sequence_invalid")
            }
            guard plan.configuration.codec == .h264 else {
                return DirectUVCNegotiationResult(
                    phase: "failed", requested: true,
                    failureCode: "direct_uvc_codec_not_validated")
            }

            guard let maxData = try await handle.control(
                .getMaxProbe, payload: nil) else {
                return failure(.getMaxProbe, reason: "probe_max_missing")
            }
            submittedCount += 1
            do {
                let value = try UVCVideoStreamingControlBlock.decode(maxData)
                guard value.formatIndex == plan.configuration.formatIndex,
                      value.frameIndex == plan.configuration.frameIndex,
                      value.frameInterval == plan.configuration.frameInterval100ns else {
                    return failure(.getMaxProbe,
                        responseBytes: maxData.count,
                        reason: "probe_max_tuple_mismatch")
                }
                maximum = value
                steps.append(DirectUVCNegotiationStep(
                    request: .getMaxProbe,
                    responseByteCount: maxData.count, submitted: true,
                    validated: true))
            } catch {
                return failure(.getMaxProbe, responseBytes: maxData.count,
                                reason: "probe_max_invalid")
            }

            guard let maximum else {
                return failure(.getMaxProbe, reason: "probe_max_missing")
            }
            let desired = plan.desiredProbe
            let requested = UVCVideoStreamingControlBlock(
                bmHint: desired.bmHint,
                formatIndex: desired.formatIndex,
                frameIndex: desired.frameIndex,
                frameInterval: desired.frameInterval,
                keyFrameRate: desired.keyFrameRate,
                pFrameRate: desired.pFrameRate,
                compressionQuality: desired.compressionQuality,
                compressionWindowSize: desired.compressionWindowSize,
                delay: desired.delay,
                maxVideoFrameSize: maximum.maxVideoFrameSize,
                maxPayloadTransferSize: maximum.maxPayloadTransferSize)

            let setProbeResponse = try await handle.control(
                .setCurProbe, payload: requested.encodedData)
            submittedCount += 1
            if let setProbeResponse, !setProbeResponse.isEmpty {
                return failure(.setCurProbe,
                    payloadBytes: requested.encodedData.count,
                    responseBytes: setProbeResponse.count,
                    reason: "probe_set_unexpected_response")
            }
            steps.append(DirectUVCNegotiationStep(
                request: .setCurProbe,
                payloadByteCount: requested.encodedData.count,
                submitted: true, validated: true))

            guard let curData = try await handle.control(
                .getCurProbe, payload: nil) else {
                return failure(.getCurProbe, reason: "probe_cur_missing")
            }
            submittedCount += 1
            let current: UVCVideoStreamingControlBlock
            do {
                current = try UVCVideoStreamingControlBlock.decode(curData)
                guard current.formatIndex == plan.configuration.formatIndex,
                      current.frameIndex == plan.configuration.frameIndex,
                      current.frameInterval == plan.configuration.frameInterval100ns,
                      current.maxVideoFrameSize <= UVCProbeCommitSizeBounds.pocket3H264.maximumVideoFrameSize,
                      current.maxPayloadTransferSize <= UVCProbeCommitSizeBounds.pocket3H264.maximumPayloadTransferSize else {
                    return failure(.getCurProbe,
                        responseBytes: curData.count,
                        reason: "probe_cur_tuple_mismatch")
                }
            } catch {
                return failure(.getCurProbe, responseBytes: curData.count,
                                reason: "probe_cur_invalid")
            }
            accepted = current
            steps.append(DirectUVCNegotiationStep(
                request: .getCurProbe,
                responseByteCount: curData.count, submitted: true,
                validated: true))

            let commitResponse = try await handle.control(
                .setCurCommit, payload: current.encodedData)
            submittedCount += 1
            if let commitResponse, !commitResponse.isEmpty {
                return failure(.setCurCommit,
                    payloadBytes: current.encodedData.count,
                    responseBytes: commitResponse.count,
                    reason: "commit_unexpected_response")
            }
            steps.append(DirectUVCNegotiationStep(
                request: .setCurCommit,
                payloadByteCount: current.encodedData.count,
                submitted: true, validated: true))
            return DirectUVCNegotiationResult(
                phase: "committed", requested: true,
                submittedCount: submittedCount,
                probeMaximum: maximum, probeAccepted: current,
                committed: true, steps: steps)
        } catch {
            let request = plan.negotiationRequests[safe: steps.count]
                ?? .getMaxProbe
            return failure(request, reason: Self.errorCode(error))
        }
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? CaptureOwnershipError {
            switch error {
            case .busy: return "direct_uvc_ownership_busy"
            case .invalidState: return "direct_uvc_ownership_invalid_state"
            case .stalePermit: return "direct_uvc_ownership_stale_permit"
            case .evidenceRequired(let evidence):
                return "direct_uvc_ownership_evidence_required_" + evidence.rawValue
            case .operationFailed: return "direct_uvc_ownership_failed"
            case .recoveryUnavailable: return "direct_uvc_ownership_recovery_unavailable"
            }
        }
        if let error = error as? DirectUVCError {
            switch error {
            case .invalidConfiguration: return "direct_uvc_invalid_configuration"
            case .controlInterfaceUnavailable: return "direct_uvc_control_interface_missing"
            case .streamingInterfaceUnavailable: return "direct_uvc_streaming_interface_missing"
            case .codecUnavailable: return "direct_uvc_codec_unavailable"
            case .endpointUnavailable: return "direct_uvc_endpoint_missing"
            case .endpointNotIN: return "direct_uvc_endpoint_not_in"
            case .endpointNotBulk: return "direct_uvc_endpoint_not_bulk"
            case .endpointPacketSizeInvalid: return "direct_uvc_endpoint_packet_size_invalid"
            case .unsupportedMode: return "direct_uvc_mode_unsupported"
            case .negotiationFailed(let reason): return reason
            case .transportUnavailable: return "direct_uvc_transport_unavailable"
            case .invalidState: return "direct_uvc_invalid_state"
            case .staleGeneration: return "direct_uvc_generation_changed"
            case .ownershipFailed: return "direct_uvc_ownership_failed"
            }
        }
        return String(String(describing: error).prefix(128))
    }
}

public enum DirectUVCSessionPhase: String, Codable, Sendable, Equatable,
    CaseIterable {
    case idle
    case stoppingAVFoundation
    case acquiringDirect
    case negotiating
    case directNegotiated
    case releasingDirect
    case awaitingAVFoundationRestart
    case cancelled
    case generationChanged
    case failed
}

public struct DirectUVCSessionSnapshot: Codable, Sendable, Equatable {
    public let phase: DirectUVCSessionPhase
    public let generation: UInt64
    public let ownershipState: CaptureOwnershipState
    public let ownershipGeneration: UInt64
    public let transportAcquired: Bool
    public let negotiation: DirectUVCNegotiationResult?
    public let releaseEvidence: DirectCaptureReleaseEvidence?
    public let failureCode: String?
}

public struct DirectUVCSessionResult: Codable, Sendable, Equatable {
    public let phase: DirectUVCSessionPhase
    public let generation: UInt64
    public let requested: Bool
    public let avfoundationStopEvidence: AVFoundationStopEvidence?
    public let transportAcquired: Bool
    public let negotiation: DirectUVCNegotiationResult?
    public let negotiated: Bool
    public let bulkReadReady: Bool
    public let releaseEvidence: DirectCaptureReleaseEvidence?
    public let failureCode: String?

    public var ready: Bool { negotiated && bulkReadReady }
}

/// Actor facade joining the descriptor/control plan to the existing
/// AVFoundation↔direct ownership reducer. It has no concrete USB transport;
/// production code must inject a separately reviewed public-API transport.
public actor DirectUVCSessionCoordinator {
    public let plan: DirectUVCStreamPlan

    private let transport: any DirectUVCStreamTransport
    private let ownership: CaptureOwnershipCoordinator
    private var phase: DirectUVCSessionPhase = .idle
    private var generation: UInt64 = 0
    private var stopEvidence: AVFoundationStopEvidence?
    private var handle: (any DirectUVCStreamHandle)?
    private var negotiation: DirectUVCNegotiationResult?
    private var releaseEvidence: DirectCaptureReleaseEvidence?
    private var activePermit: CaptureOwnershipPermit?
    private var restartPermit: CaptureOwnershipPermit?
    private var failureCode: String?
    private var attemptID: UUID?

    public init(
        plan: DirectUVCStreamPlan,
        transport: any DirectUVCStreamTransport,
        ownership: CaptureOwnershipCoordinator = CaptureOwnershipCoordinator(
            initialState: .avfoundationRunning)
    ) {
        self.plan = plan
        self.transport = transport
        self.ownership = ownership
    }

    public func snapshot() async -> DirectUVCSessionSnapshot {
        let ownership = await ownership.snapshot()
        return DirectUVCSessionSnapshot(
            phase: phase, generation: generation,
            ownershipState: ownership.state,
            ownershipGeneration: ownership.generation,
            transportAcquired: handle != nil,
            negotiation: negotiation,
            releaseEvidence: releaseEvidence,
            failureCode: failureCode)
    }

    /// Requests the direct handoff only after the caller supplies complete
    /// AVFoundation stop/drain evidence. No endpoint is opened by this actor.
    public func start(
        after evidence: AVFoundationStopEvidence
    ) async -> DirectUVCSessionResult {
        guard phase == .idle else {
            return await result(failure: "direct_uvc_session_busy")
        }
        generation = generation == UInt64.max ? 1 : generation + 1
        stopEvidence = evidence
        failureCode = nil
        negotiation = nil
        releaseEvidence = nil
        restartPermit = nil
        let attempt = UUID()
        attemptID = attempt
        phase = .stoppingAVFoundation

        let stopPermit: CaptureOwnershipPermit
        do {
            stopPermit = try await ownership.beginDirectCapture()
            activePermit = stopPermit
            let acquirePermit = try await ownership.avfoundationStopped(
                stopPermit, evidence: evidence)
            activePermit = acquirePermit
            phase = .acquiringDirect
            let acquired = try await transport.acquire(plan: plan)
            guard attemptID == attempt else {
                _ = try? await acquired.release()
                return await result(failure: "direct_uvc_cancelled")
            }
            handle = acquired
            try await ownership.directAcquired(acquirePermit)
            activePermit = nil
            phase = .negotiating
            let negotiated = await DirectUVCNegotiator.run(
                plan: plan, handle: acquired)
            guard attemptID == attempt else {
                return await result(failure: "direct_uvc_generation_changed")
            }
            negotiation = negotiated
            if negotiated.completed {
                phase = .directNegotiated
                failureCode = nil
            } else {
                phase = .failed
                failureCode = negotiated.failureCode ??
                    "direct_uvc_negotiation_failed"
            }
            attemptID = nil
            return await result()
        } catch {
            guard attemptID == attempt else {
                return await result(failure: "direct_uvc_generation_changed")
            }
            if let activePermit {
                _ = try? await ownership.cancel(activePermit)
                self.activePermit = nil
            }
            phase = .failed
            failureCode = Self.errorCode(error)
            attemptID = nil
            return await result()
        }
    }

    /// Release a negotiated direct owner. The caller must separately report
    /// AVFoundation restart after the complete release fence is returned.
    public func stop() async -> DirectUVCSessionResult {
        guard handle != nil else {
            return await result(failure: phase == .idle
                ? "direct_uvc_not_acquired" : failureCode)
        }
        attemptID = nil
        phase = .releasingDirect
        do {
            let permit = try await ownership.beginAVFoundationRestart()
            let evidence = try await handle!.release()
            releaseEvidence = evidence
            let restart = try await ownership.directReleased(
                permit, evidence: evidence)
            restartPermit = restart
            handle = nil
            phase = .awaitingAVFoundationRestart
            failureCode = evidence.isComplete ? nil :
                "direct_uvc_release_incomplete"
            return await result()
        } catch {
            phase = .failed
            failureCode = Self.errorCode(error)
            return await result()
        }
    }

    /// Complete the external AVFoundation restart only after the direct
    /// handle has reported every release fence.
    public func avfoundationRestarted() async -> DirectUVCSessionResult {
        guard (phase == .awaitingAVFoundationRestart || phase == .cancelled),
              let restartPermit else {
            return await result(failure: "direct_uvc_restart_not_ready")
        }
        do {
            try await ownership.avfoundationRestarted(restartPermit)
            self.restartPermit = nil
            phase = .idle
            failureCode = nil
            return await result()
        } catch {
            phase = .failed
            failureCode = Self.errorCode(error)
            return await result()
        }
    }

    /// Cancellation invalidates the active ownership permit and never starts
    /// a new transport operation. If direct ownership was already acquired,
    /// the handle is released exactly once and the ownership policy is left
    /// awaiting an explicit AVFoundation restart. A caller can disconnect
    /// instead when the physical endpoint has disappeared.
    public func cancel() async -> DirectUVCSessionResult {
        attemptID = nil
        if let activePermit {
            _ = try? await ownership.cancel(activePermit)
            self.activePermit = nil
        }
        if let handle {
            let ownershipState = await ownership.state()
            do {
                if ownershipState == .directRunning {
                    let permit = try await ownership.beginAVFoundationRestart()
                    let evidence = try await handle.release()
                    releaseEvidence = evidence
                    restartPermit = try await ownership.directReleased(
                        permit, evidence: evidence)
                } else {
                    // A handle can arrive after a stale acquire callback. The
                    // policy has already fenced that path, so only release
                    // the transport object and retain the policy failure.
                    releaseEvidence = try await handle.release()
                }
            } catch {
                self.handle = nil
                phase = .failed
                failureCode = Self.errorCode(error)
                return await result()
            }
            self.handle = nil
        }
        phase = .cancelled
        failureCode = "cancelled"
        return await result()
    }

    public func disconnect() async -> DirectUVCSessionResult {
        await cancel()
    }

    private func result(failure: String? = nil) async
        -> DirectUVCSessionResult {
        let ownership = await ownership.snapshot()
        let failureCode = failure ?? self.failureCode
        return DirectUVCSessionResult(
            phase: phase, generation: generation,
            requested: stopEvidence != nil,
            avfoundationStopEvidence: stopEvidence,
            transportAcquired: handle != nil || negotiation != nil,
            negotiation: negotiation,
            negotiated: negotiation?.completed == true,
            bulkReadReady: false,
            releaseEvidence: releaseEvidence,
            failureCode: failureCode ?? ownershipFailure(ownership))
    }

    private func ownershipFailure(_ snapshot: CaptureOwnershipSnapshot)
        -> String? {
        switch snapshot.failure {
        case .cancelled(let stage):
            return "direct_uvc_ownership_cancelled_" + stage.rawValue
        case .operationFailed(let stage):
            return "direct_uvc_ownership_failed_" + stage.rawValue
        case .disconnected: return "direct_uvc_ownership_disconnected"
        case nil: return nil
        }
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? CaptureOwnershipError {
            switch error {
            case .busy: return "direct_uvc_ownership_busy"
            case .invalidState: return "direct_uvc_ownership_invalid_state"
            case .stalePermit: return "direct_uvc_ownership_stale_permit"
            case .evidenceRequired(let evidence):
                return "direct_uvc_ownership_evidence_required_" + evidence.rawValue
            case .operationFailed: return "direct_uvc_ownership_failed"
            case .recoveryUnavailable: return "direct_uvc_ownership_recovery_unavailable"
            }
        }
        if let error = error as? DirectUVCError {
            switch error {
            case .invalidConfiguration: return "direct_uvc_invalid_configuration"
            case .controlInterfaceUnavailable: return "direct_uvc_control_interface_missing"
            case .streamingInterfaceUnavailable: return "direct_uvc_streaming_interface_missing"
            case .codecUnavailable: return "direct_uvc_codec_unavailable"
            case .endpointUnavailable: return "direct_uvc_endpoint_missing"
            case .endpointNotIN: return "direct_uvc_endpoint_not_in"
            case .endpointNotBulk: return "direct_uvc_endpoint_not_bulk"
            case .endpointPacketSizeInvalid: return "direct_uvc_endpoint_packet_size_invalid"
            case .unsupportedMode: return "direct_uvc_mode_unsupported"
            case .negotiationFailed(let reason): return reason
            case .transportUnavailable: return "direct_uvc_transport_unavailable"
            case .invalidState: return "direct_uvc_invalid_state"
            case .staleGeneration: return "direct_uvc_generation_changed"
            case .ownershipFailed: return "direct_uvc_ownership_failed"
            }
        }
        return String(String(describing: error).prefix(128))
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
