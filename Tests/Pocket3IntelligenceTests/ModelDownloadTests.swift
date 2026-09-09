import Foundation
import Testing
import Pocket3Core
@testable import Pocket3Intelligence

private actor DownloadProbe {
    var callbacks: [@Sendable (Double) -> Void] = []
    func run(directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: directory.appendingPathComponent("download.incomplete"))
        callbacks.append(progress); progress(0.1)
        try await Task.sleep(for: .seconds(30))
    }
    func starts() -> Int { callbacks.count }
    func staleProgress() { callbacks.first?(0.99) }
}
private func rootDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pocket3-download-" + UUID().uuidString)
}
private func waitFor(_ condition: () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Download did not reach the expected state")
}
@Test func cancellationKeepsPartialFilesVisibleAndAllowsAResume() async throws {
    let root = rootDirectory(), probe = DownloadProbe()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(rootURL: root) { directory, progress in try await probe.run(directory: directory, progress: progress) }
    let first = Task { try await manager.download() }
    try await waitFor { await manager.status().progress == 0.1 }
    await manager.unload()
    #expect(await manager.status().phase == "downloading")
    await manager.cancelDownload()
    do { try await first.value; Issue.record("Cancelled download succeeded") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(await manager.status().phase == "cancelled")
    #expect(await manager.status().hasDownload)
    #expect(await manager.status().available == false)
    let retry = Task { try await manager.download() }
    try await waitFor {
        let count = await probe.starts()
        let state = await manager.status()
        return count == 2 && state.progress == 0.1
    }
    await probe.staleProgress()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await manager.status().progress == 0.1)
    await manager.cancelDownload(); _ = try? await retry.value
    try await manager.deleteDownload()
    #expect(await manager.status().hasDownload == false)
    #expect(await manager.status().phase == "notDownloaded")
}
@Test func sharedDownloadDoesNotStartASecondTransfer() async throws {
    let root = rootDirectory(), probe = DownloadProbe()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(rootURL: root) { directory, progress in try await probe.run(directory: directory, progress: progress) }
    let first = Task { try await manager.download() }
    try await waitFor { await probe.starts() == 1 }
    let second = Task { try await manager.download() }
    try await Task.sleep(for: .milliseconds(30))
    #expect(await probe.starts() == 1)
    do { try await manager.deleteDownload(); Issue.record("Deleted files during download") } catch {}
    await manager.cancelDownload(); _ = try? await first.value; _ = try? await second.value
}
@Test func aFailedTransferRemainsAnErrorAfterUnload() async throws {
    let root = rootDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalModelManager(rootURL: root) { directory, _ in
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
        throw BridgeFailure("model_checksum", "Invalid weights")
    }
    do { try await manager.download(); Issue.record("Invalid transfer succeeded") } catch {}
    await manager.unload()
    let state = await manager.status()
    #expect(state.phase == "error" && !state.available && state.hasDownload)
    try await manager.deleteDownload()
    #expect(await manager.status().hasDownload == false)
}
