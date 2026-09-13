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
}
