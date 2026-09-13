import Foundation
import Testing
@testable import Pocket3Core

@Suite("Pocket 3 capability evidence inventory")
struct Pocket3CapabilityEvidenceTests {
    @Test func ecosystemRowsCarryTransportScopeEvidenceLicenseAndProvenance() throws {
        let inventory = Pocket3CapabilityEvidenceInventory.current
        #expect(inventory.version == Pocket3CapabilityEvidenceInventory.currentVersion)
        #expect(inventory.candidates.map(\.id) == [.station, .gimbal, .capture4K, .settings])

        let station = try #require(inventory.candidate(for: .station))
        #expect(station.metadata.transport == .multiple)
        #expect(station.metadata.hardwareScope == [.pocket3])
        #expect(station.metadata.evidenceLevel == .publicReverseEngineering)
        #expect(station.metadata.provenance.contains {
            $0.project == "OsmoOffload" && $0.commit == "9c5bad9cadcc3fecd402a4bddef7a52d8b2ad54f"
        })
        #expect(station.metadata.limitations.contains {
            $0.contains("does not add a new station operation")
        })

        let gimbal = try #require(inventory.candidate(for: .gimbal))
        #expect(gimbal.metadata.transport == .wiFiDatalink)
        #expect(gimbal.metadata.hardwareScope.contains(.pocket3))
        #expect(gimbal.metadata.hardwareScope.contains(.pocket4Pro))
        #expect(gimbal.metadata.license == .mixed)
        #expect(gimbal.metadata.limitations.contains {
            $0.contains("P4 Pro telemetry")
        })

        let capture = try #require(inventory.candidate(for: .capture4K))
        #expect(capture.metadata.transport == .usbUVC)
        #expect(capture.metadata.hardwareScope == [.pocket3])
        #expect(capture.metadata.evidenceLevel == .localReadOnly)
        #expect(capture.metadata.limitations.contains {
            $0.contains("body recording")
        })

        let settings = try #require(inventory.candidate(for: .settings))
        #expect(settings.metadata.transport == .bluetoothDatalink)
        #expect(settings.metadata.provenance.contains {
            $0.project == "node-osmo" && $0.claim.contains("FFF3")
        })
        #expect(settings.metadata.provenance.contains {
            $0.project == "dji-remote" && $0.claim.contains("unconfirmed")
        })
        #expect(settings.metadata.limitations.contains {
            $0.contains("Wi-Fi-only")
        })
    }

    @Test func graphAndWriterReportPublishTheSameSettingsEvidenceBoundary() throws {
        let graph = Pocket3CapabilityGraph()
        let settings = try #require(
            graph.evidenceInventory?.candidate(for: .settings))
        #expect(graph.version == Pocket3CapabilityGraph.currentVersion)
        #expect(settings.metadata.transport == .bluetoothDatalink)
        #expect(settings.availability.write == false)

        let report = Pocket3WriterSupportReport.current
        #expect(report.evidenceMetadata == settings.metadata)
        #expect(report.evidenceMetadata?.transportDetail.contains("FFF5") == true)
        #expect(report.sources.contains(Pocket3CapabilityEvidenceInventory.reportSource))

        let decoded = try JSONDecoder().decode(
            Pocket3CapabilityGraph.self,
            from: JSONEncoder().encode(graph))
        #expect(decoded == graph)
    }

    @Test func stationWakeE0IsNonFatalWithoutAddingA53Slash10SendOperation() throws {
        let e0 = Pocket3StationProtocol.wakeProbeEvidence(
            observedResponse: Data([0xE0]))
        #expect(e0.operation == "53/10")
        #expect(e0.equivalentOperation == .networkModeProbe)
        #expect(e0.disposition == .e0NonFatal)
        #expect(e0.acceptedNonFatal)
        #expect(e0.expectedResponseHex == "E0")
        #expect(e0.observedResponseHex == "E0")
        #expect(e0.metadata.transport == .bluetoothDatalink)
        #expect(e0.metadata.hardwareScope == [.pocket3])
        #expect(e0.metadata.provenance.first?.project == "OsmoOffload")
        #expect(!Pocket3StationBLEOperation.allCases.contains {
            $0.rawValue == "53/10"
        })

        let unexpected = Pocket3StationProtocol.wakeProbeEvidence(
            observedResponse: Data([0xE1]))
        #expect(unexpected.disposition == .unexpected)
        #expect(!unexpected.acceptedNonFatal)

        let notObserved = Pocket3StationProtocol.wakeProbeEvidence()
        #expect(notObserved.disposition == .notObserved)
        #expect(!notObserved.observed)

        let request = try Pocket3StationValidationRequest(
            expectedSessionID: UUID(), expectedPeripheralID: UUID(), generation: 1)
        let plan = Pocket3StationValidationService.dryRun(request)
        #expect(plan.wakeProbe?.operation == "53/10")
        #expect(plan.wakeProbe?.equivalentOperation == .networkModeProbe)
        #expect(plan.wakeProbe?.disposition == .notObserved)
    }
}
