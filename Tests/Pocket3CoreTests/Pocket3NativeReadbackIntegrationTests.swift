import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 native readback integration")
struct Pocket3NativeReadbackIntegrationTests {
    private let session = UUID()
    private let peer = UUID()

    private func hex(_ value: String) -> Data {
        let chars = Array(value)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }

    private func propertyPayload(_ property: CameraSettingsProperty, transaction: UInt32 = 9,
                                 value: Data) -> Data {
        var bytes: [UInt8] = [0x02, 0x06, 0x00, 0x00]
        bytes += [UInt8(truncatingIfNeeded: transaction), UInt8(truncatingIfNeeded: transaction >> 8),
                  UInt8(truncatingIfNeeded: transaction >> 16), UInt8(truncatingIfNeeded: transaction >> 24)]
        bytes += [0, 0, 0]
        func append16(_ number: Int) {
            bytes += [UInt8(number & 0xff), UInt8((number >> 8) & 0xff)]
        }
        // The named-record inner length includes name/value metadata and the value.
        append16(property.rawValue.utf8.count + value.count + 10)
        append16(property.rawValue.utf8.count)
        bytes += property.rawValue.utf8
        bytes += [0, 0, 0, 0, 0, 0]
        append16(value.count)
        bytes += value
        return Data(bytes)
    }

    private func packet(_ payload: Data, sequence: UInt16 = 20) throws -> ValidatedDUMLPacket {
        let frame = DUMLFrame(source: 0x28, destination: 0x02, sequence: sequence,
                              flags: 0, commandSet: 0, commandID: 0x99, payload: payload)
        let encoded = try DUMLCodec.encode(frame)
        return ValidatedDUMLPacket(frameData: encoded, frame: try DUMLCodec.decode(encoded))
    }

    private var formatValue: Data {
        // Version 1, inner length 13, four [resolution, fps, flags] entries.
        hex("010d00044203004302006903006a0200")
    }

    @Test func observationCarriesTypedBodyCapabilityWithSessionBindingAndFreshness() throws {
        let push = CameraPropertyPush(property: .videoFormatCapabilities, transactionID: 0x1234,
                                      value: formatValue)
        let binding = ContinuousGimbalBinding(sessionID: "ble:\(session.uuidString)", generation: 0)
        let observation = try #require(CameraSettingsObservation.decode(push, binding: binding, receivedUptime: 12))
        let capability = try #require(observation.bodyRecordingCapabilities)
        #expect(capability.entries.map(\.resolutionRaw) == [0x42, 0x43, 0x69, 0x6A])
        #expect(capability.entries[0].resolution == .portrait1080)
        #expect(capability.entries[2].resolution == .square1080)
        #expect(observation.videoFormatCapabilities == capability)
        #expect(observation.binding == binding && observation.receivedUptime == 12)
        #expect(observation.isFresh(now: 17) && !observation.isFresh(now: 17.001))
    }

    @Test func malformedCapabilityEnvelopeRemainsRawButNeverBecomesTyped() throws {
        let malformed = hex("010d0002420300") // Declares 2 entries but contains one.
        let push = CameraPropertyPush(property: .videoFormatCapabilities, transactionID: 2, value: malformed)
        let binding = ContinuousGimbalBinding(sessionID: "ble:\(session.uuidString)", generation: 0)
        let observation = try #require(CameraSettingsObservation.decode(push, binding: binding, receivedUptime: 1))
        #expect(observation.bodyRecordingCapabilities == nil)
        guard case .videoFormatCapabilities(let opaque)? = observation.readOnlyValue else {
            Issue.record("raw capability was not retained")
            return
        }
        #expect(opaque.raw == malformed)
        #expect(CameraReadOnlyPropertyDecoder.decodeVideoFormatCapabilities(malformed) == nil)
        // A future envelope version stays opaque until its layout is proven.
        #expect(CameraReadOnlyPropertyDecoder.decodeVideoFormatCapabilities(hex("02070002420300430300")) == nil)
    }

    @Test func queryExposesTypedCapabilityOnlyAfterValidNamedPush() throws {
        let binding = ContinuousGimbalBinding(sessionID: "ble:\(session.uuidString)", generation: 3)
        var query = try BluetoothCameraPropertyQuery(property: .videoFormatCapabilities, binding: binding,
            sequence: 0x4567, transactionID: 0xAA55, startedUptime: 0)
        try query.submitted(at: 0.1)
        let malformed = propertyPayload(.videoFormatCapabilities, value: hex("01070002feff7f"))
        query.receive(try DUMLCodec.encode(DUMLFrame(source: 0x28, destination: 2, sequence: 1,
            flags: 0, commandSet: 0, commandID: 0x99, payload: malformed)),
            characteristic: "FFF4", binding: binding, at: 0.2)
        #expect(query.result.propertyReceived && query.result.observed != nil)
        #expect(query.result.bodyRecordingCapabilities == nil)

        var validQuery = try BluetoothCameraPropertyQuery(property: .videoFormatCapabilities, binding: binding,
            sequence: 0x4568, transactionID: 0xAA56, startedUptime: 0)
        try validQuery.submitted(at: 0.1)
        let valid = propertyPayload(.videoFormatCapabilities, value: formatValue)
        validQuery.receive(try DUMLCodec.encode(DUMLFrame(source: 0x28, destination: 2, sequence: 2,
            flags: 0, commandSet: 0, commandID: 0x99, payload: valid)),
            characteristic: "FFF5", binding: binding, at: 0.2)
        let capability = try #require(validQuery.result.bodyRecordingCapabilities)
        #expect(capability.entries.count == 4)
        #expect(validQuery.result.observed?.binding == binding)
        #expect(validQuery.result.observed?.isFresh(now: 2.2) == true)
    }

    @Test func storeSnapshotProvidesTypedCapabilityOnlyForCurrentPairedPeerAndFreshWindow() throws {
        var store = BluetoothCameraSettingsStore()
        store.bind(sessionID: session, peripheralID: peer)
        let accepted = store.receive(try packet(propertyPayload(.videoFormatCapabilities, value: formatValue)),
                                     sessionID: session, peripheralID: peer, paired: true, uptime: 10)
        #expect(accepted)
        let capability = try #require(store.bodyRecordingCapabilities(sessionID: session, peripheralID: peer,
                                                                       paired: true, nowUptime: 10.5))
        #expect(capability.entries.count == 4 && capability.contains(resolution: .square1080, frameRate: .fps30))
        #expect(store.bodyRecordingCapabilities(sessionID: session, peripheralID: peer,
                                                 paired: true, nowUptime: 15.001) == nil)
        #expect(store.bodyRecordingCapabilities(sessionID: UUID(), peripheralID: peer,
                                                 paired: true, nowUptime: 10.5) == nil)
        #expect(store.bodyRecordingCapabilities(sessionID: session, peripheralID: peer,
                                                 paired: false, nowUptime: 10.5) == nil)
    }

    private func statusFrame(_ raw: UInt8) -> DUMLFrame {
        DUMLFrame(source: 1, destination: 2, sequence: 1, flags: 0,
                  commandSet: 2, commandID: 0x80, payload: Data([raw]))
    }

    @Test func recordingStatusMapsCapturedLifecycleBitsAndRetainsUnknownRaw() throws {
        let date = Date(timeIntervalSince1970: 100)
        let expected: [(UInt8, Pocket3BodyRecordingLifecycle)] = [
            (0x01, .idle), (0x41, .transitioningToIdle),
            (0x81, .recording), (0xC1, .transitioningToRecording)
        ]
        for (raw, lifecycle) in expected {
            let observation = try #require(Pocket3CameraStatusParser.parse(statusFrame(raw), sessionID: session,
                peripheralID: peer, receivedAt: date, receivedUptime: 4))
            #expect(observation.recordingLifecycle == lifecycle)
            #expect(observation.recordingStatus.rawValue == raw)
            #expect(observation.recordingStatus.recording == (raw & 0x80 != 0))
            #expect(observation.recordingStatus.transitioning == (raw & 0x40 != 0))
            #expect(observation.isFresh(nowUptime: 9))
        }
        let unknown = try #require(Pocket3CameraStatusParser.parse(statusFrame(0xE2), sessionID: session,
            peripheralID: peer, receivedAt: date, receivedUptime: 4))
        #expect(unknown.recordingLifecycle == .unknown(raw: 0xE2))
        #expect(unknown.recordingStatus.rawValue == 0xE2)
        #expect(!unknown.recordingStatus.isKnown && unknown.recordingStatus.recording && unknown.recordingStatus.transitioning)
    }
}
