import Foundation

/// Validated, unquantized screen-space input shared by continuous transports.
/// Right is +x and down is +y. Finite x/y values are preserved, including
/// values outside the unit circle; the transport applies its bounded motion
/// curve. Speed is a normalized 0...1 scale, not calibrated degrees/second.
public struct ContinuousGimbalInput: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let speed: Double

    public init(x: Double, y: Double, speed: Double) throws {
        // Preserve the existing scheduler's error type and validation order.
        guard x.isFinite, y.isFinite, speed.isFinite else { throw DUMLJoystickError.nonFiniteInput }
        guard (0...1).contains(speed) else { throw DUMLJoystickError.invalidSpeed }
        self.x = x; self.y = y; self.speed = speed
    }

    private init(neutral: Void) { x = 0; y = 0; speed = 0 }
    public static let neutral = Self(neutral: ())
    /// Exact zero input; transport-specific deadzones are applied separately.
    public var isNeutral: Bool { speed == 0 || (x == 0 && y == 0) }
}

/// The same binding, permit, serialization and bounded-completion contract as
/// ContinuousGimbalTransport, before any device-specific encoding. A neutral
/// input requests a hold while the gesture lease remains active. stop retires
/// that exact lease; neither operation means an absolute zero position.
public protocol ContinuousGimbalInputTransport: Sendable {
    func send(_ input: ContinuousGimbalInput, lease: ContinuousGimbalLease, permit: OperationPermit) async throws
    func stop(lease: ContinuousGimbalLease, permit: OperationPermit) async throws
}

public extension ContinuousGimbalInputTransport {
    /// Legacy velocity transports finish a lease with a neutral command. USB
    /// transports can override this to retire their trajectory and verify a
    /// fresh-position hold independently of ordinary zero-input updates.
    func stop(lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        try await send(.neutral, lease: lease, permit: permit)
    }
}

/// Keeps existing native DUML transports and callers source-compatible. Only
/// this adapter applies the DUML deadzone, curve and UInt16 quantization.
struct DUMLContinuousGimbalInputAdapter: ContinuousGimbalInputTransport {
    let transport: any ContinuousGimbalTransport
    func send(_ input: ContinuousGimbalInput, lease: ContinuousGimbalLease, permit: OperationPermit) async throws {
        let command = try DUMLJoystickCommand.encode(x: input.x, y: input.y, speed: input.speed)
        try await transport.send(command, lease: lease, permit: permit)
    }
}
