import Foundation
import Pocket3Core
import YunDesign

/// Read-only presentation for the typed `cam_expo_param` observation. The
/// formatter keeps raw selectors visible when a local enum is not known and
/// never turns a missing value into a guessed Auto/Manual setting.
enum ExposurePresentation {
    static func summary(
        _ readback: Pocket3ExposureReadback?,
        isoLimit: Pocket3AdvancedSettingObservation?
    ) -> String {
        guard let readback else { return loc("Readback pending") }
        var values = [mode(readback)]
        switch readback.exposureMode {
        case .automatic: values.append(ev(readback))
        case .manual: values.append(selectedISO(readback))
        case nil: break
        }
        if isoLimit != nil { values.append(isoLimitValue(isoLimit)) }
        return values.joined(separator: " · ")
    }

    static func mode(_ readback: Pocket3ExposureReadback?) -> String {
        guard let readback else { return loc("Unknown") }
        switch readback.exposureMode {
        case .automatic: return loc("Auto")
        case .manual: return loc("Manual exposure")
        case nil: return unknownRaw(readback.exposureModeRaw)
        }
    }

    static func ev(_ readback: Pocket3ExposureReadback?) -> String {
        guard let readback else { return loc("Unknown") }
        return readback.ev?.label ?? unknownRaw(readback.evRaw)
    }

    static func selectedISO(_ readback: Pocket3ExposureReadback?) -> String {
        guard let readback else { return loc("Unknown") }
        guard let selectedISO = readback.selectedISO else {
            return unknownRaw(readback.selectedISORaw)
        }
        if let value = selectedISO.isoValue { return "ISO \(value)" }
        return loc("Auto")
    }

    static func effectiveISO(_ readback: Pocket3ExposureReadback?) -> String {
        guard let readback else { return loc("Unknown") }
        guard readback.effectiveISO > 0 else {
            return unknownRaw(readback.effectiveISO, width: 8)
        }
        return "ISO \(readback.effectiveISO)"
    }

    static func shutter(_ readback: Pocket3ExposureReadback?) -> String {
        guard let readback else { return loc("Unknown") }
        if let shutter = readback.shutter { return shutter.label }
        if let raw = readback.shutterRaw, !raw.isEmpty {
            return unknownRaw(raw)
        }
        return loc("Unknown")
    }

    static func isoLimitValue(
        _ observation: Pocket3AdvancedSettingObservation?
    ) -> String {
        guard let observation else { return loc("No current ISO limit readback") }
        switch observation.typedValue {
        case .isoLimit(let value): return "ISO \(value.iso)"
        case .unknown(let raw): return unknownRaw(raw)
        case nil: return observation.readback.value.isEmpty
            ? loc("Unknown") : unknownRaw(observation.readback.value)
        default: return loc("Unknown")
        }
    }

    static func availability(
        hasReadback: Bool,
        reason: String = "No current exposure readback"
    ) -> CapabilityAvailability {
        hasReadback ? .readOnly : .unavailable(reason: reason)
    }

    static func isoLimitAvailability(
        _ observation: Pocket3AdvancedSettingObservation?
    ) -> CapabilityAvailability {
        guard let observation else {
            return .unavailable(reason: "No current ISO limit readback")
        }
        if observation.typedValue == nil {
            return .init(read: true, reason: "ISO limit raw selector is unknown")
        }
        return .readOnly
    }

    static func evidence(
        hasReadback: Bool,
        validation: NativeExposureValidationResult?
    ) -> CapabilityEvidenceLevel {
        if validation?.completed == true { return .localVerifiedWrite }
        return hasReadback ? .localReadOnly : .publicReverseEngineering
    }

    static func validationStages(
        _ result: NativeExposureValidationResult
    ) -> [(label: String, value: Bool)] {
        [
            (loc("Requested"), result.requested),
            (loc("Submitted"), result.submitted),
            (loc("Acknowledged"), result.acknowledged),
            (loc("Observed"), result.observed),
            (loc("Completed"), result.completed)
        ]
    }

    static func validationSummary(
        _ result: NativeExposureValidationResult?
    ) -> String {
        guard let result else { return loc("No developer exposure validation result") }
        if result.completed { return loc("Completed") }
        if result.observed { return loc("Observed") }
        if result.acknowledged { return loc("Acknowledged") }
        if result.submitted { return loc("Submitted") }
        if result.requested { return loc("Requested") }
        return loc("Unknown")
    }

    static func validationReason(
        _ result: NativeExposureValidationResult,
        currentSession: Bool
    ) -> String {
        guard currentSession else {
            return loc("Validation result belongs to another native session")
        }
        if let failureCode = result.failureCode {
            switch failureCode {
            case "native_exposure_executor_unavailable",
                 "native_exposure_datalink_unavailable":
                return loc("Native exposure validation executor is unavailable")
            case "native_exposure_baseline_missing",
                 "native_exposure_baseline_invalid":
                return loc("Current exposure readback is required")
            case "native_exposure_generation_changed",
                 "native_exposure_session_changed":
                return loc("The selected exposure validation session is unavailable")
            case "native_exposure_timeout",
                 "native_exposure_invalid_timeout":
                return loc("Exposure validation timed out before completion")
            case "native_exposure_readback_unknown":
                return loc("Exposure validation readback is unknown")
            default:
                return String(format: loc("Validation returned gate: %@"),
                              failureCode)
            }
        }
        if result.dryRun { return loc("Dry run requested; no command was submitted") }
        if !result.submitted { return loc("Command was not submitted") }
        if !result.acknowledged { return loc("Command acknowledgement was not observed") }
        if !result.observed { return loc("Exposure validation readback is pending") }
        if !result.completed { return loc("Requested exposure state was not completed") }
        return loc("Completed with same-session exposure readback")
    }

    static func unknownRaw(_ raw: UInt8) -> String {
        "\(loc("Unknown")) (0x\(String(format: "%02X", raw)))"
    }

    static func unknownRaw(_ raw: UInt32, width: Int) -> String {
        "\(loc("Unknown")) (0x\(String(format: "%0*X", width, raw)))"
    }

    static func unknownRaw(_ raw: Data) -> String {
        let hex = raw.map { String(format: "%02X", $0) }.joined()
        return "\(loc("Unknown")) (0x\(hex))"
    }
}
