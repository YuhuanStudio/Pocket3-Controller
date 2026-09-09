import Foundation
import Testing
@testable import Pocket3Core

@Suite struct BluetoothLensStateQueryTests {
    private func query() -> BluetoothLensStateQuery {
        BluetoothLensStateQuery(sequence: 0x9123, transactionID: 0x11223344, startedUptime: 0)
    }
    private func packet(source: UInt8 = 0x28, destination: UInt8 = 2, sequence: UInt16 = 0x9123,
                        flags: UInt8 = 0xc0, set: UInt8 = 0, command: UInt8 = 0x99, payload: Data = Data()) throws -> Data {
        try DUMLCodec.encode(DUMLFrame(source: source, destination: destination, sequence: sequence,
            flags: flags, commandSet: set, commandID: command, payload: payload))
    }
    private func property(name: String = "cam_lens_state", transaction: UInt32 = 77, value: Data = Data([0xb2])) -> Data {
        var bytes: [UInt8] = [2, 6, 0, 0]
        bytes += [UInt8(transaction & 255), UInt8((transaction >> 8) & 255), UInt8((transaction >> 16) & 255), UInt8(transaction >> 24)]
        bytes += [0, 0, 0]
        func append16(_ number: Int) { bytes += [UInt8(number & 255), UInt8((number >> 8) & 255)] }
        append16(name.utf8.count + value.count + 10); append16(name.utf8.count)
        bytes.append(contentsOf: name.utf8); bytes += [0, 0, 0, 0, 0, 0]; append16(value.count)
        bytes.append(contentsOf: value)
        return Data(bytes)
    }

    @Test func subscriptionIsOnlyLensStateTo28AndUsesOneFrame() throws {
        var query = query()
        let request = query.request
        let encoded = try DUMLCodec.encode(request)
        let decoded = try DUMLCodec.decode(encoded)
        #expect(encoded.count == 46 && decoded == request)
        #expect(request.source == 2 && request.destination == 0x28 && request.flags == 0x40)
        #expect(request.commandSet == 0 && request.commandID == 0x99 && request.sequence == 0x9123)
        #expect(Array(request.payload.prefix(8)) == [2, 2, 0, 0, 0x44, 0x33, 0x22, 0x11])
        #expect(String(decoding: request.payload.dropFirst(15).dropLast(4), as: UTF8.self) == "cam_lens_state")
        try query.submitted(at: 0.01)
        #expect(throws: BridgeFailure.self) { try query.submitted(at: 0.02) }
    }

    @Test func exactAckIsSeparateFromAReadableProperty() throws {
        var query = query()
        try query.submitted(at: 0.01)
        for data in try [packet(source: 0x48), packet(destination: 0x22), packet(sequence: 1), packet(flags: 0), packet(flags: 0xff)] {
            query.receive(data, characteristic: "FFF4", at: 0.1)
        }
        #expect(!query.result.ackReceived)
        query.receive(try packet(flags: 0x80), characteristic: "FFF5", at: 0.2)
        let result = query.finish(at: 2.1, cancelled: false, connectionChanged: false, failure: nil)
        #expect(result.ackReceived && result.ackHeader?.source == 0x28 && result.ackHeader?.flags == 0x80)
        #expect(!result.propertyReceived && result.timedOut && !result.ackTimedOut && !result.tapAFConfirmed)
    }

    @Test func namedPropertyPreservesActualSourceAndIndependentTransaction() throws {
        var query = query()
        try query.submitted(at: 0.01)
        let data = try packet(source: 0x48, sequence: 9, flags: 0,
            payload: property(transaction: 77, value: Data([0xb2]) + Data(repeating: 0xaa, count: 31)))
        query.receive(data, characteristic: "FFF4", at: 0.1)
        let result = query.finish(at: 2.1, cancelled: false, connectionChanged: false, failure: nil)
        #expect(result.propertyReceived && !result.ackReceived && result.ackTimedOut && !result.timedOut)
        #expect(result.propertyHeader?.source == 0x48 && result.propertyHeader?.sequence == 9)
        #expect(result.propertyTransactionID == 77 && result.subscriptionTransactionID == 0x11223344)
        #expect(result.modeCode == 0xb2 && result.mode == "continuous" && result.valueLength == 32)
        #expect(result.valuePrefixHex?.count == 18 && result.valueTruncated && !result.tapAFConfirmed)
        query.receive(try packet(payload: property(value: Data([0xb1]))), characteristic: "FFF4", at: 0.2)
        #expect(query.result.mode == "continuous") // Finished evidence cannot be rewritten.
    }

    @Test func otherNamesCredentialsMalformedAndCorruptFramesExposeNoValue() throws {
        var query = query()
        try query.submitted(at: 0.01)
        let secret = Data("fixture-private-password".utf8)
        var corrupt = try packet(payload: property()); corrupt[corrupt.count - 1] ^= 1
        var malformed = property(); malformed[13] = 0xff; malformed[14] = 0xff
        let inputs = try [packet(flags: 0, payload: property(name: "cam_image_effect", value: secret)),
            packet(flags: 0, payload: property(name: "cam_lens_state_extra", value: secret)),
            packet(set: 7, command: 0x0e, payload: secret), packet(flags: 0, payload: malformed), corrupt,
            packet(destination: 0x22, payload: property())]
        for data in inputs { query.receive(data, characteristic: "FFF4", at: 0.1) }
        query.receive(try packet(payload: property()), characteristic: "FFF3", at: 0.2)
        #expect(!query.result.propertyReceived && query.result.valuePrefixHex == nil && query.result.mode == nil)
        let json = String(decoding: try JSONEncoder().encode(query.result), as: UTF8.self)
        #expect(!json.contains("fixture-private-password") && !json.contains("cam_image_effect"))
    }

    @Test func modeCodesStayLiteralAndUnknownDoesNotBecomeAFSupport() throws {
        for (code, expected) in [(UInt8(0xb1), Optional("single")), (0xb2, Optional("continuous")), (0x00, nil)] {
            var query = query(); try query.submitted(at: 0.01)
            query.receive(try packet(flags: 0, payload: property(value: Data([code]))), characteristic: "FFF4", at: 0.1)
            #expect(query.result.propertyReceived && query.result.modeCode == code && query.result.mode == expected)
            #expect(!query.result.tapAFConfirmed)
        }
    }

    @Test func windowCancellationAndPermitFencePreventLateEvidenceOrSubmission() throws {
        var query = query()
        let data = try packet(payload: property())
        query.receive(data, characteristic: "FFF4", at: 0.005)
        try query.submitted(at: 0.01)
        query.receive(data, characteristic: "FFF4", at: 2.011)
        let result = query.finish(at: 2.1, cancelled: false, connectionChanged: false, failure: nil)
        #expect(result.observationWindowCompleted && result.timedOut && !result.propertyReceived)
        for changed in [false, true] {
            var cancelled = self.query(); try cancelled.submitted(at: 0.01)
            let result = cancelled.finish(at: 2.1, cancelled: !changed, connectionChanged: changed, failure: nil)
            #expect(!result.observationWindowCompleted && !result.timedOut && !result.ackTimedOut)
            #expect(result.cancelled == !changed && result.connectionChanged == changed)
        }
        var neverSent = self.query(); let permit = OperationPermit(); permit.invalidate()
        var writes = 0
        #expect(throws: BridgeFailure.self) { try permit.perform { try neverSent.submitted(at: 0.01); writes += 1 } }
        #expect(writes == 0 && !neverSent.result.localSubmitted)
    }

    @MainActor @Test func productionEntryDoesNotInitializeBluetooth() async {
        guard !CommandLine.arguments.contains("--hardware-validation") else { return }
        let discovery = Pocket3BluetoothDiscovery()
        do {
            _ = try await discovery.queryLensState()
            Issue.record("Production launch unexpectedly admitted a lens-state probe")
        } catch { #expect((error as? BridgeFailure)?.code == "validation_disabled") }
        #expect(!discovery.isBluetoothInitialized)
    }
}
