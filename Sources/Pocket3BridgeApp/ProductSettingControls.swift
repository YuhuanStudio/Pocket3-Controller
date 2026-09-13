import Foundation
import Pocket3Core
import YunDesign

struct NativeSettingProductOption: Identifiable {
    let action: NativeSettingValidationOperation
    let target: Pocket3NativeSettingTarget
    let title: String

    var id: String {
        "\(action.rawValue):\(title)"
    }
}

extension AppModel {
    var nativeSettingProductWriterEntries: [Pocket3WriterSupportEntry] {
        Pocket3WriterSupportReport.current.entries.filter {
            [.whiteBalance, .focusMode, .colorProfile, .productShowcase]
                .contains($0.id)
        }
    }

    func productWriterEntry(
        for id: Pocket3WriterCandidateID
    ) -> Pocket3WriterSupportEntry? {
        Pocket3WriterSupportReport.current.entry(for: id)
    }

    var nativeSettingProductOptions: [NativeSettingProductOption] {
        guard wireless.nativeSessionStatus.commandReady else { return [] }
        let now = ProcessInfo.processInfo.systemUptime
        return NativeSettingValidationOperation.allCases.flatMap {
            action -> [NativeSettingProductOption] in
            let writer = NativeSettingProductWriterService()
            guard writer.isUnlocked(for: action),
                  let baseline = nativeSettingBaseline(
                      action,
                      observations: wireless.discovery.cameraSettingsObservations,
                      sessionID: wireless.nativeSessionStatus.sessionID ?? UUID(),
                      generation: wireless.nativeSessionStatus.generation,
                      nowUptime: now),
                  baseline.isFresh(
                      session: wireless.nativeSessionStatus, nowUptime: now) else {
                return []
            }
            let targets: [Pocket3NativeSettingTarget]
            switch action {
            case .whiteBalance:
                targets = [.whiteBalance(.automatic)] + stride(
                    from: 2_000, through: 10_000, by: 100).map {
                        .whiteBalance(.customKelvin($0))
                    }
            case .focusMode:
                targets = [CameraFocusMode.single, .continuous].map {
                    .focusMode($0)
                }
            case .colorProfile:
                targets = CameraColorProfile.allCases.map { .colorProfile($0) }
            case .productShowcase:
                targets = Pocket3ProductShowcaseMode.allCases.map {
                    .productShowcase($0)
                }
            }
            return targets.map {
                NativeSettingProductOption(
                    action: action, target: $0,
                    title: Self.nativeSettingTargetTitle($0))
            }
        }
    }

    var legalBodyRecordingProductFormats:
        [CameraBodyRecordingFormatCommand] {
        let now = ProcessInfo.processInfo.systemUptime
        guard wireless.nativeSessionStatus.commandReady,
              let bodyStatus = wireless.discovery.cameraStatus,
              bodyStatus.sessionID == wireless.discovery.sessionID,
              bodyStatus.peripheralID == wireless.discovery.selectedPeripheralID,
              bodyStatus.isFresh(nowUptime: now),
              bodyStatus.shootingMode == .video else {
            return []
        }
        let binding = ContinuousGimbalBinding(
            sessionID: "ble:\(wireless.discovery.sessionID.uuidString)",
            generation: 0)
        let capabilities = wireless.discovery.cameraSettingsObservations
            .reversed()
            .first {
                $0.property == .videoFormatCapabilities &&
                    $0.binding == binding &&
                    $0.isFresh(
                        now: now,
                        maximumAge: NativeBodyFormatCoordinator.maximumReadbackAge)
            }?.bodyRecordingCapabilities
        return capabilities?.entries.compactMap {
            CameraBodyRecordingFormatCommand(capability: $0)
        } ?? []
    }

    var bodyRecordingProductWriterUnlocked: Bool {
        guard let entry = Pocket3WriterSupportReport.current.entry(
            for: .bodyRecording) else { return false }
        return entry.admission == .locallyVerifiedWrite &&
            entry.executionAllowed && entry.availability.write &&
            entry.availability.verified
    }

    var nativeSettingProductControlsVisible: Bool {
        wireless.nativeSessionStatus.commandReady
    }

    func performBodyRecordingProductWrite(
        action: CameraBodyRecordingAction,
        format: CameraBodyRecordingFormatCommand? = nil
    ) {
        guard !bodyRecordingProductBusy,
              wireless.nativeSessionStatus.commandReady,
              bodyRecordingProductWriterUnlocked else { return }
        guard let sessionID = wireless.nativeSessionStatus.sessionID,
              let peripheralID = wireless.nativeSessionStatus.peerID else {
            bodyRecordingProductError = loc("Native session is unavailable")
            return
        }
        let request: CameraBodyRecordingRequest
        do {
            request = try CameraBodyRecordingRequest(
                action: action, expectedSessionID: sessionID,
                peripheralID: peripheralID,
                generation: wireless.nativeSessionStatus.generation,
                format: format, execute: true)
        } catch {
            bodyRecordingProductError = AppErrorPresentation.message(error)
            return
        }
        bodyRecordingProductBusy = true
        bodyRecordingProductError = nil
        bodyRecordingProductResult = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.handleCameraBodyRecording(
                    ServiceRequest(token: "ui",
                        operation: CameraBodyRecordingRequest.operation,
                        arguments: request.arguments))
                guard let result = reply.result else {
                    throw BridgeFailure("camera_body_recording_empty",
                        "The camera returned no body recording result")
                }
                self.bodyRecordingProductResult = try result.decode(
                    CameraBodyRecordingResult.self)
                await self.refresh()
            } catch {
                self.bodyRecordingProductError = AppErrorPresentation.message(error)
            }
            self.bodyRecordingProductBusy = false
        }
    }

    func performNativeSettingProductWrite(
        _ option: NativeSettingProductOption
    ) {
        guard !nativeSettingProductBusy,
              wireless.nativeSessionStatus.commandReady,
              NativeSettingProductWriterService().isUnlocked(
                  for: option.action),
              let sessionID = wireless.nativeSessionStatus.sessionID,
              let peripheralID = wireless.nativeSessionStatus.peerID else {
            return
        }
        let request: NativeSettingValidationRequest
        do {
            request = try NativeSettingValidationRequest(
                action: option.action, expectedSessionID: sessionID,
                peripheralID: peripheralID,
                generation: wireless.nativeSessionStatus.generation,
                target: option.target, execute: true)
        } catch {
            nativeSettingProductError = AppErrorPresentation.message(error)
            return
        }
        nativeSettingProductBusy = true
        nativeSettingProductError = nil
        nativeSettingProductResult = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.handleNativeSettingProductWrite(
                    ServiceRequest(token: "ui",
                        operation: MCPNativeSettingToolContract.operation,
                        arguments: request.arguments))
                guard let result = reply.result else {
                    throw BridgeFailure("native_setting_empty",
                        "The camera returned no native setting result")
                }
                self.nativeSettingProductResult = try result.decode(
                    NativeSettingProductWriteResult.self)
                await self.refresh()
            } catch {
                self.nativeSettingProductError = AppErrorPresentation.message(error)
            }
            self.nativeSettingProductBusy = false
        }
    }

    private static func nativeSettingTargetTitle(
        _ target: Pocket3NativeSettingTarget
    ) -> String {
        switch target {
        case .whiteBalance(.automatic): loc("Automatic")
        case .whiteBalance(.customKelvin(let kelvin)):
            "\(kelvin) K"
        case .focusMode(.single): loc("Single AF")
        case .focusMode(.continuous): loc("Continuous AF")
        case .colorProfile(.normal): loc("Normal")
        case .colorProfile(.hlg): "HLG"
        case .colorProfile(.dLogM): "D-Log M"
        case .productShowcase(.off): loc("Off")
        case .productShowcase(.on): loc("On")
        }
    }
}
