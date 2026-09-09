import Foundation
import Observation
import Pocket3Core
import YunDesign

/// Converts normalized UI travel to the camera's real integer control grid.
/// The displayed percentage describes control travel, not a zoom multiplier.
struct CameraZoomRange: Equatable {
    let minimum: Int
    let maximum: Int
    let step: Int
    init?(_ capabilities: USBZoomCapabilities) {
        guard capabilities.writable, let minimum = capabilities.minimum, let maximum = capabilities.maximum,
              (0...65535).contains(minimum), (0...65535).contains(maximum), minimum < maximum,
              capabilities.step == nil || (0...65535).contains(capabilities.step!),
              (minimum...maximum).contains(capabilities.current) else { return nil }
        let step = max(1, capabilities.step ?? 1)
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
    var buttonIncrement: Double { max(0.05, Double(step) / Double(maximum - minimum)) }
}

@MainActor @Observable
final class CameraZoomModel {
    private(set) var sessionID: String?
    private(set) var capabilities: USBZoomCapabilities?
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
    @ObservationIgnored private let readCapabilities: @MainActor (String) async throws -> USBZoomCapabilities
    @ObservationIgnored private let applyZoom: @MainActor (Int, String) async throws -> USBZoomResult
    @ObservationIgnored private let prepare: @MainActor () async throws -> Void
    @ObservationIgnored private let reportError: @MainActor (String) -> Void

    convenience init(service: CameraService, prepare: @escaping @MainActor () async throws -> Void,
         reportError: @escaping @MainActor (String) -> Void = { _ in }) {
        self.init(readCapabilities: { try await service.zoomCapabilities(expectedSessionID: $0) },
            applyZoom: { try await service.zoom(rawValue: $0, expectedSessionID: $1, origin: .manual) },
            prepare: prepare, reportError: reportError)
    }

    init(readCapabilities: @escaping @MainActor (String) async throws -> USBZoomCapabilities,
         applyZoom: @escaping @MainActor (Int, String) async throws -> USBZoomResult,
         prepare: @escaping @MainActor () async throws -> Void = {},
         reportError: @escaping @MainActor (String) -> Void = { _ in }) {
        self.readCapabilities = readCapabilities; self.applyZoom = applyZoom
        self.prepare = prepare; self.reportError = reportError
    }

    var range: CameraZoomRange? { capabilities.flatMap(CameraZoomRange.init) }
    var canInteract: Bool { enabledByStatus && !isCancelling && !unsupported && range != nil && sessionID != nil }
    var fraction: Double { draftFraction ?? capabilities.flatMap { value in range?.fraction(rawValue: value.current) } ?? 0 }
    var hasValue: Bool { range != nil }

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
            capabilities = result; unsupported = CameraZoomRange(result) == nil
            lastError = unsupported ? loc("Zoom is unavailable for this connection.") : nil
        } catch {
            guard sessionID == session, revision == version, !isWorking else { return }
            let code = (error as? BridgeFailure)?.code ?? ""
            if ["uvc_zoom_unavailable", "uvc_zoom_not_readable", "uvc_zoom_read_only", "uvc_zoom_limits_unavailable"].contains(code) {
                unsupported = true; capabilities = nil
            }
            lastError = AppErrorPresentation.message(error, fallback: .zoomUnavailable)
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
        pending = value == inFlight ? nil : value
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
                let result = try await applyZoom(target, session)
                try Task.checkCancellation()
                guard revision == version, sessionID == session else { return }
                capabilities = result.capabilities
                guard result.verified else { throw BridgeFailure("zoom_unconfirmed", loc("Zoom could not be confirmed.")) }
                guard CameraZoomRange(result.capabilities) != nil else {
                    unsupported = true
                    throw BridgeFailure("zoom_unavailable", loc("Zoom is unavailable for this connection."))
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
            lastError = AppErrorPresentation.message(error, fallback: .zoomUnconfirmed)
            reportError(lastError!)
        }
    }
}
