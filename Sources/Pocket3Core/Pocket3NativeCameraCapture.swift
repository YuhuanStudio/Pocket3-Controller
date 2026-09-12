import Foundation

/// A known Pocket 3 camera mode. Unknown `02/80` values stay in
/// `Pocket3NativeCameraReadback.modeRaw` and never become a writer target.
public typealias Pocket3NativeCameraMode = Pocket3ShootingMode

public struct Pocket3TimelapseConfiguration: Codable, Sendable, Equatable {
    public static let minimumIntervalTenths: UInt16 = 5
    public static let maximumIntervalTenths: UInt16 = 600
    public static let maximumDurationSeconds: UInt32 = 18_000

    public let intervalTenths: UInt16
    public let durationSeconds: UInt32
    public let output: CameraTimelapseOutput

    public init(intervalTenths: UInt16, durationSeconds: UInt32,
                output: CameraTimelapseOutput) throws {
        guard (Self.minimumIntervalTenths...Self.maximumIntervalTenths).contains(intervalTenths),
              durationSeconds <= Self.maximumDurationSeconds else {
            throw Pocket3NativeCameraProtocolError.invalidLapseConfiguration
        }
        self.intervalTenths = intervalTenths
        self.durationSeconds = durationSeconds
        self.output = output
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(intervalTenths: values.decode(UInt16.self, forKey: .intervalTenths),
                      durationSeconds: values.decode(UInt32.self, forKey: .durationSeconds),
                      output: values.decode(CameraTimelapseOutput.self, forKey: .output))
    }

    private enum CodingKeys: String, CodingKey {
        case intervalTenths, durationSeconds, output
    }
}

/// One bounded Custom Motionlapse point. The command wire order is
/// yaw/roll/pitch even though the gimbal telemetry readback is pitch/roll/yaw.
public struct Pocket3MotionlapseConfiguration: Codable, Sendable, Equatable {
    public static let minimumIntervalTenths: UInt16 = 5
    public static let maximumIntervalTenths: UInt16 = 600
    public static let maximumDurationSeconds: UInt32 = 18_000

    public let slot: UInt8
    public let intervalTenths: UInt16
    public let durationSeconds: UInt32
    public let pitchTenths: Int16
    public let rollTenths: Int16
    public let yawTenths: Int16

    public init(slot: UInt8, intervalTenths: UInt16, durationSeconds: UInt32,
                pitchTenths: Int16, rollTenths: Int16, yawTenths: Int16) throws {
        guard (1...4).contains(slot),
              (Self.minimumIntervalTenths...Self.maximumIntervalTenths).contains(intervalTenths),
              durationSeconds <= Self.maximumDurationSeconds else {
            throw Pocket3NativeCameraProtocolError.invalidLapseConfiguration
        }
        self.slot = slot
        self.intervalTenths = intervalTenths
        self.durationSeconds = durationSeconds
        self.pitchTenths = pitchTenths
        self.rollTenths = rollTenths
        self.yawTenths = yawTenths
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(slot: values.decode(UInt8.self, forKey: .slot),
                      intervalTenths: values.decode(UInt16.self, forKey: .intervalTenths),
                      durationSeconds: values.decode(UInt32.self, forKey: .durationSeconds),
                      pitchTenths: values.decode(Int16.self, forKey: .pitchTenths),
                      rollTenths: values.decode(Int16.self, forKey: .rollTenths),
                      yawTenths: values.decode(Int16.self, forKey: .yawTenths))
    }

    private enum CodingKeys: String, CodingKey {
        case slot, intervalTenths, durationSeconds, pitchTenths, rollTenths, yawTenths
    }
}

/// Camera-domain intents covered by the capture settings protocol. Start and
/// stop use the capture-confirmed 02/02 body lifecycle command; their
/// completion still requires a matching 02/80 status sample in the requested
/// mode. No operation contains an arbitrary command ID or raw mode selector.
public enum Pocket3NativeCameraCaptureOperation: Codable, Sendable, Equatable {
    case setMode(Pocket3ShootingMode)
    case photoFrame(CameraPhotoFrame)
    case photoFormat(CameraPhotoFormat)
    case photoCountdown(CameraPhotoCountdown)
    case photoShutter
    case panoramaType(CameraPanoramaType)
    case panoramaFormat(CameraPanoramaPhotoFormat)
    case panoramaShutter
    case timelapseConfiguration(Pocket3TimelapseConfiguration)
    case hyperlapseSpeed(CameraHyperlapseSpeed)
    case motionlapseConfiguration(Pocket3MotionlapseConfiguration)
    case motionlapseDirection(CameraMotionlapseDirection)
    case startTimelapse
    case stopTimelapse
    case startHyperlapse
    case stopHyperlapse
    case startMotionlapse
    case stopMotionlapse
}

public enum Pocket3NativeCameraProtocolError: Error, Codable, Sendable, Equatable {
    case invalidLapseConfiguration
    case unsupportedModeWrite
    case invalidModeCombination
    case invalidBaseline
    case sessionNotReady
    case missingSessionIdentity
    case alreadyAtTarget
    case operationInFlight
    case staleTransaction
    case invalidClock
}

public struct Pocket3NativeCameraReadback: Codable, Sendable, Equatable {
    public static let maximumAge: TimeInterval = 5
    public static let maximumRawBytes = 128

    public let sessionID: UUID
    public let generation: UInt64
    public let receivedUptime: TimeInterval
    public let modeRaw: UInt8?
    public let recordingStatus: Pocket3BodyRecordingStatus?
    public let photo: CameraPhotoParameters?
    public let lapse: CameraLapseParameters?
    public let motionlapse: CameraMotionlapseParameters?
    public let panorama: CameraPanoramaParameters?

    public init(sessionID: UUID, generation: UInt64, receivedUptime: TimeInterval,
                modeRaw: UInt8? = nil,
                recordingStatus: Pocket3BodyRecordingStatus? = nil,
                photo: CameraPhotoParameters? = nil,
                lapse: CameraLapseParameters? = nil,
                motionlapse: CameraMotionlapseParameters? = nil,
                panorama: CameraPanoramaParameters? = nil) {
        self.sessionID = sessionID
        self.generation = generation
        self.receivedUptime = receivedUptime
        self.modeRaw = modeRaw
        self.recordingStatus = recordingStatus
        self.photo = photo
        self.lapse = lapse
        self.motionlapse = motionlapse
        self.panorama = panorama
    }

    public var mode: Pocket3ShootingMode? {
        modeRaw.flatMap(Pocket3ShootingMode.init(rawValue:))
    }

    public var rawByteCount: Int {
        var count = modeRaw == nil ? 0 : 1
        if recordingStatus != nil { count += 1 }
        count += photo?.raw.count ?? 0
        count += lapse?.raw.count ?? 0
        count += motionlapse?.raw.count ?? 0
        count += panorama?.raw.count ?? 0
        return count
    }

    public func isFresh(nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        generation != 0 && receivedUptime.isFinite && receivedUptime >= 0 &&
            nowUptime.isFinite && maximumAge.isFinite && maximumAge >= 0 &&
            nowUptime >= receivedUptime && nowUptime - receivedUptime <= maximumAge &&
            rawByteCount <= Self.maximumRawBytes
    }

    public func isFresh(session: NativeCameraSessionStatus,
                        nowUptime: TimeInterval,
                        maximumAge: TimeInterval = Self.maximumAge) -> Bool {
        sessionID == session.sessionID && generation == session.generation &&
            session.state.satisfies(.commandReady) &&
            isFresh(nowUptime: nowUptime, maximumAge: maximumAge)
    }
}

public struct Pocket3NativeCameraCommand: Codable, Sendable, Equatable {
    public let operation: Pocket3NativeCameraCaptureOperation
    public let commandSet: UInt8
    public let commandID: UInt8
    public let payload: Data

    public init(_ operation: Pocket3NativeCameraCaptureOperation) {
        self.operation = operation
        switch operation {
        case .setMode: commandSet = 0x02; commandID = 0xE1
        case .photoFrame: commandSet = 0x02; commandID = 0x12
        case .photoFormat: commandSet = 0x02; commandID = 0x16
        case .photoCountdown: commandSet = 0x02; commandID = 0x4A
        case .photoShutter, .panoramaShutter: commandSet = 0x02; commandID = 0x01
        case .panoramaType: commandSet = 0x02; commandID = 0x6E
        case .panoramaFormat: commandSet = 0x02; commandID = 0xE7
        case .timelapseConfiguration, .hyperlapseSpeed, .motionlapseConfiguration:
            commandSet = 0x02; commandID = 0x6C
        case .motionlapseDirection: commandSet = 0x02; commandID = 0x8E
        case .startTimelapse, .stopTimelapse, .startHyperlapse, .stopHyperlapse,
             .startMotionlapse, .stopMotionlapse:
            commandSet = 0x02; commandID = 0x02
        }
        payload = Self.payload(for: operation)
    }

    public func frame(sequence: UInt16) -> DUMLFrame {
        DUMLFrame(source: 0x02, destination: 0x01, sequence: sequence,
                  flags: 0x40, commandSet: commandSet, commandID: commandID,
                  payload: payload)
    }

    public func encodedFrame(sequence: UInt16) throws -> Data {
        try DUMLCodec.encode(frame(sequence: sequence))
    }

    private static func payload(for operation: Pocket3NativeCameraCaptureOperation) -> Data {
        switch operation {
        case .setMode(let mode): return Data([mode.rawValue])
        case .photoFrame(let frame): return Data([0x00, frame.rawValue])
        case .photoFormat(let format): return Data([format.rawValue])
        case .photoCountdown(let countdown):
            return Data([0x00, 0x01, countdown.rawValue, 0x00, 0x00, 0x00])
        case .photoShutter: return Data([0x01])
        case .panoramaType(let type): return Data([type.rawValue])
        case .panoramaFormat(let format): return Data([format.rawValue, 0x00])
        case .panoramaShutter: return Data([0x07])
        case .timelapseConfiguration(let configuration):
            var value = Data([0x04, 0x00, configuration.output.rawValue])
            appendLE16(configuration.intervalTenths, to: &value)
            appendLE32(configuration.durationSeconds, to: &value)
            value.append(contentsOf: repeatBytes(0, count: 7))
            return value
        case .hyperlapseSpeed(let speed):
            var value = Data([0x0B, 0x00, 0x00, UInt8(truncatingIfNeeded: speed.rawValue)])
            value.append(contentsOf: repeatBytes(0, count: 12))
            return value
        case .motionlapseConfiguration(let configuration):
            var value = Data([0x05])
            let token = UInt16(0x0005) + UInt16(configuration.slot - 1) * 4
            appendLE16(token, to: &value)
            appendLE16(configuration.intervalTenths, to: &value)
            appendLE32(configuration.durationSeconds, to: &value)
            appendLE16(UInt16(bitPattern: configuration.yawTenths), to: &value)
            appendLE16(UInt16(bitPattern: configuration.rollTenths), to: &value)
            appendLE16(UInt16(bitPattern: configuration.pitchTenths), to: &value)
            value.append(0)
            return value
        case .motionlapseDirection(let direction):
            return Data([0x01, 0x01, 0x37, 0x00, 0x01, direction.rawValue])
        case .startTimelapse, .startHyperlapse, .startMotionlapse: return Data([0x01])
        case .stopTimelapse, .stopHyperlapse, .stopMotionlapse: return Data([0x00])
        }
    }

    private static func repeatBytes(_ value: UInt8, count: Int) -> [UInt8] {
        Array(repeating: value, count: count)
    }

    private static func appendLE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8))
    }

    private static func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff)); data.append(UInt8(value >> 24))
    }
}

public typealias Pocket3NativeCaptureOperation = Pocket3NativeCameraCaptureOperation
public typealias Pocket3NativeCaptureCommand = Pocket3NativeCameraCommand
public typealias Pocket3NativeCaptureReadback = Pocket3NativeCameraReadback

public enum Pocket3NativeCameraCaptureCoordinatorPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case noOp
    case awaitingAcknowledgment
    case awaitingReadback
    case completed
    case timedOut
    case cancelled
    case generationChanged
    case failed
}

public struct Pocket3NativeCameraCaptureResult: Codable, Sendable, Equatable {
    public let operation: Pocket3NativeCameraCaptureOperation
    public let sessionID: UUID
    public let generation: UInt64
    public let phase: Pocket3NativeCameraCaptureCoordinatorPhase
    public let baseline: Pocket3NativeCameraReadback
    public let transaction: NativeCommandTransactionResult?
    public let readback: Pocket3NativeCameraReadback?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let completed: Bool
    public let noOp: Bool
    public let failureCode: String?
}

/// One bounded camera-domain operation. The coordinator owns no transport;
/// callers submit its request once through the existing transaction owner.
public struct Pocket3NativeCameraCaptureCoordinator: Sendable {
    public static let maximumReadbackAge: TimeInterval = 5
    public static let defaultTransactionTimeout: TimeInterval = 3

    public let sessionID: UUID
    public let generation: UInt64
    public private(set) var phase: Pocket3NativeCameraCaptureCoordinatorPhase = .idle
    public private(set) var operation: Pocket3NativeCameraCaptureOperation?
    public private(set) var request: NativeCommandTransactionRequest?
    public private(set) var transaction: NativeCommandTransactionResult?
    public private(set) var readback: Pocket3NativeCameraReadback?
    public private(set) var failureCode: String?

    private var baseline: Pocket3NativeCameraReadback?
    private var readbackBeforeTransaction: Pocket3NativeCameraReadback?
    private var expectedMotionlapseWaypointCount: UInt8?

    public init(session: NativeCameraSessionStatus) throws {
        guard session.generation != 0, session.state.satisfies(.commandReady) else {
            throw Pocket3NativeCameraProtocolError.sessionNotReady
        }
        guard let sessionID = session.sessionID else {
            throw Pocket3NativeCameraProtocolError.missingSessionIdentity
        }
        self.sessionID = sessionID
        generation = session.generation
    }

    /// Validates the exact fresh mode/property baseline and builds one
    /// command request. No frame is sent here.
    public mutating func prepare(
        _ operation: Pocket3NativeCameraCaptureOperation,
        baseline: Pocket3NativeCameraReadback,
        nowUptime: TimeInterval,
        timeout: TimeInterval = defaultTransactionTimeout
    ) throws -> NativeCommandTransactionRequest {
        guard phase == .idle else { throw Pocket3NativeCameraProtocolError.operationInFlight }
        guard baseline.sessionID == sessionID,
              baseline.generation == generation,
              baseline.isFresh(nowUptime: nowUptime,
                               maximumAge: Self.maximumReadbackAge) else {
            throw Pocket3NativeCameraProtocolError.invalidBaseline
        }
        try validate(operation, baseline: baseline)
        if isNoOp(operation, baseline: baseline) {
            self.operation = operation
            self.baseline = baseline
            phase = .noOp
            throw Pocket3NativeCameraProtocolError.alreadyAtTarget
        }

        let command = Pocket3NativeCameraCommand(operation)
        let frame = try NativeCommandFrame(source: 0x02, destination: 0x01,
                                           flags: 0x40,
                                           commandSet: command.commandSet,
                                           commandID: command.commandID,
                                           payload: command.payload)
        let sessionID = self.sessionID
        let generation = self.generation
        let expectedWaypointCount = expectedMotionlapseWaypointCount
        let request = try NativeCommandTransactionRequest(command: .cameraCapture,
            generation: generation, sessionID: sessionID, frame: frame,
            timeout: timeout) { response in
                Self.observationPayload(from: response, operation: operation,
                                        expectedMotionlapseWaypointCount: expectedWaypointCount)
            }
        self.operation = operation
        self.baseline = baseline
        self.request = request
        transaction = nil
        readback = nil
        readbackBeforeTransaction = nil
        failureCode = nil
        phase = .awaitingAcknowledgment
        return request
    }

    @discardableResult
    public mutating func apply(_ transaction: NativeCommandTransactionResult,
                               nowUptime: TimeInterval? = nil) -> Bool {
        guard let request, request.id == transaction.id,
              transaction.generation == generation,
              transaction.sessionID == sessionID else {
            failureCode = "native_camera_capture_stale_transaction"
            phase = .generationChanged
            return false
        }
        guard phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            if self.transaction == nil { self.transaction = transaction }
            return false
        }
        self.transaction = transaction
        if let nowUptime, !nowUptime.isFinite {
            failureCode = "native_camera_capture_invalid_clock"
            phase = .failed
            return false
        }
        if let observed = decodeObserved(transaction.observedPayload,
                                         at: transaction.observedUptime) {
            readback = observed
        }
        switch transaction.end {
        case .cancelled:
            failureCode = transaction.failureCode ?? "cancelled"
            phase = .cancelled
            return false
        case .generationChanged:
            failureCode = transaction.failureCode ?? "native_connection_changed"
            phase = .generationChanged
            return false
        case .timedOut:
            failureCode = transaction.failureCode ?? "native_camera_capture_timeout"
            phase = .timedOut
            return false
        case .rejected, .failed:
            failureCode = transaction.failureCode ?? "native_camera_capture_failed"
            phase = .failed
            return false
        case .acknowledged, .observed:
            guard transaction.acknowledged else {
                failureCode = transaction.failureCode ?? "native_camera_capture_ack_invalid"
                phase = .failed
                return false
            }
        }
        phase = .awaitingReadback
        if let observed = readback {
            _ = observe(observed, nowUptime: nowUptime ?? observed.receivedUptime)
        } else if let observed = readbackBeforeTransaction {
            _ = observe(observed, nowUptime: nowUptime ?? observed.receivedUptime)
        }
        return phase == .completed
    }

    /// Accepts one same-session named-property/status readback. Unknown raw
    /// selectors are retained as partial evidence but cannot complete a
    /// known target operation.
    @discardableResult
    public mutating func observe(_ value: Pocket3NativeCameraReadback,
                                 nowUptime: TimeInterval) -> Bool {
        guard let operation, let baseline,
              value.sessionID == sessionID,
              value.generation == generation,
              value.isFresh(nowUptime: nowUptime,
                            maximumAge: Self.maximumReadbackAge),
              value.receivedUptime > baseline.receivedUptime,
              isRelevant(value, for: operation),
              phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        if let submitted = transaction?.submittedUptime,
           value.receivedUptime <= submitted {
            return false
        }
        readback = value
        guard matches(value, operation: operation) else {
            if transaction == nil { readbackBeforeTransaction = value }
            return false
        }
        guard let transaction else {
            readbackBeforeTransaction = value
            return false
        }
        guard transaction.acknowledged else { return false }
        phase = .completed
        failureCode = nil
        return true
    }

    @discardableResult
    public mutating func cancel(generation callbackGeneration: UInt64) -> Bool {
        guard callbackGeneration == generation,
              phase == .awaitingAcknowledgment || phase == .awaitingReadback else {
            return false
        }
        phase = .cancelled
        failureCode = "cancelled"
        return true
    }

    public var result: Pocket3NativeCameraCaptureResult? {
        guard let operation, let baseline else { return nil }
        return Pocket3NativeCameraCaptureResult(operation: operation,
            sessionID: sessionID, generation: generation, phase: phase,
            baseline: baseline, transaction: transaction, readback: readback,
            requested: true, submitted: transaction?.submitted == true,
            acknowledged: transaction?.acknowledged == true,
            observed: readback != nil, completed: phase == .completed,
            noOp: phase == .noOp, failureCode: failureCode)
    }

    private mutating func validate(_ operation: Pocket3NativeCameraCaptureOperation,
                          baseline: Pocket3NativeCameraReadback) throws {
        switch operation {
        case .setMode(let mode):
            guard mode == .timelapse || mode == .motionlapse else {
                throw Pocket3NativeCameraProtocolError.unsupportedModeWrite
            }
            guard baseline.mode != nil else {
                throw Pocket3NativeCameraProtocolError.invalidModeCombination
            }
        case .photoFrame, .photoFormat, .photoCountdown, .photoShutter:
            guard baseline.mode == .photo, baseline.photo != nil else {
                throw Pocket3NativeCameraProtocolError.invalidModeCombination
            }
        case .panoramaType, .panoramaFormat, .panoramaShutter:
            guard baseline.mode == .panorama, baseline.panorama != nil else {
                throw Pocket3NativeCameraProtocolError.invalidModeCombination
            }
        case .timelapseConfiguration:
            guard baseline.mode == .timelapse, baseline.lapse != nil else {
                throw Pocket3NativeCameraProtocolError.invalidModeCombination
            }
        case .hyperlapseSpeed:
            guard baseline.mode == .hyperlapse, baseline.lapse != nil else {
                throw Pocket3NativeCameraProtocolError.invalidModeCombination
            }
        case .motionlapseConfiguration:
            guard baseline.mode == .motionlapse,
                  let count = baseline.motionlapse?.waypointCount,
                  count < 4 else {
                throw Pocket3NativeCameraProtocolError.invalidModeCombination
            }
            expectedMotionlapseWaypointCount = count + 1
        case .motionlapseDirection:
            guard baseline.mode == .motionlapse, baseline.motionlapse != nil else {
                throw Pocket3NativeCameraProtocolError.invalidModeCombination
            }
        case .startTimelapse, .stopTimelapse:
            try validateLifecycle(.timelapse, baseline: baseline)
        case .startHyperlapse, .stopHyperlapse:
            try validateLifecycle(.hyperlapse, baseline: baseline)
        case .startMotionlapse, .stopMotionlapse:
            try validateLifecycle(.motionlapse, baseline: baseline)
        }
    }

    private func validateLifecycle(_ mode: Pocket3ShootingMode,
                                   baseline: Pocket3NativeCameraReadback) throws {
        guard baseline.mode == mode,
              baseline.recordingStatus?.isKnown == true,
              baseline.recordingStatus?.transitioning == false else {
            throw Pocket3NativeCameraProtocolError.invalidModeCombination
        }
    }

    private func isNoOp(_ operation: Pocket3NativeCameraCaptureOperation,
                        baseline: Pocket3NativeCameraReadback) -> Bool {
        switch operation {
        case .setMode(let mode): return baseline.mode == mode
        case .photoFrame(let frame): return baseline.photo?.frame == frame
        case .photoFormat(let format): return baseline.photo?.format == format
        case .photoCountdown(let countdown): return baseline.photo?.countdown == countdown
        case .photoShutter, .panoramaShutter: return false
        case .panoramaType(let type): return baseline.panorama?.panoramaType == type
        case .panoramaFormat(let format): return baseline.panorama?.photoFormat == format
        case .timelapseConfiguration(let value):
            guard let current = baseline.lapse else { return false }
            return current.output == value.output &&
                current.intervalTenths == value.intervalTenths &&
                current.durationSeconds == value.durationSeconds
        case .hyperlapseSpeed(let speed):
            guard let current = baseline.lapse else { return false }
            return current.hyperlapseSpeed == speed &&
                current.mirroredHyperlapseSpeedRaw == speed.rawValue
        case .motionlapseConfiguration: return false
        case .motionlapseDirection(let direction):
            return baseline.motionlapse?.direction == direction
        case .startTimelapse, .startHyperlapse, .startMotionlapse:
            return baseline.recordingStatus?.recording == true
        case .stopTimelapse, .stopHyperlapse, .stopMotionlapse:
            return baseline.recordingStatus?.recording == false
        }
    }

    private func isRelevant(_ value: Pocket3NativeCameraReadback,
                            for operation: Pocket3NativeCameraCaptureOperation) -> Bool {
        switch operation {
        case .setMode, .photoShutter, .panoramaShutter,
             .startTimelapse, .stopTimelapse, .startHyperlapse, .stopHyperlapse,
             .startMotionlapse, .stopMotionlapse:
            return value.modeRaw != nil || value.recordingStatus != nil
        case .photoFrame, .photoFormat, .photoCountdown:
            return value.photo != nil
        case .panoramaType, .panoramaFormat:
            return value.panorama != nil
        case .timelapseConfiguration, .hyperlapseSpeed:
            return value.lapse != nil
        case .motionlapseConfiguration, .motionlapseDirection:
            return value.motionlapse != nil
        }
    }

    private func matches(_ value: Pocket3NativeCameraReadback,
                         operation: Pocket3NativeCameraCaptureOperation) -> Bool {
        switch operation {
        case .setMode(let mode): return value.mode == mode
        case .photoFrame(let frame): return value.photo?.frame == frame
        case .photoFormat(let format): return value.photo?.format == format
        case .photoCountdown(let countdown): return value.photo?.countdown == countdown
        case .photoShutter:
            return value.mode == .photo && value.recordingStatus?.isKnown == true
        case .panoramaType(let type): return value.panorama?.panoramaType == type
        case .panoramaFormat(let format): return value.panorama?.photoFormat == format
        case .panoramaShutter:
            return value.mode == .panorama && value.recordingStatus?.isKnown == true
        case .timelapseConfiguration(let target):
            guard let current = value.lapse else { return false }
            return current.outputRaw == target.output.rawValue &&
                current.intervalTenths == target.intervalTenths &&
                current.durationSeconds == target.durationSeconds
        case .hyperlapseSpeed(let target):
            guard let current = value.lapse else { return false }
            return current.hyperlapseSpeedRaw == target.rawValue &&
                current.mirroredHyperlapseSpeedRaw == target.rawValue
        case .motionlapseConfiguration:
            guard let expected = expectedMotionlapseWaypointCount else { return false }
            return value.motionlapse?.waypointCount.map { $0 >= expected } == true
        case .motionlapseDirection(let target):
            return value.motionlapse?.direction == target
        case .startTimelapse, .startHyperlapse, .startMotionlapse:
            return value.recordingStatus?.recording == true && value.recordingStatus?.transitioning == false
        case .stopTimelapse, .stopHyperlapse, .stopMotionlapse:
            return value.recordingStatus?.recording == false && value.recordingStatus?.transitioning == false
        }
    }

    private func decodeObserved(_ payload: Data?, at uptime: TimeInterval?) -> Pocket3NativeCameraReadback? {
        guard let payload, let uptime, let marker = payload.first else { return nil }
        let value = Data(payload.dropFirst())
        switch marker {
        case ObservationMarker.status:
            guard let status = value.first else { return nil }
            return Pocket3NativeCameraReadback(sessionID: sessionID,
                generation: generation, receivedUptime: uptime,
                modeRaw: value.count > 57 ? value[57] : nil,
                recordingStatus: Pocket3BodyRecordingStatus(rawValue: status))
        case ObservationMarker.photo:
            guard case .photoParameters(let photo) = CameraReadOnlyPropertyDecoder.decode(
                .photoParameters, value: value) else { return nil }
            return Pocket3NativeCameraReadback(sessionID: sessionID,
                generation: generation, receivedUptime: uptime, photo: photo)
        case ObservationMarker.lapse:
            guard case .lapseParameters(let lapse) = CameraReadOnlyPropertyDecoder.decode(
                .lapseParameters, value: value) else { return nil }
            return Pocket3NativeCameraReadback(sessionID: sessionID,
                generation: generation, receivedUptime: uptime, lapse: lapse)
        case ObservationMarker.motionlapse:
            guard case .motionlapseParameters(let motion) = CameraReadOnlyPropertyDecoder.decode(
                .motionlapseParameters, value: value) else { return nil }
            return Pocket3NativeCameraReadback(sessionID: sessionID,
                generation: generation, receivedUptime: uptime, motionlapse: motion)
        case ObservationMarker.panorama:
            guard case .panoramaParameters(let panorama) = CameraReadOnlyPropertyDecoder.decode(
                .panoramaParameters, value: value) else { return nil }
            return Pocket3NativeCameraReadback(sessionID: sessionID,
                generation: generation, receivedUptime: uptime, panorama: panorama)
        default: return nil
        }
    }

    private enum ObservationMarker {
        static let status: UInt8 = 1
        static let photo: UInt8 = 2
        static let lapse: UInt8 = 3
        static let motionlapse: UInt8 = 4
        static let panorama: UInt8 = 5
    }

    private static func observationPayload(
        from frame: DUMLFrame,
        operation: Pocket3NativeCameraCaptureOperation,
        expectedMotionlapseWaypointCount: UInt8?
    ) -> Data? {
        switch operation {
        case .setMode(let mode):
            guard let status = statusPayload(from: frame),
                  status.mode == mode else { return nil }
            return Data([ObservationMarker.status]) + frame.payload
        case .photoShutter:
            guard let status = statusPayload(from: frame),
                  status.mode == .photo, status.recordingStatus?.isKnown == true else { return nil }
            return Data([ObservationMarker.status]) + frame.payload
        case .panoramaShutter:
            guard let status = statusPayload(from: frame),
                  status.mode == .panorama, status.recordingStatus?.isKnown == true else { return nil }
            return Data([ObservationMarker.status]) + frame.payload
        case .startTimelapse, .stopTimelapse, .startHyperlapse, .stopHyperlapse,
             .startMotionlapse, .stopMotionlapse:
            guard let status = statusPayload(from: frame),
                  lifecycleMatches(status, operation: operation) else { return nil }
            return Data([ObservationMarker.status]) + frame.payload
        case .photoFrame(let target):
            guard let photo: CameraPhotoParameters = propertyPayload(from: frame, property: .photoParameters),
                  photo.frame == target else { return nil }
            return Data([ObservationMarker.photo]) + photo.raw
        case .photoFormat(let target):
            guard let photo: CameraPhotoParameters = propertyPayload(from: frame, property: .photoParameters),
                  photo.format == target else { return nil }
            return Data([ObservationMarker.photo]) + photo.raw
        case .photoCountdown(let target):
            guard let photo: CameraPhotoParameters = propertyPayload(from: frame, property: .photoParameters),
                  photo.countdown == target else { return nil }
            return Data([ObservationMarker.photo]) + photo.raw
        case .panoramaType(let target):
            guard let panorama: CameraPanoramaParameters = propertyPayload(from: frame, property: .panoramaParameters),
                  panorama.panoramaType == target else { return nil }
            return Data([ObservationMarker.panorama]) + panorama.raw
        case .panoramaFormat(let target):
            guard let panorama: CameraPanoramaParameters = propertyPayload(from: frame, property: .panoramaParameters),
                  panorama.photoFormat == target else { return nil }
            return Data([ObservationMarker.panorama]) + panorama.raw
        case .timelapseConfiguration(let target):
            guard let lapse: CameraLapseParameters = propertyPayload(from: frame, property: .lapseParameters),
                  lapse.outputRaw == target.output.rawValue,
                  lapse.intervalTenths == target.intervalTenths,
                  lapse.durationSeconds == target.durationSeconds else { return nil }
            return Data([ObservationMarker.lapse]) + lapse.raw
        case .hyperlapseSpeed(let target):
            guard let lapse: CameraLapseParameters = propertyPayload(from: frame, property: .lapseParameters),
                  lapse.hyperlapseSpeedRaw == target.rawValue,
                  lapse.mirroredHyperlapseSpeedRaw == target.rawValue else { return nil }
            return Data([ObservationMarker.lapse]) + lapse.raw
        case .motionlapseConfiguration:
            guard let motion: CameraMotionlapseParameters = propertyPayload(from: frame, property: .motionlapseParameters),
                  let expectedMotionlapseWaypointCount,
                  motion.waypointCount.map({ $0 >= expectedMotionlapseWaypointCount }) == true else { return nil }
            return Data([ObservationMarker.motionlapse]) + motion.raw
        case .motionlapseDirection(let target):
            guard let motion: CameraMotionlapseParameters = propertyPayload(from: frame, property: .motionlapseParameters),
                  motion.direction == target else { return nil }
            return Data([ObservationMarker.motionlapse]) + motion.raw
        }
    }

    private static func statusPayload(from frame: DUMLFrame) -> Pocket3NativeCameraReadback? {
        guard frame.source == 0x01, frame.destination == 0x02,
              frame.flags == 0, frame.commandSet == 0x02,
              frame.commandID == 0x80, let status = frame.payload.first,
              frame.payload.count >= 58 else { return nil }
        return Pocket3NativeCameraReadback(sessionID: UUID(), generation: 1,
            receivedUptime: 0, modeRaw: frame.payload[57],
            recordingStatus: Pocket3BodyRecordingStatus(rawValue: status))
    }

    private static func lifecycleMatches(_ status: Pocket3NativeCameraReadback,
                                         operation: Pocket3NativeCameraCaptureOperation) -> Bool {
        guard let mode = status.mode else { return false }
        let targetMode: Pocket3ShootingMode
        let targetRecording: Bool
        switch operation {
        case .startTimelapse: targetMode = .timelapse; targetRecording = true
        case .stopTimelapse: targetMode = .timelapse; targetRecording = false
        case .startHyperlapse: targetMode = .hyperlapse; targetRecording = true
        case .stopHyperlapse: targetMode = .hyperlapse; targetRecording = false
        case .startMotionlapse: targetMode = .motionlapse; targetRecording = true
        case .stopMotionlapse: targetMode = .motionlapse; targetRecording = false
        default: return false
        }
        return mode == targetMode && status.recordingStatus?.isKnown == true &&
            status.recordingStatus?.recording == targetRecording &&
            status.recordingStatus?.transitioning == false
    }

    private static func propertyPayload<T>(from frame: DUMLFrame,
                                           property: CameraSettingsProperty) -> T? {
        guard frame.source == 0x28, frame.destination == 0x02,
              frame.flags == 0, frame.commandSet == 0,
              frame.commandID == 0x99,
              let push = try? CameraPropertyCodec.decodePush(from: frame),
              push.property == property else { return nil }
        guard let decoded = CameraReadOnlyPropertyDecoder.decode(property, value: push.value) else { return nil }
        switch decoded {
        case .photoParameters(let value): return value as? T
        case .lapseParameters(let value): return value as? T
        case .motionlapseParameters(let value): return value as? T
        case .panoramaParameters(let value): return value as? T
        default: return nil
        }
    }
}
