import Foundation

/// Reused for one capture lifecycle; authorization is issued separately for
/// each gesture, so an idle endpoint does not own or block the camera.
public struct USBContinuousControlEndpoint: Sendable {
    public let scheduler: ContinuousGimbalScheduler
    public let binding: ContinuousGimbalBinding
    let transport: USBContinuousGimbalTransport
    let connectionPermit: OperationPermit
}
