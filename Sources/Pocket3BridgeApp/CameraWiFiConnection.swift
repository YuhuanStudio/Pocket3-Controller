import Foundation
@preconcurrency import CoreWLAN
import Pocket3Core

final class CameraWiFiJoinRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    /// The OS association becomes in-flight after this commit point. CoreWLAN
    /// offers no cancellation API for an association already entered.
    func beginAssociation() throws {
        try lock.withLock { if cancelled { throw CancellationError() } }
    }
}

/// Explicit operator action only. No network change occurs in init, discovery,
/// pairing or datalink reconnect. The password is passed directly to CoreWLAN.
/// Apple documents associate(to:password:) as blocking; keep it off MainActor.
/// https://developer.apple.com/documentation/corewlan/cwinterface/associate(to:password:)
enum CameraWiFiConnection {
    static func join(_ credentials: BluetoothWiFiCredentials, request: CameraWiFiJoinRequest) async throws {
        let work = Task.detached(priority: .userInitiated) {
            guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
                throw BridgeFailure("wifi_unavailable", "請先開啟 Mac 的 Wi-Fi")
            }
            let networks: Set<CWNetwork>
            do { networks = try interface.scanForNetworks(withSSID: Data(credentials.ssid.utf8)) }
            catch { throw BridgeFailure("camera_wifi_scan_failed", "未能搜尋相機 Wi-Fi，請使用系統 Wi-Fi 設定連接") }
            let matches = networks.filter { $0.ssidData == Data(credentials.ssid.utf8) }
            guard let network = matches.max(by: { $0.rssiValue < $1.rssiValue }) else {
                throw BridgeFailure("camera_wifi_not_found", "未找到已配對相機的 Wi-Fi，請確認相機仍開啟無線連線")
            }
            try Task.checkCancellation()
            try request.beginAssociation()
            do { try interface.associate(to: network, password: credentials.password) }
            catch { throw BridgeFailure("camera_wifi_join_failed", "未能加入相機 Wi-Fi，請使用系統 Wi-Fi 設定連接") }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { request.cancel(); work.cancel() }
    }
}
