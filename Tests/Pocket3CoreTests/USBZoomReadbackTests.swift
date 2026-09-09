import Foundation
import Testing
@testable import Pocket3Core

// Recorded scalar facts from artifacts/hardware-resumed/zoom-final/result.json:
// bounds100...400, step1, hold target147, three matching readbacks, later146.
// The original artifact remains failed under its old exact-equality driver;
// these are offline policy fixtures, not a new hardware validation run.
private func recordedZoom(_ value: Int) -> USBZoomCapabilities {
    .init(current: value, minimum: 100, maximum: 400, step: 1, writable: true)
}

@Test func recordedZoomOneStepLateQuantizationFitsPublishedBoundedTolerance() throws {
    var verifier = try USBZoomReadbackVerifier(target: 147, capabilities: recordedZoom(147), minimumDuration: 0.8)
    #expect(verifier.toleranceRaw == 1)
    // Relative replay times: the late observation follows the three initial
    // samples by 0.8 s. They model the documented ordering, not raw USB timestamps.
    for time in [0.0, 0.08, 0.16] {
        let settled = try verifier.observe(recordedZoom(147), at: time)
        #expect(!settled)
    }
    let settled = try verifier.observe(recordedZoom(146), at: 0.96)
    #expect(settled && verifier.stableSampleCount == 4)
    #expect(verifier.stableDurationSeconds == 0.96)
}

@Test func zoomToleranceCannotExceedOneAdvertisedStepOrOnePercentOfRange() {
    #expect(USBZoomPolicy.readbackTolerance(capabilities: recordedZoom(147)) == 1)
    let cases: [(Int?, Int, Int)] = [(50,999,9), (1,50,0), (nil,300,0), (0,300,0), (-1,300,0), (1000,65535,655)]
    for (step, span, expected) in cases {
        let caps = USBZoomCapabilities(current: 0, minimum: 0, maximum: span, step: step, writable: true)
        let tolerance = USBZoomPolicy.readbackTolerance(capabilities: caps)
        #expect(tolerance == expected)
        #expect(Double(tolerance) <= Double(span) * 0.01)
        if let step, step > 0 { #expect(tolerance <= step) }
    }
}

@Test func zoomReadbackContinuingRampCannotAccumulateAdjacentOneStepErrors() throws {
    var verifier = try USBZoomReadbackVerifier(target: 147, capabilities: recordedZoom(147), minimumDuration: 0.8)
    let ramp = [147,147,147,148,149,150,151,152,153,154,155,156]
    for (index, current) in ramp.enumerated() {
        let settled = try verifier.observe(recordedZoom(current), at: Double(index) * 0.1)
        #expect(!settled)
    }
    #expect(verifier.stableSampleCount == 0)
}

@Test func zoomReadbackRejectsTwoStepWindowEvenWhenEverySampleIsNearTarget() throws {
    var verifier = try USBZoomReadbackVerifier(target: 147, capabilities: recordedZoom(147), minimumDuration: 0.2)
    for index in 0..<20 {
        let settled = try verifier.observe(recordedZoom(index.isMultiple(of: 2) ? 146 : 148), at: Double(index) * 0.1)
        #expect(!settled) // Whole span2 exceeds advertised one-step tolerance1.
    }
}

@Test func zoomReadbackSingleStepNoiseSettlesButLargeErrorAndReusedTimeDoNot() throws {
    var verifier = try USBZoomReadbackVerifier(target: 147, capabilities: recordedZoom(147))
    var settled = false
    for (index, current) in [147,146,147,146].enumerated() {
        settled = try verifier.observe(recordedZoom(current), at: Double(index) * 0.1)
    }
    #expect(settled)
    let largeError = try verifier.observe(recordedZoom(160), at: 0.5)
    #expect(!largeError && verifier.stableSampleCount == 0)
    #expect(throws: BridgeFailure.self) { try verifier.observe(recordedZoom(147), at: 0.5) }
    var changed = recordedZoom(147); changed.step = 2
    #expect(throws: BridgeFailure.self) { try verifier.observe(changed, at: 0.6) }
}
