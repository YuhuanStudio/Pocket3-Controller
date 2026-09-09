import CryptoKit
import Foundation
import Testing
import Pocket3Core
@testable import Pocket3Intelligence

@Test func corruptedOrTruncatedWeightsCannotPassVerification() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("weights")
    let valid = Data("weights".utf8)
    let sha = SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined()
    try valid.write(to: file)
    try ModelIntegrity.verify(url: file, bytes: 7, sha256: sha)
    try Data("WEIGHTS".utf8).write(to: file)
    #expect(throws: BridgeFailure.self) { try ModelIntegrity.verify(url: file, bytes: 7, sha256: sha) }
    try Data("weight".utf8).write(to: file)
    #expect(throws: BridgeFailure.self) { try ModelIntegrity.verify(url: file, bytes: 7, sha256: sha) }
}
