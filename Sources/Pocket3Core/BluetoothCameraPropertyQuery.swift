import Foundation

/// Read-channel evidence for one named property. An ACK is only an
/// acknowledgment of the subscription, never proof that a setting changed.
/// Binding describes the BLE session supplied by the transport; it does not
/// associate that peer with a USB device or establish motor/tap-AF capability.
public struct BluetoothCameraPropertyQueryResult: Codable, Sendable {
    public var property: CameraSettingsProperty
    public var binding: ContinuousGimbalBinding
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
    /// Complete value when <=64 bytes; otherwise only the first 64 bytes.
    /// Truncated values are never passed to a typed settings decoder.
    public var valueHex: String?
    public var valueLength: Int?
    public var valueTruncated = false
    public var observed: CameraSettingsObservation?
    /// Typed only after a complete, valid `camcap_video_format` envelope is
    /// received. This is derived from `observed`, so it carries that
    /// observation's session binding and freshness timestamp.
    public var bodyRecordingCapabilities: CameraVideoFormatCapabilities? {
        observed?.bodyRecordingCapabilities
    }
    public var videoFormatCapabilities: CameraVideoFormatCapabilities? {
        bodyRecordingCapabilities
    }
    public var startedUptime: TimeInterval
    public var submittedUptime: TimeInterval?
    public var finishedUptime: TimeInterval?
    public var observationWindowCompleted = false
    public var timedOut = false
    public var ackTimedOut = false
    public var cancelled = false
    public var connectionChanged = false
    /// Bounded rejection evidence retained for the readback diagnostic. These
    /// counters never retain notification payload bytes.
    public var wrongEnvelopeCount: Int? = 0
    public var wrongPropertyCount: Int? = 0
    public var wrongSequenceCount: Int? = 0
    public var foreignSessionNotificationCount: Int? = 0
    public var lastRejectedHeader: BluetoothDUMLHeader?
    public var failure: String?
    public var evidence = "same_ble_session_post_subscription_named_property_not_setting_confirmation"

    init(property: CameraSettingsProperty, binding: ContinuousGimbalBinding,
         sequence: UInt16, transactionID: UInt32, startedUptime: TimeInterval) {
        self.property = property; self.binding = binding; querySequence = sequence
        subscriptionTransactionID = transactionID; self.startedUptime = startedUptime
    }
}

/// Pure one-submission state machine. It builds only the existing 00/99
/// subscription to address28. No transport, discovery, callback or SET exists
/// here. The receiving route is restricted to the observed 28→02 ACK/push.
struct BluetoothCameraPropertyQuery {
    static let observationDuration: TimeInterval = 2
    static let maximumValueBytes = 64
    private(set) var result: BluetoothCameraPropertyQueryResult
    private var lastAcceptedUptime: TimeInterval?

    var request: DUMLFrame {
        CameraPropertyCodec.subscription(result.property, transactionID: result.subscriptionTransactionID,
                                         sequence: result.querySequence)
    }

    init(property: CameraSettingsProperty, binding: ContinuousGimbalBinding,
         sequence: UInt16, transactionID: UInt32, startedUptime: TimeInterval) throws {
        guard CameraSettingsProperty.allCases.contains(property) else {
            throw BridgeFailure("bluetooth_property_query_unsupported", "The requested camera property is not in the read-only allowlist.")
        }
        guard !binding.sessionID.isEmpty else { throw CameraSettingsError.invalidSession }
        guard Self.validWindowStart(startedUptime) else { throw CameraSettingsError.invalidTime }
        result = BluetoothCameraPropertyQueryResult(property: property, binding: binding,
            sequence: sequence, transactionID: transactionID, startedUptime: startedUptime)
    }

    /// Called inside the transport's final permit immediately before its one
    /// local write. The observation deadline starts here, not at construction.
    mutating func submitted(at uptime: TimeInterval) throws {
        guard !result.localSubmitted, result.finishedUptime == nil,
              Self.validWindowStart(uptime), uptime >= result.startedUptime else {
            throw BridgeFailure("bluetooth_property_query_submission", "The property subscription may be submitted only once within its session.")
        }
        result.localSubmitted = true; result.submittedUptime = uptime
        lastAcceptedUptime = uptime
    }

    mutating func receive(_ data: Data, characteristic: String,
                          binding: ContinuousGimbalBinding, at uptime: TimeInterval) {
        guard result.finishedUptime == nil, result.localSubmitted,
              !result.cancelled, !result.connectionChanged else { return }
        guard binding == result.binding else {
            result.foreignSessionNotificationCount =
                (result.foreignSessionNotificationCount ?? 0) + 1
            return
        }
        guard let submitted = result.submittedUptime,
              uptime.isFinite, uptime >= submitted,
              uptime - submitted <= Self.observationDuration,
              lastAcceptedUptime == nil || uptime >= lastAcceptedUptime! else { return }
        guard characteristic == "FFF4" || characteristic == "FFF5",
              let frame = try? DUMLCodec.decode(data) else { return }
        let header = BluetoothDUMLHeader(direction: "received", characteristic: characteristic,
            source: frame.source, destination: frame.destination, sequence: frame.sequence,
            flags: frame.flags, commandSet: frame.commandSet, commandID: frame.commandID)

        guard frame.source == 0x28, frame.destination == 0x02,
              frame.commandSet == 0x00, frame.commandID == 0x99 else {
            // The paired channel carries unrelated telemetry. Count only a
            // packet that presents the named-property envelope but violates
            // its expected source/destination; unrelated frames are ignored.
            if frame.commandSet == 0x00, frame.commandID == 0x99 {
                result.wrongEnvelopeCount = (result.wrongEnvelopeCount ?? 0) + 1
                result.lastRejectedHeader = header
            }
            return
        }

        if !result.ackReceived, frame.sequence == result.querySequence,
           frame.flags == 0x80 || frame.flags == 0xc0 {
            result.ackReceived = true; result.ackHeader = header; result.ackUptime = uptime
            lastAcceptedUptime = uptime
        }

        if frame.flags == 0x80 || frame.flags == 0xc0 {
            if frame.sequence != result.querySequence {
                result.wrongSequenceCount = (result.wrongSequenceCount ?? 0) + 1
                result.lastRejectedHeader = header
            }
            return
        }

        // Named state is independently received. Its transaction and DUML
        // sequence are preserved, not required to echo the subscription.
        // Even an ACK containing a named-looking body is not a property push.
        guard !result.propertyReceived else { return }
        guard frame.flags == 0,
              let push = try? CameraPropertyCodec.decodePush(from: frame) else {
            result.wrongEnvelopeCount = (result.wrongEnvelopeCount ?? 0) + 1
            result.lastRejectedHeader = header
            return
        }
        guard push.property == result.property else {
            result.wrongPropertyCount = (result.wrongPropertyCount ?? 0) + 1
            result.lastRejectedHeader = header
            return
        }
        result.propertyReceived = true; result.propertyHeader = header; result.propertyUptime = uptime
        result.propertyTransactionID = push.transactionID; result.valueLength = push.value.count
        result.valueTruncated = push.value.count > Self.maximumValueBytes
        result.valueHex = push.value.prefix(Self.maximumValueBytes).map { String(format: "%02x", $0) }.joined()
        if !result.valueTruncated {
            result.observed = CameraSettingsObservation.decode(push, binding: binding, receivedUptime: uptime)
        }
        lastAcceptedUptime = uptime
    }

    mutating func finish(at uptime: TimeInterval, cancelled: Bool = false,
                         connectionChanged: Bool = false, failure: String? = nil) -> BluetoothCameraPropertyQueryResult {
        guard result.finishedUptime == nil else { return result }
        let validTime = uptime.isFinite && uptime >= (lastAcceptedUptime ?? result.startedUptime)
        // Keep failure output JSON-encodable even when a caller supplies NaN.
        result.finishedUptime = validTime ? uptime : lastAcceptedUptime ?? result.startedUptime
        result.cancelled = cancelled; result.connectionChanged = connectionChanged
        result.failure = failure ?? (validTime ? nil : "bluetooth_property_query_clock")
        result.observationWindowCompleted = validTime && !cancelled && !connectionChanged && result.failure == nil
            && result.submittedUptime.map { uptime - $0 >= Self.observationDuration } == true
        result.timedOut = result.observationWindowCompleted && !result.propertyReceived
        result.ackTimedOut = result.observationWindowCompleted && !result.ackReceived
        return result
    }

    private static func validWindowStart(_ uptime: TimeInterval) -> Bool {
        uptime.isFinite && uptime >= 0 && (uptime + observationDuration).isFinite && uptime + observationDuration > uptime
    }
}
