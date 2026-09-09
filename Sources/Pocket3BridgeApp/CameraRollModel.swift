import Foundation
import Observation
import Pocket3Core
import YunDesign

/// Maps the slider to a signed, device-advertised roll grid.
/// Raw values do not assert calibrated physical angles or image orientation.
struct CameraRollRange: Equatable {
    let minimum: Int
    let maximum: Int
    let step: Int
    init?(_ capabilities: USBRollCapabilities) {
        guard capabilities.writable, let minimum = capabilities.minimum, let maximum = capabilities.maximum,
              (-32768...32767).contains(minimum), (-32768...32767).contains(maximum), minimum < maximum,
              capabilities.step.map({ (1...32767).contains($0) }) == true,
              (minimum...maximum).contains(capabilities.current) else { return nil }
        let step = capabilities.step!
        guard maximum - minimum >= step else { return nil }
        self.minimum = minimum; self.maximum = maximum; self.step = step
    }
    func rawValue(fraction: Double) -> Int {
        let bounded = max(0, min(1, fraction))
        let availableSteps = (maximum - minimum) / step
        let requestedSteps = Int((bounded * Double(maximum - minimum) / Double(step)).rounded())
        return minimum + min(availableSteps, max(0, requestedSteps)) * step
    }
    func fraction(rawValue: Int) -> Double {
        max(0, min(1, Double(rawValue - minimum) / Double(maximum - minimum)))
    }
    var buttonIncrement: Double { Double(step) / Double(maximum - minimum) }
}

@MainActor @Observable
final class CameraRollModel {
    private(set) var sessionID: String?
    private(set) var capabilities: USBRollCapabilities?
    private(set) var isWorking = false
    private(set) var isCancelling = false
    private(set) var lastError: String?
    private var draftFraction: Double?
    private var enabledByStatus = false
    private var unsupported = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var pending: Int?
    @ObservationIgnored private var inFlight: Int?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerID: UUID?
    @ObservationIgnored private var readID: UUID?
    @ObservationIgnored private let readCapabilities: @MainActor (String) async throws -> USBRollCapabilities
    @ObservationIgnored private let applyRoll: @MainActor (Int, String) async throws -> USBRollResult
    @ObservationIgnored private let prepare: @MainActor () async throws -> Void
    @ObservationIgnored private let reportError: @MainActor (String) -> Void

    convenience init(service: CameraService, prepare: @escaping @MainActor () async throws -> Void,
         reportError: @escaping @MainActor (String) -> Void = { _ in }) {
        self.init(readCapabilities: { try await service.rollCapabilities(expectedSessionID: $0) },
            applyRoll: { try await service.roll(rawValue: $0, expectedSessionID: $1, origin: .manual) },
            prepare: prepare, reportError: reportError)
    }

    init(readCapabilities: @escaping @MainActor (String) async throws -> USBRollCapabilities,
         applyRoll: @escaping @MainActor (Int, String) async throws -> USBRollResult,
         prepare: @escaping @MainActor () async throws -> Void = {},
         reportError: @escaping @MainActor (String) -> Void = { _ in }) {
        self.readCapabilities = readCapabilities; self.applyRoll = applyRoll
        self.prepare = prepare; self.reportError = reportError
    }

    var range: CameraRollRange? { capabilities.flatMap(CameraRollRange.init) }
    var canInteract: Bool { enabledByStatus && !isCancelling && !unsupported && range != nil && sessionID != nil }
    var fraction: Double { draftFraction ?? capabilities.flatMap { value in range?.fraction(rawValue: value.current) } ?? 0 }
    var hasValue: Bool { range != nil }
    var currentRawValue: Int? { range.map { $0.rawValue(fraction: fraction) } }
    var defaultRawValue: Int? {
        guard let range, let value = capabilities?.defaultValue,
              (range.minimum...range.maximum).contains(value), (value - range.minimum).isMultiple(of: range.step) else { return nil }
        return value
    }
    var canRestoreDefault: Bool { canInteract && defaultRawValue != nil && currentRawValue != defaultRawValue }
    func restoreDefault() {
        guard canRestoreDefault, let range, let value = defaultRawValue else { return }
        request(fraction: range.fraction(rawValue: value))
    }

    /// Polling must not replace the user's draft or disable a slider because
    /// this model's own write temporarily put the service into moving state.
    func refresh(sessionID nextSession: String?, phase: String, blocked: Bool = false) async {
        let next = nextSession.flatMap { $0.isEmpty ? nil : $0 }
        if next != sessionID {
            cancel(); sessionID = next; capabilities = nil; unsupported = false; lastError = nil
        }
        let ownTransition = isWorking && !isCancelling && ["moving", "stopping"].contains(phase)
        enabledByStatus = !blocked && (phase == "ready" || ownTransition)
        guard let session = sessionID, enabledByStatus else {
            if isWorking && (blocked || !ownTransition) { cancel() }
            return
        }
        guard !isWorking, readID == nil, !unsupported else { return }
        let id = UUID(), version = revision
        readID = id
        defer { if readID == id { readID = nil } }
        do {
            let result = try await readCapabilities(session)
            guard sessionID == session, revision == version, !isWorking else { return }
            capabilities = result; unsupported = CameraRollRange(result) == nil
            lastError = unsupported ? loc("Roll is unavailable for this connection.") : nil
        } catch {
            guard sessionID == session, revision == version, !isWorking else { return }
            let code = (error as? BridgeFailure)?.code ?? ""
            if ["uvc_roll_unavailable", "uvc_roll_not_readable", "uvc_roll_read_only", "uvc_roll_limits_unavailable", "uvc_roll_step_unavailable"].contains(code) {
                unsupported = true; capabilities = nil
            }
            lastError = AppErrorPresentation.message(error, fallback: .rollUnavailable)
        }
    }

    func request(fraction requested: Double) {
        guard canInteract, requested.isFinite, let range, let session = sessionID else { return }
        let value = range.rawValue(fraction: requested)
        draftFraction = range.fraction(rawValue: value)
        lastError = nil
        if worker == nil, capabilities?.current == value { draftFraction = nil; return }
        // Replacing this one slot discards old drag targets. Returning to the
        // in-flight value also withdraws a previously queued different value.
        pending = value == inFlight || (inFlight == nil && value == capabilities?.current) ? nil : value
        guard worker == nil else { return }
        let id = UUID(), version = revision
        workerID = id; isWorking = true; isCancelling = false
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id, version: version, session: session)
        }
    }

    func adjust(_ direction: Int) {
        guard let range, direction != 0 else { return }
        request(fraction: fraction + (direction > 0 ? 1 : -1) * range.buttonIncrement)
    }

    /// Synchronous UI/lifecycle fence. Keep the cancelled worker reference
    /// until it finishes, so a rapid reconnect cannot create a second worker.
    func cancel() {
        revision &+= 1; pending = nil; draftFraction = nil
        enabledByStatus = false; isCancelling = worker != nil
        worker?.cancel()
    }

    private func run(id: UUID, version: UInt64, session: String) async {
        defer {
            if workerID == id {
                worker = nil; workerID = nil; inFlight = nil
                isWorking = false; isCancelling = false
                if version == revision { draftFraction = nil }
            }
        }
        do {
            try Task.checkCancellation()
            guard revision == version, sessionID == session else { return }
            try await prepare()
            try Task.checkCancellation()
            guard revision == version, sessionID == session else { return }
            while let target = pending {
                pending = nil; inFlight = target
                try Task.checkCancellation()
                guard revision == version, sessionID == session else { return }
                let result = try await applyRoll(target, session)
                try Task.checkCancellation()
                guard revision == version, sessionID == session else { return }
                capabilities = result.capabilities
                guard result.verified else { throw BridgeFailure("roll_unconfirmed", loc("Roll could not be confirmed.")) }
                guard CameraRollRange(result.capabilities) != nil else {
                    unsupported = true
                    throw BridgeFailure("roll_unavailable", loc("Roll is unavailable for this connection."))
                }
                inFlight = nil
                if pending == nil { draftFraction = nil }
            }
        } catch {
            guard revision == version, sessionID == session else { return }
            pending = nil
            let code = (error as? BridgeFailure)?.code ?? ""
            guard !(error is CancellationError),
                  !["cancelled", "control_cancelled", "session_changed", "uvc_connection_closed"].contains(code) else { return }
            lastError = AppErrorPresentation.message(error, fallback: .rollUnconfirmed)
            reportError(lastError!)
        }
    }
}
