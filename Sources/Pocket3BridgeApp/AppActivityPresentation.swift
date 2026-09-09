import Foundation
import Pocket3Core
import YunDesign

enum AppActivityMessageKey: String, CaseIterable {
    case connected = "Camera connected."
    case connectionFailed = "Could not connect the camera."
    case paused = "Camera observation paused."
    case suspended = "Camera paused for sleep."
    case disconnected = "Camera disconnected."
    case captured = "Fresh image captured."
    case controlStarted = "Camera control started."
    case controlCompleted = "Camera position readback confirmed."
    case controlFailed = "Camera control was not confirmed."
    case stopped = "Camera control ended; position readback confirmed."
    case stopFailed = "Camera stop was not confirmed."
    case zoomCompleted = "Zoom readback confirmed."
    case zoomFailed = "Zoom adjustment was not confirmed."
    case rollCompleted = "Roll readback confirmed."
    case rollFailed = "Roll adjustment was not confirmed."
    case audioCompleted = "Camera audio check completed."
    case manualAccess = "Manual camera control selected."
    case observationAccess = "AI observation access selected."
    case controlAccess = "AI camera control access selected."
    case recorded = "Camera activity recorded."
    case failed = "Camera operation failed. Check diagnostics."
}

enum AppActivityPresentation {
    static func key(for activity: Activity) -> AppActivityMessageKey {
        switch activity.presentationKey {
        case "camera.connected": .connected
        case "camera.connection_failed": .connectionFailed
        case "camera.paused": .paused
        case "camera.suspended": .suspended
        case "camera.disconnected": .disconnected
        case "capture.completed": .captured
        case "control.started": .controlStarted
        case "control.completed": .controlCompleted
        case "control.failed": .controlFailed
        case "control.stopped": .stopped
        case "control.stop_failed": .stopFailed
        case "zoom.completed": .zoomCompleted
        case "zoom.failed": .zoomFailed
        case "roll.completed": .rollCompleted
        case "roll.failed": .rollFailed
        case "audio.completed": .audioCompleted
        case "access.manual": .manualAccess
        case "access.observe": .observationAccess
        case "access.control": .controlAccess
        default: activity.isError ? .failed : .recorded
        }
    }
    static func message(_ activity: Activity) -> String {
        AppErrorDiagnostics.shared.record(code: "activity:\(activity.presentationKey ?? activity.operation)", details: activity.message)
        return loc(key(for: activity).rawValue)
    }
}
