import Foundation
import Testing
@testable import Pocket3Core
@testable import Pocket3BridgeApp

@Test func appErrorCodeMappingCoversUserActionsWithoutDisplayingBackendProse() {
    let cases: [(String, AppErrorMessageKey)] = [
        ("camera_permission", .cameraPermission), ("microphone_permission", .microphonePermission),
        ("device_missing", .cameraConnection), ("capture_unavailable", .cameraInUse),
        ("cancelled", .cancelled), ("motion_busy", .busy), ("session_changed", .connectionChanged),
        ("stale_frame", .freshImage), ("movement_denied", .controlPermission),
        ("usb_stop_unverified", .stopUnconfirmed), ("zoom_stop_required", .stopUnconfirmed), ("uvc_zoom_out_of_range", .zoomRange),
        ("zoom_unconfirmed", .zoomUnconfirmed), ("focus_point_unsupported", .focusUnavailable),
        ("bluetooth_permission_denied", .bluetoothPermission), ("bluetooth_powered_off", .bluetoothOff),
        ("model_not_downloaded", .modelDownload), ("model_checksum", .modelFiles),
        ("model_timeout", .timedOut), ("ipc_disconnected", .bridge)
    ]
    for (code, expected) in cases {
        let error = BridgeFailure(code, "技術原文 /private/example question=SECRET")
        let key = AppErrorPresentation.key(for: error)
        #expect(key == expected)
        #expect(!key.rawValue.contains("SECRET") && !key.rawValue.contains("/private"))
    }
    #expect(AppErrorPresentation.key(for: CancellationError()) == .cancelled)
    #expect(AppErrorPresentation.key(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) == .network)
    #expect(AppErrorPresentation.key(for: ContinuousGimbalError.staleLease) == .connectionChanged)
}

@Test func appUnknownErrorUsesActionableGenericWithoutGuessingMessageMeaning() {
    let first = BridgeFailure("unknown_future_code", "縮放已完成")
    let second = BridgeFailure("unknown_future_code", "Camera permission denied: SECRET")
    #expect(AppErrorPresentation.key(for: first) == .generic)
    #expect(AppErrorPresentation.key(for: second) == .generic)
    #expect(AppErrorMessageKey.generic.rawValue.contains("Check"))
    #expect(AppErrorPresentation.key(for: first, fallback: .loginItem) == .loginItem)
}

@Test func appDynamicErrorAndActivityKeysExistInAllThreeBundlesWithoutChangingGlobalLanguage() throws {
    let resource = AppResources.bundle
    let roots = [resource.resourceURL, resource.bundleURL].compactMap { $0 }
    let keys = AppErrorMessageKey.allCases.map(\.rawValue) + AppActivityMessageKey.allCases.map(\.rawValue)
    for language in ["en", "zh-Hant", "zh-Hans"] {
        let url = try #require(roots.map { $0.appendingPathComponent(language + ".lproj") }.first {
            FileManager.default.fileExists(atPath: $0.path)
        })
        let localized = try #require(Bundle(url: url))
        for key in keys {
            let text = localized.localizedString(forKey: key, value: "__MISSING__", table: "Localizable")
            #expect(text != "__MISSING__" && !text.isEmpty)
            if language == "en" {
                #expect(text == key)
                #expect(!text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
            }
        }
    }
}

@Test func appErrorDiagnosticsKeepBoundedOriginalDetailsOnlyInMemory() {
    let diagnostics = AppErrorDiagnostics() // Local instance: no shared test state.
    for index in 0..<20 { diagnostics.record(code: "test\(index)", details: "技術原文 /private/path \(index)") }
    let records = diagnostics.recentForAdvancedDiagnostics()
    #expect(records.count == 16 && records.first?.code == "test4")
    #expect(records.last?.details == "技術原文 /private/path 19")
    diagnostics.record(code: "test19", details: "技術原文 /private/path 19")
    #expect(diagnostics.recentForAdvancedDiagnostics().count == 16)
    diagnostics.record(code: String(repeating: "c", count: 1000), details: String(repeating: "d", count: 10000))
    #expect(diagnostics.recentForAdvancedDiagnostics().last?.code.count == 128)
    #expect(diagnostics.recentForAdvancedDiagnostics().last?.details.count == 4096)
}

@Test func appActivityPresentationDistinguishesExplicitEventsAndNeverGuessesFreeTextCompletion() throws {
    let started = Activity("move", "任意技術文字", presentationKey: "control.started")
    let completed = Activity("move", "任意技術文字", presentationKey: "control.completed")
    #expect(AppActivityPresentation.key(for: started) == .controlStarted)
    #expect(AppActivityPresentation.key(for: completed) == .controlCompleted)
    let legacy = Activity("move", "已完成，或是 still starting；不可猜測")
    #expect(AppActivityPresentation.key(for: legacy) == .recorded)
    #expect(AppActivityPresentation.key(for: Activity("future", "中文錯誤", isError: true)) == .failed)
    let encoded = try JSONEncoder().encode(legacy)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("presentationKey"))
    let decoded = try JSONDecoder().decode(Activity.self, from: encoded)
    #expect(decoded.presentationKey == nil && decoded.message == legacy.message)
    let event = try JSONDecoder().decode(Activity.self, from: JSONEncoder().encode(completed))
    #expect(event.presentationKey == "control.completed" && event.message == completed.message)
}
