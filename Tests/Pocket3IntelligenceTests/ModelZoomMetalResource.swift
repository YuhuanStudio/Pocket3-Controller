import Foundation
import CryptoKit
import Pocket3Core

private final class ModelZoomBundleAnchor: NSObject {}

private final class ModelZoomBundleRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var retained: [Bundle] = []
    func retain(_ bundle: Bundle) {
        lock.withLock {
            if !retained.contains(where: { $0.bundleURL == bundle.bundleURL }) { retained.append(bundle) }
        }
    }
}

/// Registers the already-executing test bundle with Foundation so upstream
/// load_swiftpm_library can find its nested resource bundle via allBundles.
/// Metallib data belongs under Contents/Resources, never Contents/MacOS.
enum ModelZoomMetalResource {
    private static let registry = ModelZoomBundleRegistry()
    private static let resourceBundleName = "mlx-swift_Cmlx.bundle"

    static func prepare(project: URL) throws -> JSONValue {
        let files = FileManager.default
        let root = canonical(project)
        let build = canonical(root.appendingPathComponent(".build", isDirectory: true))
        let bundle = Bundle(for: ModelZoomBundleAnchor.self)
        let testURL = canonical(bundle.bundleURL)
        guard build.path.hasPrefix(root.path + "/"), testURL.pathExtension == "xctest",
              testURL.path.hasPrefix(build.path + "/"), let executable = bundle.executableURL,
              canonical(executable).path.hasPrefix(testURL.path + "/Contents/MacOS/") else {
            throw unavailable("The model test bundle is not inside this repository's .build test products")
        }
        let initiallyListed = Bundle.allBundles.contains { canonical($0.bundleURL) == testURL }
        if !initiallyListed || !bundle.isLoaded {
            // Test code is already executing from this image. This registers
            // it with NSBundle; it does not ask MLX to initialize a GPU device.
            try bundle.loadAndReturnError()
        }
        registry.retain(bundle)
        guard let registered = Bundle.allBundles.first(where: { canonical($0.bundleURL) == testURL }),
              let resourceURL = registered.resourceURL else {
            throw unavailable("The test bundle is not registered in Bundle.allBundles; refusing to initialize MLX")
        }
        let resources = canonical(resourceURL)
        guard resources == canonical(testURL.appendingPathComponent("Contents/Resources", isDirectory: true)),
              resources.path.hasPrefix(build.path + "/") else {
            throw unavailable("The registered test bundle has an unexpected resource directory")
        }

        let packagedBundleURL = canonical(root.appendingPathComponent("dist/Pocket 3 Controller.app/Contents/Resources/" + resourceBundleName))
        guard packagedBundleURL.path.hasPrefix(root.appendingPathComponent("dist").path + "/"),
              let packaged = Bundle(url: packagedBundleURL), let packagedResources = packaged.resourceURL else {
            throw unavailable("The packaged App's local MLX resource bundle is missing")
        }
        let source = canonical(packagedResources.appendingPathComponent("default.metallib"))
        guard source.path.hasPrefix(packagedBundleURL.path + "/") else { throw unavailable("Packaged metallib escapes its resource bundle") }
        let contents = try readLibrary(source)
        let sourceHash = sha256(contents)

        // This is the exact lookup performed by upstream try_load_bundle:
        // registered.resourceURL / SWIFTPM_BUNDLE.bundle / resources / default.metallib.
        let nestedURL = resources.appendingPathComponent(resourceBundleName, isDirectory: true)
        guard !isSymlink(nestedURL), canonical(nestedURL).path.hasPrefix(resources.path + "/") else {
            throw unavailable("MLX resource bundle target is a symlink or escapes test Resources")
        }
        var copied = false
        if !files.fileExists(atPath: nestedURL.path) {
            try files.createDirectory(at: resources, withIntermediateDirectories: true)
            try files.copyItem(at: packagedBundleURL, to: nestedURL)
            copied = true
        }
        guard let nested = Bundle(url: nestedURL), let nestedResources = nested.resourceURL else {
            throw unavailable("The test's existing MLX resource bundle has invalid bundle metadata")
        }
        registry.retain(nested)
        let target = nestedResources.appendingPathComponent("default.metallib")
        guard !isSymlink(target), canonical(target).path.hasPrefix(resources.path + "/"),
              canonical(nestedResources).path.hasPrefix(canonical(nestedURL).path + "/") else {
            throw unavailable("Metallib target escapes the test resource bundle")
        }
        let existing = try? readLibrary(target)
        if existing.map(sha256) != sourceHash {
            if files.fileExists(atPath: target.path) {
                let attributes = try files.attributesOfItem(atPath: target.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else { throw unavailable("Refusing to replace a non-regular resource file") }
            }
            try files.createDirectory(at: nestedResources, withIntermediateDirectories: true)
            try contents.write(to: target, options: .atomic)
            copied = true
        }
        let targetHash = sha256(try readLibrary(target))
        guard targetHash == sourceHash,
              Bundle.allBundles.contains(where: { canonical($0.bundleURL) == testURL }) else {
            throw unavailable("MLX resource hash or NSBundle registration changed during preparation")
        }
        return .object([
            "prepared": .bool(true), "copied": .bool(copied), "initiallyRegistered": .bool(initiallyListed),
            "registeredInAllBundles": .bool(true), "testBundleLoaded": .bool(bundle.isLoaded),
            "source": .string(source.path), "target": .string(target.path), "testBundle": .string(testURL.path),
            "registeredResourceURL": .string(resources.path), "resourceBundle": .string(nestedURL.path),
            "bytes": .number(Double(contents.count)), "sourceSHA256": .string(sourceHash), "targetSHA256": .string(targetHash),
            "lookup": .string("NSBundle.allBundles resourceURL -> mlx-swift_Cmlx.bundle -> default.metallib"),
            "scope": .string("repository .build test Contents/Resources only; no explicit GPU or MLX calls")
        ])
    }

    private static func readLibrary(_ url: URL) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, (4...64_000_000).contains(size),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw unavailable("The local metallib is missing or is not a bounded regular file")
        }
        let data = try Data(contentsOf: url)
        guard data.count == size, data.prefix(4) == Data([0x4d, 0x54, 0x4c, 0x42]) else {
            throw unavailable("The local metallib has an invalid Metal library header")
        }
        return data
    }
    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private static func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func unavailable(_ message: String) -> BridgeFailure { BridgeFailure("model_check_unavailable", message) }
}
