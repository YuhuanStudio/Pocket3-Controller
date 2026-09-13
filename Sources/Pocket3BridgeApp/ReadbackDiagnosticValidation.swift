import Foundation
import Pocket3Core

extension AppModel {
    /// Read-only developer diagnostic for the already active paired BLE/native
    /// session. It consumes cached query/notification evidence only: no scan,
    /// subscription, setter, opcode, Wi-Fi route or hardware action occurs.
    func handleReadbackDiagnostic(_ request: ServiceRequest) async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                                "Readback diagnostics require an explicit development launch")
        }
        let input: BluetoothReadbackSessionDiagnosticRequest
        do {
            input = try BluetoothReadbackSessionDiagnosticRequest(
                arguments: request.arguments)
        } catch {
            throw BridgeFailure("invalid_readback_diagnostic_arguments",
                                "Pass exact BLE session/peripheral UUIDs and an optional settings or tap-focus path")
        }
        let wireless = self.wireless
        let report = BluetoothReadbackSessionDiagnostic.make(
            request: input,
            bluetooth: wireless.discovery,
            settingsQueries: wireless.lastCameraSettingsQueryResults,
            settingsFailures: wireless.lastCameraSettingsQueryFailures,
            pairedTapFocus: wireless.lastPairedTapFocusResult,
            nativeSession: wireless.nativeSessionStatus,
            nativeTapFocus: developerNativeTapFocusValidationResult)
        return ServiceReply(id: request.id, result: try .encode(report))
    }
}
