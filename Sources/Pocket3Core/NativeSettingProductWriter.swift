import Foundation

/// Product-facing result for one typed native setting transaction. The
/// transaction owner remains the caller's existing Pocket3Datalink adapter;
/// this value only reports the two correlated setting operations.
public struct NativeSettingProductWriteResult: Codable, Sendable, Equatable {
    public let action: NativeSettingValidationOperation
    public let target: Pocket3NativeSettingTarget
    public let baseline: Pocket3NativeSettingObservation
    public let targetResult: NativeSettingValidationResult
    public let restoreResult: NativeSettingValidationResult?
    public let requested: Bool
    public let submitted: Bool
    public let acknowledged: Bool
    public let observed: Bool
    public let restored: Bool
    public let completed: Bool
    public let unlocked: Bool
    public let failureCode: String?

    public var targetCompleted: Bool { targetResult.completed }

    public init(
        action: NativeSettingValidationOperation,
        target: Pocket3NativeSettingTarget,
        baseline: Pocket3NativeSettingObservation,
        targetResult: NativeSettingValidationResult,
        restoreResult: NativeSettingValidationResult?,
        restored: Bool,
        unlocked: Bool,
        failureCode: String?
    ) {
        self.action = action
        self.target = target
        self.baseline = baseline
        self.targetResult = targetResult
        self.restoreResult = restoreResult
        requested = true
        submitted = targetResult.submitted || restoreResult?.submitted == true
        acknowledged = targetResult.acknowledged &&
            (restoreResult?.acknowledged ?? true)
        observed = targetResult.observed && (restoreResult?.observed ?? true)
        self.restored = restored
        completed = targetResult.completed && restored
        self.unlocked = unlocked
        self.failureCode = failureCode
    }
}

public enum NativeSettingProductWriterError: Error, LocalizedError,
    Codable, Sendable, Equatable {
    case unsupportedSetting
    case executionNotUnlocked
    case executionRequired
    case restoreBaselineUnavailable
    case targetNotCompleted
    case restoreNotCompleted
    case restoreMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedSetting:
            "the native setting has no supported product writer"
        case .executionNotUnlocked:
            "the native setting writer is not unlocked by verified product evidence"
        case .executionRequired:
            "native setting product writes require explicit execution"
        case .restoreBaselineUnavailable:
            "the exact typed baseline cannot be restored safely"
        case .targetNotCompleted:
            "the native setting target did not receive matching ACK and readback"
        case .restoreNotCompleted:
            "the native setting baseline restore did not receive matching ACK and readback"
        case .restoreMismatch:
            "the restored native setting raw value does not match its captured baseline"
        }
    }
}

/// General-product wrapper around ``NativeSettingValidationService``.
///
/// Every product write requires an explicitly unlocked support entry. The
/// current evidence matrix keeps all four native setting candidates locked;
/// a future hardware acceptance update can unlock one entry independently by
/// setting its admission and executionAllowed fields. The writer still
/// requires command-ready state and a fresh exact baseline at every call.
public struct NativeSettingProductWriterService: Sendable {
    private let executor: NativeSettingValidationExecutorAdapter?
    private let support: Pocket3WriterSupportReport

    public init(
        adapter: NativeSettingValidationExecutorAdapter? = nil,
        support: Pocket3WriterSupportReport = .current
    ) {
        executor = adapter
        self.support = support
    }

    public func isUnlocked(
        for action: NativeSettingValidationOperation
    ) -> Bool {
        guard let entry = support.entry(for: Self.candidateID(for: action)) else {
            return false
        }
        return entry.admission == .locallyVerifiedWrite &&
            entry.executionAllowed && entry.availability.write &&
            entry.availability.verified &&
            entry.acknowledgedWrites > 0 &&
            entry.matchingReadbacksAfterWrite >= 2
    }

    public func write(
        _ request: NativeSettingValidationRequest,
        snapshot: NativeSettingValidationSnapshot
    ) async throws -> NativeSettingProductWriteResult {
        guard Self.candidateIDIfSupported(for: request.action) != nil else {
            throw NativeSettingProductWriterError.unsupportedSetting
        }
        guard request.execute else {
            throw NativeSettingProductWriterError.executionRequired
        }
        guard isUnlocked(for: request.action) else {
            throw NativeSettingProductWriterError.executionNotUnlocked
        }

        let targetResult = try await NativeSettingValidationService(
            adapter: executor).run(request, snapshot: snapshot)
        guard targetResult.completed else {
            throw NativeSettingProductWriterError.targetNotCompleted
        }
        guard let targetReadback = targetResult.setting?.readback else {
            throw NativeSettingProductWriterError.targetNotCompleted
        }
        guard let originalBaseline = snapshot.baseline,
              let restoreTarget = Self.restoreTarget(
            action: request.action, baseline: originalBaseline) else {
            throw NativeSettingProductWriterError.restoreBaselineUnavailable
        }

        // A second independently correlated transaction restores exactly the
        // captured setting. No retry or fallback transport is introduced.
        let restoreRequest = try NativeSettingValidationRequest(
            target: restoreTarget,
            expectedSessionID: request.expectedSessionID,
            peripheralID: request.peripheralID,
            generation: request.generation,
            execute: true,
            timeout: request.timeout)
        let restoreBaseline = NativeSettingValidationSnapshot(
            session: snapshot.session,
            baseline: targetReadback,
            nowUptime: max(snapshot.nowUptime,
                           targetReadback.receivedUptime))
        let restoreResult = try await NativeSettingValidationService(
            adapter: executor).run(restoreRequest, snapshot: restoreBaseline)
        guard restoreResult.completed else {
            throw NativeSettingProductWriterError.restoreNotCompleted
        }
        guard restoreResult.setting?.readback?.raw == originalBaseline.raw else {
            throw NativeSettingProductWriterError.restoreMismatch
        }
        return NativeSettingProductWriteResult(
            action: request.action,
            target: request.target,
            baseline: originalBaseline,
            targetResult: targetResult,
            restoreResult: restoreResult,
            restored: true,
            unlocked: true,
            failureCode: nil)
    }

    private static func candidateID(
        for action: NativeSettingValidationOperation
    ) -> Pocket3WriterCandidateID {
        switch action {
        case .whiteBalance: .whiteBalance
        case .focusMode: .focusMode
        case .colorProfile: .colorProfile
        case .productShowcase: .productShowcase
        }
    }

    private static func candidateIDIfSupported(
        for action: NativeSettingValidationOperation
    ) -> Pocket3WriterCandidateID? {
        switch action {
        case .whiteBalance: .whiteBalance
        case .focusMode: .focusMode
        case .colorProfile: .colorProfile
        case .productShowcase: .productShowcase
        }
    }

    private static func restoreTarget(
        action: NativeSettingValidationOperation,
        baseline: Pocket3NativeSettingObservation?
    ) -> Pocket3NativeSettingTarget? {
        guard let baseline else { return nil }
        switch action {
        case .whiteBalance:
            return baseline.readback.imageEffect?.whiteBalance.map {
                .whiteBalance($0)
            }
        case .focusMode:
            return baseline.readback.lensState?.focusMode.map {
                .focusMode($0)
            }
        case .colorProfile:
            return baseline.readback.imageEffect?.colorProfile.map {
                .colorProfile($0)
            }
        case .productShowcase:
            return baseline.readback.showcase?.mode.map {
                .productShowcase($0)
            }
        }
    }
}

public typealias Pocket3NativeSettingProductWriter =
    NativeSettingProductWriterService
