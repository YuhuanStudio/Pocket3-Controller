import Foundation
import SwiftUI
import Testing
@testable import Pocket3BridgeApp
import Pocket3Core

@Suite("Pocket 3 media library presentation")
struct Pocket3MediaLibraryTests {
    private func identity(generation: UInt64 = 3)
        throws -> Pocket3MediaSessionIdentity {
        try Pocket3MediaSessionIdentity(sessionID: UUID(), generation: generation,
                                         peripheralID: UUID())
    }

    private func route() -> Pocket3DatalinkRouteStatus {
        Pocket3DatalinkRouteStatus(state: .interfaceBound,
            interfaceName: "en0", interfaceIndex: 4,
            cameraRouteReachable: true, samePrimaryRoute: true,
            defaultRouteChanged: false, evidence: "fake_route")
    }

    @Test func projectsOnlyBoundedMetadataRows() throws {
        let identity = try identity()
        let entry = Pocket3MediaIndexEntry(
            mediaPath: "DCIM/100MEDIA/CLIP001",
            thumbnailPath: "MISC/CLIP001",
            fileName: "CLIP001.MP4", fileTypeRaw: 3, fileType: .mp4,
            handle: 42, sizeBytes: 1_048_576, durationSeconds: 65,
            frameRateRaw: 3, resolutionRaw: 0x10, starred: true)
        let index = try Pocket3MediaIndex(identity: identity, counter: 1,
            cursor: 0, declaredRecordCount: 1, entries: [entry], raw: Data([1]))
        var model = Pocket3MediaLibraryModel()

        let applied = model.apply(index: index, expectedIdentity: identity,
            routeStatus: route(), receivedUptime: 10, nowUptime: 10)
        #expect(applied)
        #expect(model.phase == .ready && model.rows.count == 1)
        let row = try #require(model.rows.first)
        #expect(row.name == "CLIP001.MP4")
        #expect(row.typeLabel == "MP4")
        #expect(row.durationLabel == "1:05")
        #expect(row.sizeLabel == "1.0 MB")
        #expect(row.starred == true)
        let labels = Mirror(reflecting: row).children.compactMap(\.label)
        #expect(!labels.contains("mediaPath"))
        #expect(!labels.contains("thumbnailPath"))
    }

    @Test func rangeProgressIsIdentityAndFreshnessFenced() throws {
        let identity = try identity()
        var model = Pocket3MediaLibraryModel()
        let currentRoute = route()
        let bound = model.bind(identity: identity, routeStatus: currentRoute,
            observedUptime: 10, nowUptime: 10)
        #expect(bound)
        let range = try Pocket3MediaHTTPRangeRequest(identity: identity,
            storage: 0, path: "DCIM/100MEDIA/CLIP001.MP4",
            range: try Pocket3MediaByteRange(start: 0, endInclusive: 255))
        let started = model.beginRange(range, nowUptime: 11)
        #expect(started)
        let updated = model.updateRangeProgress(receivedBytes: 128, nowUptime: 11)
        #expect(updated)
        #expect(model.phase == .downloading)
        #expect(model.rangeProgress?.fraction == 0.5)
        let cancelled = model.cancelRange(nowUptime: 11)
        #expect(cancelled)
        #expect(model.phase == .cancelled && model.rangeProgress?.isPartial == true)

        let newer = try Pocket3MediaSessionIdentity(sessionID: UUID(),
            generation: 4, peripheralID: UUID())
        let rebound = model.bind(identity: newer, routeStatus: currentRoute,
            observedUptime: 12, nowUptime: 12)
        #expect(rebound)
        #expect(model.rows.isEmpty && model.rangeProgress == nil)
    }

    @Test @MainActor func disclosureBuildsWithMetadataOnlyState() throws {
        let identity = try identity()
        let entry = Pocket3MediaIndexEntry(mediaPath: "DCIM/100MEDIA/PHOTO001",
            fileName: "PHOTO001.JPG", fileTypeRaw: 0, fileType: .jpeg,
            sizeBytes: 2048, starred: false)
        let index = try Pocket3MediaIndex(identity: identity, counter: 1,
            cursor: 0, declaredRecordCount: 1, entries: [entry], raw: Data([1]))
        var model = Pocket3MediaLibraryModel()
        _ = model.apply(index: index, expectedIdentity: identity,
            routeStatus: route(), receivedUptime: 10, nowUptime: 10)

        let disclosure = Pocket3MediaLibraryDiagnostics(model: .constant(model))
        _ = disclosure.body
        #expect(model.rows.first?.name == "PHOTO001.JPG")
        #expect(model.rows.first?.typeLabel == "JPEG")
    }
}
