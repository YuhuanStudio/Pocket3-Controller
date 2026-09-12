import Foundation
import SwiftUI
import Pocket3Core
import YunDesign

/// Read-only identity and route evidence used by the media library model.
/// Route status has no camera bytes or credentials; `observedUptime` bounds
/// how long the model may present the page as current.
struct Pocket3MediaLibraryContext: Codable, Sendable, Equatable {
    let identity: Pocket3MediaSessionIdentity
    let routeStatus: Pocket3DatalinkRouteStatus
    let observedUptime: TimeInterval
    let maximumAge: TimeInterval
    /// Latest typed 02/80 state admitted for this exact media session. The
    /// model keeps it alongside route freshness so a changed session cannot
    /// reuse an old playback or active-store value.
    let mediaSession: Pocket3MediaSessionObservation?

    init(identity: Pocket3MediaSessionIdentity,
         routeStatus: Pocket3DatalinkRouteStatus,
         observedUptime: TimeInterval,
         maximumAge: TimeInterval = 5,
         mediaSession: Pocket3MediaSessionObservation? = nil) {
        self.identity = identity
        self.routeStatus = routeStatus
        self.observedUptime = observedUptime
        self.maximumAge = maximumAge
        self.mediaSession = mediaSession
    }

    var routeAllowed: Bool {
        switch routeStatus.state {
        case .legacyUnbound, .interfaceBound, .samePrimaryRoute: true
        case .unknown, .interfaceUnavailable, .interfaceNotReady,
             .cameraRouteUnavailable, .defaultRouteChanged: false
        }
    }

    var rangeRouteAllowed: Bool {
        guard routeAllowed,
              routeStatus.cameraHost == Pocket3MediaHTTPRangeRequest.host,
              routeStatus.cameraRouteReachable == true,
              routeStatus.defaultRouteChanged != true,
              routeStatus.samePrimaryRoute != false else { return false }
        return [.interfaceBound, .samePrimaryRoute].contains(routeStatus.state)
    }

    func isFresh(nowUptime: TimeInterval) -> Bool {
        observedUptime.isFinite && observedUptime >= 0 &&
            nowUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
            nowUptime >= observedUptime &&
            nowUptime - observedUptime <= maximumAge
    }

    func isMediaSessionFresh(nowUptime: TimeInterval) -> Bool {
        guard let mediaSession,
              mediaSession.sessionID == identity.sessionID,
              mediaSession.generation == identity.generation,
              (identity.peripheralID == nil ||
               identity.peripheralID == mediaSession.peripheralID) else {
            return false
        }
        return mediaSession.isFresh(nowUptime: nowUptime,
                                    maximumAge: maximumAge)
    }
}

/// Metadata-only row. It deliberately has no media path, thumbnail path,
/// image data or download data, so a view can never accidentally render a
/// camera image from the library result.
struct Pocket3MediaLibraryRow: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let type: Pocket3MediaFileType?
    let typeRaw: UInt8?
    let durationSeconds: UInt16?
    let sizeBytes: UInt32?
    let starred: Bool?

    init(entry: Pocket3MediaIndexEntry, ordinal: Int = 0) {
        let fallback = entry.mediaPath.split(separator: "/").last.map(String.init)
            ?? "Unnamed media"
        name = entry.fileName ?? fallback
        // A path is useful to the protocol/range layer but is not retained by
        // the metadata-only presentation model. Handles are stable when the
        // parser found one; otherwise the page ordinal is sufficient for a
        // one-page list.
        id = entry.handle.map { "handle-\($0)" } ?? "row-\(ordinal)"
        type = entry.fileType
        typeRaw = entry.fileTypeRaw
        durationSeconds = entry.durationSeconds
        sizeBytes = entry.sizeBytes
        starred = entry.starred
    }

    var typeLabel: String {
        switch type {
        case .jpeg: "JPEG"
        case .dng: "DNG"
        case .mov: "MOV"
        case .mp4: "MP4"
        case .panorama: "Panorama"
        case .tiff: "TIFF"
        case .audio: "Audio"
        case .lrf: "LRF"
        case .thm: "THM"
        case .scr: "SCR"
        case .osv: "OSV"
        case .unknown(let raw): String(format: "Unknown (0x%02X)", raw)
        case nil: "Unknown"
        }
    }

    var durationLabel: String? {
        guard let durationSeconds else { return nil }
        return String(format: "%d:%02d", durationSeconds / 60,
                      durationSeconds % 60)
    }

    var sizeLabel: String? {
        guard let sizeBytes else { return nil }
        let bytes = Double(sizeBytes)
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB", bytes / 1_048_576)
        }
        if bytes >= 1024 {
            return String(format: "%.1f KB", bytes / 1024)
        }
        return "\(sizeBytes) B"
    }
}

enum Pocket3MediaLibraryPhase: String, Codable, Sendable, Equatable {
    case empty
    case loading
    case ready
    case downloading
    case partial
    case cancelled
    case stale
    case failed
}

enum Pocket3MediaRangeProgressPhase: String, Codable, Sendable, Equatable {
    case downloading
    case completed
    case partial
    case cancelled
    case failed
}

/// Range state contains counts and terminal status only. The bytes returned
/// by `NativeMediaValidationResult.range` are intentionally discarded by the
/// UI model; a future file export can add a separately reviewed sink.
struct Pocket3MediaRangeProgress: Codable, Sendable, Equatable {
    let identity: Pocket3MediaSessionIdentity
    let expectedBytes: UInt64
    let receivedBytes: UInt64
    let phase: Pocket3MediaRangeProgressPhase
    let failureCode: String?

    var fraction: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(expectedBytes)))
    }

    var isPartial: Bool {
        phase == .partial || phase == .cancelled ||
            (phase == .downloading && receivedBytes < expectedBytes)
    }
}

/// A compact page progress projection; the assembled bytes remain owned by
/// the protocol result and are never copied into this App model.
struct Pocket3MediaListProgress: Codable, Sendable, Equatable {
    let phase: Pocket3MediaListReassemblyPhase
    let assembledByteCount: Int
    let acceptedChunkCount: Int
    let rejectedChunkCount: Int
    let unknownChunkCount: Int
}

/// Main-actor-owned presentation model for the developer Diagnostics media
/// disclosure. It consumes completed native validation evidence and exposes
/// only bounded metadata. It performs no I/O itself, which keeps fake render
/// tests deterministic and prevents a view from starting Bluetooth/Wi-Fi.
struct Pocket3MediaLibraryModel: Codable, Sendable, Equatable {
    static let maximumRows = Pocket3MediaIndex.maximumEntries

    private(set) var context: Pocket3MediaLibraryContext?
    private(set) var phase: Pocket3MediaLibraryPhase = .empty
    private(set) var rows: [Pocket3MediaLibraryRow] = []
    private(set) var listProgress: Pocket3MediaListProgress?
    private(set) var rangeProgress: Pocket3MediaRangeProgress?
    private(set) var lastFailureCode: String?

    var isFresh: Bool {
        guard let context else { return false }
        return context.isFresh(nowUptime: ProcessInfo.processInfo.systemUptime)
    }

    /// The latest camera-reported media state, when one was admitted for the
    /// current library identity. It is read-only presentation evidence.
    var mediaSession: Pocket3MediaSessionObservation? { context?.mediaSession }
    var mediaState: Pocket3MediaSessionState? { context?.mediaSession?.state }
    var mediaStateIsFresh: Bool {
        guard let context else { return false }
        return context.isMediaSessionFresh(
            nowUptime: ProcessInfo.processInfo.systemUptime)
    }
    var activeStoreTotalMiB: UInt32? {
        context?.mediaSession?.activeStoreTotalMiB
    }
    var activeStoreFreeMiB: UInt32? {
        context?.mediaSession?.activeStoreFreeMiB
    }

    var summary: String {
        switch phase {
        case .empty: return "No media page loaded"
        case .loading:
            if let listProgress {
                return "Loading · \(listProgress.acceptedChunkCount) chunks"
            }
            return "Loading"
        case .ready: return "\(rows.count) metadata rows"
        case .downloading:
            guard let rangeProgress else { return "Downloading" }
            return String(format: "Downloading · %.0f%%", rangeProgress.fraction * 100)
        case .partial: return "Partial download"
        case .cancelled: return "Download cancelled"
        case .stale: return "Media session stale"
        case .failed: return "Media validation failed"
        }
    }

    /// Bind an exact session/generation and route snapshot. A changed
    /// identity clears prior rows and progress before accepting new evidence.
    @discardableResult
    mutating func bind(identity: Pocket3MediaSessionIdentity,
                       routeStatus: Pocket3DatalinkRouteStatus,
                       observedUptime: TimeInterval,
                       nowUptime: TimeInterval,
                       maximumAge: TimeInterval = 5,
                       mediaSession: Pocket3MediaSessionObservation? = nil) -> Bool {
        guard identity.generation > 0, observedUptime.isFinite,
              observedUptime >= 0, nowUptime.isFinite,
              maximumAge.isFinite, maximumAge >= 0 else {
            phase = .failed
            lastFailureCode = "media_library_invalid_clock"
            return false
        }
        guard mediaSession.map({ observation in
            observation.sessionID == identity.sessionID &&
                observation.generation == identity.generation &&
                (identity.peripheralID == nil ||
                 identity.peripheralID == observation.peripheralID)
        }) ?? true else {
            phase = .failed
            lastFailureCode = "media_library_media_session_mismatch"
            return false
        }
        let sameIdentity = context?.identity == identity
        let retainedMediaSession = mediaSession ??
            (sameIdentity ? context?.mediaSession : nil)
        let next = Pocket3MediaLibraryContext(identity: identity,
            routeStatus: routeStatus, observedUptime: observedUptime,
            maximumAge: maximumAge, mediaSession: retainedMediaSession)
        if context?.identity != identity {
            rows.removeAll(keepingCapacity: false)
            listProgress = nil
            rangeProgress = nil
            lastFailureCode = nil
        }
        context = next
        if !next.isFresh(nowUptime: nowUptime) || !next.routeAllowed {
            phase = .stale
            lastFailureCode = next.routeAllowed
                ? "media_library_context_stale" : "media_library_route_invalid"
            return false
        }
        if phase == .stale || phase == .failed {
            phase = rows.isEmpty ? .empty : .ready
        }
        return true
    }

    /// Applies one page result. The expected identity and route are supplied
    /// by the current native owner, so an old result cannot repopulate a new
    /// session even if its page bytes happen to look valid.
    @discardableResult
    mutating func applyListResult(
        _ result: NativeMediaValidationResult,
        expectedIdentity: Pocket3MediaSessionIdentity,
        routeStatus: Pocket3DatalinkRouteStatus,
        receivedUptime: TimeInterval,
        nowUptime: TimeInterval,
        maximumAge: TimeInterval = 5,
        mediaSession: Pocket3MediaSessionObservation? = nil
    ) -> Bool {
        guard result.action == .list else {
            lastFailureCode = "media_library_action_mismatch"
            phase = .failed
            return false
        }
        guard bind(identity: expectedIdentity, routeStatus: routeStatus,
                   observedUptime: receivedUptime, nowUptime: nowUptime,
                   maximumAge: maximumAge, mediaSession: mediaSession) else {
            return false
        }
        if let evidence = result.list {
            listProgress = Pocket3MediaListProgress(phase: evidence.phase,
                assembledByteCount: evidence.assembledByteCount,
                acceptedChunkCount: evidence.acceptedChunkCount,
                rejectedChunkCount: evidence.rejectedChunkCount,
                unknownChunkCount: evidence.unknownChunkCount)
        }
        guard let index = result.mediaIndex,
              result.completed,
              index.identity == expectedIdentity,
              index.entries.count <= Self.maximumRows else {
            phase = result.phase == .cancelled ? .cancelled : .loading
            lastFailureCode = result.failureCode
            return false
        }
        rows = index.entries.enumerated().map { ordinal, entry in
            Pocket3MediaLibraryRow(entry: entry, ordinal: ordinal)
        }
        phase = .ready
        lastFailureCode = nil
        return true
    }

    /// Direct fixture-friendly ingestion for an already decoded page. The
    /// native validation route normally uses `applyListResult`; this overload
    /// keeps render/model tests independent from a transport response while
    /// retaining the same identity and freshness fences.
    @discardableResult
    mutating func apply(
        index: Pocket3MediaIndex,
        expectedIdentity: Pocket3MediaSessionIdentity,
        routeStatus: Pocket3DatalinkRouteStatus,
        receivedUptime: TimeInterval,
        nowUptime: TimeInterval,
        maximumAge: TimeInterval = 5,
        mediaSession: Pocket3MediaSessionObservation? = nil
    ) -> Bool {
        guard index.identity == expectedIdentity else {
            phase = .stale
            lastFailureCode = "media_library_identity_changed"
            return false
        }
        guard bind(identity: expectedIdentity, routeStatus: routeStatus,
                   observedUptime: receivedUptime, nowUptime: nowUptime,
                   maximumAge: maximumAge, mediaSession: mediaSession) else {
            return false
        }
        guard index.entries.count <= Self.maximumRows else {
            phase = .failed
            lastFailureCode = "media_library_rows_too_large"
            return false
        }
        rows = index.entries.enumerated().map { ordinal, entry in
            Pocket3MediaLibraryRow(entry: entry, ordinal: ordinal)
        }
        phase = .ready
        listProgress = nil
        lastFailureCode = nil
        return true
    }

    /// Admits a camera-reported 02/80 media state without requiring a list
    /// page. Playback enter/exit validation uses this path so Diagnostics can
    /// show the terminal state and active-store capacity while rows remain
    /// metadata-only.
    @discardableResult
    mutating func applyMediaSession(
        _ mediaSession: Pocket3MediaSessionObservation,
        expectedIdentity: Pocket3MediaSessionIdentity,
        routeStatus: Pocket3DatalinkRouteStatus,
        nowUptime: TimeInterval,
        maximumAge: TimeInterval = 5
    ) -> Bool {
        bind(identity: expectedIdentity, routeStatus: routeStatus,
             observedUptime: mediaSession.receivedUptime,
             nowUptime: nowUptime, maximumAge: maximumAge,
             mediaSession: mediaSession)
    }

    /// Starts a metadata-only range progress ledger after exact identity and
    /// route checks. This does not invoke a fetcher.
    @discardableResult
    mutating func beginRange(_ request: Pocket3MediaHTTPRangeRequest,
                             nowUptime: TimeInterval) -> Bool {
        guard let context,
              context.identity == request.identity,
              context.isFresh(nowUptime: nowUptime),
              context.rangeRouteAllowed else {
            phase = .stale
            lastFailureCode = "media_library_range_context_invalid"
            return false
        }
        rangeProgress = Pocket3MediaRangeProgress(identity: request.identity,
            expectedBytes: request.range.length, receivedBytes: 0,
            phase: .downloading, failureCode: nil)
        phase = .downloading
        lastFailureCode = nil
        return true
    }

    @discardableResult
    mutating func updateRangeProgress(receivedBytes: UInt64,
                                      nowUptime: TimeInterval) -> Bool {
        guard let current = rangeProgress,
              current.phase == .downloading,
              let context, context.identity == current.identity,
              context.isFresh(nowUptime: nowUptime),
              receivedBytes <= current.expectedBytes else { return false }
        rangeProgress = Pocket3MediaRangeProgress(identity: current.identity,
            expectedBytes: current.expectedBytes, receivedBytes: receivedBytes,
            phase: .downloading, failureCode: nil)
        return true
    }

    /// Records only the range byte count and terminal status; `data` is never
    /// retained. A cancelled or failed transfer remains visible as partial
    /// evidence and can be cleared by a new session bind.
    @discardableResult
    mutating func applyRangeResult(_ result: NativeMediaValidationResult,
                                   nowUptime: TimeInterval) -> Bool {
        guard result.action == .range,
              let range = result.range,
              let context,
              range.request.identity == context.identity,
              context.isFresh(nowUptime: nowUptime) else {
            phase = .stale
            lastFailureCode = "media_library_range_identity_changed"
            return false
        }
        let received = min(UInt64(max(0, range.byteCount)),
                           range.request.range.length)
        let progressPhase: Pocket3MediaRangeProgressPhase
        switch result.phase {
        case .completed: progressPhase = .completed
        case .cancelled: progressPhase = .cancelled
        case .failed, .routeRejected, .fetcherUnavailable,
             .executorUnavailable, .generationChanged, .timedOut:
            progressPhase = .partial
        case .dryRun, .awaitingAcknowledgment, .awaitingReadback:
            progressPhase = .downloading
        }
        rangeProgress = Pocket3MediaRangeProgress(identity: range.request.identity,
            expectedBytes: range.request.range.length, receivedBytes: received,
            phase: progressPhase, failureCode: result.failureCode)
        switch progressPhase {
        case .completed: phase = .ready
        case .partial: phase = .partial
        case .cancelled: phase = .cancelled
        case .downloading: phase = .downloading
        case .failed: phase = .failed
        }
        lastFailureCode = result.failureCode
        return progressPhase == .completed
    }

    /// Consumes the result shape shared by the native media validation route.
    /// The owner supplies the current identity and route snapshot, so this
    /// convenience keeps list/range ingestion under one exact session fence.
    @discardableResult
    mutating func apply(
        _ result: NativeMediaValidationResult,
        expectedIdentity: Pocket3MediaSessionIdentity,
        routeStatus: Pocket3DatalinkRouteStatus,
        receivedUptime: TimeInterval,
        nowUptime: TimeInterval,
        maximumAge: TimeInterval = 5,
        mediaSession: Pocket3MediaSessionObservation? = nil
    ) -> Bool {
        switch result.action {
        case .list:
            return applyListResult(result,
                expectedIdentity: expectedIdentity, routeStatus: routeStatus,
                receivedUptime: receivedUptime, nowUptime: nowUptime,
                maximumAge: maximumAge, mediaSession: mediaSession)
        case .range:
            guard bind(identity: expectedIdentity, routeStatus: routeStatus,
                       observedUptime: receivedUptime, nowUptime: nowUptime,
                       maximumAge: maximumAge, mediaSession: mediaSession) else {
                return false
            }
            return applyRangeResult(result, nowUptime: nowUptime)
        case .playbackEnter, .playbackExit, .presence:
            return false
        }
    }

    /// Cancellation is a local state transition. It never calls an executor.
    @discardableResult
    mutating func cancelRange(nowUptime: TimeInterval) -> Bool {
        guard let current = rangeProgress,
              current.phase == .downloading,
              context?.isFresh(nowUptime: nowUptime) == true else { return false }
        rangeProgress = Pocket3MediaRangeProgress(identity: current.identity,
            expectedBytes: current.expectedBytes,
            receivedBytes: current.receivedBytes, phase: .cancelled,
            failureCode: "cancelled")
        phase = .cancelled
        lastFailureCode = "cancelled"
        return true
    }

    mutating func clear() {
        context = nil
        phase = .empty
        rows.removeAll(keepingCapacity: false)
        listProgress = nil
        rangeProgress = nil
        lastFailureCode = nil
    }
}

/// Compact developer Diagnostics disclosure. All values are metadata and
/// bounded counters; there is no thumbnail, preview, delete, favorite or
/// credential control in this view.
struct Pocket3MediaLibraryDiagnostics: View {
    @Binding var model: Pocket3MediaLibraryModel
    @State private var isExpanded = false

    var body: some View {
        YunDisclosure(loc("Camera media library"),
                      subtitle: loc(model.summary),
                      isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
                if let context = model.context {
                    detail(loc("Media session"), context.identity.sessionID.uuidString)
                    detail(loc("Media generation"), "\(context.identity.generation)")
                    detail(loc("Media route"), context.routeStatus.state.rawValue)
                    detail(loc("Media freshness"), model.isFresh
                        ? loc("Fresh") : loc("Stale"))
                    if let mediaSession = context.mediaSession {
                        detail(loc("Media state"),
                               mediaStateLabel(mediaSession.state))
                        detail(loc("Playback bit"),
                               playbackBitLabel(mediaSession.playback))
                        if mediaSession.activeStoreTotalMiB != nil ||
                            mediaSession.activeStoreFreeMiB != nil {
                            let total = mediaSession.activeStoreTotalMiB.map(String.init)
                                ?? loc("Unknown")
                            let free = mediaSession.activeStoreFreeMiB.map(String.init)
                                ?? loc("Unknown")
                            detail(loc("Active store"),
                                   "\(free) / \(total) MiB")
                        }
                        detail(loc("Media state freshness"),
                               mediaSession.isFresh(
                                   nowUptime: ProcessInfo.processInfo.systemUptime,
                                   maximumAge: context.maximumAge)
                               ? loc("Fresh") : loc("Stale"))
                    }
                }
                if let progress = model.listProgress {
                    detail(loc("List progress"),
                           "\(progress.acceptedChunkCount) chunks · \(progress.assembledByteCount) bytes")
                }
                if model.rows.isEmpty {
                    Text(loc("No metadata page loaded.")).font(Yun.Text.caption)
                        .foregroundStyle(Yun.Palette.textTertiary)
                } else {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                }
                if let progress = model.rangeProgress {
                    YunDivider()
                    detail(loc("Range download"),
                           "\(progress.receivedBytes)/\(progress.expectedBytes) bytes")
                    ProgressView(value: progress.fraction)
                    if progress.phase == .downloading {
                        Button(loc("Cancel download")) {
                            _ = model.cancelRange(
                                nowUptime: ProcessInfo.processInfo.systemUptime)
                        }
                        .buttonStyle(YunButtonStyle(.secondary, small: true))
                    } else if progress.isPartial {
                        Text(loc("Partial or cancelled; no media file was saved."))
                            .font(Yun.Text.caption)
                            .foregroundStyle(Yun.Palette.textTertiary)
                    }
                }
                Text(loc("Media library shows metadata only; thumbnails and camera images stay hidden."))
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("Pocket3MediaLibraryDiagnostics")
        .measuredForLayout("pocket3MediaLibraryDiagnostics")
    }

    private func rowView(_ row: Pocket3MediaLibraryRow) -> some View {
        VStack(alignment: .leading, spacing: Yun.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name).font(Yun.Text.body)
                Spacer(minLength: Yun.Space.sm)
                if row.starred == true {
                    Image(systemName: "star.fill").foregroundStyle(Yun.Palette.warning)
                }
            }
            HStack(spacing: Yun.Space.md) {
                Text(row.typeLabel)
                if let duration = row.durationLabel { Text(duration) }
                if let size = row.sizeLabel { Text(size) }
                if row.starred == false { Text(loc("Not starred")) }
            }
            .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
        }
        .accessibilityIdentifier("Pocket3MediaLibraryRow.\(row.id)")
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(Yun.Palette.textTertiary)
            Spacer(minLength: Yun.Space.md)
            Text(value).foregroundStyle(Yun.Palette.textSecondary)
                .textSelection(.enabled).multilineTextAlignment(.trailing)
        }.font(Yun.Text.caption)
    }

    private func mediaStateLabel(_ state: Pocket3MediaSessionState) -> String {
        switch state {
        case .normal: return loc("Normal")
        case .playback: return loc("Playback")
        case .transition: return loc("Transition")
        case .unknown(let raw):
            let unknown = loc("Unknown")
            let rawLabel = String(format: "%02X", raw)
            return "\(unknown) (0x\(rawLabel))"
        }
    }

    private func playbackBitLabel(_ value: Bool?) -> String {
        guard let value else { return loc("Unknown") }
        return loc(value ? "Set" : "Clear")
    }
}
