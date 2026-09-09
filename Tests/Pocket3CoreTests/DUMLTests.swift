import Foundation
import Testing
@testable import Pocket3Core

// Frozen wire/CRC vectors from Kaze for DJI at 341a35de18493ff61f97c93b8b10161a7512aa36.
// Copyright (c) 2026 Brian Merchant, MIT. Full notice and source hashes:
// research/2026-09-08/duml-fixtures/PROVENANCE.md.
@Suite("Bounded DUML codec and Pocket 3 battery telemetry") struct DUMLTests {
    private let wake = Data([0x55, 0x0f, 0x04, 0xa2, 0x02, 0xf0, 0x2b, 0x80, 0x40, 0x00, 0x2b, 0x04, 0x00, 0x24, 0x40])

    @Test func frozenFramesVerifyCRCsFieldOrderAndEncoding() throws {
        let expected = DUMLFrame(source: 0x02, destination: 0xf0, sequence: 0x802b, flags: 0x40,
                                 commandSet: 0, commandID: 0x2b, payload: Data([4, 0]))
        #expect(try DUMLCodec.decode(wake) == expected)
        #expect(try DUMLCodec.encode(expected) == wake)
        #expect(DUMLCodec.crc8([0x55, 0x33, 0x04]) == 0xc2)
        #expect(DUMLCodec.crc16(wake.dropLast(2)) == 0x4024)
        let routing = Data([0x55, 0x0f, 0x04, 0xa2, 0x02, 0x07, 0x34, 0x12, 0x40, 0x0d, 0x02, 0x61, 0x62, 0x9b, 0x33])
        let decoded = try DUMLCodec.decode(routing)
        #expect(decoded.sequence == 0x1234)
        #expect(decoded.source == 2 && decoded.destination == 7)
        #expect(decoded.commandSet == 0x0d && decoded.commandID == 2 && decoded.flags == 0x40)
        #expect(decoded.payload == Data([0x61, 0x62]))
        #expect(try DUMLCodec.encode(decoded) == routing)
    }

    @Test func rejectsCorruptionAtEveryByteAndDoesNotAcceptTrailingData() {
        for index in wake.indices {
            var corrupt = wake; corrupt[index] ^= 0x01
            #expect(throws: DUMLCodecError.self) { try DUMLCodec.decode(corrupt) }
        }
        for length in 0..<wake.count {
            #expect(throws: DUMLCodecError.self) { try DUMLCodec.decode(wake.prefix(length)) }
        }
        #expect(throws: DUMLCodecError.lengthMismatch) { try DUMLCodec.decode(wake + Data([0])) }
        #expect(throws: DUMLCodecError.lengthMismatch) { try DUMLCodec.decode(wake + wake) }
        #expect(throws: DUMLCodecError.invalidSize) { try DUMLCodec.decode(Data(repeating: 0, count: 1024)) }
    }

    @Test func rejectsUnsupportedVersionAndInvalidDeclaredLengthWithValidChecksums() throws {
        func repaired(_ input: Data) -> Data {
            var bytes = Array(input)
            bytes[3] = DUMLCodec.crc8(bytes.prefix(3))
            let crc = DUMLCodec.crc16(bytes.dropLast(2))
            bytes[bytes.count - 2] = UInt8(crc & 0xff); bytes[bytes.count - 1] = UInt8(crc >> 8)
            return Data(bytes)
        }
        var version = wake; version[2] = 0x08
        #expect(throws: DUMLCodecError.unsupportedVersion) { try DUMLCodec.decode(repaired(version)) }
        for declared in [0, 12, 14, 16, 1023] {
            var length = wake; length[1] = UInt8(declared & 0xff); length[2] = 0x04 | UInt8(declared >> 8)
            #expect(throws: DUMLCodecError.lengthMismatch) { try DUMLCodec.decode(repaired(length)) }
        }
    }

    @Test func handlesTenBitLengthsAndNonzeroDataSliceIndices() throws {
        for payloadSize in [0, 242, 243, 1010] {
            let frame = DUMLFrame(source: 0xad, destination: 0xd3, sequence: 0xfedc, flags: 0x80,
                commandSet: 0x02, commandID: 0x80, payload: Data(repeating: 0x55, count: payloadSize))
            let bytes = try DUMLCodec.encode(frame)
            #expect(bytes.count == payloadSize + 13)
            #expect(try DUMLCodec.decode(bytes) == frame)
            let wrapped = Data([0xff, 0xee]) + bytes
            #expect(try DUMLCodec.decode(wrapped.dropFirst(2)) == frame)
        }
        let tooLarge = DUMLFrame(source: 1, destination: 2, sequence: 0, flags: 0, commandSet: 0,
                                 commandID: 0, payload: Data(repeating: 0, count: 1011))
        #expect(throws: DUMLCodecError.invalidSize) { try DUMLCodec.encode(tooLarge) }
    }

    private func batteryFrame(percent: UInt8 = 42, state: UInt8 = 1, commandSet: UInt8 = 0x0d, commandID: UInt8 = 2, length: Int = 33) -> DUMLFrame {
        var payload = [UInt8](repeating: 0, count: length)
        if length > 0 { payload[0] = 99 } // A different first byte is not the battery percentage.
        if length > 20 { payload[20] = percent }
        if length > 32 { payload[32] = state }
        return DUMLFrame(source: 0x0d, destination: 2, sequence: 17, flags: 0,
                         commandSet: commandSet, commandID: commandID, payload: Data(payload))
    }

    @Test func batteryRequiresExactCommandLengthRangeAndKnownChargingValues() throws {
        let now = Date(timeIntervalSince1970: 1000)
        for (state, expected) in [(UInt8(0), Pocket3ChargingState.notCharging), (1, .charging), (2, .unknown), (255, .unknown)] {
            let frame = batteryFrame(percent: 100, state: state)
            let encoded = try DUMLCodec.encode(frame)
            let decoded = try Pocket3TelemetryParser.battery(in: encoded, source: .bluetooth, receivedAt: now)
            let result = try #require(decoded)
            #expect(result.percent == 100 && result.chargingState == expected)
            #expect(result.source == .bluetooth && result.receivedAt == now)
        }
        for frame in [batteryFrame(percent: 101), batteryFrame(commandID: 3), batteryFrame(commandSet: 2), batteryFrame(length: 32), batteryFrame(length: 0)] {
            #expect(Pocket3TelemetryParser.battery(from: frame, source: .wifi, receivedAt: now) == nil)
        }
        #expect(Pocket3TelemetryParser.battery(from: batteryFrame(percent: 0), source: .wifi, receivedAt: now)?.percent == 0)
        #expect(Pocket3TelemetryParser.battery(from: batteryFrame(length: 40), source: .wifi, receivedAt: now)?.percent == 42)
    }

    @Test func badCRCPreventsBatteryInterpretationAndUnknownFutureFlagsStayUnknown() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var bytes = try DUMLCodec.encode(batteryFrame())
        bytes[31] = 43
        #expect(throws: DUMLCodecError.invalidFrameChecksum) { try Pocket3TelemetryParser.battery(in: bytes, source: .wifi, receivedAt: now) }
        #expect(Pocket3TelemetryParser.battery(from: batteryFrame(), source: .wifi,
                    receivedAt: Date(timeIntervalSince1970: .infinity)) == nil)
    }

    @Test func batteryFreshnessRejectsStaleFutureAndInvalidClocks() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let sample = try #require(Pocket3TelemetryParser.battery(from: batteryFrame(), source: .bluetooth, receivedAt: date))
        #expect(sample.isFresh(now: date))
        #expect(sample.isFresh(now: date.addingTimeInterval(5)))
        #expect(!sample.isFresh(now: date.addingTimeInterval(5.001)))
        #expect(!sample.isFresh(now: date.addingTimeInterval(-0.001)))
        #expect(!sample.isFresh(now: Date(timeIntervalSince1970: .infinity)))
        for invalidAge in [Double.nan, .infinity, -1] { #expect(!sample.isFresh(now: date, maxAge: invalidAge)) }
    }
}
