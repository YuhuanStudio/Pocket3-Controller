import Testing
@testable import Pocket3Core

@Suite("Absolute UVC navigation policy") struct GimbalNavigationTests {
    private func capabilities(
        minimum: GimbalPosition = .init(pan: -126_000, tilt: -324_000),
        maximum: GimbalPosition = .init(pan: 774_000, tilt: 324_000),
        defaultPosition: GimbalPosition? = .init(pan: 0, tilt: 0)
    ) -> UVCCapabilities {
        var value = UVCCapabilities(location: 1, position: .init(pan: 72_000, tilt: -32_400),
            minimum: minimum, maximum: maximum, step: .init(pan: 3600, tilt: 3600),
            writable: true, controls: ["pan-tilt-abs"], uvcVersion: 256)
        value.defaultPosition = defaultPosition
        return value
    }

    @Test func convertsDegreesAndPreservesOnlyOmittedAxes() throws {
        let cap = capabilities()
        #expect(try GimbalNavigationPolicy.absolute(panDegrees: -12.5, origin: cap.position, capabilities: cap)
            == .init(pan: -45_000, tilt: -32_400))
        #expect(try GimbalNavigationPolicy.absolute(tiltDegrees: 5.25, origin: cap.position, capabilities: cap)
            == .init(pan: 72_000, tilt: 18_900))
        #expect(try GimbalNavigationPolicy.absolute(panDegrees: -35, tiltDegrees: 90, origin: cap.position, capabilities: cap)
            == .init(pan: -126_000, tilt: 324_000))
    }

    @Test func rejectsNonfiniteHugeEmptyAndOutOfRangeTargets() {
        let cap = capabilities()
        for angle in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 215.01, -35.01] {
            #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.absolute(panDegrees: angle, origin: cap.position, capabilities: cap) }
        }
        #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.absolute(origin: cap.position, capabilities: cap) }
        #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.absolute(tiltDegrees: 90.01, origin: cap.position, capabilities: cap) }
    }

    @Test func explicitRecoveryDoesNotPermitAnOmittedInvalidAxis() throws {
        let cap = capabilities(), invalid = GimbalPosition(pan: .max, tilt: .min)
        #expect(try GimbalNavigationPolicy.absolute(panDegrees: 0, tiltDegrees: 0, origin: invalid, capabilities: cap)
            == .init(pan: 0, tilt: 0))
        #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.absolute(panDegrees: 0, origin: invalid, capabilities: cap) }
        #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.absolute(tiltDegrees: 0, origin: invalid, capabilities: cap) }
        #expect(throws: BridgeFailure.self) { try MotionPolicy.target(direction: "left", origin: invalid, capabilities: cap) }
    }

    @Test func homeUsesDeviceDefaultInsteadOfInventingZeroOrCurrentPosition() throws {
        let expected = GimbalPosition(pan: 36_000, tilt: -18_000), cap = capabilities(defaultPosition: expected)
        #expect(try GimbalNavigationPolicy.home(capabilities: cap) == expected)
        #expect(try GimbalNavigationPolicy.front(capabilities: cap) == expected)
        #expect(try GimbalNavigationPolicy.preset(named: "home", capabilities: cap) == expected)
        #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.home(capabilities: capabilities(defaultPosition: nil)) }
        #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.home(capabilities: capabilities(defaultPosition: .init(pan: .max, tilt: 0))) }
        #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.preset(named: "native-dji-flip", capabilities: cap) }
    }

    @Test func backUsesAnInRangeHalfTurnAndPreservesDefaultTilt() throws {
        let cap = capabilities(defaultPosition: .init(pan: 36_000, tilt: -18_000))
        #expect(try GimbalNavigationPolicy.back(capabilities: cap) == .init(pan: 684_000, tilt: -18_000))
        let reverse = capabilities(minimum: .init(pan: -774_000, tilt: -324_000), maximum: .init(pan: 126_000, tilt: 324_000), defaultPosition: .init(pan: 36_000, tilt: -18_000))
        #expect(try GimbalNavigationPolicy.back(capabilities: reverse) == .init(pan: -612_000, tilt: -18_000))
        let narrow = capabilities(minimum: .init(pan: -3600, tilt: -3600), maximum: .init(pan: 3600, tilt: 3600))
        #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.back(capabilities: narrow) }
    }

    @Test func integerExtremesCannotOverflowAndPresetIsIndependentOfCurrentPosition() throws {
        var wide = capabilities(minimum: .init(pan: .min, tilt: .min), maximum: .init(pan: .max, tilt: .max))
        wide.position.pan = -648_000
        #expect(try GimbalNavigationPolicy.back(capabilities: wide).pan == 648_000)
        wide.defaultPosition = .init(pan: .max, tilt: .max)
        #expect(try GimbalNavigationPolicy.back(capabilities: wide) == .init(pan: .max - 648_000, tilt: .max))
        wide.defaultPosition = .init(pan: .min, tilt: .min)
        #expect(try GimbalNavigationPolicy.back(capabilities: wide) == .init(pan: .min + 648_000, tilt: .min))
        #expect(try GimbalNavigationPolicy.absolute(panDegrees: 500_000, tiltDegrees: -500_000, origin: wide.position, capabilities: wide)
            == .init(pan: 1_800_000_000, tilt: -1_800_000_000))
    }

    @Test func invalidCapabilitiesDoNotAdmitAnyNavigation() {
        var readOnly = capabilities(); readOnly.writable = false
        var missing = capabilities(); missing.minimum = nil
        let reversed = capabilities(minimum: .init(pan: 1, tilt: 0), maximum: .init(pan: 0, tilt: 0))
        for cap in [readOnly, missing, reversed] {
            #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.absolute(panDegrees: 0, origin: cap.position, capabilities: cap) }
            #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.home(capabilities: cap) }
            #expect(throws: BridgeFailure.self) { try GimbalNavigationPolicy.back(capabilities: cap) }
        }
    }
}
