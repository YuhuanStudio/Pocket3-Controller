import Testing
@testable import Pocket3Core

@Suite struct ValidationPositionProbeTests {
    private func request(pan: JSONValue? = nil, tilt: JSONValue? = .number(-1.6),
                         expectedPan: JSONValue = .number(360), expectedTilt: JSONValue = .number(-9360)) -> JSONValue {
        var fields = ["expectedPanRaw": expectedPan, "expectedTiltRaw": expectedTilt]
        if let pan { fields["panDegrees"] = pan }
        if let tilt { fields["tiltDegrees"] = tilt }
        return .object(fields)
    }
    private func capabilities(position: GimbalPosition = .init(pan: 360, tilt: -9360)) -> UVCCapabilities {
        UVCCapabilities(location: 1, position: position, minimum: .init(pan: -126000, tilt: -324000),
            maximum: .init(pan: 774000, tilt: 324000), step: .init(pan: 3600, tilt: 3600),
            writable: true, controls: ["pan-tilt-abs"], uvcVersion: 256)
    }

    @Test func oneAxisProbeUsesFreshOriginAndPreservesOtherAxis() throws {
        let probe = try ValidationPositionProbe(arguments: request())
        #expect(try probe.target(from: capabilities()) == .init(pan: 360, tilt: -5760))
        let crossZero = try ValidationPositionProbe(arguments: request(tilt: .number(0.1)))
        #expect(try crossZero.target(from: capabilities()) == .init(pan: 360, tilt: 360))
        let pan = try ValidationPositionProbe(arguments: request(pan: .number(1.1), tilt: nil))
        #expect(try pan.target(from: capabilities()) == .init(pan: 3960, tilt: -9360))
    }

    @Test func originMustMatchBothRawAxesExactly() throws {
        let probe = try ValidationPositionProbe(arguments: request())
        for changed in [GimbalPosition(pan: 720, tilt: -9360), .init(pan: 360, tilt: -9000)] {
            #expect(throws: BridgeFailure("probe_origin_changed", "新鮮 USB 原點與預期值不符，沒有送出探測指令")) {
                try probe.target(from: capabilities(position: changed))
            }
        }
    }

    @Test func fiveDegreeLimitIsCheckedBeforeRoundingAndHugeValuesNeverOverflow() throws {
        let boundary = try ValidationPositionProbe(arguments: request(tilt: .number(2.4)))
        #expect(try boundary.target(from: capabilities()).tilt == 8640)
        for target in [2.40001, -7.60001, Double.greatestFiniteMagnitude] {
            let probe = try ValidationPositionProbe(arguments: request(tilt: .number(target)))
            #expect(throws: BridgeFailure.self) { try probe.target(from: capabilities()) }
        }
    }

    @Test func malformedOrNonProbeArgumentsAreRejectedWithoutHardwareAccess() {
        let invalid = [
            request(pan: .number(0)), request(tilt: nil), request(tilt: .number(.nan)),
            request(tilt: .string("home")), request(expectedPan: .number(360.5)),
            request(expectedPan: .number(Double(Int32.max) + 1)), request(expectedTilt: .null),
            JSONValue.object(["direction": .string("back"), "expectedPanRaw": .number(360), "expectedTiltRaw": .number(-9360)]),
        ]
        for arguments in invalid { #expect(throws: BridgeFailure.self) { try ValidationPositionProbe(arguments: arguments) } }
    }

    @Test func advertisedBoundsAndValidOriginStillApply() throws {
        var readOnly = capabilities(); readOnly.writable = false
        let probe = try ValidationPositionProbe(arguments: request())
        #expect(throws: BridgeFailure.self) { try probe.target(from: readOnly) }
        let outside = GimbalPosition(pan: 360, tilt: -324360)
        let recovery = try ValidationPositionProbe(arguments: request(tilt: .number(-90), expectedTilt: .number(-324360)))
        #expect(throws: BridgeFailure.self) { try recovery.target(from: capabilities(position: outside)) }
    }

    @Test func serviceRefusesProbeWithoutDeveloperValidation() async {
        let service = CameraService()
        let reply = await service.handle(ServiceRequest(token: "fixture", operation: "validation-position-probe", arguments: request()))
        #expect(reply.error?.code == "validation_disabled")
        let developer = CameraService(validationEnabled: true)
        let malformed = await developer.handle(ServiceRequest(token: "fixture", operation: "validation-position-probe", arguments: request(pan: .number(0))))
        #expect(malformed.error?.code == "invalid_position_probe")
    }
}
