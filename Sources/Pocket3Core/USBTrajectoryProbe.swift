import Foundation

struct USBTrajectoryProbeSample: Codable, Sendable {
    let elapsed: TimeInterval
    let target: GimbalPosition
    let observed: GimbalPosition
    let writeSeconds: TimeInterval
    let reversed: Bool
}
struct USBTrajectoryProbeReport: Encodable, Sendable {
    let direction: String
    let origin: GimbalPosition
    let samples: [USBTrajectoryProbeSample]
    let failure: String?
    let stop: MotionResult?
    let verification: String = "usb_targets_and_get_cur_only_not_calibrated_physical_motion"
}
