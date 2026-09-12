import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only live-view route.  Dry-run validates the request shape
    /// and current route/readiness snapshot without creating a sink or sending
    /// a command.  Execute binds to the WirelessGimbalModel's existing
    /// datalink owner and tears the passive sink down when the bounded
    /// validation window ends.
    func handleNativeLiveViewValidation(_ request: ServiceRequest) async
        throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Native live-view validation requires an explicit development launch")
        }
        let input: Pocket3LiveViewValidationRequest
        do {
            input = try Pocket3LiveViewValidationRequest(arguments: request.arguments)
        } catch let error as Pocket3LiveViewValidationError {
            throw BridgeFailure("invalid_native_live_view_request",
                String(describing: error))
        }
        let result = try await wireless.performNativeLiveViewValidation(input)
        return ServiceReply(id: request.id, result: try .encode(result))
    }
}

extension WirelessGimbalModel {
    func performNativeLiveViewValidation(
        _ input: Pocket3LiveViewValidationRequest
    ) async throws -> Pocket3LiveViewValidationResult {
        let readiness = nativeSessionStatus
        let exactSessionMatch = input.expectedSessionID == readiness.sessionID &&
            input.peripheralID == readiness.peerID &&
            input.generation == readiness.generation &&
            input.expectedSessionID == discovery.sessionID &&
            input.peripheralID == discovery.selectedPeripheralID
        let routeAllowed = nativeRouteStatus.state != .unknown &&
            nativeRouteStatus.defaultRouteChanged != true
        let commandReady = readiness.state.satisfies(.commandReady)
        let diagnostics = Pocket3LiveViewValidationDiagnostics(
            requestedSessionID: input.expectedSessionID,
            requestedPeripheralID: input.peripheralID,
            requestedGeneration: input.generation,
            currentSessionID: readiness.sessionID,
            currentPeerID: readiness.peerID,
            currentGeneration: readiness.generation,
            nativeState: readiness.state,
            datalinkAvailable: datalink != nil,
            datalinkPhase: nativeStatus?.phase,
            datalinkBindingGeneration: nativeStatus?.binding?.generation ??
                binding?.generation,
            routeStatus: nativeRouteStatus,
            liveViewSinkAttached: liveViewAdapter != nil)

        func result(
            coordinator: Pocket3LiveViewSessionSnapshot? = nil,
            sessionResult: Pocket3LiveViewSessionResult? = nil,
            failureCode: String? = nil
        ) -> Pocket3LiveViewValidationResult {
            Pocket3LiveViewValidationResult(
                request: input, exactSessionMatch: exactSessionMatch,
                routeAllowed: routeAllowed, commandReady: commandReady,
                diagnostics: diagnostics,
                coordinator: coordinator, sessionResult: sessionResult,
                failureCode: failureCode)
        }

        if !input.execute {
            let failure: String?
            if !exactSessionMatch {
                failure = "native_live_view_session_changed"
            } else if !commandReady {
                failure = "native_live_view_command_not_ready"
            } else if !routeAllowed {
                failure = "native_live_view_route_unvalidated"
            } else {
                failure = nil
            }
            return result(failureCode: failure)
        }

        guard exactSessionMatch else {
            return result(failureCode: "native_live_view_session_changed")
        }
        guard commandReady else {
            return result(failureCode: "native_live_view_command_not_ready")
        }
        guard routeAllowed else {
            return result(failureCode: "native_live_view_route_unvalidated")
        }
        guard nativeStatus?.phase == .ready,
              let link = datalink, let binding else {
            return result(failureCode: "native_live_view_executor_unavailable")
        }
        if let existing = liveViewCoordinator {
            let existingSnapshot = existing.snapshot()
            if let until = existingSnapshot.cooldownUntil,
               ProcessInfo.processInfo.systemUptime < until {
                return result(coordinator: existingSnapshot,
                              failureCode: "native_live_view_cooldown")
            }
            let phase = existingSnapshot.phase
            let terminal: Set<Pocket3LiveViewSessionPhase> = [
                .idle, .disconnected, .cancelled, .failed
            ]
            if phase == .cooldown {
                // The cooldown has expired; retire the old coordinator before
                // creating a fresh attempt for this same native generation.
                invalidateLiveViewValidation()
            } else {
                guard terminal.contains(phase) else {
                    return result(coordinator: existingSnapshot,
                                  failureCode: "native_live_view_busy")
                }
                invalidateLiveViewValidation()
            }
        }

        let routePlan = Pocket3DatalinkRoutePlan(
            configuration: nativeNetworkConfiguration,
            status: nativeRouteStatus,
            allowed: routeAllowed,
            boundInterfaceIndex: nativeRouteStatus.interfaceIndex)
        let decoder = try Pocket3LiveViewVideoToolboxDecoder(
            generation: readiness.generation)
        let sink = try Pocket3LiveViewMediaSink(
            generation: readiness.generation, decoder: decoder)
        let adapter = Pocket3LiveViewDatalinkAdapter(
            datalink: link, sink: sink)
        _ = adapter.attach(binding: binding,
                           logicalGeneration: readiness.generation)

        let expectedReadiness = readiness
        let expectedConnection = generation
        let expectedBinding = binding
        let expectedLink = link
        let commandExecutor = Pocket3LiveViewCommandExecutorAdapter {
            [weak self] request, currentReadiness in
            guard let self else {
                throw NativeCommandTransactionError.datalinkUnavailable
            }
            return try await self.executeNativeLiveView(
                request, readiness: currentReadiness,
                expectedReadiness: expectedReadiness,
                expectedConnection: expectedConnection,
                expectedLink: expectedLink,
                expectedBinding: expectedBinding)
        }
        let coordinator = try Pocket3LiveViewSessionCoordinator(
            mediaSource: adapter, executor: commandExecutor,
            configuration: Pocket3LiveViewSessionConfiguration(
                sendPreEnableHint: input.sendPreEnableHint,
                commandTimeout: input.timeout))
        _ = try coordinator.begin(session: readiness, routePlan: routePlan)
        liveViewSink = sink
        liveViewAdapter = adapter
        liveViewCoordinator = coordinator
        var routeFinished = false
        defer {
            if !routeFinished {
                _ = coordinator.cancel(generation: readiness.generation)
                releaseLiveViewValidationResources(coordinator)
            }
        }

        let start = ProcessInfo.processInfo.systemUptime
        let ingestDeadline = start + input.waitSeconds
        var ingested = coordinator.ingestLatestMedia()
        while !ingested && ProcessInfo.processInfo.systemUptime < ingestDeadline {
            try await Task.sleep(for: .milliseconds(50))
            try Task.checkCancellation()
            ingested = coordinator.ingestLatestMedia()
        }
        guard ingested else {
            let snapshot = coordinator.snapshot()
            return result(coordinator: snapshot,
                          failureCode: "native_live_view_ingest_timeout")
        }

        let afterIngest: Pocket3LiveViewSessionResult
        do {
            afterIngest = try await coordinator.enableIfReady()
        } catch let error as Pocket3LiveViewSessionCoordinatorError {
            let snapshot = coordinator.snapshot()
            return result(coordinator: snapshot,
                          failureCode: Self.liveViewFailureCode(error))
        }

        if afterIngest.phase == .failed || afterIngest.phase == .cancelled ||
           afterIngest.phase == .generationChanged {
            let snapshot = coordinator.snapshot()
            routeFinished = true
            _ = coordinator.disconnect(generation: readiness.generation)
            releaseLiveViewValidationResources(coordinator)
            return result(coordinator: snapshot, sessionResult: afterIngest,
                          failureCode: afterIngest.failureCode ??
                            "native_live_view_enable_failed")
        }

        let readyDeadline = ProcessInfo.processInfo.systemUptime + input.waitSeconds
        while ProcessInfo.processInfo.systemUptime < readyDeadline {
            _ = coordinator.ingestLatestMedia()
            let snapshot = coordinator.tick()
            if snapshot.phase == .ready { break }
            try await Task.sleep(for: .milliseconds(50))
            try Task.checkCancellation()
        }
        let finalSnapshot = coordinator.snapshot()
        let finalResult = coordinator.result ?? afterIngest
        routeFinished = true
        _ = coordinator.disconnect(generation: readiness.generation)
        releaseLiveViewValidationResources(coordinator)
        return result(coordinator: finalSnapshot,
                      sessionResult: finalResult,
                      failureCode: finalResult.ready ? nil :
                        (finalResult.failureCode ?? "native_live_view_stalled"))
    }

    private func executeNativeLiveView(
        _ request: NativeCommandTransactionRequest,
        readiness: NativeCameraSessionStatus,
        expectedReadiness: NativeCameraSessionStatus,
        expectedConnection: UUID,
        expectedLink: Pocket3Datalink,
        expectedBinding: ContinuousGimbalBinding
    ) async throws -> NativeCommandTransactionResult {
        guard nativeSessionStatus == expectedReadiness,
              request.generation == expectedReadiness.generation,
              request.sessionID == expectedReadiness.sessionID,
              generation == expectedConnection,
              datalink === expectedLink,
              binding == expectedBinding,
              !connecting, !joiningNetwork,
              nativeStatus?.phase == .ready else {
            throw NativeCommandTransactionError.staleGeneration
        }
        return try await expectedLink.transact(request, readiness: readiness)
    }

    func invalidateLiveViewValidation() {
        if let coordinator = liveViewCoordinator,
           coordinator.currentGeneration != 0 {
            _ = coordinator.cancel(
                generation: coordinator.currentGeneration)
        }
        liveViewCoordinator = nil
        liveViewAdapter = nil
        liveViewSink = nil
    }

    private func releaseLiveViewValidationResources(
        _ coordinator: Pocket3LiveViewSessionCoordinator
    ) {
        guard liveViewCoordinator === coordinator else { return }
        liveViewAdapter = nil
        liveViewSink = nil
    }

    private static func liveViewFailureCode(
        _ error: Pocket3LiveViewSessionCoordinatorError
    ) -> String {
        switch error {
        case .invalidConfiguration: return "native_live_view_invalid_configuration"
        case .invalidClock: return "native_live_view_invalid_clock"
        case .sessionNotReady: return "native_live_view_command_not_ready"
        case .missingSessionIdentity: return "native_live_view_session_missing"
        case .routeUnavailable(let code): return code
        case .cooldown: return "native_live_view_cooldown"
        case .busy: return "native_live_view_busy"
        case .ingestRequired: return "native_live_view_ingest_required"
        case .alreadyStarted: return "native_live_view_already_started"
        case .staleGeneration: return "native_live_view_generation_changed"
        }
    }
}
