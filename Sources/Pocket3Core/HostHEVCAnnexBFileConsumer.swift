import CoreMedia
import Foundation

/// Bounds for one explicit local host-HEVC elementary-stream recording.
///
/// The path is intentionally part of the caller's request. Constructing a
/// host HEVC encoder never creates a file unless this value is supplied.
public struct HostHEVCProductFileConfiguration: Codable, Sendable, Equatable {
    public static let defaultMaximumBytes = 256 * 1024 * 1024
    public static let defaultMaximumDurationSeconds = 300.0
    public static let maximumBytes = 1 * 1024 * 1024 * 1024
    public static let maximumDurationSeconds = 3_600.0

    public let outputPath: String
    public let maximumBytes: Int
    public let maximumDurationSeconds: Double

    public init(
        outputPath: String,
        maximumBytes: Int = Self.defaultMaximumBytes,
        maximumDurationSeconds: Double = Self.defaultMaximumDurationSeconds
    ) throws {
        let trimmed = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard !trimmed.isEmpty, !url.hasDirectoryPath,
              url.pathExtension.caseInsensitiveCompare("hevc") == .orderedSame else {
            throw HostHEVCProductFileConfigurationError.invalidPath
        }
        guard (1...Self.maximumBytes).contains(maximumBytes),
              maximumDurationSeconds.isFinite,
              maximumDurationSeconds > 0,
              maximumDurationSeconds <= Self.maximumDurationSeconds else {
            throw HostHEVCProductFileConfigurationError.invalidLimits
        }
        self.outputPath = url.path
        self.maximumBytes = maximumBytes
        self.maximumDurationSeconds = maximumDurationSeconds
    }
}

public enum HostHEVCProductFileConfigurationError: Error, LocalizedError,
    Codable, Sendable, Equatable {
    case invalidPath
    case invalidLimits

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            "host HEVC output path must name a local .hevc file"
        case .invalidLimits:
            "host HEVC file limits are invalid"
        }
    }
}

/// Pure conversion of one VideoToolbox hvc1 access unit to Annex-B bytes.
///
/// VideoToolbox supplies four-byte big-endian NAL lengths in hvc1 samples.
/// The normalizer validates that framing strictly; this converter then emits
/// each NAL in the exact input order with a four-byte Annex-B start code.
/// Parameter sets are emitted in the required VPS, SPS, PPS order only when
/// the caller requests stream-start/keyframe insertion.
public struct HostHEVCAnnexBAccessUnitConverter: Sendable {
    public let limits: HEVCAccessUnitLimits

    public init(limits: HEVCAccessUnitLimits = .default) {
        self.limits = limits
    }

    public func convert(
        parameterSets: VideoToolboxParameterSetBundle,
        accessUnit: Data,
        prependParameterSets: Bool
    ) throws -> Data {
        guard parameterSets.codec == .hevc else {
            throw HostHEVCAnnexBConversionError.invalidParameterSets
        }
        guard let vps = parameterSets.vps,
              let sps = parameterSets.sps,
              let pps = parameterSets.pps else {
            throw HostHEVCAnnexBConversionError.invalidParameterSets
        }

        var normalizer = HEVCAccessUnitNormalizer(limits: limits)
        let normalized: HEVCNormalizedAccessUnit
        do {
            normalized = try normalizer.normalize(accessUnit)
        } catch let error as HEVCAccessUnitError {
            throw HostHEVCAnnexBConversionError.normalizer(error)
        }
        guard normalized.inputFormat == .hvcc else {
            throw HostHEVCAnnexBConversionError.lengthPrefixedInputRequired
        }

        var total = 0
        func add(_ data: Data) throws {
            guard data.count <= Int.max - 4,
                  total <= Int.max - 4 - data.count else {
                throw HostHEVCAnnexBConversionError.outputTooLarge
            }
            total += 4 + data.count
            guard total <= limits.maxOutputBytes else {
                throw HostHEVCAnnexBConversionError.outputTooLarge
            }
        }
        if prependParameterSets {
            try add(vps)
            try add(sps)
            try add(pps)
        }
        for unit in normalized.nalUnits {
            try add(unit.data)
        }

        var output = Data()
        output.reserveCapacity(total)
        func appendNAL(_ data: Data) {
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(data)
        }
        if prependParameterSets {
            appendNAL(vps)
            appendNAL(sps)
            appendNAL(pps)
        }
        for unit in normalized.nalUnits {
            appendNAL(unit.data)
        }
        return output
    }
}

public enum HostHEVCAnnexBConversionError: Error, LocalizedError,
    Codable, Sendable, Equatable {
    case invalidParameterSets
    case normalizer(HEVCAccessUnitError)
    case lengthPrefixedInputRequired
    case outputTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidParameterSets:
            "host HEVC parameter sets are invalid"
        case .normalizer(let error):
            "host HEVC access unit is invalid: \(error)"
        case .lengthPrefixedInputRequired:
            "host HEVC file consumer requires length-prefixed hvc1 access units"
        case .outputTooLarge:
            "host HEVC Annex-B access unit exceeds its output bound"
        }
    }
}

public enum HostHEVCAnnexBFileConsumerPhase: String, Codable, Sendable,
    Equatable {
    case running
    case finished
    case cancelled
    case failed
}

public enum HostHEVCAnnexBFileFinishReason: String, Codable, Sendable,
    Equatable {
    case explicitlyStopped = "explicit_stop"
    case byteLimit = "byte_limit"
    case durationLimit = "duration_limit"
}

public struct HostHEVCAnnexBFileConsumerSnapshot: Codable, Sendable,
    Equatable {
    public let phase: HostHEVCAnnexBFileConsumerPhase
    public let outputPath: String
    public let sessionID: String
    public let generation: UInt64
    public let maximumBytes: Int
    public let maximumDurationSeconds: Double
    public let bytesWritten: Int
    public let samplesWritten: Int
    public let durationSeconds: Double?
    public let lastSequence: UInt64?
    public let finishReason: HostHEVCAnnexBFileFinishReason?
    public let finalFilePublished: Bool
    public let failureCode: String?
}

public enum HostHEVCAnnexBFileConsumerError: Error, LocalizedError,
    Codable, Sendable, Equatable {
    case invalidIdentity
    case outputAlreadyExists
    case parentDirectoryMissing
    case cannotOpenTemporaryFile
    case staleSession
    case staleGeneration
    case sequenceOutOfOrder
    case invalidPresentationTime
    case writeFailed
    case finalizeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: "host HEVC file consumer identity is invalid"
        case .outputAlreadyExists: "host HEVC output file already exists"
        case .parentDirectoryMissing: "host HEVC output directory does not exist"
        case .cannotOpenTemporaryFile: "host HEVC temporary output file could not be opened"
        case .staleSession: "host HEVC file sample belongs to an older session"
        case .staleGeneration: "host HEVC file sample belongs to an older generation"
        case .sequenceOutOfOrder: "host HEVC encoded samples arrived out of order"
        case .invalidPresentationTime: "host HEVC encoded sample presentation time is invalid"
        case .writeFailed: "host HEVC Annex-B output could not be written"
        case .finalizeFailed: "host HEVC temporary output could not be published atomically"
        }
    }
}

public enum HostHEVCAnnexBFileAppendDisposition: String, Codable, Sendable,
    Equatable {
    case accepted
    case finishedAtByteLimit = "finished_at_byte_limit"
    case finishedAtDurationLimit = "finished_at_duration_limit"
    case ignored
    case failed
}

/// Synchronous, bounded writer used as the encoded-sample sink.
///
/// The writer owns only the current temporary file and scalar counters. It
/// validates session, generation, sequence and presentation-time ordering
/// before each write. A successful stop flushes and atomically moves the
/// temporary file beside the requested final path; cancellation or a stale
/// sample removes the temporary file and never publishes it.
public final class HostHEVCAnnexBFileConsumer: @unchecked Sendable {
    public let configuration: HostHEVCProductFileConfiguration
    public private(set) var sessionID: String
    public private(set) var generation: UInt64

    private let lock = NSLock()
    private let converter: HostHEVCAnnexBAccessUnitConverter
    private let outputURL: URL
    private var temporaryURL: URL?
    private var fileHandle: FileHandle?
    private var phase: HostHEVCAnnexBFileConsumerPhase = .running
    private var bytesWritten = 0
    private var samplesWritten = 0
    private var firstPresentationTime: Double?
    private var lastPresentationTime: Double?
    private var lastSequence: UInt64?
    private var finishReason: HostHEVCAnnexBFileFinishReason?
    private var finalFilePublished = false
    private var failureCode: String?

    public init(
        configuration: HostHEVCProductFileConfiguration,
        sessionID: String,
        generation: UInt64,
        limits: HEVCAccessUnitLimits = .default
    ) throws {
        let session = String(sessionID.prefix(128))
        guard !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              generation > 0 else {
            throw HostHEVCAnnexBFileConsumerError.invalidIdentity
        }
        self.configuration = configuration
        self.sessionID = session
        self.generation = generation
        self.converter = HostHEVCAnnexBAccessUnitConverter(limits: limits)
        self.outputURL = URL(fileURLWithPath: configuration.outputPath)

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw HostHEVCAnnexBFileConsumerError.outputAlreadyExists
        }
        let parent = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw HostHEVCAnnexBFileConsumerError.parentDirectoryMissing
        }
        let temporary = parent.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: nil,
                                     attributes: [FileAttributeKey.posixPermissions: 0o600]) else {
            throw HostHEVCAnnexBFileConsumerError.cannotOpenTemporaryFile
        }
        do {
            self.fileHandle = try FileHandle(forWritingTo: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw HostHEVCAnnexBFileConsumerError.cannotOpenTemporaryFile
        }
        self.temporaryURL = temporary
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.close()
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }

    public func snapshot() -> HostHEVCAnnexBFileConsumerSnapshot {
        lock.withLock { makeSnapshot() }
    }

    @discardableResult
    public func append(_ sample: HostHEVCEncodedSample)
        -> HostHEVCAnnexBFileAppendDisposition {
        lock.withLock {
            guard phase == .running else { return .ignored }
            guard sample.sessionID == sessionID else {
                failLocked(HostHEVCAnnexBFileConsumerError.staleSession)
                return .failed
            }
            guard sample.generation == generation else {
                failLocked(HostHEVCAnnexBFileConsumerError.staleGeneration)
                return .failed
            }
            if let lastSequence, sample.sequence <= lastSequence {
                failLocked(HostHEVCAnnexBFileConsumerError.sequenceOutOfOrder)
                return .failed
            }

            let presentationTime = CMTimeGetSeconds(sample.presentationTimeStamp)
            guard presentationTime.isFinite else {
                failLocked(HostHEVCAnnexBFileConsumerError.invalidPresentationTime)
                return .failed
            }
            let relativeTime: Double
            if let firstPresentationTime {
                relativeTime = presentationTime - firstPresentationTime
                guard relativeTime >= 0, relativeTime.isFinite else {
                    failLocked(HostHEVCAnnexBFileConsumerError.invalidPresentationTime)
                    return .failed
                }
            } else {
                relativeTime = 0
            }
            if relativeTime > configuration.maximumDurationSeconds {
                finishLocked(reason: .durationLimit)
                return .finishedAtDurationLimit
            }

            let includeParameterSets = samplesWritten == 0 || sample.isKeyFrame
            let bytes: Data
            do {
                bytes = try converter.convert(
                    parameterSets: sample.parameterSets,
                    accessUnit: sample.accessUnit,
                    prependParameterSets: includeParameterSets)
            } catch {
                failLocked(error)
                return .failed
            }
            guard bytes.count <= configuration.maximumBytes - bytesWritten else {
                finishLocked(reason: .byteLimit)
                return .finishedAtByteLimit
            }
            guard let fileHandle else {
                failLocked(HostHEVCAnnexBFileConsumerError.writeFailed)
                return .failed
            }
            do {
                try fileHandle.write(contentsOf: bytes)
            } catch {
                failLocked(HostHEVCAnnexBFileConsumerError.writeFailed)
                return .failed
            }
            bytesWritten += bytes.count
            samplesWritten += 1
            if firstPresentationTime == nil {
                firstPresentationTime = presentationTime
            }
            lastPresentationTime = presentationTime
            lastSequence = sample.sequence
            return .accepted
        }
    }

    /// Flushes and atomically publishes the final file. Calling this more
    /// than once is harmless and returns the resulting terminal snapshot.
    @discardableResult
    public func finish() -> HostHEVCAnnexBFileConsumerSnapshot {
        lock.withLock {
            guard phase == .running else { return makeSnapshot() }
            finishLocked(reason: .explicitlyStopped)
            return makeSnapshot()
        }
    }

    /// Removes the temporary file. A cancelled recording never replaces a
    /// caller's existing final file.
    @discardableResult
    public func cancel() -> HostHEVCAnnexBFileConsumerSnapshot {
        lock.withLock {
            guard phase == .running else { return makeSnapshot() }
            closeAndRemoveTemporaryLocked()
            phase = .cancelled
            return makeSnapshot()
        }
    }

    /// Fences the previous capture identity and starts a fresh temporary
    /// recording at the same user-selected path. No old bytes survive a
    /// reconnect, and a final file that was already published is never
    /// replaced.
    @discardableResult
    public func rebind(sessionID: String, generation: UInt64) -> Bool {
        lock.withLock {
            guard phase == .running else { return false }
            let reboundSession = String(sessionID.prefix(128))
            guard !reboundSession.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  generation > 0 else {
                failLocked(HostHEVCAnnexBFileConsumerError.invalidIdentity)
                return false
            }
            closeAndRemoveTemporaryLocked()
            guard openTemporaryLocked() else { return false }
            self.sessionID = reboundSession
            self.generation = generation
            bytesWritten = 0
            samplesWritten = 0
            firstPresentationTime = nil
            lastPresentationTime = nil
            lastSequence = nil
            finishReason = nil
            finalFilePublished = false
            failureCode = nil
            return true
        }
    }

    private func finishLocked(reason: HostHEVCAnnexBFileFinishReason) {
        guard phase == .running else { return }
        finishReason = reason
        guard let fileHandle, let temporaryURL else {
            failLocked(HostHEVCAnnexBFileConsumerError.finalizeFailed)
            return
        }
        do {
            try fileHandle.synchronize()
            try fileHandle.close()
            self.fileHandle = nil
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                try? FileManager.default.removeItem(at: temporaryURL)
                self.temporaryURL = nil
                phase = .failed
                failureCode = code(HostHEVCAnnexBFileConsumerError.outputAlreadyExists)
                return
            }
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            self.temporaryURL = nil
            phase = .finished
            finalFilePublished = true
        } catch {
            self.fileHandle = nil
            try? FileManager.default.removeItem(at: temporaryURL)
            self.temporaryURL = nil
            phase = .failed
            failureCode = code(HostHEVCAnnexBFileConsumerError.finalizeFailed)
        }
    }

    private func failLocked(_ error: Error) {
        closeAndRemoveTemporaryLocked()
        phase = .failed
        if let known = error as? HostHEVCAnnexBFileConsumerError {
            failureCode = code(known)
        } else if let conversion = error as? HostHEVCAnnexBConversionError {
            failureCode = "host_hevc_annex_b_" + String(describing: conversion)
        } else {
            failureCode = "host_hevc_annex_b_write_failed"
        }
    }

    private func closeAndRemoveTemporaryLocked() {
        try? fileHandle?.close()
        fileHandle = nil
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        temporaryURL = nil
    }

    private func openTemporaryLocked() -> Bool {
        let parent = outputURL.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: nil,
            attributes: [FileAttributeKey.posixPermissions: 0o600]) else {
            phase = .failed
            failureCode = code(HostHEVCAnnexBFileConsumerError.cannotOpenTemporaryFile)
            return false
        }
        do {
            fileHandle = try FileHandle(forWritingTo: temporary)
            temporaryURL = temporary
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            phase = .failed
            failureCode = code(HostHEVCAnnexBFileConsumerError.cannotOpenTemporaryFile)
            return false
        }
    }

    private func makeSnapshot() -> HostHEVCAnnexBFileConsumerSnapshot {
        let duration: Double?
        if let firstPresentationTime, let lastPresentationTime {
            let value = lastPresentationTime - firstPresentationTime
            duration = value.isFinite && value >= 0 ? value : nil
        } else {
            duration = nil
        }
        return HostHEVCAnnexBFileConsumerSnapshot(
            phase: phase,
            outputPath: outputURL.path,
            sessionID: sessionID,
            generation: generation,
            maximumBytes: configuration.maximumBytes,
            maximumDurationSeconds: configuration.maximumDurationSeconds,
            bytesWritten: bytesWritten,
            samplesWritten: samplesWritten,
            durationSeconds: duration,
            lastSequence: lastSequence,
            finishReason: finishReason,
            finalFilePublished: finalFilePublished,
            failureCode: failureCode)
    }

    private func code(_ error: HostHEVCAnnexBFileConsumerError) -> String {
        switch error {
        case .invalidIdentity: "host_hevc_file_invalid_identity"
        case .outputAlreadyExists: "host_hevc_file_output_exists"
        case .parentDirectoryMissing: "host_hevc_file_parent_missing"
        case .cannotOpenTemporaryFile: "host_hevc_file_open_failed"
        case .staleSession: "host_hevc_file_stale_session"
        case .staleGeneration: "host_hevc_file_stale_generation"
        case .sequenceOutOfOrder: "host_hevc_file_sequence_out_of_order"
        case .invalidPresentationTime: "host_hevc_file_invalid_presentation_time"
        case .writeFailed: "host_hevc_file_write_failed"
        case .finalizeFailed: "host_hevc_file_finalize_failed"
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
