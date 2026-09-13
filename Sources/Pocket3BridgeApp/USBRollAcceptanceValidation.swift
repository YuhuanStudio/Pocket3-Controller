import Foundation
import Pocket3Core

@MainActor private var usbRollAcceptanceRunning = false

/// Developer-only projection for the Roll acceptance reply. Keeping the
/// report and evaluation together makes progress, stop, restore and reconnect
/// evidence visible to a validation caller without adding a general UI model.
enum USBRollAcceptanceAppPresentation {
    static func payload(report: USBRollAcceptanceReport,
                        evaluation: USBRollAcceptanceEvaluation,
                        rollControlUnlocked: Bool = false) throws -> JSONValue {
        .object([
            "operation": .string(USBRollAcceptanceRequest.operation),
            "report": try .encode(report),
            "evaluation": try .encode(evaluation),
            "cameraImagesStored": .bool(report.cameraImagesStored),
            "physicalMotionVerified": .bool(report.physicalMotionVerified),
            "rollControlUnlocked": .bool(rollControlUnlocked)
        ])
    }
}

extension AppModel {
    /// Runs one bounded Roll moving-stop/restore acceptance sequence through
    /// the existing CameraService USB owner. It never captures or returns an
    /// image, and it is separate from the ordinary Roll control model.
    func handleUSBRollAcceptance(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Roll acceptance requires a development launch")
        }
        let input: USBRollAcceptanceRequest
        do {
            input = try USBRollAcceptanceRequest(arguments: request.arguments)
        } catch USBRollAcceptanceRequestError.identityRequired {
            throw BridgeFailure("roll_acceptance_identity_required",
                "Execute requires the exact current device and capture session")
        } catch USBRollAcceptanceRequestError.invalidRawValue {
            throw BridgeFailure("roll_acceptance_raw_invalid",
                "Roll acceptance rawValue must be a signed Int16 value")
        } catch {
            throw BridgeFailure("invalid_roll_acceptance_arguments",
                "Use the bounded Roll acceptance arguments")
        }

        if !input.execute {
            let report = USBRollAcceptanceExecutor.dryRun(input)
            return ServiceReply(id: request.id,
                result: try USBRollAcceptanceAppPresentation.payload(
                    report: report,
                    evaluation: USBRollAcceptanceExecutor.evaluate(report)))
        }
        guard !usbRollAcceptanceRunning else {
            throw BridgeFailure("roll_acceptance_busy",
                "A Roll acceptance run is already in progress")
        }
        usbRollAcceptanceRunning = true
        defer { usbRollAcceptanceRunning = false }

        guard let expectedDeviceID = input.expectedDeviceID,
              let expectedSessionID = input.expectedSessionID else {
            throw BridgeFailure("roll_acceptance_identity_required",
                "Execute requires the exact current device and capture session")
        }
        let initial = await service.status()
        guard initial.phase == "ready",
              initial.selected?.id == expectedDeviceID,
              initial.capture.sessionID == expectedSessionID,
              initial.capture.frame?.sessionID == expectedSessionID,
              initial.capture.frame?.deviceID == expectedDeviceID,
              initial.capture.age.map({ $0.isFinite && $0 >= 0 && $0 <= 1 }) == true,
              !initial.motionActive,
              initial.controlTransport == "usb_position",
              initial.gimbal?.writable == true,
              let initialMode = initial.requestedMode else {
            throw BridgeFailure("roll_acceptance_session_changed",
                "Roll acceptance requires a fresh ready USB capture session")
        }

        let service = service
        let initialPixelFormat = initial.requestedPixelFormat ?? .automatic
        let initialOutputPolicy = initial.requestedOutputPolicy ?? .bgra
        let readBinding: USBRollAcceptanceExecutorAdapter.ReadBinding = {
            let status = await service.status()
            return try rollAcceptanceBinding(from: status)
        }
        let readCapabilities: USBRollAcceptanceExecutorAdapter.ReadCapabilities = {
            try await service.rollCapabilities(expectedSessionID: expectedSessionID)
        }
        let startMove: USBRollAcceptanceExecutorAdapter.StartMove = { rawValue, sessionID in
            Task { () throws -> USBRollResult in
                try await service.roll(rawValue: rawValue,
                    expectedSessionID: sessionID, origin: .manual)
            }
        }
        let stop: USBRollAcceptanceExecutorAdapter.Stop = {
            let motion = try await service.stop()
            guard let roll = motion.rollStop else {
                return USBRollStopResult(submitted: false, target: nil,
                    observed: nil, verified: false,
                    failure: "roll_acceptance_stop_missing")
            }
            return roll
        }
        let reconnect: USBRollAcceptanceExecutorAdapter.Reconnect = {
            oldBinding, oldTargetRaw, request in
            try Task.checkCancellation()
            await service.pause()
            try await service.connect(id: expectedDeviceID, mode: initialMode,
                pixelFormat: initialPixelFormat,
                outputPolicy: initialOutputPolicy,
                validationStartupTimeout: min(30, max(1, request.timeout / 2)),
                validationSkipUVC: false)
            let status = await service.status()
            let newBinding = try rollAcceptanceBinding(from: status)
            let newReady = status.phase == "ready" &&
                status.selected?.id == expectedDeviceID &&
                status.capture.frame?.sessionID == newBinding.captureSessionID &&
                status.capture.frame?.deviceID == expectedDeviceID &&
                status.capture.age.map({ $0.isFinite && $0 >= 0 && $0 <= 1 }) == true

            // Reuse the old expected session as a fence probe. CameraService
            // rejects this before its UVC SET, so this does not retry a Roll
            // command against the replacement connection.
            var oldOperationSuppressed = false
            do {
                _ = try await service.roll(rawValue: oldTargetRaw,
                    expectedSessionID: oldBinding.captureSessionID,
                    origin: .manual)
            } catch let failure as BridgeFailure
                where failure.code == "session_changed" {
                oldOperationSuppressed = true
            } catch {
                oldOperationSuppressed = false
            }
            let failureCode: String? = newBinding == oldBinding
                ? "roll_acceptance_reconnect_same_binding"
                : (!newReady || !oldOperationSuppressed
                    ? "roll_acceptance_reconnect_unverified" : nil)
            return USBRollAcceptanceReconnectEvidence(
                oldBinding: oldBinding, newBinding: newBinding,
                oldOperationStopped: true,
                oldOperationSuppressed: oldOperationSuppressed,
                newSessionReady: newReady, failureCode: failureCode)
        }

        let adapter = USBRollAcceptanceExecutorAdapter(
            readCapabilities: readCapabilities, startMove: startMove,
            stop: stop, readBinding: readBinding, reconnect: reconnect)
        let report = await USBRollAcceptanceExecutor.execute(input,
            adapter: adapter)
        let evaluation = USBRollAcceptanceExecutor.evaluate(report)
        var unlocked = false
        if evaluation.metricsPassed, report.completed,
           let old = report.initialBinding,
           let new = report.finalBinding {
            try await service.admitRollStopValidation(old: old, new: new)
            unlocked = true
        }
        return ServiceReply(id: request.id,
            result: try USBRollAcceptanceAppPresentation.payload(
                report: report,
                evaluation: evaluation,
                rollControlUnlocked: unlocked))
    }
}

private func rollAcceptanceBinding(from status: ServiceStatus)
    throws -> USBRollAcceptanceBinding {
    guard let deviceID = status.selected?.id,
          !status.capture.sessionID.isEmpty else {
        throw BridgeFailure("roll_acceptance_binding_missing",
            "The current USB status has no complete Roll acceptance binding")
    }
    return USBRollAcceptanceBinding(
        deviceID: deviceID, captureSessionID: status.capture.sessionID,
        registryID: status.gimbal?.registryID,
        bootSessionID: status.gimbal?.bootSessionID)
}
