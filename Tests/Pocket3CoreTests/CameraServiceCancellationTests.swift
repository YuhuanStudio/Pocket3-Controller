import Foundation
import Testing
@testable import Pocket3Core

@Suite struct CameraServiceCancellationTests {
    @Test func cancelledServiceRequestUsesStableCodeWithoutReplacingBridgeFailures() async {
        let service = CameraService()
        // roll-status checks Task cancellation before touching the capture or
        // UVC connection, so this exercises the real service catch without I/O.
        let request = ServiceRequest(token: "fixture", operation: "roll-status")
        let invalid = ServiceRequest(token: "fixture", operation: "fixture-unknown-operation")
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream {}
            let cancelled = await service.handle(request)
            let knownFailure = await service.handle(invalid)
            return (cancelled, knownFailure)
        }
        // The stream cannot finish before cancellation, avoiding a timing race
        // between starting the request and setting the task's cancellation bit.
        task.cancel()
        gate.continuation.finish()
        let (cancelled, knownFailure) = await task.value
        #expect(cancelled.id == request.id)
        #expect(cancelled.error?.code == "cancelled")
        #expect(cancelled.error?.message == "操作已取消")
        #expect(cancelled.error?.retryable == false)
        #expect(cancelled.result == nil && cancelled.imageJPEG == nil)
        // A task's cancelled state must not erase a concrete BridgeFailure.
        #expect(knownFailure.id == invalid.id)
        #expect(knownFailure.error?.code == "unknown_operation")
        #expect(knownFailure.error?.message == "不支持此操作")
        #expect(service.capture.store.stats().frames == 0)
    }
}
