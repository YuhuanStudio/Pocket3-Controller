import Foundation

/// Approaches one absolute preset using the same bounded position trajectory
/// as held manual input. Units and rates are UVC raw values, not calibrated
/// physical angles or native velocity commands. No hardware I/O.
struct USBTargetApproach: Sendable {
    enum Failure: Error, Equatable { case invalidTarget }
    let target: GimbalPosition
    private let capabilities: UVCCapabilities
    private let configuration = USBPositionTrajectory.Configuration()
    private var planner: USBPositionTrajectory?
    private var lastAdvance: TimeInterval

    init(target: GimbalPosition, capabilities: UVCCapabilities, now: TimeInterval) throws {
        let planner = try USBPositionTrajectory(capabilities: capabilities, now: now)
        guard let low = capabilities.minimum, let high = capabilities.maximum,
              target.pan >= low.pan, target.pan <= high.pan,
              target.tilt >= low.tilt, target.tilt <= high.tilt else { throw Failure.invalidTarget }
        self.target = target; self.capabilities = capabilities
        self.planner = planner; lastAdvance = now
    }

    mutating func advance(observed: GimbalPosition, observedAt: TimeInterval, now: TimeInterval) throws -> GimbalPosition {
        guard now.isFinite, observedAt.isFinite, now >= observedAt,
              let low = capabilities.minimum, let high = capabilities.maximum,
              observed.pan >= low.pan, observed.pan <= high.pan,
              observed.tilt >= low.tilt, observed.tilt <= high.tilt else {
            throw USBPositionTrajectory.Failure.invalidFeedback
        }
        guard now >= lastAdvance else { throw USBPositionTrajectory.Failure.delayedTick }
        guard now - observedAt <= configuration.maximumFeedbackAge else { throw USBPositionTrajectory.Failure.staleFeedback }
        let distance = observed.distance(to: target)
        if distance <= 720 {
            // A final short exact target also discards accumulated rate/lead.
            // If the device later drifts, start afresh at that fresh readback;
            // do not integrate the entire time spent at the preset.
            planner = nil; lastAdvance = now
            return target
        }
        if planner == nil {
            var current = capabilities; current.position = observed
            planner = try USBPositionTrajectory(capabilities: current, now: now)
        }
        let panError = Double(Int64(target.pan) - Int64(observed.pan))
        let tiltError = Double(Int64(target.tilt) - Int64(observed.tilt))
        let length = hypot(panError, tiltError)
        let speed = max(0.15, min(1, Double(distance) / configuration.maximumLead))
        let candidate = try planner!.advance(x: panError / length, y: -tiltError / length,
            speed: speed, now: now, observed: observed, observedAt: observedAt)
        lastAdvance = now
        // Clamp each axis between fresh feedback and the preset. This keeps
        // the planner's 7200-unit lead bound while preventing target crossing
        // or a stale internal target pulling an axis away from the preset.
        return GimbalPosition(
            pan: min(max(candidate.pan, min(observed.pan, target.pan)), max(observed.pan, target.pan)),
            tilt: min(max(candidate.tilt, min(observed.tilt, target.tilt)), max(observed.tilt, target.tilt)))
    }
}
