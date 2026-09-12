import Foundation

/// Readiness of the native Pocket 3 session.  These states describe the
/// evidence available to the command layer; they do not start Bluetooth,
/// change the Mac's network route, or open a datalink by themselves.
public enum NativeCameraSessionState: String, Codable, CaseIterable, Hashable, Sendable {
    case disconnected
    case paired
    case credentialsAvailable
    case datalinkHandshaking
    case commandReady
    case liveReady

    fileprivate var rank: Int {
        switch self {
        case .disconnected: 0
        case .paired: 1
        case .credentialsAvailable: 2
        case .datalinkHandshaking: 3
        case .commandReady: 4
        case .liveReady: 5
        }
    }

    /// A higher state contains the evidence required by a lower state.  The
    /// handshaking state is intentionally not command-ready while it is in
    /// flight.
    public func satisfies(_ minimum: Self) -> Bool {
        self != .disconnected && rank >= minimum.rank
    }
}

/// Commands are named by capability rather than by a guessed DUML opcode.
/// The mapping is a policy gate only; an adapter still needs to submit a
/// validated frame and obtain its own ACK/readback evidence.
public enum NativeCameraSessionCommand: String, Codable, CaseIterable, Hashable, Sendable {
    // Read-only observations available on the paired BLE channel.
    case battery
    case telemetry
    case cameraStatus
    case storage
    case cameraSettingsRead

    // Credential use and datalink setup are represented explicitly so callers
    // cannot accidentally treat them as command-ready camera controls.
    case credentials

    // Camera/gimbal commands require the completed native datalink handshake.
    case whiteBalance
    case exposure
    case focusMode
    case colorProfile
    case record
    case tracking
    case gimbal
    case gimbalPreset
    case zoom
    case productShowcase
    case audioDSP
    case advancedSetting
    case cameraCapture
    case bodyFormat
    case mediaPresence
    case mediaPlayback
    case mediaList
    case mediaFavorite
    case mediaDelete

    // Live view is a separate phase.  The developer-only start/IDR/hint
    // requests are command-ready operations; a live-preview consumer itself
    // becomes live-ready only after fresh media evidence arrives.
    case livePreviewHint
    case livePreviewEnable
    case livePreviewIDR
    case livePreview

    public var minimumReadiness: NativeCameraSessionState {
        switch self {
        case .battery, .telemetry, .cameraStatus, .storage, .cameraSettingsRead:
            .paired
        case .credentials:
            .credentialsAvailable
        case .whiteBalance, .exposure, .focusMode, .colorProfile, .record,
             .tracking, .gimbal, .gimbalPreset, .zoom, .productShowcase, .audioDSP,
             .advancedSetting, .cameraCapture:
            .commandReady
        case .bodyFormat, .mediaPresence, .mediaPlayback, .mediaList,
             .mediaFavorite, .mediaDelete:
            .commandReady
        case .livePreviewHint, .livePreviewEnable, .livePreviewIDR:
            .commandReady
        case .livePreview:
            .liveReady
        }
    }

    /// Alias useful at call sites that use “state” for readiness gates.
    public var minimumState: NativeCameraSessionState { minimumReadiness }

    // Descriptive aliases keep the policy readable at call sites while the
    // wire-independent cases above remain the canonical Codable values.
    public static let readBattery = Self.battery
    public static let readTelemetry = Self.telemetry
    public static let readCameraStatus = Self.cameraStatus
    public static let readStorage = Self.storage
    public static let readCameraSettings = Self.cameraSettingsRead
    public static let startStopRecording = Self.record
    public static let activeTrack = Self.tracking
    public static let advancedSettings = Self.advancedSetting
    public static let liveViewHint = Self.livePreviewHint
    public static let liveViewEnable = Self.livePreviewEnable
    public static let liveViewIDR = Self.livePreviewIDR
    public static let liveView = Self.livePreview

    public static func minimumReadiness(for command: Self) -> NativeCameraSessionState {
        command.minimumReadiness
    }
}

/// Shorter spelling for clients that model commands independently of the
/// session object.
public typealias NativeCameraCommand = NativeCameraSessionCommand
public typealias NativeCameraSessionPhase = NativeCameraSessionState

public enum NativeCameraSessionTransitionError: Error, Equatable, Sendable {
    case staleGeneration(expected: UInt64, received: UInt64)
    case invalidTransition(from: NativeCameraSessionState, to: NativeCameraSessionState)
    case commandUnavailable(command: NativeCameraSessionCommand,
                            state: NativeCameraSessionState)
    case noActiveSession
}

extension NativeCameraSessionTransitionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .staleGeneration(expected, received):
            "Native camera session generation changed (expected \(expected), received \(received))."
        case let .invalidTransition(from, to):
            "Native camera session cannot transition from \(from.rawValue) to \(to.rawValue)."
        case let .commandUnavailable(command, state):
            "Native camera command \(command.rawValue) is unavailable in \(state.rawValue)."
        case .noActiveSession:
            "Native camera session is disconnected."
        }
    }
}

/// A serializable, credential-free projection suitable for App/UI/IPC status.
public struct NativeCameraSessionStatus: Codable, Equatable, Sendable {
    public let state: NativeCameraSessionState
    public let generation: UInt64
    public let sessionID: UUID?
    public let peerID: UUID?

    public var commandReady: Bool { state.satisfies(.commandReady) }
    public var liveReady: Bool { state.satisfies(.liveReady) }

    public var phase: NativeCameraSessionState { state }

    public func isReady(for command: NativeCameraSessionCommand) -> Bool {
        state.satisfies(command.minimumReadiness)
    }

    public func canIssue(_ command: NativeCameraSessionCommand) -> Bool {
        isReady(for: command)
    }

    public func require(_ command: NativeCameraSessionCommand,
                        generation callbackGeneration: UInt64? = nil) throws {
        guard let callbackGeneration else {
            guard generation != 0, state != .disconnected else {
                throw NativeCameraSessionTransitionError.noActiveSession
            }
            guard state.satisfies(command.minimumReadiness) else {
                throw NativeCameraSessionTransitionError.commandUnavailable(command: command, state: state)
            }
            return
        }
        guard callbackGeneration == generation else {
            throw NativeCameraSessionTransitionError.staleGeneration(expected: generation,
                                                                      received: callbackGeneration)
        }
        guard generation != 0, state != .disconnected else {
            throw NativeCameraSessionTransitionError.noActiveSession
        }
        guard state.satisfies(command.minimumReadiness) else {
            throw NativeCameraSessionTransitionError.commandUnavailable(command: command, state: state)
        }
    }
}

/// Pure readiness state machine for the native Pocket 3 path.
///
/// The state machine owns no I/O and deliberately has no “connect” method.
/// A transport adapter must report evidence through the generation it received
/// from `begin`.  Starting a new session or invalidating one increments the
/// generation, so a delayed callback from an older BLE/datalink session cannot
/// reopen command readiness.
public struct NativeCameraSession: Sendable {
    public private(set) var state: NativeCameraSessionState = .disconnected
    public private(set) var generation: UInt64 = 0
    public private(set) var sessionID: UUID?
    public private(set) var peerID: UUID?

    public init() {}

    public var status: NativeCameraSessionStatus {
        NativeCameraSessionStatus(state: state, generation: generation,
                                   sessionID: sessionID, peerID: peerID)
    }

    /// Starts a fresh logical session without touching hardware.
    @discardableResult
    public mutating func begin(sessionID: UUID? = nil, peerID: UUID? = nil) -> UInt64 {
        generation &+= 1
        state = .disconnected
        self.sessionID = sessionID
        self.peerID = peerID
        return generation
    }

    /// Invalidates the current session and all callbacks carrying its token.
    @discardableResult
    public mutating func invalidate() -> UInt64 {
        generation &+= 1
        state = .disconnected
        sessionID = nil
        peerID = nil
        return generation
    }

    /// Alias for callers that express the lifecycle operation as disconnect.
    @discardableResult
    public mutating func disconnect() -> UInt64 { invalidate() }

    /// Applies one legal transition only when the callback belongs to the
    /// current generation. Repeated observations of the same state are safe.
    @discardableResult
    public mutating func transition(to next: NativeCameraSessionState,
                                    generation callbackGeneration: UInt64) -> Bool {
        guard generation != 0, callbackGeneration == generation else { return false }
        guard next == state || Self.allows(from: state, to: next) else { return false }
        if next == .disconnected {
            // A disconnect is itself a generation boundary.  This keeps a
            // later callback carrying the old token from reopening pairing.
            generation &+= 1
            sessionID = nil
            peerID = nil
        }
        state = next
        return true
    }

    /// Convenience overload for synchronous code that already owns the
    /// current state machine. Asynchronous callbacks should use the explicit
    /// generation overload above.
    @discardableResult
    public mutating func transition(to next: NativeCameraSessionState) -> Bool {
        transition(to: next, generation: generation)
    }

    @discardableResult
    public mutating func markPaired(generation callbackGeneration: UInt64) -> Bool {
        transition(to: .paired, generation: callbackGeneration)
    }

    @discardableResult
    public mutating func markCredentialsAvailable(generation callbackGeneration: UInt64) -> Bool {
        transition(to: .credentialsAvailable, generation: callbackGeneration)
    }

    @discardableResult
    public mutating func beginDatalinkHandshake(generation callbackGeneration: UInt64) -> Bool {
        transition(to: .datalinkHandshaking, generation: callbackGeneration)
    }

    @discardableResult
    public mutating func markCommandReady(generation callbackGeneration: UInt64) -> Bool {
        transition(to: .commandReady, generation: callbackGeneration)
    }

    @discardableResult
    public mutating func markLiveReady(generation callbackGeneration: UInt64) -> Bool {
        transition(to: .liveReady, generation: callbackGeneration)
    }

    /// Bridges the existing `Pocket3Datalink` lifecycle into this state
    /// machine.  A transport `ready` report is meaningful only after this
    /// generation has explicitly entered `datalinkHandshaking`; a BLE-paired
    /// session therefore cannot be promoted by a late or unrelated ready
    /// snapshot.
    @discardableResult
    public mutating func observeDatalink(_ phase: Pocket3DatalinkPhase,
                                         generation callbackGeneration: UInt64) -> Bool {
        guard generation != 0, callbackGeneration == generation else { return false }
        switch phase {
        case .connecting:
            guard state == .credentialsAvailable else { return false }
            return beginDatalinkHandshake(generation: callbackGeneration)
        case .ready:
            guard state == .datalinkHandshaking else { return false }
            return markCommandReady(generation: callbackGeneration)
        case .idle, .disarmed, .error:
            guard [.datalinkHandshaking, .commandReady, .liveReady].contains(state) else { return false }
            // The datalink generation is no longer trustworthy.  Preserve
            // only the BLE evidence already held by this session and issue a
            // new token before any reconnect can begin.
            let retainedSessionID = sessionID
            let retainedPeerID = peerID
            let retainedCredentials = state.satisfies(.credentialsAvailable)
            _ = begin(sessionID: retainedSessionID, peerID: retainedPeerID)
            let nextGeneration = generation
            _ = markPaired(generation: nextGeneration)
            if retainedCredentials {
                _ = markCredentialsAvailable(generation: nextGeneration)
            }
            return true
        }
    }

    public func isReady(for command: NativeCameraSessionCommand,
                        generation callbackGeneration: UInt64? = nil) -> Bool {
        guard callbackGeneration.map({ $0 == generation }) ?? true else { return false }
        return state.satisfies(command.minimumReadiness)
    }

    public func canIssue(_ command: NativeCameraSessionCommand,
                         generation callbackGeneration: UInt64? = nil) -> Bool {
        isReady(for: command, generation: callbackGeneration)
    }

    /// Throws instead of silently allowing a command to cross a stale or
    /// insufficient readiness boundary.
    public func require(_ command: NativeCameraSessionCommand,
                        generation callbackGeneration: UInt64? = nil) throws {
        guard let callbackGeneration else {
            guard generation != 0, state != .disconnected else {
                throw NativeCameraSessionTransitionError.noActiveSession
            }
            guard state.satisfies(command.minimumReadiness) else {
                throw NativeCameraSessionTransitionError.commandUnavailable(command: command, state: state)
            }
            return
        }
        guard callbackGeneration == generation else {
            throw NativeCameraSessionTransitionError.staleGeneration(expected: generation,
                                                                      received: callbackGeneration)
        }
        guard generation != 0, state != .disconnected else {
            throw NativeCameraSessionTransitionError.noActiveSession
        }
        guard state.satisfies(command.minimumReadiness) else {
            throw NativeCameraSessionTransitionError.commandUnavailable(command: command, state: state)
        }
    }

    /// The first phase has no live-view adapter, so the only legal path to
    /// `liveReady` is an explicit future evidence event from a live transport.
    /// In particular, command-ready never implies live-ready.
    private static func allows(from: NativeCameraSessionState,
                               to: NativeCameraSessionState) -> Bool {
        switch (from, to) {
        case (.disconnected, .paired):
            true
        case (.paired, .credentialsAvailable),
             (.credentialsAvailable, .datalinkHandshaking),
             (.datalinkHandshaking, .commandReady),
             (.commandReady, .liveReady):
            true
        // A transport can disappear while BLE pairing remains valid. These
        // regressions retain the strongest evidence that is still true.
        case (.credentialsAvailable, .paired),
             (.datalinkHandshaking, .credentialsAvailable),
             (.datalinkHandshaking, .paired),
             (.commandReady, .credentialsAvailable),
             (.commandReady, .paired),
             (.liveReady, .commandReady),
             (.liveReady, .credentialsAvailable),
             (.liveReady, .paired):
            true
        // Any active state can be explicitly disconnected without relying on
        // a callback transition; `invalidate` also changes the generation.
        case (.paired, .disconnected),
             (.credentialsAvailable, .disconnected),
             (.datalinkHandshaking, .disconnected),
             (.commandReady, .disconnected),
             (.liveReady, .disconnected):
            true
        default:
            false
        }
    }
}
