import Foundation

/// Normalized display point paired with the point the camera reported for the
/// same local touch/calibration mark. Both points use 0...1 coordinates. The
/// sample is scalar evidence only; it does not submit an A6 command.
public struct NativeActiveTrackCalibrationPoint: Codable, Sendable,
    Equatable, Hashable {
    public let displayX: Double
    public let displayY: Double
    public let cameraX: Double
    public let cameraY: Double

    public init(displayX: Double, displayY: Double,
                cameraX: Double, cameraY: Double) throws {
        guard [displayX, displayY, cameraX, cameraY].allSatisfy({
            $0.isFinite && (0...1).contains($0)
        }) else {
            throw NativeActiveTrackCalibrationError.invalidPoint
        }
        self.displayX = displayX
        self.displayY = displayY
        self.cameraX = cameraX
        self.cameraY = cameraY
    }
}

public enum NativeActiveTrackCalibrationPhase: String, Codable, Sendable,
    Equatable, CaseIterable {
    case idle
    case collecting
    case completed
    case failed
    case cancelled
}

/// Candidate transform from the app's displayed normalized coordinates to the
/// camera's A6/A89 normalized coordinates. Rotation is clockwise; mirroring is
/// a horizontal flip after rotation. This convention is explicit so a future
/// hardware result cannot silently swap portrait axes.
public struct NativeActiveTrackCoordinateTransform: Codable, Sendable,
    Equatable, Hashable {
    public let rotation: NativeTapFocusRotation
    public let mirrored: Bool
    public let sampleCount: Int
    public let maximumResidual: Double
    public let rootMeanSquareResidual: Double
    public let verified: Bool

    public init(rotation: NativeTapFocusRotation,
                mirrored: Bool,
                sampleCount: Int,
                maximumResidual: Double,
                rootMeanSquareResidual: Double,
                verified: Bool) {
        self.rotation = rotation
        self.mirrored = mirrored
        self.sampleCount = sampleCount
        self.maximumResidual = maximumResidual
        self.rootMeanSquareResidual = rootMeanSquareResidual
        self.verified = verified
    }

    public static let unverified = Self(
        rotation: .zero, mirrored: false, sampleCount: 0,
        maximumResidual: .infinity, rootMeanSquareResidual: .infinity,
        verified: false)

    /// Maps one displayed normalized point into camera coordinates.
    public func map(x: Double, y: Double) -> (x: Double, y: Double)? {
        guard x.isFinite, y.isFinite, (0...1).contains(x),
              (0...1).contains(y) else { return nil }
        let rotated: (Double, Double)
        switch rotation {
        case .zero: rotated = (x, y)
        case .ninety: rotated = (1 - y, x)
        case .oneEighty: rotated = (1 - x, 1 - y)
        case .twoSeventy: rotated = (y, 1 - x)
        }
        let mappedX = mirrored ? 1 - rotated.0 : rotated.0
        return (mappedX, rotated.1)
    }

    /// Maps a top-left/size box while preserving the A6/A89 wire convention
    /// of center plus size. At 90°/270° the dimensions swap.
    public func map(_ box: Pocket3TrackingBox) -> Pocket3TrackingBox? {
        guard let center = map(x: box.centerX, y: box.centerY) else {
            return nil
        }
        let swaps = rotation == .ninety || rotation == .twoSeventy
        let width = swaps ? box.height : box.width
        let height = swaps ? box.width : box.height
        guard let mapped = try? Pocket3TrackingBox(
            centerX: center.x, centerY: center.y,
            width: width, height: height) else { return nil }
        return mapped
    }
}

public struct NativeActiveTrackCalibrationResult: Codable, Sendable,
    Equatable {
    public let sessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public let phase: NativeActiveTrackCalibrationPhase
    public let points: [NativeActiveTrackCalibrationPoint]
    public let transform: NativeActiveTrackCoordinateTransform?
    public let failureCode: String?

    public init(sessionID: UUID, peripheralID: UUID, generation: UInt64,
                phase: NativeActiveTrackCalibrationPhase,
                points: [NativeActiveTrackCalibrationPoint],
                transform: NativeActiveTrackCoordinateTransform? = nil,
                failureCode: String? = nil) {
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.generation = generation
        self.phase = phase
        self.points = points
        self.transform = transform
        self.failureCode = failureCode
    }

    public var verified: Bool { transform?.verified == true && phase == .completed }

    /// The value accepted by the existing ActiveTrack writer gate. A caller
    /// must retain this result together with its exact session identity.
    public var validationCalibration: Pocket3TrackingCoordinateCalibration {
        verified ? .cameraNativeCoordinates : .unverified
    }
}

public enum NativeActiveTrackCalibrationError: Error, Codable, Sendable,
    Equatable {
    case invalidIdentity
    case invalidPoint
    case tooManyPoints
    case notCollecting
    case insufficientPoints
    case asymmetricPointsRequired
}

/// Local touch calibration workflow. It fits only the eight explicit
/// rotation/mirror transforms; scale, shear and arbitrary affine warps are
/// rejected so a convenient but unproven mapping cannot unlock A6.
public struct NativeActiveTrackCalibrationWorkflow: Sendable {
    public static let minimumPoints = 3
    public static let maximumPoints = 8
    public static let maximumResidual: Double = 0.035
    public static let maximumRMSResidual: Double = 0.025

    public let sessionID: UUID
    public let peripheralID: UUID
    public let generation: UInt64
    public private(set) var phase: NativeActiveTrackCalibrationPhase = .idle
    public private(set) var points: [NativeActiveTrackCalibrationPoint] = []
    public private(set) var result: NativeActiveTrackCalibrationResult?

    public init(sessionID: UUID, peripheralID: UUID, generation: UInt64) throws {
        guard generation > 0 else {
            throw NativeActiveTrackCalibrationError.invalidIdentity
        }
        self.sessionID = sessionID
        self.peripheralID = peripheralID
        self.generation = generation
    }

    public mutating func start() throws {
        guard phase == .idle || phase == .failed || phase == .cancelled else {
            throw NativeActiveTrackCalibrationError.notCollecting
        }
        phase = .collecting
        points = []
        result = nil
    }

    @discardableResult
    public mutating func append(_ point: NativeActiveTrackCalibrationPoint)
        throws -> Int {
        guard phase == .collecting else {
            throw NativeActiveTrackCalibrationError.notCollecting
        }
        guard points.count < Self.maximumPoints else {
            throw NativeActiveTrackCalibrationError.tooManyPoints
        }
        points.append(point)
        return points.count
    }

    /// Convenience touch entry that validates all four coordinates before it
    /// mutates the workflow.
    @discardableResult
    public mutating func append(displayX: Double, displayY: Double,
                                cameraX: Double, cameraY: Double) throws -> Int {
        try append(NativeActiveTrackCalibrationPoint(
            displayX: displayX, displayY: displayY,
            cameraX: cameraX, cameraY: cameraY))
    }

    @discardableResult
    public mutating func finish() throws -> NativeActiveTrackCalibrationResult {
        guard phase == .collecting else {
            throw NativeActiveTrackCalibrationError.notCollecting
        }
        guard points.count >= Self.minimumPoints else {
            phase = .failed
            let value = NativeActiveTrackCalibrationResult(
                sessionID: sessionID, peripheralID: peripheralID,
                generation: generation, phase: phase, points: points,
                failureCode: "active_track_calibration_insufficient_points")
            result = value
            throw NativeActiveTrackCalibrationError.insufficientPoints
        }
        guard asymmetric(points) else {
            phase = .failed
            let value = NativeActiveTrackCalibrationResult(
                sessionID: sessionID, peripheralID: peripheralID,
                generation: generation, phase: phase, points: points,
                failureCode: "active_track_calibration_asymmetric_points_required")
            result = value
            throw NativeActiveTrackCalibrationError.asymmetricPointsRequired
        }

        var best: NativeActiveTrackCoordinateTransform?
        for rotation in NativeTapFocusRotation.allCases {
            for mirrored in [false, true] {
                let residuals = points.compactMap { point -> Double? in
                    let transform = NativeActiveTrackCoordinateTransform(
                        rotation: rotation, mirrored: mirrored,
                        sampleCount: points.count,
                        maximumResidual: 0,
                        rootMeanSquareResidual: 0, verified: false)
                    guard let mapped = transform.map(
                        x: point.displayX, y: point.displayY) else { return nil }
                    return hypot(mapped.x - point.cameraX,
                                 mapped.y - point.cameraY)
                }
                guard residuals.count == points.count,
                      let maximum = residuals.max() else { continue }
                let rms = sqrt(residuals.reduce(0) { $0 + $1 * $1 } /
                               Double(residuals.count))
                let candidate = NativeActiveTrackCoordinateTransform(
                    rotation: rotation, mirrored: mirrored,
                    sampleCount: points.count,
                    maximumResidual: maximum,
                    rootMeanSquareResidual: rms,
                    verified: maximum <= Self.maximumResidual &&
                        rms <= Self.maximumRMSResidual)
                if best == nil || candidate.rootMeanSquareResidual <
                    best!.rootMeanSquareResidual {
                    best = candidate
                }
            }
        }
        guard let best, best.verified else {
            phase = .failed
            let value = NativeActiveTrackCalibrationResult(
                sessionID: sessionID, peripheralID: peripheralID,
                generation: generation, phase: phase, points: points,
                transform: best,
                failureCode: "active_track_calibration_transform_unverified")
            result = value
            return value
        }
        phase = .completed
        let value = NativeActiveTrackCalibrationResult(
            sessionID: sessionID, peripheralID: peripheralID,
            generation: generation, phase: phase, points: points,
            transform: best)
        result = value
        return value
    }

    @discardableResult
    public mutating func cancel() -> NativeActiveTrackCalibrationResult {
        phase = .cancelled
        let value = NativeActiveTrackCalibrationResult(
            sessionID: sessionID, peripheralID: peripheralID,
            generation: generation, phase: phase, points: points,
            failureCode: "cancelled")
        result = value
        return value
    }

    private func asymmetric(_ points: [NativeActiveTrackCalibrationPoint]) -> Bool {
        guard let minX = points.map(\.displayX).min(),
              let maxX = points.map(\.displayX).max(),
              let minY = points.map(\.displayY).min(),
              let maxY = points.map(\.displayY).max() else { return false }
        return maxX - minX >= 0.2 && maxY - minY >= 0.2
    }
}

public typealias Pocket3ActiveTrackCalibrationPoint = NativeActiveTrackCalibrationPoint
public typealias Pocket3ActiveTrackCoordinateTransform = NativeActiveTrackCoordinateTransform
public typealias Pocket3ActiveTrackCalibrationResult = NativeActiveTrackCalibrationResult
public typealias Pocket3ActiveTrackCalibrationWorkflow = NativeActiveTrackCalibrationWorkflow
