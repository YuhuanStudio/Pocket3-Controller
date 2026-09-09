import Foundation

public struct ValidatedDUMLPacket: Sendable {
    public let frameData: Data
    public let frame: DUMLFrame
}

public struct DUMLFragmentStatistics: Codable, Sendable, Equatable {
    public var validFrames = 0
    public var invalidHeaders = 0
    public var invalidFrames = 0
    public var discardedBytes = 0
    public var overflows = 0
    public var expiredFragments = 0
}

public enum DUMLFragmentError: Error, Sendable, Equatable { case invalidClock, byteBudgetExceeded }

/// One decoder per BLE characteristic; streams from FFF4/FFF5 must not mix.
/// No payload is logged or persisted. A valid CRC is not device authentication.
public struct DUMLFragmentDecoder: Sendable {
    public static let maximumBufferedBytes = 4096
    public static let fragmentTimeout: TimeInterval = 2
    public private(set) var statistics = DUMLFragmentStatistics()
    public var pendingByteCount: Int { bytes.count }
    private var bytes: [UInt8] = []
    private var pendingSince: TimeInterval?

    public init() {}

    public mutating func append(_ fragment: Data, at uptime: TimeInterval) throws -> [ValidatedDUMLPacket] {
        guard uptime.isFinite, uptime >= 0 else { clearPending(); throw DUMLFragmentError.invalidClock }
        expire(at: uptime)
        guard fragment.count <= Self.maximumBufferedBytes,
              bytes.count <= Self.maximumBufferedBytes - fragment.count else {
            statistics.overflows += 1
            statistics.discardedBytes += bytes.count + fragment.count
            clearPending()
            throw DUMLFragmentError.byteBudgetExceeded
        }
        if bytes.isEmpty, !fragment.isEmpty { pendingSince = uptime }
        bytes.append(contentsOf: fragment)
        var packets: [ValidatedDUMLPacket] = []
        while !bytes.isEmpty {
            guard let start = bytes.firstIndex(of: 0x55) else {
                statistics.discardedBytes += bytes.count; clearPending(); break
            }
            if start > 0 { discard(start) }
            guard bytes.count >= 4 else { break }
            let length = Int(bytes[1]) | (Int(bytes[2] & 3) << 8)
            guard bytes[2] >> 2 == 1,
                  (DUMLCodec.minimumFrameLength...DUMLCodec.maximumFrameLength).contains(length),
                  DUMLCodec.crc8(bytes.prefix(3)) == bytes[3] else {
                statistics.invalidHeaders += 1; discard(1); continue
            }
            guard bytes.count >= length else { break }
            let data = Data(bytes.prefix(length))
            do {
                let frame = try DUMLCodec.decode(data)
                packets.append(ValidatedDUMLPacket(frameData: data, frame: frame))
                statistics.validFrames += 1
                bytes.removeFirst(length)
                pendingSince = bytes.isEmpty ? nil : uptime
            } catch {
                statistics.invalidFrames += 1; discard(1)
            }
        }
        if bytes.isEmpty { pendingSince = nil }
        return packets
    }

    @discardableResult
    public mutating func expire(at uptime: TimeInterval) -> Bool {
        guard let pendingSince else { return false }
        guard uptime.isFinite, uptime >= pendingSince,
              uptime - pendingSince < Self.fragmentTimeout else {
            statistics.expiredFragments += 1
            statistics.discardedBytes += bytes.count
            clearPending()
            return true
        }
        return false
    }

    public mutating func reset() { self = Self() }
    public mutating func discardPending() {
        statistics.discardedBytes += bytes.count
        clearPending()
    }
    private mutating func discard(_ count: Int) {
        statistics.discardedBytes += count
        bytes.removeFirst(count)
    }
    private mutating func clearPending() { bytes.removeAll(keepingCapacity: false); pendingSince = nil }
}
