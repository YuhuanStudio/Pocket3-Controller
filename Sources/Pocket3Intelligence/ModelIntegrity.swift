import CryptoKit
import Foundation
import Pocket3Core

public enum ModelIntegrity {
    public static func verify(url: URL, bytes: Int64, sha256: String) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256(), count: Int64 = 0
        while let data = try file.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= bytes else { throw BridgeFailure("model_checksum", "模型檔案大小不符，請刪除後重新下載") }
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == bytes && digest == sha256 else { throw BridgeFailure("model_checksum", "模型校驗失敗，請刪除後重新下載") }
    }
    public static func verifyAsync(url: URL, bytes: Int64, sha256: String) async throws {
        let task = Task.detached(priority: .utility) { try verify(url: url, bytes: bytes, sha256: sha256) }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
