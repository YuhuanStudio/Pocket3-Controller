import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only media browsing validation. The route uses the current
    /// native readiness and route snapshot, then delegates one prepared media
    /// command to WirelessGimbalModel's existing datalink owner. It never
    /// joins Wi-Fi, creates a second transport, or installs a real HTTP
    /// downloader.
    func handleNativeMediaValidation(_ request: ServiceRequest) async throws
        -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Native media validation requires an explicit development launch")
        }

        let input: NativeMediaValidationRequest
        do {
            input = try NativeMediaValidationRequest(arguments: request.arguments)
        } catch let error as NativeMediaValidationError {
            throw nativeMediaValidationFailure(error)
        } catch let error as Pocket3MediaProtocolError {
            throw BridgeFailure("invalid_native_media_request",
                String(describing: error))
        }

        let wireless = self.wireless
        let readiness = wireless.nativeSessionStatus
        let discovery = wireless.discovery
        guard input.expectedSessionID == readiness.sessionID,
              input.peripheralID == readiness.peerID,
              input.expectedSessionID == discovery.sessionID,
              input.peripheralID == discovery.selectedPeripheralID else {
            throw BridgeFailure("native_media_session_changed",
                "The requested native session or peer is no longer current")
        }

        let snapshot = NativeMediaValidationSnapshot(
            session: readiness, routeStatus: wireless.nativeRouteStatus,
            nowUptime: ProcessInfo.processInfo.systemUptime)
        do {
            // Explicit command execution is the only path that obtains the
            // adapter. Range fetching intentionally has no App adapter in
            // this batch, so it remains dry-run/protocol-only here.
            let adapter = input.execute
                ? wireless.nativeMediaValidationAdapter() : nil
            let result = try await NativeMediaValidationService(
                adapter: adapter).run(input, snapshot: snapshot)
            return ServiceReply(id: request.id, result: try .encode(result))
        } catch let error as NativeMediaValidationError {
            throw nativeMediaValidationFailure(error)
        } catch let error as Pocket3MediaProtocolError {
            throw BridgeFailure("invalid_native_media_request",
                String(describing: error))
        }
    }
}

private func nativeMediaValidationFailure(
    _ error: NativeMediaValidationError
) -> BridgeFailure {
    switch error {
    case .invalidArguments:
        BridgeFailure("invalid_native_media_request",
            "Pass one media action with exact session options")
    case .invalidAction:
        BridgeFailure("invalid_native_media_action",
            "Use playback-enter, playback-exit, presence, list or range")
    case .invalidRequestIdentity:
        BridgeFailure("native_media_session_changed",
            "The requested native session, peer or generation is no longer current")
    case .invalidTimeout:
        BridgeFailure("invalid_native_media_timeout",
            "timeout must be between 0 and 5 seconds")
    case .invalidRange:
        BridgeFailure("invalid_native_media_range",
            "Use a bounded HTTP range and a safe relative camera path")
    case .invalidRoute:
        BridgeFailure("native_media_route_invalid",
            "The selected native route is not safe for media validation")
    case .sessionNotReady:
        BridgeFailure("native_media_command_not_ready",
            "Native media validation requires a command-ready session")
    case .missingSessionIdentity:
        BridgeFailure("native_media_session_missing",
            "The native session has no exact camera identity")
    case .baselineRequired:
        BridgeFailure("native_media_baseline_missing",
            "A current media baseline is required")
    case .executorUnavailable:
        BridgeFailure("native_media_executor_unavailable",
            "The existing native datalink owner is unavailable")
    case .fetcherUnavailable:
        BridgeFailure("native_media_range_fetcher_unavailable",
            "HTTP range fetching is protocol-only in this batch")
    case .responseTooLarge:
        BridgeFailure("native_media_response_too_large",
            "The media page or range exceeded its bound")
    case .terminalReadbackMissing:
        BridgeFailure("native_media_terminal_readback_missing",
            "A complete 00/27 terminal chunk is required")
    case .operationInFlight:
        BridgeFailure("native_media_validation_busy",
            "A native media validation operation is already in flight")
    case .staleTransaction:
        BridgeFailure("native_media_transaction_stale",
            "The media transaction belongs to another native generation")
    }
}
