import Foundation

/// Generates absolute UVC targets from a held stick. Rates are in UVC raw
/// units/second, not calibrated physical degrees/second. No hardware I/O.
/// Feedback must come from GET_CUR, never from the last submitted target.
struct USBPositionTrajectory: Sendable {
    struct Configuration: Sendable {
        var maximumRate: Double = 36_000
        var acceleration: Double = 72_000
        var maximumLead: Double = 7_200
        var maximumFeedbackAge: TimeInterval = 0.25
        var maximumTickGap: TimeInterval = 0.15
    }
    enum Failure: Error, Equatable { case invalidConfiguration, invalidCapabilities, invalidFeedback, staleFeedback, delayedTick }

    private let configuration: Configuration
    private let minimum: GimbalPosition
    private let maximum: GimbalPosition
    private var pan: Double
    private var tilt: Double
    private var panRate: Double = 0
    private var tiltRate: Double = 0
    private var previousPanDirection: Double = 0
    private var previousTiltDirection: Double = 0
    private var lastTick: TimeInterval

    init(capabilities: UVCCapabilities, now: TimeInterval, configuration: Configuration = .init()) throws {
        guard now.isFinite,
              [configuration.maximumRate, configuration.acceleration, configuration.maximumLead,
               configuration.maximumFeedbackAge, configuration.maximumTickGap].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw Failure.invalidConfiguration
        }
        guard capabilities.writable, let minimum = capabilities.minimum, let maximum = capabilities.maximum,
              minimum.pan <= maximum.pan, minimum.tilt <= maximum.tilt,
              Self.contains(capabilities.position, minimum: minimum, maximum: maximum) else { throw Failure.invalidCapabilities }
        self.configuration = configuration; self.minimum = minimum; self.maximum = maximum
        pan = Double(capabilities.position.pan); tilt = Double(capabilities.position.tilt); lastTick = now
    }

    mutating func advance(x: Double, y: Double, speed: Double, now: TimeInterval,
                          observed: GimbalPosition, observedAt: TimeInterval) throws -> GimbalPosition {
        guard x.isFinite, y.isFinite, speed.isFinite else { throw DUMLJoystickError.nonFiniteInput }
        guard (0...1).contains(speed) else { throw DUMLJoystickError.invalidSpeed }
        guard now.isFinite, observedAt.isFinite, now >= observedAt,
              Self.contains(observed, minimum: minimum, maximum: maximum) else { throw Failure.invalidFeedback }
        guard now - observedAt <= configuration.maximumFeedbackAge else { throw Failure.staleFeedback }
        let elapsed = now - lastTick
        guard elapsed >= 0, elapsed <= configuration.maximumTickGap else { throw Failure.delayedTick }
        lastTick = now

        // Scale before hypot so even finite extreme drag coordinates cannot
        // overflow. Preserve the direction and apply a radial dead zone.
        let scale = max(1, abs(x), abs(y))
        var horizontal = x / scale, vertical = y / scale
        let length = hypot(horizontal, vertical)
        if length > 1 { horizontal /= length; vertical /= length }
        let magnitude = min(1, hypot(horizontal, vertical))
        if magnitude <= 0.06 || speed == 0 {
            panRate = 0; tiltRate = 0
            previousPanDirection = 0; previousTiltDirection = 0
            pan = Double(observed.pan); tilt = Double(observed.tilt)
            return observed // Hold fresh readback; zero never means centre.
        }
        let rate = (magnitude - 0.06) / 0.94 * speed * configuration.maximumRate
        let wantedPanRate = horizontal / magnitude * rate
        let wantedTiltRate = -vertical / magnitude * rate // Screen up -> positive UVC tilt.
        // A direction reversal withdraws the old lead immediately. Ramp up
        // the new direction from fresh feedback instead of completing the
        // old trajectory first; this does not assert instant mechanical stop.
        if (wantedPanRate > 0 && previousPanDirection < 0) || (wantedPanRate < 0 && previousPanDirection > 0) {
            pan = Double(observed.pan); panRate = 0
        }
        if (wantedTiltRate > 0 && previousTiltDirection < 0) || (wantedTiltRate < 0 && previousTiltDirection > 0) {
            tilt = Double(observed.tilt); tiltRate = 0
        }
        previousPanDirection = wantedPanRate; previousTiltDirection = wantedTiltRate
        // Follow fresh feedback if the device is already ahead of the plan.
        // An inactive axis must keep its observed position, not drag the
        // camera back to a stale origin after a physical/external adjustment.
        if wantedPanRate == 0 { pan = Double(observed.pan); panRate = 0 }
        else if (wantedPanRate > 0 && Double(observed.pan) > pan) || (wantedPanRate < 0 && Double(observed.pan) < pan) {
            pan = Double(observed.pan)
        }
        if wantedTiltRate == 0 { tilt = Double(observed.tilt); tiltRate = 0 }
        else if (wantedTiltRate > 0 && Double(observed.tilt) > tilt) || (wantedTiltRate < 0 && Double(observed.tilt) < tilt) {
            tilt = Double(observed.tilt)
        }
        let deltaPan = wantedPanRate - panRate, deltaTilt = wantedTiltRate - tiltRate
        let deltaLength = hypot(deltaPan, deltaTilt)
        let change = min(1, configuration.acceleration * elapsed / max(deltaLength, 1e-12))
        panRate += deltaPan * change; tiltRate += deltaTilt * change

        // Discard unexecuted distance at both the device bounds and the lead
        // bounds. A slow/stalled device must not accumulate a distant target.
        let nextPan = pan + panRate * elapsed, nextTilt = tilt + tiltRate * elapsed
        pan = min(Double(maximum.pan), max(Double(minimum.pan),
            min(Double(observed.pan) + configuration.maximumLead, max(Double(observed.pan) - configuration.maximumLead, nextPan))))
        tilt = min(Double(maximum.tilt), max(Double(minimum.tilt),
            min(Double(observed.tilt) + configuration.maximumLead, max(Double(observed.tilt) - configuration.maximumLead, nextTilt))))
        if pan != nextPan { panRate = 0 }
        if tilt != nextTilt { tiltRate = 0 }
        return GimbalPosition(pan: Int32(pan.rounded()), tilt: Int32(tilt.rounded()))
    }

    private static func contains(_ value: GimbalPosition, minimum: GimbalPosition, maximum: GimbalPosition) -> Bool {
        value.pan >= minimum.pan && value.pan <= maximum.pan && value.tilt >= minimum.tilt && value.tilt <= maximum.tilt
    }
}
