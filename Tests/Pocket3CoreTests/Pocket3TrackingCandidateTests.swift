import Foundation
import Testing
@testable import Pocket3Core

@Suite struct Pocket3TrackingCandidateTests {
    @Test func strictPassiveCandidatePreservesBytesWithoutInterpretingTracking() throws {
        let session = UUID(), peer = UUID(), payload = Data([1, 0, 0, 4, 3, 2, 1])
        let frame = DUMLFrame(source: 1, destination: 2, sequence: 4, flags: 0,
            commandSet: 2, commandID: 0x89, payload: payload)
        let result = try #require(Pocket3TrackingCandidateParser.parse(frame, sessionID: session,
            peripheralID: peer, receivedAt: Date(), receivedUptime: 5))
        #expect(result.commandID == 0x89 && result.payloadLength == payload.count)
        #expect(result.payloadHex == "01000004030201")
        #expect(result.evidence.contains("unverified_on_pocket3"))
    }

    @Test func unrelatedRoutesAndOversizePayloadsAreIgnored() {
        let session = UUID(), peer = UUID(), date = Date()
        for frame in [
            DUMLFrame(source: 1, destination: 2, sequence: 1, flags: 0, commandSet: 2, commandID: 0x88, payload: Data([1])),
            DUMLFrame(source: 1, destination: 2, sequence: 1, flags: 0x80, commandSet: 2, commandID: 0x89, payload: Data([1])),
            DUMLFrame(source: 2, destination: 1, sequence: 1, flags: 0, commandSet: 2, commandID: 0xA5, payload: Data([1])),
            DUMLFrame(source: 1, destination: 2, sequence: 1, flags: 0, commandSet: 2, commandID: 0xA6, payload: Data()),
            DUMLFrame(source: 1, destination: 2, sequence: 1, flags: 0, commandSet: 2, commandID: 0xA6,
                payload: Data(repeating: 0, count: Pocket3TrackingCandidateParser.maximumPayloadBytes + 1))
        ] {
            #expect(Pocket3TrackingCandidateParser.parse(frame, sessionID: session, peripheralID: peer,
                receivedAt: date, receivedUptime: 1) == nil)
        }
    }
}
