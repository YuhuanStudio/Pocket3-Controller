import Foundation
import Pocket3Core
import YunDesign

/// Literal English keys are intentionally enumerable: the design gate and
/// bundle tests validate dynamic error messages without changing app language.
enum AppErrorMessageKey: String, CaseIterable {
    case cancelled = "The operation was cancelled."
    case cameraConnection = "Connect Pocket 3 in Webcam mode, then try again."
    case cameraPermission = "Allow camera access for Pocket 3 Controller in System Settings."
    case microphonePermission = "Allow microphone access for Pocket 3 Controller in System Settings."
    case bluetoothPermission = "Allow Bluetooth access for Pocket 3 Controller in System Settings."
    case bluetoothOff = "Turn on Bluetooth, then scan for the camera again."
    case cameraInUse = "Close other apps using the camera, then reconnect."
    case connectionChanged = "The camera connection changed. Reconnect before starting a new action."
    case freshImage = "No fresh camera image is available. Check the camera and reconnect."
    case busy = "Another operation is finishing. Wait a moment, then try again."
    case observationPermission = "Allow AI observation in the app before requesting an image."
    case controlPermission = "Allow AI camera control in the app before requesting an adjustment."
    case controlUnconfirmed = "Camera control was not confirmed. Check the camera before starting another action."
    case stopUnconfirmed = "The stop could not be confirmed. Check the camera before continuing."
    case zoomUnavailable = "Zoom is unavailable for this connection."
    case zoomUnconfirmed = "Zoom could not be confirmed."
    case zoomRange = "Choose a zoom setting within the available range."
    case rollUnavailable = "Roll is unavailable for this connection."
    case rollUnconfirmed = "Roll could not be confirmed."
    case rollRange = "Choose a roll setting within the available range."
    case rollValidation = "Roll needs its own camera validation before AI can use it."
    case rollNeedsStop = "Stop the roll adjustment before starting another camera control."
    case scalarNeedsStop = "Stop the current camera adjustment before continuing."
    case cameraSettingsUnavailable = "Camera settings could not be read. Check the paired camera and try again."
    case focusUnavailable = "This camera connection does not expose point focus control."
    case focusChanged = "Focus control changed. Choose a focus point again."
    case focusPoint = "Choose a focus point inside the image."
    case focusUnconfirmed = "Could not set the focus point."
    case positionRange = "Choose a camera position within the available range."
    case controlInput = "Invalid control input."
    case controlUnavailable = "This camera connection does not support that control."
    case videoFormat = "Choose a video format supported by the connected camera."
    case bluetoothSelection = "Select a camera from the current Bluetooth scan."
    case pairingRequired = "Connect and pair the selected camera before continuing."
    case bluetoothConnection = "Bluetooth control is unavailable. Check the camera and scan again."
    case controlFeedback = "Camera feedback was lost. Reconnect control before continuing."
    case network = "Check your internet connection and try again."
    case modelDownload = "Download the local model from the AI engines page first."
    case modelFiles = "The model files are incomplete or invalid. Check the download and download them again."
    case appleModel = "The on-device model is unavailable. Check Apple Intelligence in System Settings."
    case localModel = "The local model needs attention. Check its files and download status."
    case modelAnswer = "The model could not produce a verified answer. Check the scene and rephrase the request."
    case question = "Enter a shorter question and choose an available AI engine."
    case timedOut = "The operation timed out. Check the camera before trying again."
    case bridge = "The local camera service is unavailable. Reopen Pocket 3 Controller and try again."
    case loginItem = "Could not update the login item. Check Login Items in System Settings."
    case audio = "Camera audio is unavailable. Check microphone access and reconnect."
    case preset = "This camera connection does not provide that preset."
    case fileAccess = "The file could not be accessed. Check its location and permissions."
    case validation = "Complete camera control validation in Diagnostics before allowing AI adjustments."
    case postActionImage = "The camera action finished, but a new image was unavailable. Capture a fresh image before another adjustment."
    case generic = "The operation could not be completed. Check the connection and diagnostics."
}

enum AppErrorPresentation {
    /// Pure mapping. Error messages are never used as translation keys or
    /// guessed at by language/content, and never interpolated into UI text.
    static func key(for error: Error, fallback: AppErrorMessageKey = .generic) -> AppErrorMessageKey {
        if error is CancellationError { return .cancelled }
        if let failure = error as? BridgeFailure { return key(forCode: failure.code, fallback: fallback) }
        if let error = error as? ContinuousGimbalError {
            switch error {
            case .busy: return .busy
            case .invalidSession, .staleLease: return .connectionChanged
            case .invalidDuration: return .controlInput
            }
        }
        if error is DUMLJoystickError { return .controlInput }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorCancelled ? .cancelled : .network
        }
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoSuchFileError, NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteOutOfSpaceError].contains(nsError.code) {
            return .fileAccess
        }
        return fallback
    }

    static func key(forCode code: String, fallback: AppErrorMessageKey = .generic) -> AppErrorMessageKey {
        switch code {
        case "cancelled", "control_cancelled", "observation_cancelled": return .cancelled
        case "camera_permission": return .cameraPermission
        case "microphone_permission": return .microphonePermission
        case "bluetooth_permission_denied", "bluetooth_authorization_unknown": return .bluetoothPermission
        case "bluetooth_powered_off": return .bluetoothOff
        case "not_connected", "device_missing", "camera_not_ready", "capture_start_failed", "uvc_device_missing": return .cameraConnection
        case "capture_unavailable": return .cameraInUse
        case "session_changed", "session_required", "access_changed", "interaction_changed", "hardware_identity", "uvc_attachment_changed", "uvc_connection_closed", "native_connection_changed", "zoom_connection_changed": return .connectionChanged
        case "no_frame", "stale_frame": return .freshImage
        case "connection_busy", "motion_busy", "wireless_busy", "native_busy", "service_busy", "audio_busy", "ai_busy", "model_busy", "perception_busy", "validation_busy", "bluetooth_probe_busy", "duplicate_request": return .busy
        case "access_denied": return .observationPermission
        case "movement_denied", "zoom_denied": return .controlPermission
        case "motion_not_validated": return .validation
        case "motion_timeout", "motion_not_progressing", "control_unconfirmed", "uvc_write_failed", "uvc_request_timeout": return .controlUnconfirmed
        case "stop_unverified", "usb_stop_failed", "usb_stop_unverified", "usb_stop_feedback_stale", "native_neutral_failed", "zoom_stop_failed", "zoom_stop_unverified", "zoom_stop_feedback_stale": return .stopUnconfirmed
        case "zoom_unavailable", "uvc_zoom_unavailable", "uvc_zoom_not_readable", "uvc_zoom_read_only", "uvc_zoom_limits_unavailable": return .zoomUnavailable
        case "zoom_unconfirmed", "zoom_timing", "zoom_feedback_stale", "zoom_capabilities_changed", "uvc_zoom_read_failed", "uvc_zoom_write_failed": return .zoomUnconfirmed
        case "invalid_zoom_value", "invalid_zoom_arguments", "uvc_zoom_out_of_range", "uvc_zoom_step_mismatch": return .zoomRange
        case "roll_unavailable", "uvc_roll_unavailable", "uvc_roll_not_readable", "uvc_roll_read_only", "uvc_roll_limits_unavailable", "uvc_roll_step_unavailable": return .rollUnavailable
        case "roll_unconfirmed", "roll_timing", "roll_feedback_stale", "roll_capabilities_changed", "uvc_roll_read_failed", "uvc_roll_write_failed": return .rollUnconfirmed
        case "invalid_roll_value", "invalid_roll_arguments", "uvc_roll_out_of_range", "uvc_roll_step_mismatch": return .rollRange
        case "roll_not_validated": return .rollValidation
        case "roll_stop_required": return .rollNeedsStop
        case "scalar_stop_required": return .scalarNeedsStop
        case "camera_settings_unavailable": return .cameraSettingsUnavailable
        case "bluetooth_property_query_not_ready": return .pairingRequired
        case "roll_denied": return .controlPermission
        case "roll_stop_failed", "roll_stop_unverified", "roll_stop_feedback_stale": return .stopUnconfirmed
        case "roll_connection_changed": return .connectionChanged
        case "focus_point_unsupported", "focus_mode_unsupported": return .focusUnavailable
        case "focus_mode_changed": return .focusChanged
        case "invalid_focus_point": return .focusPoint
        case "focus_unconfirmed", "focus_failed": return .focusUnconfirmed
        case "invalid_direction", "invalid_target", "limit_reached", "invalid_preset": return .positionRange
        case "unsupported", "uvc_control_unavailable", "native_control_active": return .controlUnavailable
        case "default_unavailable", "preset_unavailable": return .preset
        case "invalid_format", "invalid_input_format", "format_changed", "format_unavailable", "input_format_changed", "input_format_unavailable": return .videoFormat
        case "bluetooth_selection_required": return .bluetoothSelection
        case "pairing_required", "bluetooth_gatt_required", "bluetooth_probe_not_ready", "bluetooth_readiness_not_ready", "bluetooth_recenter_not_ready", "bluetooth_lens_query_not_ready": return .pairingRequired
        case "bluetooth_connect_failed", "bluetooth_link_lost", "bluetooth_notification_error", "bluetooth_notification_failed", "bluetooth_pairing_failed", "bluetooth_pairing_rejected", "bluetooth_pairing_timeout", "bluetooth_start_timeout", "bluetooth_gatt_timeout", "bluetooth_reset", "bluetooth_service_invalidated", "bluetooth_unsupported", "bluetooth_characteristics_missing", "bluetooth_gatt_properties_mismatch": return .bluetoothConnection
        case "native_feedback_stale", "native_feedback_unavailable", "native_not_connected", "native_disarmed", "native_handshake_timeout", "native_connect_failed", "usb_feedback_stale", "usb_feedback_invalid", "invalid_readback", "usb_capabilities_changed", "trajectory_timing": return .controlFeedback
        case "model_not_downloaded": return .modelDownload
        case "model_checksum", "model_incomplete": return .modelFiles
        case "model_unavailable": return .appleModel
        case "local_model_error": return .localModel
        case "invalid_model_output", "unverified_action_claim", "unverified_zoom_claim", "tool_budget", "movement_budget", "zoom_budget": return .modelAnswer
        case "invalid_question", "invalid_engine": return .question
        case "model_timeout", "native_action_timeout": return .timedOut
        case "already_running", "app_not_running", "ipc_auth", "ipc_bind", "ipc_disconnected", "ipc_identity", "ipc_lock", "ipc_path", "ipc_protocol", "ipc_size", "ipc_socket", "ipc_write", "invalid_probe", "invalid_probe_reply": return .bridge
        case "audio_ambiguous", "audio_start_timeout", "audio_unavailable": return .audio
        case "post_move_frame_failed", "stale_zoom_frame": return .postActionImage
        default: return fallback
        }
    }

    static func message(_ error: Error, fallback: AppErrorMessageKey = .generic) -> String {
        let nsError = error as NSError
        AppErrorDiagnostics.shared.record(code: (error as? BridgeFailure)?.code ?? "\(nsError.domain):\(nsError.code)",
                                          details: error.localizedDescription)
        return loc(key(for: error, fallback: fallback).rawValue)
    }

    /// For structured failure states whose API supplies a code separately.
    /// A context-only status without a code uses an honest generic category.
    static func message(code: String, details: String? = nil, fallback: AppErrorMessageKey = .generic) -> String {
        if let details { AppErrorDiagnostics.shared.record(code: code, details: details) }
        return loc(key(forCode: code, fallback: fallback).rawValue)
    }

}

/// Bounded, memory-only technical details for explicit advanced diagnostics.
/// Deliberately not Codable, persisted, exported, or included in Copy issue
/// report. Paths/questions/device identifiers must not enter default reports.
final class AppErrorDiagnostics: @unchecked Sendable {
    struct Record: Sendable {
        let date: Date
        let code: String
        let details: String
    }
    static let shared = AppErrorDiagnostics()
    private let lock = NSLock()
    private var records: [Record] = []
    func record(code: String, details: String) {
        lock.withLock {
            let boundedCode = String(code.prefix(128)), boundedDetails = String(details.prefix(4096))
            if records.last?.code == boundedCode && records.last?.details == boundedDetails { return }
            records.append(Record(date: Date(), code: boundedCode, details: boundedDetails))
            if records.count > 16 { records.removeFirst(records.count - 16) }
        }
    }
    func recentForAdvancedDiagnostics() -> [Record] { lock.withLock { records } }
}
