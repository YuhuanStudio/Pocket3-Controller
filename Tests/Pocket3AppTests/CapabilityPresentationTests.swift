import Foundation
import AppKit
import SwiftUI
import Testing
import Pocket3Core
@testable import Pocket3BridgeApp

@Suite("Capability graph presentation") struct CapabilityPresentationTests {
    @Test func presentationKeepsUSBHostBodyNativeAndLiveBoundariesVisible() throws {
        let uvc = UVCCaptureFormat(mode: .default1080p30, inputPixelFormat: .nv12,
                                   availability: .verified, evidence: .localReadOnly)
        let bodyEntry = CameraVideoFormatCapability(resolutionRaw: CameraVideoResolution.portrait3K.rawValue,
                                                     frameRateRaw: CameraFrameRate.fps30.rawValue)
        let body = BodyRecordingFormatCapability(capability: bodyEntry)
        let host = HostOutputCodecCapability(codec: .h264, requested: true,
                                             availability: .init(read: true, write: true, verified: false,
                                                                 reason: "No decoded sample"),
                                             evidence: .softwareFixture)
        let graph = Pocket3CapabilityGraph(
            uvcCaptureFormats: [uvc], hostOutputCodecs: [host], bodyRecordingFormats: [body],
            nativeSession: NativeSessionCapability(readiness: .commandReady,
                                                   availability: .init(read: true, write: true),
                                                   evidence: .localReadOnly),
            liveSession: .unavailable)

        #expect(CapabilityPresentation.usbCapture(graph).contains("NV12"))
        #expect(CapabilityPresentation.hostOutput(graph).contains("H.264"))
        #expect(CapabilityPresentation.bodyRecording(graph).contains("3K 9:16"))
        #expect(CapabilityPresentation.nativeSession(graph) == "Ready")
        #expect(CapabilityPresentation.liveSession(graph) == "Unavailable")
        let detail = CapabilityPresentation.graphDetail(graph)
        #expect(detail.contains("read=true,write=true,verified=false"))
        #expect(detail.contains("Evidence D"))
    }

    @Test func pendingBodyCatalogDoesNotPretendToHaveReadback() {
        let graph = Pocket3CapabilityGraph()
        #expect(CapabilityPresentation.bodyRecording(graph).contains("Readback pending"))
        #expect(CapabilityPresentation.bodyRecordingDetail(graph).contains("No current body readback"))
        #expect(CapabilityPresentation.reason("No current body readback") != nil)
        #expect(graph.bodyRecordingFormats.contains { $0.format.resolution == .square3K })
    }

    @Test func advancedSettingsPresentationKeepsEvidenceAndAccessSeparate() throws {
        let disconnected = Pocket3CapabilityGraph()
        #expect(CapabilityPresentation.advancedSettingsSummary(disconnected)
            .contains("0 of 8"))
        let iso = try #require(Pocket3AdvancedSettingInventory.entry(for: .isoLimit))
        #expect(CapabilityPresentation.advancedSettingTitle(.isoLimit) == "ISO limit")
        #expect(CapabilityPresentation.advancedSettingEvidence(.officialOnly) == "Official only")
        #expect(CapabilityPresentation.advancedSettingAccess(
            CapabilityPresentation.advancedSettingAvailability(iso, graph: disconnected))
            == "R —  W —  V —")
        #expect(CapabilityPresentation.reason(iso.availability.reason)?.contains("fresh") == true)

        var native = NativeCameraSession()
        let generation = native.begin(sessionID: UUID(), peerID: UUID())
        _ = native.markPaired(generation: generation)
        _ = native.markCredentialsAvailable(generation: generation)
        _ = native.observeDatalink(.connecting, generation: generation)
        _ = native.observeDatalink(.ready, generation: generation)
        let ready = Pocket3CapabilityGraph(nativeSession: .from(native.status))
        let readyISO = CapabilityPresentation.advancedSettingAvailability(iso, graph: ready)
        #expect(readyISO.read && readyISO.write && !readyISO.verified)
        let selfie = try #require(Pocket3AdvancedSettingInventory.entry(for: .selfieFlip))
        let selfieAccess = CapabilityPresentation.advancedSettingAvailability(selfie, graph: ready)
        #expect(selfieAccess.read && !selfieAccess.write && !selfieAccess.verified)
    }

    @Test func activeTrackAndBodyValidationPresentationKeepReadOnlyBoundaries() async throws {
        let sessionID = UUID()
        let peripheralID = UUID()
        let binding = Pocket3ActiveTrackObservation.bluetoothBinding(sessionID: sessionID)
        let frame = DUMLFrame(source: 0x01, destination: 0x02, sequence: 1,
                              flags: 0, commandSet: 0x02, commandID: 0xA5,
                              payload: Data([0, 0, 0, 0]))
        let observation = try #require(Pocket3ActiveTrackObservation(
            frame: frame, sessionID: sessionID, peripheralID: peripheralID,
            binding: binding, receivedAt: Date(timeIntervalSince1970: 20),
            receivedUptime: 10))
        #expect(CapabilityPresentation.activeTrackState(observation) == "Idle")
        #expect(CapabilityPresentation.activeTrackAvailability(observation).read)
        #expect(CapabilityPresentation.activeTrackEvidence(observation) == .localReadOnly)
        #expect(CapabilityPresentation.activeTrackAvailability(nil).write == false)

        var native = NativeCameraSession()
        let generation = native.begin(sessionID: sessionID, peerID: peripheralID)
        _ = native.markPaired(generation: generation)
        _ = native.markCredentialsAvailable(generation: generation)
        _ = native.observeDatalink(.connecting, generation: generation)
        _ = native.observeDatalink(.ready, generation: generation)
        let result = try await NativeBodyValidationService().run(
            .init(operation: .start),
            snapshot: .init(session: native.status,
                            recordingBaseline: .init(sessionID: sessionID,
                                                     generation: generation,
                                                     receivedUptime: 10,
                                                     statusByte: 0x01),
                            nowUptime: 10))
        #expect(CapabilityPresentation.bodyValidationRequested(result))
        #expect(!result.submitted && !result.acknowledged && !result.observed && !result.completed)
        #expect(CapabilityPresentation.bodyValidationSummary(result) == "Requested")
        #expect(CapabilityPresentation.bodyValidationReason(result).contains("Dry run"))
        #expect(CapabilityPresentation.bodyValidationReason(result, currentSession: false).contains("another native session"))
    }

    @MainActor @Test func bodyCapabilitySectionFitsTheSettingsColumnWithoutOpeningHardware() async throws {
        let model = AppModel()
        model.status = await model.service.status()
        let renderer = ImageRenderer(content: BodyCapabilitySection(model: model).frame(width: 560))
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 560)
        #expect(image.size.height > 300 && image.size.height < 1_200)
        #expect(!model.wireless.bluetooth.isBluetoothInitialized)
        if ProcessInfo.processInfo.environment["POCKET3_RENDER_ARTIFACT"] == "1",
           let data = image.tiffRepresentation {
            try data.write(to: URL(fileURLWithPath: "/tmp/Pocket3BodyCapabilitySection.tiff"), options: .atomic)
        }
    }

    @MainActor @Test func advancedSettingsDisclosureRendersCompactReadOnlyInventory() async throws {
        let model = AppModel()
        model.status = await model.service.status()
        let renderer = ImageRenderer(content: BodyCapabilitySection(
            model: model, advancedSettingsExpanded: true).frame(width: 560))
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 560)
        #expect(image.size.height > 650 && image.size.height < 1_800)
        #expect(!model.wireless.bluetooth.isBluetoothInitialized)
        if ProcessInfo.processInfo.environment["POCKET3_RENDER_ARTIFACT"] == "1",
           let data = image.tiffRepresentation {
            try data.write(to: URL(fileURLWithPath: "/tmp/Pocket3AdvancedSettingsSection.tiff"), options: .atomic)
        }
    }

    @MainActor @Test func diagnosticsBodySummaryCanExpandTheSameAdvancedInventory() async throws {
        let model = AppModel()
        model.status = await model.service.status()
        let renderer = ImageRenderer(content: BodyCapabilitySummary(
            model: model, advancedSettingsExpanded: true,
            initiallyExpanded: true).frame(width: 560))
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 560)
        #expect(image.size.height > 650 && image.size.height < 1_900)
        #expect(!model.wireless.bluetooth.isBluetoothInitialized)
    }

    @MainActor @Test func diagnosticsBodySummaryStaysCompactWhenDisclosureIsCollapsed() async throws {
        let model = AppModel()
        model.status = await model.service.status()
        let full = ImageRenderer(content: BodyCapabilitySection(model: model).frame(width: 560))
        full.proposedSize = ProposedViewSize(width: 560, height: nil)
        let summary = ImageRenderer(content: BodyCapabilitySummary(model: model).frame(width: 560))
        summary.proposedSize = ProposedViewSize(width: 560, height: nil)
        let fullImage = try #require(full.nsImage)
        let summaryImage = try #require(summary.nsImage)
        #expect(summaryImage.size.height < fullImage.size.height)
        #expect(summaryImage.size.height < 360)
    }

    @MainActor @Test func developerBodyCapabilityRenderShowsStagesWithoutHardware() async throws {
        let model = AppModel()
        model.status = await model.service.status()
        var native = NativeCameraSession()
        let generation = native.begin(sessionID: UUID(), peerID: UUID())
        _ = native.markPaired(generation: generation)
        _ = native.markCredentialsAvailable(generation: generation)
        _ = native.observeDatalink(.connecting, generation: generation)
        _ = native.observeDatalink(.ready, generation: generation)
        model.developerBodyValidationResult = try await NativeBodyValidationService().run(
            .init(operation: .start),
            snapshot: .init(session: native.status,
                            recordingBaseline: .init(sessionID: native.status.sessionID!,
                                                     generation: generation,
                                                     receivedUptime: 10,
                                                     statusByte: 0x01),
                            nowUptime: 10))
        let renderer = ImageRenderer(content: BodyCapabilitySection(
            model: model, developerMode: true,
            developerValidationExpanded: true).frame(width: 560))
        renderer.proposedSize = ProposedViewSize(width: 560, height: nil)
        let image = try #require(renderer.nsImage)
        #expect(image.size.width <= 560)
        #expect(image.size.height > 500 && image.size.height < 1_600)
        #expect(!model.wireless.bluetooth.isBluetoothInitialized)
        if ProcessInfo.processInfo.environment["POCKET3_RENDER_ARTIFACT"] == "1",
           let data = image.tiffRepresentation {
            try data.write(to: URL(fileURLWithPath: "/tmp/Pocket3BodyCapabilitySectionDeveloper.tiff"), options: .atomic)
        }
    }
}
