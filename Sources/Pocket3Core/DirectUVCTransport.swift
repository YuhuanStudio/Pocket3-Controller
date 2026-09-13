import Foundation
import Pocket3UVC

/// One endpoint property returned by the scalar interface-open boundary.
/// The endpoint is described for diagnostics only; this phase never claims a
/// pipe or submits a bulk transfer.
public struct DirectUVCEndpointObservation: Codable, Sendable, Equatable {
    public let pipe: UInt8
    public let address: UInt8
    public let direction: UInt8
    public let transferType: UInt8
    public let maximumPacketSize: UInt16
    public let interval: UInt8

    public init(pipe: UInt8, address: UInt8, direction: UInt8,
                transferType: UInt8, maximumPacketSize: UInt16,
                interval: UInt8) {
        self.pipe = pipe
        self.address = address
        self.direction = direction
        self.transferType = transferType
        self.maximumPacketSize = maximumPacketSize
        self.interval = interval
    }

    /// IOUSBLib's `GetPipeProperties` uses direction 1 for IN; descriptor
    /// endpoint addresses use bit 7. Accept both representations at this
    /// boundary so diagnostics cannot confuse pipe number 2 with 0x82.
    public var isIN: Bool { direction == 1 || direction == 0x80 || address & 0x80 != 0 }
    public var isBulk: Bool { transferType == 0x02 }
}

public enum DirectUVCOpenStatus: String, Codable, Sendable, Equatable,
    CaseIterable {
    case opened
    case busy
    case detached
    case timeout
    case deviceUnavailable
    case interfaceUnavailable
    case endpointUnavailable
    case registryUnavailable
    case failed
    case unknown
}

/// Scalar evidence from one normal VS interface open or status call.
/// `opened && ownedOpen` is required before a handle is published to the
/// direct session. A descriptor or endpoint observation alone never grants
/// ownership.
public struct DirectUVCOpenObservation: Codable, Sendable, Equatable {
    public let location: UInt32?
    public let interfaceNumber: UInt8?
    public let alternateSetting: UInt8?
    public let endpointAddress: UInt8?
    public let endpointCount: UInt8?
    public let endpoints: [DirectUVCEndpointObservation]
    public let opened: Bool
    public let ownedOpen: Bool
    public let result: String
    public let openIOReturn: UInt32?
    public let closeIOReturn: UInt32?
    public let registryID: String?
    public let bootSessionID: String?
    public let access: String?

    public init(location: UInt32? = nil,
                interfaceNumber: UInt8? = nil,
                alternateSetting: UInt8? = nil,
                endpointAddress: UInt8? = nil,
                endpointCount: UInt8? = nil,
                endpoints: [DirectUVCEndpointObservation] = [],
                opened: Bool,
                ownedOpen: Bool,
                result: String,
                openIOReturn: UInt32? = nil,
                closeIOReturn: UInt32? = nil,
                registryID: String? = nil,
                bootSessionID: String? = nil,
                access: String? = nil) {
        self.location = location
        self.interfaceNumber = interfaceNumber
        self.alternateSetting = alternateSetting
        self.endpointAddress = endpointAddress
        self.endpointCount = endpointCount
        self.endpoints = Array(endpoints.prefix(32))
        self.opened = opened
        self.ownedOpen = ownedOpen
        self.result = String(result.prefix(128))
        self.openIOReturn = openIOReturn
        self.closeIOReturn = closeIOReturn
        self.registryID = registryID.map { String($0.prefix(128)) }
        self.bootSessionID = bootSessionID.map { String($0.prefix(128)) }
        self.access = access.map { String($0.prefix(128)) }
    }

    public var status: DirectUVCOpenStatus {
        switch result {
        case "opened", "closed": .opened
        case "busy": .busy
        case "detached": .detached
        case "timeout": .timeout
        case "device_unavailable": .deviceUnavailable
        case "interface_unavailable": .interfaceUnavailable
        case "endpoint_unavailable": .endpointUnavailable
        case "registry_unavailable": .registryUnavailable
        case "open_failed", "close_failed", "memory_unavailable": .failed
        default: .unknown
        }
    }
}

public struct DirectUVCTransportSnapshot: Codable, Sendable, Equatable {
    public let active: Bool
    public let observation: DirectUVCOpenObservation?

    public init(active: Bool, observation: DirectUVCOpenObservation?) {
        self.active = active
        self.observation = observation
    }
}

/// Evidence produced when a normal open is rejected by an existing system
/// camera owner. The public AVFoundation/CMIO APIs can stop and drain a graph
/// owned by this process and can report running/ownership properties, but they
/// provide no product-safe API to release another application's VDCAssistant
/// client. `ownerIdentity` therefore remains unknown and this evidence never
/// authorizes a seize or a process termination.
public struct DirectUVCSystemOwnerBusyEvidence: Codable, Sendable,
    Equatable {
    public let interfaceNumber: UInt8?
    public let openIOReturn: UInt32?
    public let ownerIdentity: String
    public let publicReleasePathAvailable: Bool
    public let nextSafeAction: String

    public init(interfaceNumber: UInt8? = nil,
                openIOReturn: UInt32? = nil,
                ownerIdentity: String = "unknown",
                publicReleasePathAvailable: Bool = false,
                nextSafeAction: String = "stop_and_drain_own_avfoundation_graph") {
        self.interfaceNumber = interfaceNumber
        self.openIOReturn = openIOReturn
        self.ownerIdentity = String(ownerIdentity.prefix(64))
        self.publicReleasePathAvailable = publicReleasePathAvailable
        self.nextSafeAction = String(nextSafeAction.prefix(128))
    }
}

public enum DirectUVCTransportError: Error, LocalizedError, Sendable,
    Equatable {
    case busy
    case systemOwnerBusy(DirectUVCSystemOwnerBusyEvidence)
    case detached
    case timeout
    case deviceUnavailable
    case interfaceUnavailable
    case endpointUnavailable
    case registryUnavailable
    case observationMismatch
    case openFailed(code: String, ioReturn: UInt32?)
    case closeFailed(code: String, ioReturn: UInt32?)
    case controlUnavailable
    case alreadyReleased
    case cancelled
    case bridgeFailure(String)

    public var errorDescription: String? {
        switch self {
        case .busy: "direct UVC VS interface is already owned"
        case .systemOwnerBusy: "direct UVC VS interface is owned by another system camera client"
        case .detached: "direct UVC device detached during interface lifecycle"
        case .timeout: "direct UVC VS interface open timed out"
        case .deviceUnavailable: "direct UVC device is unavailable"
        case .interfaceUnavailable: "direct UVC VS interface is unavailable"
        case .endpointUnavailable: "direct UVC bulk IN endpoint is unavailable"
        case .registryUnavailable: "direct UVC IORegistry is unavailable"
        case .observationMismatch: "direct UVC open did not match the planned interface"
        case .openFailed(let code, _): "direct UVC VS interface open failed: " + code
        case .closeFailed(let code, _): "direct UVC VS interface close failed: " + code
        case .controlUnavailable: "direct UVC control requests are not implemented by this transport slice"
        case .alreadyReleased: "direct UVC stream handle was already released"
        case .cancelled: "direct UVC interface lifecycle was cancelled"
        case .bridgeFailure(let reason): "direct UVC bridge failed: " + reason
        }
    }
}

/// The only operation needed by the scalar transport. A bridge implementation
/// owns its legacy/public API details; fake bridges keep tests hardware-free.
public protocol DirectUVCNormalOpenHandle: AnyObject, Sendable {
    var openObservation: DirectUVCOpenObservation { get }
    func scalarStatus() throws -> DirectUVCOpenObservation
    func close() throws -> DirectCaptureReleaseEvidence
}

/// Native extension of a normal-open handle. It remains bound to the same
/// already-owned VS interface and exposes only the reviewed UVC probe/commit
/// controls and selected bulk-IN pipe. It has no seize or alternate-setting
/// operation.
public protocol DirectUVCNativeOpenHandle: DirectUVCNormalOpenHandle {
    func controlTransfer(_ request: UVCVideoStreamingRequest,
                         payload: Data?) throws -> Data?
    func readBulkIn(maximumBytes: Int) throws -> DirectUVCBulkTransfer
    func cancelBulkIn() throws
}

public protocol DirectUVCNormalOpenBridge: Sendable {
    func openVS(plan: DirectUVCStreamPlan) throws
        -> any DirectUVCNormalOpenHandle
}

/// A public-API-only transport owner for one normal VS interface open.
///
/// The actor serializes acquire/release and publishes no borrowed or seized
/// interface. Native controls/bulk are exposed only when the injected bridge
/// returns a `DirectUVCNativeOpenHandle`; scalar-only fake bridges remain
/// read-only.
public actor DirectUVCNormalOpenTransport: DirectUVCStreamTransport {
    private let bridge: any DirectUVCNormalOpenBridge
    private var activeHandle: ManagedDirectUVCStreamHandle?

    public init(bridge: any DirectUVCNormalOpenBridge) {
        self.bridge = bridge
    }

    public func snapshot() -> DirectUVCTransportSnapshot {
        DirectUVCTransportSnapshot(
            active: activeHandle != nil,
            observation: activeHandle?.openObservation)
    }

    public func acquire(plan: DirectUVCStreamPlan) async throws
        -> any DirectUVCStreamHandle {
        guard activeHandle == nil else { throw DirectUVCTransportError.busy }
        guard !Task.isCancelled else { throw DirectUVCTransportError.cancelled }

        let bridgeHandle: any DirectUVCNormalOpenHandle
        do {
            bridgeHandle = try bridge.openVS(plan: plan)
        } catch is CancellationError {
            throw DirectUVCTransportError.cancelled
        } catch let error as DirectUVCTransportError {
            throw error
        } catch {
            throw DirectUVCTransportError.bridgeFailure(
                String(String(describing: error).prefix(128)))
        }

        do {
            try Task.checkCancellation()
        } catch {
            // A bridge can only return after its synchronous open boundary;
            // fence a late handle exactly once before reporting cancellation.
            _ = try? bridgeHandle.close()
            throw DirectUVCTransportError.cancelled
        }

        let observation = bridgeHandle.openObservation
        guard observation.opened, observation.ownedOpen,
              observation.status == .opened else {
            _ = try? bridgeHandle.close()
            throw Self.error(for: observation)
        }
        guard observation.interfaceNumber == plan.configuration.streamingInterfaceNumber,
              observation.alternateSetting == plan.configuration.alternateSetting,
              observation.endpointAddress == plan.configuration.endpointAddress else {
            _ = try? bridgeHandle.close()
            throw DirectUVCTransportError.observationMismatch
        }

        let managed = ManagedDirectUVCStreamHandle(
            owner: self, bridgeHandle: bridgeHandle)
        activeHandle = managed
        return managed
    }

    fileprivate func didRelease(_ id: UUID) {
        guard activeHandle?.id == id else { return }
        activeHandle = nil
    }

    private static func error(for observation: DirectUVCOpenObservation)
        -> DirectUVCTransportError {
        switch observation.status {
        case .busy:
            return .systemOwnerBusy(.init(
                interfaceNumber: observation.interfaceNumber,
                openIOReturn: observation.openIOReturn))
        case .detached: return .detached
        case .timeout: return .timeout
        case .deviceUnavailable: return .deviceUnavailable
        case .interfaceUnavailable: return .interfaceUnavailable
        case .endpointUnavailable: return .endpointUnavailable
        case .registryUnavailable: return .registryUnavailable
        case .opened: return .openFailed(code: observation.result,
                                          ioReturn: observation.openIOReturn)
        case .failed, .unknown:
            return .openFailed(code: observation.result,
                               ioReturn: observation.openIOReturn)
        }
    }
}

public protocol DirectUVCScalarDiagnosticsHandle: DirectUVCStreamHandle {
    func scalarStatus() async throws -> DirectUVCOpenObservation
}

/// Handle returned by the native adapter. `readBulkIn` is one bounded
/// completion; H.264 assembly and lifecycle fences remain in the existing
/// `DirectUVCH264BulkReader` actor.
public protocol DirectUVCNativeStreamHandle: DirectUVCScalarDiagnosticsHandle {
    func readBulkIn(maximumBytes: Int) async throws -> DirectUVCBulkTransfer
    func cancelBulkIn() async
}

/// Bridges the owned native stream handle to the existing bounded H.264 reader
/// without adding another pipe owner or a second transport object.
public struct DirectUVCNativeBulkReaderIO: DirectUVCBulkReaderIO {
    private let handle: any DirectUVCNativeStreamHandle

    public init(handle: any DirectUVCNativeStreamHandle) {
        self.handle = handle
    }

    public func readBulkIn(maximumBytes: Int) async throws
        -> DirectUVCBulkTransfer {
        try await handle.readBulkIn(maximumBytes: maximumBytes)
    }

    public func cancelBulkIn() async {
        await handle.cancelBulkIn()
    }
}

private final class ManagedDirectUVCStreamHandle: @unchecked Sendable,
    DirectUVCNativeStreamHandle {
    let id = UUID()
    let openObservation: DirectUVCOpenObservation
    private weak var owner: DirectUVCNormalOpenTransport?
    private let bridgeHandle: any DirectUVCNormalOpenHandle
    private let lock = NSLock()
    private var released = false

    init(owner: DirectUVCNormalOpenTransport,
         bridgeHandle: any DirectUVCNormalOpenHandle) {
        self.owner = owner
        self.bridgeHandle = bridgeHandle
        self.openObservation = bridgeHandle.openObservation
    }

    func control(_ request: UVCVideoStreamingRequest,
                 payload: Data?) async throws
        -> Data? {
        try ensureOpen()
        guard let native = bridgeHandle as? any DirectUVCNativeOpenHandle else {
            throw DirectUVCTransportError.controlUnavailable
        }
        return try native.controlTransfer(request, payload: payload)
    }

    func scalarStatus() async throws -> DirectUVCOpenObservation {
        try ensureOpen()
        do {
            return try bridgeHandle.scalarStatus()
        } catch let error as DirectUVCTransportError {
            throw error
        } catch {
            throw DirectUVCTransportError.bridgeFailure(
                String(String(describing: error).prefix(128)))
        }
    }

    func readBulkIn(maximumBytes: Int) async throws -> DirectUVCBulkTransfer {
        try ensureOpen()
        guard let native = bridgeHandle as? any DirectUVCNativeOpenHandle else {
            throw DirectUVCTransportError.controlUnavailable
        }
        return try native.readBulkIn(maximumBytes: maximumBytes)
    }

    func cancelBulkIn() async {
        let isReleased = lock.withLock { released }
        guard !isReleased,
              let native = bridgeHandle as? any DirectUVCNativeOpenHandle else {
            return
        }
        _ = try? native.cancelBulkIn()
    }

    func release() async throws -> DirectCaptureReleaseEvidence {
        do {
            try markReleased()
            let evidence = try bridgeHandle.close()
            await owner?.didRelease(id)
            return evidence
        } catch {
            await owner?.didRelease(id)
            throw error
        }
    }

    private func ensureOpen() throws {
        try lock.withLock {
            guard !released else {
                throw DirectUVCTransportError.alreadyReleased
            }
        }
    }

    private func markReleased() throws {
        try lock.withLock {
            guard !released else {
                throw DirectUVCTransportError.alreadyReleased
            }
            released = true
        }
    }
}

/// Adapter around the existing `Pocket3UVC` legacy IOUSBLib bridge. This is
/// intentionally opt-in: constructing it has no I/O; `openVS` performs one
/// normal `USBInterfaceOpen` only and never calls `USBInterfaceOpenSeize`.
public struct LegacyIOUSBLibDirectUVCBridge: DirectUVCNormalOpenBridge {
    public let location: UInt32

    /// The location is supplied by the caller that already owns the exact
    /// camera identity. No enumeration or fallback selection is performed.
    public init(location: UInt32) {
        self.location = location
    }

    public func openVS(plan: DirectUVCStreamPlan) throws
        -> any DirectUVCNormalOpenHandle {
        var pointer: OpaquePointer?
        let raw = p3_uvc_stream_session_open(
            location,
            plan.configuration.streamingInterfaceNumber,
            plan.configuration.alternateSetting,
            plan.configuration.endpointAddress,
            &pointer)
        do {
            let value = try Self.consume(raw)
            if let code = value["error"].string {
                throw Self.mapOpenError(code: code, value: value)
            }
            guard let pointer else {
                throw DirectUVCTransportError.openFailed(
                    code: value["result"].string ?? "open_missing_handle",
                    ioReturn: Self.uint32(value["openIOReturn"]))
            }
            do {
                let observation = try Self.observation(value)
                return LegacyIOUSBLibDirectUVCHandle(
                    pointer: pointer, observation: observation)
            } catch {
                throw error
            }
        } catch {
            if let pointer { Self.closeUnexpected(pointer) }
            throw error
        }
    }

    fileprivate static func consume(_ raw: UnsafeMutablePointer<CChar>?)
        throws -> JSONValue {
        guard let raw else {
            throw DirectUVCTransportError.bridgeFailure("bridge_memory")
        }
        defer { p3_uvc_free(raw) }
        do {
            return try JSONDecoder().decode(
                JSONValue.self,
                from: Data(String(cString: raw).utf8))
        } catch {
            throw DirectUVCTransportError.bridgeFailure("bridge_json")
        }
    }

    fileprivate static func observation(_ value: JSONValue)
        throws -> DirectUVCOpenObservation {
        let endpoints: [DirectUVCEndpointObservation]
        if case .array = value["endpoints"] {
            endpoints = (try? value["endpoints"].decode(
                [DirectUVCEndpointObservation].self)) ?? []
        } else {
            endpoints = []
        }
        guard let result = value["result"].string else {
            throw DirectUVCTransportError.bridgeFailure("open_result_missing")
        }
        return DirectUVCOpenObservation(
            location: Self.uint32(value["location"]),
            interfaceNumber: Self.uint8(value["interfaceNumber"]),
            alternateSetting: Self.uint8(value["alternateSetting"]),
            endpointAddress: Self.uint8(value["endpointAddress"]),
            endpointCount: Self.uint8(value["endpointCount"]),
            endpoints: endpoints,
            opened: value["opened"].bool ?? false,
            ownedOpen: value["ownedOpen"].bool ?? false,
            result: result,
            openIOReturn: Self.uint32(value["openIOReturn"]),
            closeIOReturn: Self.uint32(value["closeIOReturn"]),
            registryID: value["registryID"].string,
            bootSessionID: value["bootSessionID"].string,
            access: value["access"].string)
    }

    fileprivate static func releaseEvidence(_ value: JSONValue)
        -> DirectCaptureReleaseEvidence {
        DirectCaptureReleaseEvidence(
            readerStopped: value["readerStopped"].bool ?? false,
            pipeReleased: value["pipeReleased"].bool ?? false,
            interfaceReleased: value["interfaceReleased"].bool ?? false,
            objectsReleased: value["objectsReleased"].bool ?? false)
    }

    fileprivate static func mapOpenError(code: String, value: JSONValue)
        -> DirectUVCTransportError {
        let ioReturn = Self.uint32(value["openIOReturn"])
        switch code {
        case "uvc_stream_busy":
            return .systemOwnerBusy(.init(
                interfaceNumber: Self.uint8(value["interfaceNumber"]),
                openIOReturn: ioReturn))
        case "uvc_attachment_changed": return .detached
        case "uvc_stream_open_timeout": return .timeout
        case "uvc_device_missing": return .deviceUnavailable
        case "uvc_streaming_interface_unavailable": return .interfaceUnavailable
        case "uvc_stream_endpoint_unavailable": return .endpointUnavailable
        case "uvc_registry_unavailable": return .registryUnavailable
        default: return .openFailed(code: String(code.prefix(128)),
                                     ioReturn: ioReturn)
        }
    }

    fileprivate static func mapStatusError(code: String, value: JSONValue)
        -> DirectUVCTransportError {
        switch code {
        case "uvc_attachment_changed": return .detached
        case "uvc_stream_not_open": return .interfaceUnavailable
        default: return .bridgeFailure(String(code.prefix(128)))
        }
    }

    fileprivate static func mapStreamError(code: String, value: JSONValue)
        -> DirectUVCTransportError {
        switch code {
        case "uvc_stream_detached", "uvc_attachment_changed": return .detached
        case "uvc_stream_control_timeout", "uvc_stream_bulk_timeout":
            return .timeout
        case "uvc_stream_not_owned": return .controlUnavailable
        default: return .bridgeFailure(String(code.prefix(128)))
        }
    }

    fileprivate static func uint8(_ value: JSONValue) -> UInt8? {
        guard let number = value.number, number.isFinite,
              number.rounded() == number, number >= 0,
              number <= Double(UInt8.max) else { return nil }
        return UInt8(number)
    }

    fileprivate static func uint32(_ value: JSONValue) -> UInt32? {
        guard let number = value.number, number.isFinite,
              number.rounded() == number, number >= 0,
              number <= Double(UInt32.max) else { return nil }
        return UInt32(number)
    }

    fileprivate static func intValue(_ value: JSONValue) -> Int? {
        guard let number = value.number, number.isFinite,
              number.rounded() == number, number >= 0,
              number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func closeUnexpected(_ pointer: OpaquePointer) {
        if let raw = p3_uvc_stream_session_close(pointer) { p3_uvc_free(raw) }
    }
}

private final class LegacyIOUSBLibDirectUVCHandle: @unchecked Sendable,
    DirectUVCNativeOpenHandle {
    let openObservation: DirectUVCOpenObservation
    private let pointer: OpaquePointer
    private let lock = NSLock()
    /// Serializes status/control/read/close calls. Cancellation deliberately
    /// bypasses this lock so it can abort a blocking ReadPipeTO.
    private let operationLock = NSLock()
    private var closed = false

    init(pointer: OpaquePointer, observation: DirectUVCOpenObservation) {
        self.pointer = pointer
        self.openObservation = observation
    }

    func scalarStatus() throws -> DirectUVCOpenObservation {
        try ensureOpen()
        operationLock.lock()
        defer { operationLock.unlock() }
        let value = try LegacyIOUSBLibDirectUVCBridge.consume(
            p3_uvc_stream_session_status(pointer))
        if let code = value["error"].string {
            throw LegacyIOUSBLibDirectUVCBridge.mapStatusError(
                code: code, value: value)
        }
        return try LegacyIOUSBLibDirectUVCBridge.observation(value)
    }

    func controlTransfer(_ request: UVCVideoStreamingRequest,
                         payload: Data?) throws -> Data? {
        try ensureOpen()
        let metadata = request.metadata
        let length = metadata.wLength
        if request == .getMaxProbe || request == .getCurProbe {
            guard payload == nil else {
                throw DirectUVCTransportError.bridgeFailure(
                    "uvc_stream_control_invalid_payload")
            }
        } else {
            guard payload?.count == Int(length) else {
                throw DirectUVCTransportError.bridgeFailure(
                    "uvc_stream_control_invalid_payload")
            }
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        let raw: UnsafeMutablePointer<CChar>?
        if let payload {
            raw = payload.withUnsafeBytes { bytes in
                p3_uvc_stream_session_control(
                    pointer, metadata.bmRequestType, metadata.bRequest,
                    metadata.wValue, metadata.wIndex,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    length, 1000)
            }
        } else {
            raw = p3_uvc_stream_session_control(
                pointer, metadata.bmRequestType, metadata.bRequest,
                metadata.wValue, metadata.wIndex, nil, length, 1000)
        }
        let value = try LegacyIOUSBLibDirectUVCBridge.consume(raw)
        if let code = value["error"].string {
            throw LegacyIOUSBLibDirectUVCBridge.mapStreamError(
                code: code, value: value)
        }
        if request == .setCurProbe || request == .setCurCommit {
            return nil
        }
        guard let encoded = value["data"].string,
              let data = Data(base64Encoded: encoded) else {
            throw DirectUVCTransportError.bridgeFailure(
                "uvc_stream_control_data_invalid")
        }
        return data
    }

    func readBulkIn(maximumBytes: Int) throws -> DirectUVCBulkTransfer {
        try ensureOpen()
        guard maximumBytes > 2,
              maximumBytes <= DirectUVCH264BulkReader.defaultMaximumTransferBytes else {
            throw DirectUVCTransportError.bridgeFailure(
                "uvc_stream_bulk_invalid_size")
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        let raw = p3_uvc_stream_session_read_bulk(
            pointer, openObservation.endpointAddress ?? 0,
            UInt32(maximumBytes), 1000, 1500)
        let value = try LegacyIOUSBLibDirectUVCBridge.consume(raw)
        if let code = value["error"].string {
            throw LegacyIOUSBLibDirectUVCBridge.mapStreamError(
                code: code, value: value)
        }
        guard let encoded = value["data"].string,
              let data = Data(base64Encoded: encoded) else {
            throw DirectUVCTransportError.bridgeFailure(
                "uvc_stream_bulk_data_invalid")
        }
        let requested = LegacyIOUSBLibDirectUVCBridge.intValue(
            value["requestedByteCount"]) ?? maximumBytes
        let status: DirectUVCBulkTransferStatus =
            value["status"].string == "complete" ? .complete : .short
        return DirectUVCBulkTransfer(requestedByteCount: requested,
                                     data: data, status: status)
    }

    func cancelBulkIn() throws {
        try ensureOpen()
        let raw = p3_uvc_stream_session_abort_bulk(
            pointer, openObservation.endpointAddress ?? 0)
        let value = try LegacyIOUSBLibDirectUVCBridge.consume(raw)
        if let code = value["error"].string {
            throw LegacyIOUSBLibDirectUVCBridge.mapStreamError(
                code: code, value: value)
        }
    }

    func close() throws -> DirectCaptureReleaseEvidence {
        try lock.withLock {
            guard !closed else { throw DirectUVCTransportError.alreadyReleased }
            closed = true
        }
        operationLock.lock()
        defer { operationLock.unlock() }
        let value = try LegacyIOUSBLibDirectUVCBridge.consume(
            p3_uvc_stream_session_close(pointer))
        if let code = value["error"].string {
            throw DirectUVCTransportError.closeFailed(
                code: String(code.prefix(128)),
                ioReturn: LegacyIOUSBLibDirectUVCBridge.uint32(
                    value["closeIOReturn"]))
        }
        return LegacyIOUSBLibDirectUVCBridge.releaseEvidence(value)
    }

    private func ensureOpen() throws {
        guard !lock.withLock({ closed }) else {
            throw DirectUVCTransportError.alreadyReleased
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
