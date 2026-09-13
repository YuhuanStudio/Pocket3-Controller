import SwiftUI
import AppKit
import Pocket3Core
import YunDesign

struct WirelessGimbalConnectionView: View {
    @Bindable var model: WirelessGimbalModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Yun.Space.md) {
            HStack {
                Text(loc("Bluetooth gimbal control")).font(Yun.Text.title)
                Spacer(minLength: 0)
                if model.connecting { ProgressView().controlSize(.mini) }
            }
            Text(loc("Use USB for video and Bluetooth for control. Your Mac keeps its current network.")).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
            YunDivider()
            HStack {
                Text(loc("Camera pairing")).font(Yun.Text.label)
                Spacer(minLength: 0)
                Button(loc("Scan")) { Task { await model.scan() } }
                    .buttonStyle(YunButtonStyle(.secondary, small: true))
                    .disabled(model.connecting || model.joiningNetwork || model.nativeConnected)
            }
            Text(phaseTitle).font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary)
            if !model.discovery.candidates.isEmpty && !model.hasCredentials {
                YunSelect(selection: $model.selectedPeripheral, placeholder: loc("Select a wireless camera"),
                    options: model.discovery.candidates.map {
                        .init(value: $0.id.uuidString, title: $0.name ?? loc("Wireless camera"), detail: $0.rssi.map { "\($0) dBm" })
                    })
                    .disabled(![.scanning, .scanComplete].contains(model.discovery.phase))
                HStack(spacing: Yun.Space.sm) {
                    if [.scanning, .scanComplete].contains(model.discovery.phase) {
                        Button(loc("Connect Bluetooth")) {
                            do { try model.connectBluetooth() } catch { model.issue = AppErrorPresentation.message(error) }
                        }.buttonStyle(YunButtonStyle(.primary, small: true)).disabled(model.selectedPeripheral.isEmpty)
                    }
                    if model.discovery.phase == .gattConnectedUnauthenticated {
                        Button(loc("Pair camera")) {
                            do { try model.pair() } catch { model.issue = AppErrorPresentation.message(error) }
                        }.buttonStyle(YunButtonStyle(.primary, small: true))
                    }
                }
            }
            if model.pairingStatus?.peerReportedPaired == true {
                Label(loc("Bluetooth peer paired"), systemImage: "checkmark.circle")
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary)
                Text(loc("Pocket 3 identity and USB association are not verified."))
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textTertiary)
            }
            if model.pairingStatus?.credentialsAvailable == true {
                YunDivider()
                Button {
                    Task {
                        if model.nativeConnected || model.nativeStatus != nil {
                            await model.disconnectNative()
                        } else {
                            await model.connectNative()
                        }
                    }
                } label: {
                    Label(
                        loc(model.nativeConnected
                            ? "Disconnect wireless"
                            : "Connect native camera control to move continuously."),
                        systemImage: model.nativeConnected
                            ? "xmark.circle" : "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(YunButtonStyle(.secondary, small: true))
                .disabled(model.connecting || model.joiningNetwork)
            }
            if let battery = model.freshBatteryAssessment {
                YunDivider()
                BluetoothBatteryView(assessment: battery)
            }
            if model.pairingStatus?.peerReportedPaired == true, model.discovery.phase == .gattPaired {
                YunDivider()
                BluetoothCameraSettingsView(observations: model.discovery.cameraSettingsObservations,
                    reading: model.readingCameraSettings, refresh: { model.readCameraSettings() })
            }
            if let camera = model.discovery.cameraStatus,
               camera.sessionID == model.discovery.sessionID,
               camera.peripheralID == model.discovery.selectedPeripheralID,
               camera.isFresh(nowUptime: ProcessInfo.processInfo.systemUptime) {
                YunDivider()
                BluetoothCameraStatusView(observation: camera, storage: model.discovery.storageStatus)
            }
            if let pose = model.discovery.pose,
               pose.sessionID == model.discovery.sessionID,
               pose.peripheralID == model.discovery.selectedPeripheralID,
               pose.isFresh(nowUptime: ProcessInfo.processInfo.systemUptime) {
                YunDivider()
                BluetoothPoseView(observation: pose)
            }
            if model.nativeConnected {
                Label(loc("Continuous control connected"), systemImage: "checkmark.circle")
                    .font(Yun.Text.caption).foregroundStyle(Yun.Palette.textSecondary)
            }
            if let detail = model.nativeConnectionDetail, model.nativeStatus != nil {
                Text(detail).font(Yun.Text.caption)
                    .foregroundStyle(model.nativeStatus?.phase == .disarmed || model.nativeStatus?.phase == .error ? Yun.Palette.warning : Yun.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let issue = model.issue {
                Text(issue).font(Yun.Text.caption).foregroundStyle(Yun.Palette.warning).fixedSize(horizontal: false, vertical: true)
            }
            if model.discovery.phase != .idle && model.discovery.phase != .disconnected {
                Button(loc("Disconnect wireless")) { Task { await model.disconnect() } }
                    .buttonStyle(YunButtonStyle(.ghost, small: true))
            }
        }
        .padding(Yun.Space.lg)
        }
        .scrollIndicators(.visible)
        .frame(width: 340)
        .frame(maxHeight: 680)
        .background(Yun.Palette.background)
    }

    private var phaseTitle: String {
        if let pairing = model.pairingStatus {
            if pairing.credentialAccessFailed { return loc("Camera pairing was confirmed.") }
            switch pairing.phase {
            case .awaitingApproval: return loc("Approve pairing on the Pocket 3 screen.")
            case .paired, .credentialsReady: return loc("Bluetooth peer paired")
            case .failed: return loc("Pairing did not finish. Scan and try again.")
            case .cancelled: return loc("Pairing cancelled")
            default: return loc("Pairing camera…")
            }
        }
        switch model.discovery.phase {
        case .idle, .disconnected: return loc("Wireless control disconnected")
        case .waitingForBluetooth: return loc("Waiting for Bluetooth permission…")
        case .scanning: return loc("Scanning for cameras…")
        case .scanComplete: return model.discovery.candidates.isEmpty ? loc("No wireless camera found") : loc("Select a wireless camera")
        case .gattConnectedUnauthenticated: return loc("Bluetooth connected. Pair the camera to continue.")
        case .unauthorized: return loc("Allow Bluetooth in System Settings to continue.")
        case .poweredOff: return loc("Turn on Bluetooth to continue.")
        case .failed, .unsupported: return loc("Bluetooth connection unavailable")
        default: return loc("Connecting…")
        }
    }
}
