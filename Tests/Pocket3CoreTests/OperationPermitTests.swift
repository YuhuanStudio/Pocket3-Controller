import Foundation
import Testing
@testable import Pocket3Core

@Test func stoppedPermitRejectsAQueuedHardwareWrite() throws {
    let permit = OperationPermit()
    var writes = 0
    try permit.perform { writes += 1 }
    permit.invalidate()
    #expect(throws: BridgeFailure.self) { try permit.perform { writes += 1 } }
    #expect(writes == 1)
}
@Test func cancellationRejectsHardwareWriteBeforeItRuns() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        let permit = OperationPermit()
        var called = false
        do { try permit.perform { called = true } } catch {}
        return called
    }
    #expect(await task.value == false)
}

@Test func anOutOfRangeUSBPositionCannotOverflowMotionArithmetic() throws {
    let json = JSONValue.object([
        "location": .number(1), "position": .object(["pan": .number(Double(Int32.max)), "tilt": .number(0)]),
        "minimum": .object(["pan": .number(Double(Int32.min)), "tilt": .number(-100)]),
        "maximum": .object(["pan": .number(Double(Int32.max)), "tilt": .number(100)]),
        "writable": .bool(true), "controls": .array([]), "uvcVersion": .number(0)
    ])
    let capabilities = try json.decode(UVCCapabilities.self)
    #expect(throws: BridgeFailure.self) {
        try MotionPolicy.target(direction: "right", origin: capabilities.position, capabilities: capabilities)
    }
}
