import Foundation

/// Explicit product output selection for the Mac capture path.
///
/// `host-hevc` is an additional host-side output mode. It consumes copied
/// BGRA/NV12 frames from the existing capture path and leaves the BGRA preview
/// available to its caller. It does not describe, enable, or infer a codec on
/// the camera USB wire.
public enum HostHEVCProductSelection: String, Codable, CaseIterable, Sendable,
    Equatable, Identifiable {
    case bgraPreview = "bgra"
    case hostHEVC = "host-hevc"

    public var id: String { rawValue }
}

/// Immutable provenance and fallback contract for one product selection.
///
/// The initializer derives all transport and codec fields from the selection,
/// so callers cannot construct a `host-hevc` status that claims USB-wire HEVC
/// or silently falls back to BGRA after an encoder failure.
public struct HostHEVCProductContract: Codable, Sendable, Equatable {
    public let selection: HostHEVCProductSelection
    public let transport: HostVideoEncodingTransport?
    public let codec: VideoToolboxCodec?
    public let codecIdentifier: String?
    public let inputPixelFormats: [HostVideoInputPixelFormat]
    public let supportsConcurrentBGRAPreview: Bool
    public let automaticFallback: Bool
    public let usbWireCodecClaim: String?

    public init(selection: HostHEVCProductSelection) {
        self.selection = selection
        self.supportsConcurrentBGRAPreview = true
        self.automaticFallback = false
        self.usbWireCodecClaim = nil
        switch selection {
        case .bgraPreview:
            self.transport = nil
            self.codec = nil
            self.codecIdentifier = nil
            self.inputPixelFormats = [.bgra]
        case .hostHEVC:
            self.transport = .macVideoToolboxHost
            self.codec = .hevc
            self.codecIdentifier = "hvc1"
            self.inputPixelFormats = [
                .bgra, .nv12VideoRange, .nv12FullRange
            ]
        }
    }
}

/// Runtime capability projected from the bounded host output session.
/// Contract fields remain fixed by `HostHEVCProductContract`; the remaining
/// fields are observations from the current or most recently stopped session.
public struct HostHEVCProductCapability: Codable, Sendable, Equatable {
    public let contract: HostHEVCProductContract
    public let sessionID: String?
    public let generation: UInt64?
    public let configured: Bool
    public let verified: Bool
    public let observedSampleCount: Int

    public var selection: HostHEVCProductSelection { contract.selection }
    public var transport: HostVideoEncodingTransport? { contract.transport }
    public var codec: VideoToolboxCodec? { contract.codec }
    public var codecIdentifier: String? { contract.codecIdentifier }
    public var inputPixelFormats: [HostVideoInputPixelFormat] {
        contract.inputPixelFormats
    }
    public var supportsConcurrentBGRAPreview: Bool {
        contract.supportsConcurrentBGRAPreview
    }
    public var automaticFallback: Bool { contract.automaticFallback }
    public var usbWireCodecClaim: String? { contract.usbWireCodecClaim }

    fileprivate init(contract: HostHEVCProductContract,
                     session: HostHEVCOutputSessionSnapshot?) {
        self.contract = contract
        self.sessionID = session?.sessionID
        self.generation = session?.generation
        self.configured = session?.capability.configured ?? false
        self.verified = session?.capability.verified ?? false
        self.observedSampleCount = session?.capability.observedSampleCount ?? 0
    }
}

public enum HostHEVCProductOutputPhase: String, Codable, Sendable, Equatable {
    case bgraPreview
    case idle
    case running
    case reconnecting
    case stopping
    case stopped
    case cancelled
    case failed
}

public struct HostHEVCProductOutputStatus: Codable, Sendable, Equatable {
    public let selection: HostHEVCProductSelection
    public let phase: HostHEVCProductOutputPhase
    public let capability: HostHEVCProductCapability
    public let session: HostHEVCOutputSessionSnapshot?
    public let sinkAttached: Bool
    public let failureCode: String?

    public var isRunning: Bool { phase == .running || phase == .reconnecting }
    public var isVerified: Bool { capability.verified }

    fileprivate init(selection: HostHEVCProductSelection,
                     phase: HostHEVCProductOutputPhase,
                     session: HostHEVCOutputSessionSnapshot?,
                     sinkAttached: Bool,
                     failureCode: String?) {
        self.selection = selection
        self.phase = phase
        self.capability = HostHEVCProductCapability(
            contract: HostHEVCProductContract(selection: selection),
            session: session)
        self.session = session
        self.sinkAttached = sinkAttached
        self.failureCode = failureCode ?? session?.failureCode
    }
}

public enum HostHEVCProductSubmissionDisposition: String, Codable, Sendable,
    Equatable {
    case accepted
    case droppedBackpressure
    case staleSession
    case staleGeneration
    case inputStale
    case inputClockInvalid
    case pixelFormatUnsupported
    case dimensionMismatch
    case notSelected
    case notRunning
    case stopped
}

public struct HostHEVCProductSubmissionEvidence: Codable, Sendable,
    Equatable {
    public let selection: HostHEVCProductSelection
    public let disposition: HostHEVCProductSubmissionDisposition
    public let sessionID: String
    public let generation: UInt64
    public let sequence: UInt64
    public let inputPixelFormat: HostVideoInputPixelFormat?
    public let inputAgeSeconds: Double?
    public let sessionEvidence: HostHEVCOutputSubmissionEvidence?

    fileprivate init(selection: HostHEVCProductSelection,
                     disposition: HostHEVCProductSubmissionDisposition,
                     frame: HostVideoFrame,
                     inputAgeSeconds: Double? = nil,
                     sessionEvidence: HostHEVCOutputSubmissionEvidence? = nil) {
        self.selection = selection
        self.disposition = disposition
        self.sessionID = String(frame.sessionID.prefix(128))
        self.generation = frame.generation
        self.sequence = frame.sequence
        self.inputPixelFormat = frame.inputPixelFormat
        self.inputAgeSeconds = inputAgeSeconds
        self.sessionEvidence = sessionEvidence
    }
}

public enum HostHEVCProductOutputError: Error, LocalizedError, Sendable,
    Equatable {
    case invalidFreshnessWindow
    case invalidSessionID
    case invalidGeneration
    case hostHEVCSelectionRequired
    case outputAlreadyRunning
    case outputNotRunning
    case selectionChangeRequiresStop
    case staleSession
    case staleGeneration

    public var errorDescription: String? {
        switch self {
        case .invalidFreshnessWindow:
            "host HEVC product freshness window is invalid"
        case .invalidSessionID:
            "host HEVC product session ID must be non-empty"
        case .invalidGeneration:
            "host HEVC product generation must be greater than zero"
        case .hostHEVCSelectionRequired:
            "select host-hevc before starting the host encoder"
        case .outputAlreadyRunning:
            "host HEVC product output is already running"
        case .outputNotRunning:
            "host HEVC product output is not running"
        case .selectionChangeRequiresStop:
            "stop host HEVC output before changing product selection"
        case .staleSession:
            "host HEVC product session identity changed"
        case .staleGeneration:
            "host HEVC product generation changed"
        }
    }
}

/// Product-facing lifecycle owner for explicit Mac host HEVC output.
///
/// The service does not own `CaptureEngine`, change its output policy, open a
/// USB endpoint, or retain a frame queue of its own. `startHostHEVC` attaches
/// one caller sink to one bounded `HostHEVCOutputSession`; stop/cancel releases
/// that session and sink. A failed host encoder stays failed until the caller
/// explicitly stops or cancels it, so BGRA is never an implicit fallback.
public actor HostHEVCProductOutputService {
    public typealias BackendFactory = @Sendable () -> any HostHEVCEncoderBackend
    public typealias SampleSink = @Sendable (HostHEVCEncodedSample) -> Void

    public let configuration: HostVideoEncoderConfiguration
    public let maximumInputAgeSeconds: Double

    private let backendFactory: BackendFactory
    private var selection: HostHEVCProductSelection = .bgraPreview
    private var outputSession: HostHEVCOutputSession?
    private var lastSessionSnapshot: HostHEVCOutputSessionSnapshot?

    public init(
        configuration: HostVideoEncoderConfiguration,
        maximumInputAgeSeconds: Double = 1,
        backendFactory: @escaping BackendFactory
    ) throws {
        guard maximumInputAgeSeconds.isFinite,
              maximumInputAgeSeconds > 0,
              maximumInputAgeSeconds <= 5 else {
            throw HostHEVCProductOutputError.invalidFreshnessWindow
        }
        self.configuration = configuration
        self.maximumInputAgeSeconds = maximumInputAgeSeconds
        self.backendFactory = backendFactory
    }

    /// Product convenience initializer for the real Mac host encoder. Tests
    /// and alternate hosts should use the injectable initializer above.
    public init(
        configuration: HostVideoEncoderConfiguration,
        maximumInputAgeSeconds: Double = 1
    ) throws {
        try self.init(
            configuration: configuration,
            maximumInputAgeSeconds: maximumInputAgeSeconds,
            backendFactory: { VideoToolboxHostHEVCEncoderBackend() })
    }

    /// Selects a product mode without starting an encoder. Selecting
    /// `host-hevc` is explicit; it does not alter the existing BGRA capture or
    /// preview path until `startHostHEVC` is called.
    public func select(_ selection: HostHEVCProductSelection) async throws
        -> HostHEVCProductOutputStatus {
        if selection == self.selection {
            return await status()
        }
        if let outputSession {
            let snapshot = await outputSession.snapshot()
            guard snapshot.phase == .stopped || snapshot.phase == .cancelled else {
                throw HostHEVCProductOutputError.selectionChangeRequiresStop
            }
            lastSessionSnapshot = snapshot
            self.outputSession = nil
        }
        self.selection = selection
        self.lastSessionSnapshot = nil
        return await status()
    }

    /// Starts one explicit host HEVC output session. The source capture path
    /// remains the caller's responsibility and can continue feeding BGRA
    /// preview at the same time.
    public func startHostHEVC(
        sessionID: String,
        generation: UInt64,
        sink: @escaping SampleSink
    ) async throws -> HostHEVCProductOutputStatus {
        guard selection == .hostHEVC else {
            throw HostHEVCProductOutputError.hostHEVCSelectionRequired
        }
        try validateIdentity(sessionID: sessionID, generation: generation)

        if let outputSession {
            let snapshot = await outputSession.snapshot()
            guard snapshot.phase == .stopped || snapshot.phase == .cancelled else {
                throw HostHEVCProductOutputError.outputAlreadyRunning
            }
            lastSessionSnapshot = snapshot
            self.outputSession = nil
        }

        let session = try HostHEVCOutputSession(
            sessionID: sessionID,
            generation: generation,
            configuration: configuration,
            backend: backendFactory(),
            maximumInputAgeSeconds: maximumInputAgeSeconds,
            sink: sink)
        self.outputSession = session
        self.lastSessionSnapshot = nil
        return await status()
    }

    /// Submits a frame only when `host-hevc` was explicitly selected and
    /// started. The underlying session performs freshness, dimensions, and
    /// session/generation checks before its bounded encoder queue.
    public func submit(
        _ frame: HostVideoFrame,
        receivedUptime: Double,
        nowUptime: Double
    ) async -> HostHEVCProductSubmissionEvidence {
        guard selection == .hostHEVC else {
            return evidence(.notSelected, for: frame)
        }
        guard let outputSession else {
            let disposition: HostHEVCProductSubmissionDisposition =
                lastSessionSnapshot == nil ? .notRunning : .stopped
            return evidence(disposition, for: frame)
        }
        let sessionEvidence = await outputSession.submit(
            frame, receivedUptime: receivedUptime, nowUptime: nowUptime)
        return evidence(
            Self.map(sessionEvidence.disposition),
            for: frame,
            inputAgeSeconds: sessionEvidence.inputAgeSeconds,
            sessionEvidence: sessionEvidence)
    }

    /// Reconnects the host output only when the caller presents the exact
    /// identity that is currently active. The old session is fenced and its
    /// backend is reset by `HostHEVCOutputSession`.
    public func reconnect(
        expectedSessionID: String,
        expectedGeneration: UInt64,
        newSessionID: String,
        newGeneration: UInt64
    ) async throws -> HostHEVCProductOutputStatus {
        guard selection == .hostHEVC, let outputSession else {
            throw HostHEVCProductOutputError.outputNotRunning
        }
        try validateIdentity(sessionID: newSessionID, generation: newGeneration)
        let current = await outputSession.snapshot()
        guard current.sessionID == expectedSessionID else {
            throw HostHEVCProductOutputError.staleSession
        }
        guard current.generation == expectedGeneration else {
            throw HostHEVCProductOutputError.staleGeneration
        }
        guard current.phase == .running || current.phase == .failed else {
            throw HostHEVCProductOutputError.outputNotRunning
        }
        _ = await outputSession.reconnect(
            sessionID: newSessionID, generation: newGeneration)
        return await status()
    }

    /// Stops and releases the current bounded sink/session. The stopped
    /// snapshot remains available through `status()` for diagnostics.
    public func stop() async -> HostHEVCProductOutputStatus {
        guard let outputSession else { return await status() }
        let snapshot = await outputSession.stop()
        lastSessionSnapshot = snapshot
        self.outputSession = nil
        return await status()
    }

    /// Cancels and releases the current bounded sink/session. Cancellation is
    /// observable in the returned status and never changes selection to BGRA.
    public func cancel() async -> HostHEVCProductOutputStatus {
        guard let outputSession else { return await status() }
        let snapshot = await outputSession.cancel()
        lastSessionSnapshot = snapshot
        self.outputSession = nil
        return await status()
    }

    public func status() async -> HostHEVCProductOutputStatus {
        if let outputSession {
            let snapshot = await outputSession.snapshot()
            return makeStatus(snapshot, sinkAttached: true)
        }
        return makeStatus(lastSessionSnapshot, sinkAttached: false)
    }

    private func makeStatus(
        _ snapshot: HostHEVCOutputSessionSnapshot?,
        sinkAttached: Bool
    ) -> HostHEVCProductOutputStatus {
        let phase: HostHEVCProductOutputPhase
        switch selection {
        case .bgraPreview:
            phase = .bgraPreview
        case .hostHEVC:
            guard let snapshot else {
                phase = .idle
                return HostHEVCProductOutputStatus(
                    selection: selection, phase: phase, session: nil,
                    sinkAttached: false, failureCode: nil)
            }
            switch snapshot.phase {
            case .running: phase = .running
            case .reconnecting: phase = .reconnecting
            case .stopping: phase = .stopping
            case .stopped: phase = .stopped
            case .cancelled: phase = .cancelled
            case .failed: phase = .failed
            }
        }
        return HostHEVCProductOutputStatus(
            selection: selection, phase: phase, session: snapshot,
            sinkAttached: sinkAttached, failureCode: snapshot?.failureCode)
    }

    private func validateIdentity(sessionID: String, generation: UInt64) throws {
        guard !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HostHEVCProductOutputError.invalidSessionID
        }
        guard generation > 0 else {
            throw HostHEVCProductOutputError.invalidGeneration
        }
    }

    private func evidence(
        _ disposition: HostHEVCProductSubmissionDisposition,
        for frame: HostVideoFrame,
        inputAgeSeconds: Double? = nil,
        sessionEvidence: HostHEVCOutputSubmissionEvidence? = nil
    ) -> HostHEVCProductSubmissionEvidence {
        HostHEVCProductSubmissionEvidence(
            selection: selection,
            disposition: disposition,
            frame: frame,
            inputAgeSeconds: inputAgeSeconds,
            sessionEvidence: sessionEvidence)
    }

    private static func map(
        _ disposition: HostHEVCOutputSubmissionDisposition
    ) -> HostHEVCProductSubmissionDisposition {
        switch disposition {
        case .accepted: return .accepted
        case .droppedBackpressure: return .droppedBackpressure
        case .staleSession: return .staleSession
        case .staleGeneration: return .staleGeneration
        case .inputStale: return .inputStale
        case .inputClockInvalid: return .inputClockInvalid
        case .pixelFormatUnsupported: return .pixelFormatUnsupported
        case .dimensionMismatch: return .dimensionMismatch
        case .stopped: return .stopped
        }
    }
}
