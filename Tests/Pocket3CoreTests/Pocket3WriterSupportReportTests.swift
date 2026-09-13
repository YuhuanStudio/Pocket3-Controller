import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 writer support report")
struct Pocket3WriterSupportReportTests {
    @Test func reportCoversTheSixWriterFamiliesWithoutHardwareAccess() throws {
        let report = Pocket3WriterSupportReport.current
        #expect(report.version == Pocket3WriterSupportReport.currentVersion)
        #expect(report.operation == Pocket3WriterSupportReport.operation)
        #expect(report.localTransport == .bluetoothDatalink)
        #expect(report.localTransportDetail.contains("CoreBluetooth"))
        #expect(report.localTransportDetail.contains("FFF5"))
        #expect(report.entries.map(\.id) == [
            .whiteBalance, .focusMode, .colorProfile, .exposure,
            .bodyRecording, .audioDSP
        ])
        #expect(!report.hardwareAccessed)
        #expect(!report.executeAllowed)
        #expect(report.candidateCount == 4)
        #expect(report.blockedCount == 2)
        #expect(report.unsupportedCount == 0)
        #expect(report.verifiedCount == 0)
        #expect(report.entries.allSatisfy { !$0.executionAllowed })
        #expect(report.entries.allSatisfy { !$0.availability.write })
        #expect(report.entries.allSatisfy { !$0.availability.verified })
    }

    @Test func packetAndReadbackEvidenceRetainExactRoutes() throws {
        let report = Pocket3WriterSupportReport.current

        let whiteBalance = try #require(report.entry(for: .whiteBalance))
        let wbPacket = try #require(whiteBalance.packetEvidence.first)
        #expect(wbPacket.command == "02/2C")
        #expect(wbPacket.payloadLength == 5)
        #expect(wbPacket.payloadHex == "06 38 00 00 00")
        #expect(wbPacket.payloadExact)
        #expect(wbPacket.upstreamAccepted)
        #expect(wbPacket.upstreamTransport == .wiFiDatalink)
        #expect(wbPacket.upstreamEvidence?.contains("9b30b935") == true)
        #expect(wbPacket.upstreamTransportDetail?.contains("Wi-Fi") == true)
        #expect(wbPacket.transportDetail.contains("CoreBluetooth"))
        let wbReadback = try #require(whiteBalance.readbackEvidence.first)
        #expect(wbReadback.command == "00/99")
        #expect(wbReadback.property == "cam_image_effect")
        #expect(wbReadback.minimumPayloadBytes == 6)
        #expect(wbReadback.rawPreserved)
        #expect(wbReadback.observedLocally)
        #expect(wbReadback.upstreamObserved)
        #expect(wbReadback.upstreamTransport == .wiFiDatalink)

        let focus = try #require(report.entry(for: .focusMode))
        #expect(focus.packetEvidence.first?.command == "02/24")
        #expect(focus.readbackEvidence.first?.property == "cam_lens_state")
        #expect(focus.readbackEvidence.first?.typedFields == ["focusMode[0]: B1/B2"])

        let exposure = try #require(report.entry(for: .exposure))
        #expect(exposure.packetEvidence.map(\.command) == [
            "02/1E", "02/2E", "02/2A", "02/28", "02/8E"
        ])
        #expect(exposure.readbackEvidence.map(\.property) == [
            "cam_expo_param", "iso_limit"
        ])
        #expect(exposure.readbackEvidence.first?.minimumPayloadBytes == 20)
        #expect(exposure.readbackEvidence.last?.command == "02/8E")
        #expect(exposure.packetEvidence.first?.upstreamAccepted == true)
        #expect(exposure.packetEvidence.last?.upstreamAccepted == false)
        let isoPacket = exposure.packetEvidence[2]
        #expect(isoPacket.upstreamPayloadHex == ["10", "11"])
        #expect(isoPacket.payloadShape.contains("sparse"))

        let body = try #require(report.entry(for: .bodyRecording))
        #expect(body.readbackEvidence.map(\.command) == [
            "00/99", "02/80", "00/99"
        ])

        let audio = try #require(report.entry(for: .audioDSP))
        #expect(audio.readbackEvidence.first?.command == "02/A0")
        #expect(audio.readbackEvidence.first?.source == 0x01)
        #expect(audio.readbackEvidence.first?.destination == 0x02)
        #expect(audio.readbackEvidence.first?.upstreamObserved == true)
        #expect(audio.readbackEvidence.first?.upstreamTransport == .wiFiDatalink)
        #expect(audio.readbackEvidence.first?.transportDetail.contains("FFF4") == true)
        #expect(audio.readbackEvidence.first?.upstreamTransportDetail?.contains("Wi-Fi") == true)
    }

    @Test func candidateAndBlockedAdmissionExplainTheMissingWriteProof() throws {
        let report = Pocket3WriterSupportReport.current
        let candidate = try #require(report.entry(for: .focusMode))
        #expect(candidate.protocolStatus == .exact)
        #expect(candidate.admission == .candidateOnly)
        #expect(candidate.candidateOperation == "validation-wireless-setting-candidate")
        #expect(candidate.writeAttempts == 0)
        #expect(candidate.nextValidation.contains(.correlateMatchingACK))
        #expect(candidate.nextValidation.contains(.restoreCapturedBaseline))

        let whiteBalance = try #require(report.entry(for: .whiteBalance))
        #expect(whiteBalance.admission == .blockedNoVerifiedWrite)
        #expect(whiteBalance.writeAttempts == 2)
        #expect(whiteBalance.acknowledgedWrites == 0)
        #expect(whiteBalance.matchingReadbacksAfterWrite == 0)
        #expect(whiteBalance.reason.contains("no ACK"))

        let audio = try #require(report.entry(for: .audioDSP))
        #expect(audio.protocolStatus == .partial)
        #expect(audio.admission == .blockedNoVerifiedWrite)
        #expect(audio.packetEvidence.map(\.command) == ["02/A0", "02/9F"])
        #expect(audio.readbackEvidence.first?.observedLocally == false)
        #expect(audio.readbackEvidence.first?.rawPreserved == true)
    }

    @Test func reportRoundTripsAsStableMachineReadableJSON() throws {
        let report = Pocket3WriterSupportReport.current
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(
            Pocket3WriterSupportReport.self, from: data)
        #expect(decoded == report)
        #expect(report.sources.contains(
            "research/2026-09-09/ble-camera-write-route.md"))
        #expect(report.notes.contains(
            "A command ACK without matching same-session readback is not a verified write"))
    }
}
