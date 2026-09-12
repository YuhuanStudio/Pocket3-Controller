import Foundation
import Pocket3Core

extension AppModel {
    /// Developer-only dry-run entry point for the scalar format matrix. The
    /// current route returns a plan and never starts, stops or reconfigures a
    /// capture session; a separate runner/fake may feed metrics to the Core
    /// evaluator.
    func handleNativeCaptureFormatValidation(_ request: ServiceRequest)
        async throws -> ServiceReply {
        guard CommandLine.arguments.contains("--hardware-validation") else {
            throw BridgeFailure("validation_disabled",
                "Capture format validation requires an explicit development launch")
        }
        let input: NativeCaptureFormatValidationRequest
        do {
            input = try NativeCaptureFormatValidationRequest(
                arguments: request.arguments)
        } catch let error as NativeCaptureFormatValidationError {
            throw nativeCaptureFormatValidationFailure(error)
        }
        let report = NativeCaptureFormatValidationService.dryRun(input)
        return ServiceReply(id: request.id, result: try .encode(report))
    }
}

private func nativeCaptureFormatValidationFailure(
    _ error: NativeCaptureFormatValidationError
) -> BridgeFailure {
    switch error {
    case .invalidArguments:
        BridgeFailure("invalid_capture_format_matrix_arguments",
            "Pass an exact capture session, device and bounded case list")
    case .invalidSession:
        BridgeFailure("capture_format_session_required",
            "Capture format validation requires exact session and device IDs")
    case .unknownCase:
        BridgeFailure("capture_format_case_unknown",
            "The requested format case is not in the reviewed matrix")
    case .duplicateCase:
        BridgeFailure("capture_format_case_duplicate",
            "Each capture format case may appear only once")
    case .tooManyCases:
        BridgeFailure("capture_format_case_limit",
            "The capture format matrix is limited to four cases")
    case .invalidSampleLimit:
        BridgeFailure("capture_format_sample_limit",
            "Each capture format case accepts at most twenty scalar samples")
    }
}
