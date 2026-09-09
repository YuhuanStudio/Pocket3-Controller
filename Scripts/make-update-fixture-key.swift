import Foundation
import CryptoKit

// Ephemeral signing fixtures only. No Keychain access or secret stdout.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let key = Curve25519.Signing.PrivateKey()
let secret = directory.appendingPathComponent("private-key.txt")
try key.rawRepresentation.base64EncodedString().write(to: secret, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: directory.appendingPathComponent("public-key.txt"), atomically: true, encoding: .utf8)
