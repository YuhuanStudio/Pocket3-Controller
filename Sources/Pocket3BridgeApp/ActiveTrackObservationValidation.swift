import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only passive ActiveTrack observation route. It arms the
    /// existing exact BLE event recorder after taking a typed baseline; the
    /// route never sends A6, reads credentials or changes subscriptions.
    func handleActiveTrackObservationWindow(_ request: ServiceRequest)
        async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "ActiveTrack observation requires an explicit development launch")
        }
        let input = try NativeActiveTrackObservationWindowRequest(
            arguments: request.arguments)
        let discovery = wireless.bluetooth.status
        let route = NativeActiveTrackObservationWindowRoute.evaluate(
            status: discovery,
            expectedSessionID: input.expectedSessionID,
            peripheralID: input.peripheralID)
        guard route.isAvailable else {
            let result = NativeActiveTrackObservationWindowService().run(
                input, route: route, baseline: nil, recording: nil)
            return ServiceReply(id: request.id, result: try .encode(result))
        }

        let baseline = NativeActiveTrackObservationBaseline(
            sessionID: input.expectedSessionID,
            peripheralID: input.peripheralID,
            capturedUptime: ProcessInfo.processInfo.systemUptime,
            activeTrackObservations: discovery.activeTrackObservations,
            trackingCandidates: discovery.trackingCandidates,
            cameraStatus: discovery.cameraStatus)
        let recording: BluetoothCameraEventRecording
        do {
            recording = try await wireless.bluetooth.recordCameraEvents(
                expectedSessionID: input.expectedSessionID,
                peripheralID: input.peripheralID)
        } catch let error as BridgeFailure {
            // A route failure is returned as typed evidence. Busy/usage
            // errors remain errors so an operator can distinguish them from a
            // disconnected or unavailable BLE owner.
            guard [
                "bluetooth_camera_events_connection_changed",
                "bluetooth_camera_events_not_ready"
            ].contains(error.code) else { throw error }
            let unavailable = NativeActiveTrackObservationWindowRoute.unavailable(
                code: error.code)
            let result = NativeActiveTrackObservationWindowService().run(
                input, route: unavailable, baseline: nil, recording: nil)
            return ServiceReply(id: request.id, result: try .encode(result))
        }
        let result = NativeActiveTrackObservationWindowService().run(
            input, route: .available, baseline: baseline, recording: recording)
        return ServiceReply(id: request.id, result: try .encode(result))
    }

    /// Interactive developer-only lifecycle for one passive ActiveTrack
    /// window. The BLE discovery object remains the sole event-recorder owner;
    /// these calls only mutate the operator marker coordinator.
    func handleActiveTrackObservationWindowLifecycle(_ request: ServiceRequest)
        async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "ActiveTrack observation requires an explicit development launch")
        }
        let input = try NativeActiveTrackObservationWindowLifecycleRequest(
            arguments: request.arguments)
        switch input.action {
        case .start:
            // The passive recorder owns the twenty-second deadline.  It can
            // therefore become terminal between IPC lifecycle calls while
            // the marker coordinator still says armed/observing.  Reap that
            // stale coordinator before applying the single-window gate so a
            // completed recorder cannot permanently wedge later trials.
            if var existing = developerActiveTrackObservationWindow,
               let recording = wireless.bluetooth.cameraEventRecordingSnapshot,
               recording.end != nil {
                _ = existing.finish(recording: recording)
                developerActiveTrackObservationWindow = nil
            }
            guard developerActiveTrackObservationWindow == nil else {
                throw BridgeFailure("active_track_observation_busy",
                    "Finish or cancel the active ActiveTrack observation window first")
            }
            let discovery = wireless.bluetooth.status
            let route = NativeActiveTrackObservationWindowRoute.evaluate(
                status: discovery,
                expectedSessionID: input.expectedSessionID,
                peripheralID: input.peripheralID)
            let now = ProcessInfo.processInfo.systemUptime
            let baseline = NativeActiveTrackObservationBaseline(
                sessionID: input.expectedSessionID,
                peripheralID: input.peripheralID,
                capturedUptime: now,
                activeTrackObservations: discovery.activeTrackObservations,
                trackingCandidates: discovery.trackingCandidates,
                cameraStatus: discovery.cameraStatus)
            guard route.isAvailable else {
                let coordinator = try NativeActiveTrackObservationWindowLifecycleCoordinator(
                    start: input, route: route, baseline: nil, startedUptime: now)
                return ServiceReply(id: request.id,
                                    result: try .encode(coordinator.status(action: .start)))
            }
            do {
                try wireless.bluetooth.startCameraEventRecording(
                    expectedSessionID: input.expectedSessionID,
                    peripheralID: input.peripheralID)
            } catch let error as BridgeFailure {
                guard [
                    "bluetooth_camera_events_connection_changed",
                    "bluetooth_camera_events_not_ready"
                ].contains(error.code) else { throw error }
                let unavailable = NativeActiveTrackObservationWindowRoute.unavailable(
                    code: error.code)
                let coordinator = try NativeActiveTrackObservationWindowLifecycleCoordinator(
                    start: input, route: unavailable, baseline: nil,
                    startedUptime: now)
                return ServiceReply(id: request.id,
                                    result: try .encode(coordinator.status(action: .start)))
            }
            let recorderStartedUptime = wireless.bluetooth.cameraEventRecordingSnapshot?.startedUptime ?? now
            let coordinator = try NativeActiveTrackObservationWindowLifecycleCoordinator(
                start: input, route: .available, baseline: baseline,
                startedUptime: recorderStartedUptime)
            developerActiveTrackObservationWindow = coordinator
            let status = coordinator.update(
                recording: wireless.bluetooth.cameraEventRecordingSnapshot,
                action: .start)
            return ServiceReply(id: request.id, result: try .encode(status))

        case .marker:
            guard var coordinator = developerActiveTrackObservationWindow else {
                throw BridgeFailure("active_track_observation_not_active",
                    "Start an ActiveTrack observation window first")
            }
            try ensureActiveTrackLifecycleIdentity(input, coordinator: coordinator)
            if let recording = wireless.bluetooth.cameraEventRecordingSnapshot,
               recording.end != nil {
                let status = coordinator.finish(recording: recording)
                developerActiveTrackObservationWindow = nil
                return ServiceReply(id: request.id, result: try .encode(status))
            }
            let route = NativeActiveTrackObservationWindowRoute.evaluate(
                status: wireless.bluetooth.status,
                expectedSessionID: coordinator.expectedSessionID,
                peripheralID: coordinator.peripheralID)
            guard route.isAvailable else {
                coordinator.observeRoute(route)
                developerActiveTrackObservationWindow = coordinator
                let status = coordinator.status(
                    action: .marker,
                    recording: wireless.bluetooth.cameraEventRecordingSnapshot)
                return ServiceReply(id: request.id, result: try .encode(status))
            }
            let markerRequest: NativeActiveTrackObservationWindowLifecycleRequest
            if input.markerUptime != nil {
                markerRequest = input
            } else {
                markerRequest = try NativeActiveTrackObservationWindowLifecycleRequest(
                    action: .marker,
                    expectedSessionID: input.expectedSessionID,
                    peripheralID: input.peripheralID,
                    markerState: input.markerState,
                    markerUptime: ProcessInfo.processInfo.systemUptime)
            }
            try coordinator.mark(markerRequest)
            developerActiveTrackObservationWindow = coordinator
            let status = coordinator.update(
                recording: wireless.bluetooth.cameraEventRecordingSnapshot,
                action: .marker)
            return ServiceReply(id: request.id, result: try .encode(status))

        case .status:
            guard var coordinator = developerActiveTrackObservationWindow else {
                throw BridgeFailure("active_track_observation_not_active",
                    "Start an ActiveTrack observation window first")
            }
            try ensureActiveTrackLifecycleIdentity(input, coordinator: coordinator)
            if let recording = wireless.bluetooth.cameraEventRecordingSnapshot,
               recording.end != nil {
                let status = coordinator.finish(recording: recording)
                developerActiveTrackObservationWindow = nil
                return ServiceReply(id: request.id, result: try .encode(status))
            }
            let route = NativeActiveTrackObservationWindowRoute.evaluate(
                status: wireless.bluetooth.status,
                expectedSessionID: coordinator.expectedSessionID,
                peripheralID: coordinator.peripheralID)
            if !route.isAvailable {
                coordinator.observeRoute(route)
            }
            developerActiveTrackObservationWindow = coordinator
            let status = coordinator.update(
                recording: wireless.bluetooth.cameraEventRecordingSnapshot,
                action: .status)
            return ServiceReply(id: request.id, result: try .encode(status))

        case .finish:
            guard var coordinator = developerActiveTrackObservationWindow else {
                throw BridgeFailure("active_track_observation_not_active",
                    "Start an ActiveTrack observation window first")
            }
            try ensureActiveTrackLifecycleIdentity(input, coordinator: coordinator)
            let route = NativeActiveTrackObservationWindowRoute.evaluate(
                status: wireless.bluetooth.status,
                expectedSessionID: coordinator.expectedSessionID,
                peripheralID: coordinator.peripheralID)
            if !route.isAvailable {
                coordinator.observeRoute(route)
            }
            let recording = await wireless.bluetooth.finishCameraEventRecording()
            let status = coordinator.finish(recording: recording)
            developerActiveTrackObservationWindow = nil
            return ServiceReply(id: request.id, result: try .encode(status))

        case .cancel:
            guard var coordinator = developerActiveTrackObservationWindow else {
                throw BridgeFailure("active_track_observation_not_active",
                    "Start an ActiveTrack observation window first")
            }
            try ensureActiveTrackLifecycleIdentity(input, coordinator: coordinator)
            let route = NativeActiveTrackObservationWindowRoute.evaluate(
                status: wireless.bluetooth.status,
                expectedSessionID: coordinator.expectedSessionID,
                peripheralID: coordinator.peripheralID)
            if !route.isAvailable {
                coordinator.observeRoute(route)
            }
            let recording = await wireless.bluetooth.stopCameraEventRecording()
            let status = coordinator.cancel(recording: recording)
            developerActiveTrackObservationWindow = nil
            return ServiceReply(id: request.id, result: try .encode(status))
        }
    }

    private func ensureActiveTrackLifecycleIdentity(
        _ request: NativeActiveTrackObservationWindowLifecycleRequest,
        coordinator: NativeActiveTrackObservationWindowLifecycleCoordinator
    ) throws {
        guard request.expectedSessionID == coordinator.expectedSessionID else {
            throw BridgeFailure("active_track_observation_stale_session",
                "The ActiveTrack observation session changed")
        }
        guard request.peripheralID == coordinator.peripheralID else {
            throw BridgeFailure("active_track_observation_stale_peer",
                "The ActiveTrack observation peer changed")
        }
    }
}
