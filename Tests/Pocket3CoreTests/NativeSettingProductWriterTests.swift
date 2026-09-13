import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native setting product writer", .serialized)
struct NativeSettingProductWriterTests {
    private let sessionID = UUID()
    private let peerID = UUID()

    private func readySession() -> NativeCameraSessionStatus {
        var session = NativeCameraSession()
        let generation = session.begin(sessionID: sessionID, peerID: peerID)
        _ = session.markPaired(generation: generation)
        _ = session.markCredentialsAvailable(generation: generation)
        _ = session.observeDatalink(.connecting, generation: generation)
        _ = session.observeDatalink(.ready, generation: generation)
        return session.status
    }

    private func imageEffectBaseline(
        _ status: NativeCameraSessionStatus,
        uptime: TimeInterval = 10
    ) -> Pocket3NativeSettingObservation {
        Pocket3NativeSettingObservation(
            sessionID: status.sessionID!, generation: status.generation,
            receivedUptime: uptime, property: .imageEffect,
            raw: Data([0, 0, 0, 0, 0, 0]))
    }

    private func propertyFrame(
        raw: Data,
        sequence: UInt16 = 9
    ) -> DUMLFrame {
        var bytes: [UInt8] = [2, 6, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        func append16(_ value: Int) {
            bytes += [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
        }
        let name = Array(CameraSettingsProperty.imageEffect.rawValue.utf8)
        append16(name.count + raw.count + 10)
        append16(name.count)
        bytes += name
        bytes += [0, 0, 0, 0, 0, 0]
        append16(raw.count)
        bytes += raw
        return DUMLFrame(
            source: 0x28, destination: 0x02, sequence: sequence, flags: 0,
            commandSet: 0, commandID: 0x99, payload: Data(bytes))
    }

    private func transaction(
        for request: NativeCommandTransactionRequest,
        observedPayload: Data?
    ) -> NativeCommandTransactionResult {
        var result = NativeCommandTransactionResult(
            id: request.id, command: request.command,
            generation: request.generation, sessionID: request.sessionID,
            end: observedPayload == nil ? .acknowledged : .observed)
        result.sequence = 0x6001
        result.submitted = true
        result.submittedUptime = 11
        result.responseReceived = true
        result.acknowledged = true
        result.acknowledgedUptime = 11.01
        result.observedPayload = observedPayload
        result.observed = observedPayload != nil
        result.observedUptime = observedPayload == nil ? nil : 12
        result.finishedUptime = 12
        return result
    }

    private func unlockedReport(
        for id: Pocket3WriterCandidateID = .whiteBalance
    ) throws -> Pocket3WriterSupportReport {
        let entries = Pocket3WriterSupportReport.current.entries.map {
            entry -> Pocket3WriterSupportEntry in
            guard entry.id == id else { return entry }
            return Pocket3WriterSupportEntry(
                id: entry.id, protocolStatus: entry.protocolStatus,
                evidence: entry.evidence,
                packetEvidence: entry.packetEvidence,
                readbackEvidence: entry.readbackEvidence,
                availability: CapabilityAvailability(
                    read: true, write: true, verified: true,
                    reason: nil),
                admission: .locallyVerifiedWrite,
                executionAllowed: true,
                candidateOperation: entry.candidateOperation,
                writeAttempts: entry.writeAttempts,
                acknowledgedWrites: 2,
                matchingReadbacksAfterWrite: 2,
                reason: "test evidence",
                nextValidation: entry.nextValidation,
                nextValidationNote: entry.nextValidationNote)
        }
        return Pocket3WriterSupportReport(entries: entries)
    }

    private func request(
        status: NativeCameraSessionStatus,
        execute: Bool = true
    ) throws -> NativeSettingValidationRequest {
        try NativeSettingValidationRequest(
            action: .whiteBalance,
            expectedSessionID: sessionID,
            peripheralID: peerID,
            generation: status.generation,
            target: .whiteBalance(.customKelvin(5600)),
            execute: execute, timeout: 3)
    }

    @Test func unlockedWriterSubmitsTargetThenRestoresCapturedRawBaseline()
        async throws {
        let status = readySession()
        let baseline = imageEffectBaseline(status)
        let requests = LockedBox<[NativeCommandTransactionRequest]>([])
        let adapter = NativeSettingValidationExecutorAdapter { request, _ in
            requests.withValue { $0.append(request) }
            let raw = requests.value.count == 1
                ? Data([0, 0, 0, 0, 0x06, 0x38])
                : baseline.raw
            let observed = request.observationHandler()!(self.propertyFrame(raw: raw))
            var result = self.transaction(for: request, observedPayload: observed)
            if requests.value.count == 2 {
                result.submittedUptime = 12.1
                result.acknowledgedUptime = 12.2
                result.observedUptime = 13
                result.finishedUptime = 13
            }
            return result
        }
        let writer = NativeSettingProductWriterService(
            adapter: adapter, support: try unlockedReport())
        let result = try await writer.write(
            try request(status: status),
            snapshot: NativeSettingValidationSnapshot(
                session: status, baseline: baseline, nowUptime: 10))

        #expect(result.completed && result.restored && result.unlocked)
        #expect(result.targetResult.completed)
        #expect(result.restoreResult?.completed == true)
        #expect(result.restoreResult?.setting?.readback?.raw == baseline.raw)
        #expect(requests.value.count == 2)
        #expect(requests.value[0].frame.commandID == 0x2C)
        #expect(requests.value[0].frame.payload == Data([6, 0x38, 0, 0, 0]))
        #expect(requests.value[1].frame.payload == Data([0, 0, 0, 0, 0]))
    }

    @Test func lockedOrNonExplicitRequestsNeverReachTheDatalinkAdapter()
        async throws {
        let status = readySession()
        let baseline = imageEffectBaseline(status)
        let count = LockedBox(0)
        let adapter = NativeSettingValidationExecutorAdapter { _, _ in
            count.withValue { $0 += 1 }
            throw NativeCommandTransactionError.datalinkUnavailable
        }
        let locked = NativeSettingProductWriterService(adapter: adapter)
        await #expect(throws: NativeSettingProductWriterError.executionNotUnlocked) {
            try await locked.write(
                try self.request(status: status),
                snapshot: NativeSettingValidationSnapshot(
                    session: status, baseline: baseline, nowUptime: 10))
        }
        await #expect(throws: NativeSettingProductWriterError.executionRequired) {
            try await NativeSettingProductWriterService(
                adapter: adapter, support: try self.unlockedReport()).write(
                    try self.request(status: status, execute: false),
                    snapshot: NativeSettingValidationSnapshot(
                        session: status, baseline: baseline, nowUptime: 10))
        }
        #expect(count.value == 0)
    }

    @Test func targetACKWithoutReadbackBlocksRestoreAndCompletion()
        async throws {
        let status = readySession()
        let baseline = imageEffectBaseline(status)
        let count = LockedBox(0)
        let adapter = NativeSettingValidationExecutorAdapter { request, _ in
            count.withValue { $0 += 1 }
            return self.transaction(for: request, observedPayload: nil)
        }
        let writer = NativeSettingProductWriterService(
            adapter: adapter, support: try unlockedReport())
        await #expect(throws: NativeSettingProductWriterError.targetNotCompleted) {
            try await writer.write(
                try self.request(status: status),
                snapshot: NativeSettingValidationSnapshot(
                    session: status, baseline: baseline, nowUptime: 10))
        }
        #expect(count.value == 1)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var valueStorage: Value

    init(_ value: Value) { valueStorage = value }

    var value: Value { lock.withLock { valueStorage } }

    func withValue(_ body: (inout Value) -> Void) {
        lock.withLock { body(&valueStorage) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
