import Foundation

/// Bounded read-channel evidence, not AF write support or tap-to-focus proof.
public struct BluetoothLensStateQueryResult: Codable, Sendable {
    public var querySequence: UInt16
    public var subscriptionTransactionID: UInt32
    public var localSubmitted = false
    public var ackReceived = false
    public var ackHeader: BluetoothDUMLHeader?
    public var ackUptime: TimeInterval?
    public var propertyReceived = false
    public var propertyHeader: BluetoothDUMLHeader?
    public var propertyTransactionID: UInt32?
    public var propertyUptime: TimeInterval?
    public var modeCode: UInt8?
    public var mode: String?
    public var valueLength: Int?
    /// Only the first nine value bytes of cam_lens_state, never other records.
    public var valuePrefixHex: String?
    public var valueTruncated = false
    public var startedUptime: TimeInterval
    public var submittedUptime: TimeInterval?
    public var finishedUptime: TimeInterval?
    public var observationWindowCompleted = false
    public var timedOut = false
    public var ackTimedOut = false
    public var cancelled = false
    public var connectionChanged = false
    public var failure: String?
    public var evidence = "same_ble_session_post_submission_named_lens_state_not_request_id_echo"
    public var tapAFConfirmed = false

    init(sequence: UInt16, transactionID: UInt32, startedUptime: TimeInterval) {
        querySequence = sequence; subscriptionTransactionID = transactionID; self.startedUptime = startedUptime
    }
}

/// Fixed 02 -> 28 / 00/99 cam_lens_state subscription. Incoming property
/// sender mapping is not established: preserve it as evidence without using
/// it to guess an alternate request destination or claim a correlated SET.
struct BluetoothLensStateQuery {
    static let observationDuration: TimeInterval = 2
    private(set) var result: BluetoothLensStateQueryResult
    var request: DUMLFrame {
        CameraPropertyCodec.subscription(.lensState, transactionID: result.subscriptionTransactionID,
            sequence: result.querySequence)
    }
    init(sequence: UInt16, transactionID: UInt32, startedUptime: TimeInterval) {
        result = BluetoothLensStateQueryResult(sequence: sequence, transactionID: transactionID, startedUptime: startedUptime)
    }
    mutating func submitted(at uptime: TimeInterval) throws {
        guard !result.localSubmitted, result.finishedUptime == nil, uptime.isFinite,
              result.startedUptime.isFinite, uptime >= result.startedUptime else {
            throw BridgeFailure("bluetooth_lens_query_submission", "The lens-state subscription may be submitted only once.")
        }
        result.localSubmitted = true; result.submittedUptime = uptime
    }
    mutating func receive(_ data: Data, characteristic: String, at uptime: TimeInterval) {
        guard result.finishedUptime == nil, result.localSubmitted, !result.cancelled, !result.connectionChanged,
              let submitted = result.submittedUptime, uptime.isFinite, uptime >= submitted,
              uptime - submitted <= Self.observationDuration,
              characteristic == "FFF4" || characteristic == "FFF5",
              let frame = try? DUMLCodec.decode(data), frame.destination == 2,
              frame.commandSet == 0, frame.commandID == 0x99 else { return }
        func header() -> BluetoothDUMLHeader {
            BluetoothDUMLHeader(direction: "received", characteristic: characteristic,
                source: frame.source, destination: frame.destination, sequence: frame.sequence,
                flags: frame.flags, commandSet: frame.commandSet, commandID: frame.commandID)
        }
        if !result.ackReceived, frame.source == 0x28, frame.sequence == result.querySequence,
           frame.flags == 0x80 || frame.flags == 0xc0 {
            result.ackReceived = true; result.ackHeader = header(); result.ackUptime = uptime
        }
        // First valid named observation only. Its transaction/DUML sequence
        // need not echo this subscription, and no setter was sent here.
        guard !result.propertyReceived, let push = try? CameraPropertyCodec.decodePush(from: frame),
              push.property == .lensState else { return }
        result.propertyReceived = true; result.propertyHeader = header(); result.propertyUptime = uptime
        result.propertyTransactionID = push.transactionID; result.valueLength = push.value.count
        result.valuePrefixHex = push.value.prefix(9).map { String(format: "%02x", $0) }.joined()
        result.valueTruncated = push.value.count > 9; result.modeCode = push.value.first
        switch push.value.first {
        case 0xb1: result.mode = "single"
        case 0xb2: result.mode = "continuous"
        default: result.mode = nil
        }
    }
    mutating func finish(at uptime: TimeInterval, cancelled: Bool, connectionChanged: Bool, failure: String?) -> BluetoothLensStateQueryResult {
        guard result.finishedUptime == nil else { return result }
        result.finishedUptime = uptime; result.cancelled = cancelled; result.connectionChanged = connectionChanged
        result.failure = failure
        result.observationWindowCompleted = uptime.isFinite && !cancelled && !connectionChanged && failure == nil
            && result.submittedUptime.map { uptime - $0 >= Self.observationDuration } == true
        result.timedOut = result.observationWindowCompleted && !result.propertyReceived
        result.ackTimedOut = result.observationWindowCompleted && !result.ackReceived
        return result
    }
}
