import Foundation
import Testing
@testable import Pocket3Core

@Suite("Native ActiveTrack touch calibration")
struct NativeActiveTrackCalibrationTests {
    private let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let peripheralID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func point(_ x: Double, _ y: Double,
                       rotation: NativeTapFocusRotation,
                       mirrored: Bool) throws -> NativeActiveTrackCalibrationPoint {
        let base = NativeActiveTrackCoordinateTransform(
            rotation: rotation, mirrored: mirrored, sampleCount: 3,
            maximumResidual: 0, rootMeanSquareResidual: 0, verified: false)
        let mapped = try #require(base.map(x: x, y: y))
        return try NativeActiveTrackCalibrationPoint(
            displayX: x, displayY: y,
            cameraX: mapped.x, cameraY: mapped.y)
    }

    @Test func fitsExplicitRotationAndMirrorAndMapsBox() throws {
        var workflow = try NativeActiveTrackCalibrationWorkflow(
            sessionID: sessionID, peripheralID: peripheralID, generation: 3)
        try workflow.start()
        for value in [(0.2, 0.25), (0.7, 0.3), (0.35, 0.8)] {
            try workflow.append(try point(value.0, value.1,
                rotation: .ninety, mirrored: true))
        }
        let result = try workflow.finish()
        #expect(result.verified)
        #expect(result.transform?.rotation == .ninety)
        #expect(result.transform?.mirrored == true)
        #expect(result.validationCalibration == .cameraNativeCoordinates)
        let box = try Pocket3TrackingBox(
            centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.3)
        let mapped = try #require(result.transform?.map(box))
        #expect(mapped.width == 0.3 && mapped.height == 0.2)
    }

    @Test func insufficientOrSymmetricSamplesCannotUnlockWriter() throws {
        var insufficient = try NativeActiveTrackCalibrationWorkflow(
            sessionID: sessionID, peripheralID: peripheralID, generation: 1)
        try insufficient.start()
        try insufficient.append(displayX: 0.2, displayY: 0.2,
                                cameraX: 0.2, cameraY: 0.2)
        #expect(throws: NativeActiveTrackCalibrationError.insufficientPoints) {
            try insufficient.finish()
        }
        #expect(insufficient.result?.validationCalibration == .unverified)

        var symmetric = try NativeActiveTrackCalibrationWorkflow(
            sessionID: sessionID, peripheralID: peripheralID, generation: 1)
        try symmetric.start()
        for value in [(0.45, 0.45), (0.55, 0.55), (0.45, 0.55)] {
            try symmetric.append(displayX: value.0, displayY: value.1,
                                 cameraX: value.0, cameraY: value.1)
        }
        let result = try symmetric.finish()
        #expect(!result.verified)
        #expect(result.failureCode ==
                "active_track_calibration_transform_unverified" ||
                result.failureCode ==
                "active_track_calibration_asymmetric_points_required")
        #expect(result.validationCalibration == .unverified)
    }

    @Test func workflowIdentityAndPointLimitsAreFenced() throws {
        #expect(throws: NativeActiveTrackCalibrationError.invalidIdentity) {
            try NativeActiveTrackCalibrationWorkflow(
                sessionID: sessionID, peripheralID: peripheralID, generation: 0)
        }
        var workflow = try NativeActiveTrackCalibrationWorkflow(
            sessionID: sessionID, peripheralID: peripheralID, generation: 2)
        #expect(throws: NativeActiveTrackCalibrationError.notCollecting) {
            try workflow.append(displayX: 0.5, displayY: 0.5,
                                cameraX: 0.5, cameraY: 0.5)
        }
        try workflow.start()
        #expect(throws: NativeActiveTrackCalibrationError.invalidPoint) {
            try workflow.append(displayX: 1.1, displayY: 0.5,
                                cameraX: 0.5, cameraY: 0.5)
        }
        _ = workflow.cancel()
        #expect(workflow.result?.phase == .cancelled)
        #expect(workflow.result?.validationCalibration == .unverified)
    }
}
