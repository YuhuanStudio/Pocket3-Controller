import Foundation
import Testing
@testable import Pocket3Core

private final class CaptureActivityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [ObjectIdentifier] = []
    private var closed: [ObjectIdentifier] = []
    private var flags: [ProcessInfo.ActivityOptions] = []
    func begin(_ options: ProcessInfo.ActivityOptions, _ reason: String) -> any NSObjectProtocol {
        let token = NSObject()
        lock.withLock { opened.append(ObjectIdentifier(token)); flags.append(options) }
        return token
    }
    func end(_ token: any NSObjectProtocol) { lock.withLock { closed.append(ObjectIdentifier(token)) } }
    var counts: (begins: Int, ends: Int) { lock.withLock { (opened.count, closed.count) } }
    var balanced: Bool { lock.withLock { opened.sorted { $0.hashValue < $1.hashValue } == closed.sorted { $0.hashValue < $1.hashValue } } }
    var options: [ProcessInfo.ActivityOptions] { lock.withLock { flags } }
    func lease() -> CaptureActivityLease { .init(begin: { self.begin($0, $1) }, end: { self.end($0) }) }
}

@Test func captureActivityPreventsIdleSystemSleepWithoutKeepingDisplayAwake() {
    let recorder = CaptureActivityRecorder(), lease = recorder.lease()
    #expect(recorder.counts.begins == 0)
    lease.start(generation: 1); lease.start(generation: 1)
    #expect(recorder.counts.begins == 1)
    let options = recorder.options[0]
    #expect(options == .userInitiated)
    #expect(options.contains(.idleSystemSleepDisabled))
    #expect(!options.contains(.idleDisplaySleepDisabled) && !options.contains(.latencyCritical))
    lease.stop(); lease.stop()
    #expect(recorder.counts.ends == 1 && recorder.balanced)
}

@Test func stoppedOrDisconnectedCaptureReleasesAndCurrentResumeReacquires() {
    for condition in [(false, true), (true, false)] {
        let recorder = CaptureActivityRecorder(), lease = recorder.lease()
        lease.start(generation: 1)
        lease.reconcile(generation: 1, isRunning: condition.0, deviceConnected: condition.1)
        lease.reconcile(generation: 1, isRunning: condition.0, deviceConnected: condition.1)
        #expect(recorder.counts.ends == 1)
        lease.reconcile(generation: 1, isRunning: true, deviceConnected: true)
        #expect(recorder.counts.begins == 2)
        lease.stop()
        #expect(recorder.counts.ends == 2 && recorder.balanced)
    }
}

@Test func lateOldCaptureNotificationsCannotEndOrRestartNewGenerationActivity() {
    let recorder = CaptureActivityRecorder(), lease = recorder.lease()
    lease.start(generation: 1); lease.start(generation: 2)
    #expect(recorder.counts.begins == 2 && recorder.counts.ends == 1)
    lease.reconcile(generation: 1, isRunning: false, deviceConnected: false)
    lease.reconcile(generation: 1, isRunning: true, deviceConnected: true)
    // Even when the old notification arrives after the new generation begins,
    // current AVF state (running/connected) wins over its stale event name.
    lease.reconcile(generation: 2, isRunning: true, deviceConnected: true)
    #expect(recorder.counts.begins == 2 && recorder.counts.ends == 1)
    lease.stop()
    lease.reconcile(generation: 2, isRunning: true, deviceConnected: true)
    #expect(recorder.counts.begins == 2 && recorder.balanced)
}

@Test func failedStartupCannotAcquireActivityAndTeardownBalancesActiveToken() {
    let recorder = CaptureActivityRecorder()
    var lease: CaptureActivityLease? = recorder.lease()
    // A start notification before successful configuration is not admission.
    lease?.reconcile(generation: 1, isRunning: true, deviceConnected: true)
    lease?.stop()
    #expect(recorder.counts.begins == 0)
    lease?.start(generation: 2)
    lease = nil
    #expect(recorder.counts.begins == 1 && recorder.counts.ends == 1 && recorder.balanced)
}
