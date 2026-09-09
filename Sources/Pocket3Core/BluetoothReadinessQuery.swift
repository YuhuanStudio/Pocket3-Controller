import Foundation

/// An explicit developer query result. A correlated 04/50 reply proves only
/// routing/readiness response, never permission or support for motor movement.
public struct BluetoothReadinessResult: Codable, Sendable {
    public var querySequence: UInt16
    public var localSubmitted = false
    public var responseReceived = false
    public var timedOut = false
    public var cancelled = false
    public var connectionChanged = false
    public var replyHeader: BluetoothDUMLHeader?
    /// Only the one specifically correlated 04/50 reply, never general traffic.
    public var payloadHex: String?
    public var payloadByteCount: Int?
    public var startedUptime: TimeInterval
    public var submittedUptime: TimeInterval?
    public var responseUptime: TimeInterval?
    public var finishedUptime: TimeInterval?
    public var interpretation = "routing_readiness_reply_only"
    public var motorPermissionConfirmed = false
    init(sequence: UInt16, startedUptime: TimeInterval) {
        querySequence = sequence; self.startedUptime = startedUptime
    }
}

struct BluetoothReadinessQuery {
    static let responseTimeout: TimeInterval = 1
    private(set) var result: BluetoothReadinessResult
    var request: DUMLFrame {
        DUMLFrame(source: 2, destination: 4, sequence: result.querySequence, flags: 0x40,
            commandSet: 4, commandID: 0x50, payload: Data([1, 4, 5]))
    }
    init(sequence: UInt16, startedUptime: TimeInterval) {
        result = BluetoothReadinessResult(sequence: sequence, startedUptime: startedUptime)
    }
    mutating func submitted(at uptime: TimeInterval) {
        guard !result.localSubmitted, result.finishedUptime == nil, uptime.isFinite, uptime >= result.startedUptime else { return }
        result.localSubmitted = true; result.submittedUptime = uptime
    }
    @discardableResult
    mutating func receive(_ data: Data, characteristic: String, at uptime: TimeInterval) -> Bool {
        guard result.localSubmitted, result.finishedUptime == nil, !result.responseReceived, !result.cancelled, !result.connectionChanged,
              let submitted = result.submittedUptime, uptime.isFinite, uptime >= submitted,
              uptime - submitted <= Self.responseTimeout,
              characteristic == "FFF4" || characteristic == "FFF5",
              let frame = try? DUMLCodec.decode(data), frame.source == 4, frame.destination == 2,
              frame.commandSet == 4, frame.commandID == 0x50,
              frame.sequence == result.querySequence, frame.flags & 0x80 != 0 else { return false }
        result.responseReceived = true; result.responseUptime = uptime
        result.replyHeader = BluetoothDUMLHeader(direction: "received", characteristic: characteristic,
            source: frame.source, destination: frame.destination, sequence: frame.sequence,
            flags: frame.flags, commandSet: frame.commandSet, commandID: frame.commandID)
        result.payloadHex = frame.payload.map { String(format: "%02x", $0) }.joined()
        result.payloadByteCount = frame.payload.count
        return true
    }
    mutating func finish(at uptime: TimeInterval, cancelled: Bool, connectionChanged: Bool) -> BluetoothReadinessResult {
        result.finishedUptime = uptime; result.cancelled = cancelled; result.connectionChanged = connectionChanged
        result.timedOut = result.localSubmitted && !result.responseReceived && !cancelled && !connectionChanged
            && result.submittedUptime.map { uptime - $0 >= Self.responseTimeout } == true
        return result
    }
}
