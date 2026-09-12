import Foundation

/// Media type codes observed in the CompositePack index. Unknown values stay
/// typed as `.unknown(raw:)`; they are never coerced into a file extension.
public enum Pocket3MediaFileType: Codable, Sendable, Equatable {
    case jpeg
    case dng
    case mov
    case mp4
    case panorama
    case tiff
    case audio
    case lrf
    case thm
    case scr
    case osv
    case unknown(raw: UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .jpeg
        case 1: self = .dng
        case 2: self = .mov
        case 3: self = .mp4
        case 4: self = .panorama
        case 5: self = .tiff
        case 10: self = .audio
        case 19: self = .lrf
        case 20: self = .thm
        case 21: self = .scr
        case 44: self = .osv
        default: self = .unknown(raw: rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .jpeg: 0
        case .dng: 1
        case .mov: 2
        case .mp4: 3
        case .panorama: 4
        case .tiff: 5
        case .audio: 10
        case .lrf: 19
        case .thm: 20
        case .scr: 21
        case .osv: 44
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    public var isVideo: Bool { self == .mov || self == .mp4 }
}

/// One structurally decoded media-path record. The media and thumbnail paths
/// are read from length-delimited fields. Metadata is optional because the
/// Pocket 3 writes multiple record layouts and unknown enum bytes must remain
/// visible without being guessed.
public struct Pocket3MediaIndexEntry: Codable, Sendable, Equatable {
    public let mediaPath: String
    public let thumbnailPath: String?
    public let fileName: String?
    public let fileTypeRaw: UInt8?
    public let fileType: Pocket3MediaFileType?
    public let handle: UInt32?
    public let sizeBytes: UInt32?
    public let durationSeconds: UInt16?
    public let frameRateRaw: UInt8?
    public let resolutionRaw: UInt8?
    public let starred: Bool?

    public init(mediaPath: String, thumbnailPath: String? = nil,
                fileName: String? = nil, fileTypeRaw: UInt8? = nil,
                fileType: Pocket3MediaFileType? = nil,
                handle: UInt32? = nil, sizeBytes: UInt32? = nil,
                durationSeconds: UInt16? = nil, frameRateRaw: UInt8? = nil,
                resolutionRaw: UInt8? = nil, starred: Bool? = nil) {
        self.mediaPath = mediaPath
        self.thumbnailPath = thumbnailPath
        self.fileName = fileName
        self.fileTypeRaw = fileTypeRaw
        self.fileType = fileType
        self.handle = handle
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.frameRateRaw = frameRateRaw
        self.resolutionRaw = resolutionRaw
        self.starred = starred
    }

    /// A usable `/v2` path only when the record carries a matching filename
    /// extension. The base media path itself is retained separately.
    public var path: String {
        let base = mediaPath.split(separator: "/").last.map(String.init)
        guard let fileName, let dot = fileName.lastIndex(of: "."),
              dot > fileName.startIndex,
              String(fileName[..<dot]) == base
        else { return mediaPath }
        return mediaPath + fileName[dot...]
    }

    public var hasKnownFileType: Bool { fileType?.isUnknown == false }
}

/// Typed view of one completed `00/26` CompositePack page. `raw` and
/// `unknownChunks` remain available as evidence, while entries expose only
/// fields whose tag/offset is structurally bounded by that record's media path
/// and the next record boundary.
public struct Pocket3MediaIndex: Codable, Sendable, Equatable {
    public static let maximumEntries = Pocket3MediaListReassembler.maximumChunks

    public let identity: Pocket3MediaSessionIdentity
    public let counter: UInt8
    public let cursor: UInt32
    public let storage: UInt8?
    public let declaredRecordCount: UInt32?
    public let entries: [Pocket3MediaIndexEntry]
    public let raw: Data
    public let unknownRaw: [Data]
    public let countMatchesDeclared: Bool?

    public init(pack: Pocket3MediaListPack) throws {
        guard pack.raw.count <= Pocket3MediaListReassembler.maximumAssembledBytes,
              pack.unknownChunks.count <= Self.maximumEntries else {
            throw Pocket3MediaProtocolError.responseTooLarge
        }
        let parsed = Self.parse(pack.raw)
        guard parsed.count <= Self.maximumEntries else {
            throw Pocket3MediaProtocolError.responseTooLarge
        }
        self.identity = pack.identity
        self.counter = pack.counter
        self.cursor = pack.cursor
        self.storage = pack.cursor & Pocket3MediaListRequest.internalBit != 0 ? 1 : 0
        self.declaredRecordCount = pack.declaredRecordCount
        self.entries = parsed
        self.raw = pack.raw
        self.unknownRaw = pack.unknownRaw
        if let declared = pack.declaredRecordCount {
            self.countMatchesDeclared = Int(declared) == parsed.count
        } else {
            self.countMatchesDeclared = nil
        }
    }

    public init(identity: Pocket3MediaSessionIdentity, counter: UInt8,
                cursor: UInt32, declaredRecordCount: UInt32?,
                entries: [Pocket3MediaIndexEntry], raw: Data,
                unknownRaw: [Data] = []) throws {
        guard counter != 0, entries.count <= Self.maximumEntries,
              raw.count <= Pocket3MediaListReassembler.maximumAssembledBytes,
              unknownRaw.count <= Self.maximumEntries else {
            throw Pocket3MediaProtocolError.responseTooLarge
        }
        self.identity = identity
        self.counter = counter
        self.cursor = cursor
        self.storage = cursor & Pocket3MediaListRequest.internalBit != 0 ? 1 : 0
        self.declaredRecordCount = declaredRecordCount
        self.entries = entries
        self.raw = raw
        self.unknownRaw = unknownRaw
        self.countMatchesDeclared = declaredRecordCount.map {
            Int($0) == entries.count
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: values.decode(Pocket3MediaSessionIdentity.self,
                                    forKey: .identity),
            counter: values.decode(UInt8.self, forKey: .counter),
            cursor: values.decode(UInt32.self, forKey: .cursor),
            declaredRecordCount: values.decodeIfPresent(UInt32.self,
                                                        forKey: .declaredRecordCount),
            entries: values.decode([Pocket3MediaIndexEntry].self,
                                   forKey: .entries),
            raw: values.decode(Data.self, forKey: .raw),
            unknownRaw: values.decode([Data].self, forKey: .unknownRaw))
    }

    private enum CodingKeys: String, CodingKey {
        case identity, counter, cursor, declaredRecordCount, entries, raw,
             unknownRaw
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    private struct PathField {
        let value: String
        let end: Int
    }

    private static func parse(_ raw: Data) -> [Pocket3MediaIndexEntry] {
        let bytes = Array(raw)
        guard !bytes.isEmpty else { return [] }
        var paths: [(position: Int, field: PathField)] = []
        var cursor = 0
        while cursor < bytes.count {
            if let field = pathField(bytes, at: cursor, subtype: 1,
                                      prefix: "DCIM/") {
                paths.append((cursor, field))
                cursor = field.end
            } else {
                cursor += 1
            }
        }
        guard !paths.isEmpty else { return [] }

        var entries: [Pocket3MediaIndexEntry] = []
        entries.reserveCapacity(min(paths.count, Self.maximumEntries))
        for index in paths.indices.prefix(Self.maximumEntries) {
            let current = paths[index]
            let lower = index == paths.startIndex ? 0 : paths[index - 1].field.end
            let upper = index + 1 < paths.count
                ? paths[index + 1].position : bytes.count
            let base = current.field.value.split(separator: "/").last.map(String.init) ?? ""
            let fileName = filename(bytes, lower: lower, upper: upper,
                                    base: base)
            let thumbnail = thumbnailPath(bytes, lower: lower, upper: upper,
                                          base: base)
            let metadata = metadata(bytes, pathPosition: current.position,
                                    lower: lower, upper: upper)
            entries.append(Pocket3MediaIndexEntry(
                mediaPath: current.field.value, thumbnailPath: thumbnail,
                fileName: fileName, fileTypeRaw: metadata.typeRaw,
                fileType: metadata.typeRaw.map(Pocket3MediaFileType.init(rawValue:)),
                handle: metadata.handle, sizeBytes: metadata.sizeBytes,
                durationSeconds: metadata.durationSeconds,
                frameRateRaw: metadata.frameRateRaw,
                resolutionRaw: metadata.resolutionRaw,
                starred: metadata.starred))
        }
        return entries
    }

    private static func pathField(_ bytes: [UInt8], at position: Int,
                                  subtype: UInt8, prefix: String)
        -> PathField? {
        guard position >= 0, position + 6 <= bytes.count,
              bytes[position] == 0x1A,
              bytes[position + 2] == 0, bytes[position + 3] == 0,
              bytes[position + 4] == 0, bytes[position + 5] == subtype else {
            return nil
        }
        let total = Int(bytes[position + 1])
        guard total >= 6, position + total <= bytes.count else { return nil }
        let length = total - 6
        let valueBytes = Array(bytes[(position + 6)..<(position + total)])
        guard valueBytes.count == length,
              valueBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            return nil
        }
        let value = String(decoding: valueBytes, as: UTF8.self)
        guard value.hasPrefix(prefix) else { return nil }
        return PathField(value: value, end: position + total)
    }

    private static func filename(_ bytes: [UInt8], lower: Int, upper: Int,
                                 base: String) -> String? {
        guard lower >= 0, lower < upper else { return nil }
        var index = lower
        while index + 2 <= upper {
            guard bytes[index] == 0x0D else {
                index += 1
                continue
            }
            let length = Int(bytes[index + 1])
            guard length > 0, index + 2 + length <= upper else {
                index += 1
                continue
            }
            let valueBytes = Array(bytes[(index + 2)..<(index + 2 + length)])
            guard valueBytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
                index += 1
                continue
            }
            let value = String(decoding: valueBytes, as: UTF8.self)
            if value.hasPrefix(base + "."), value.count > base.count + 1 {
                return value
            }
            index += 1
        }
        return nil
    }

    private static func thumbnailPath(_ bytes: [UInt8], lower: Int,
                                      upper: Int, base: String) -> String? {
        guard lower >= 0, lower < upper else { return nil }
        var index = lower
        while index < upper {
            if let field = pathField(bytes, at: index, subtype: 2,
                                     prefix: "MISC/"), field.end <= upper,
               field.value.hasSuffix(base) {
                return field.value
            }
            index += 1
        }
        return nil
    }

    private struct Metadata {
        var typeRaw: UInt8?
        var handle: UInt32?
        var sizeBytes: UInt32?
        var durationSeconds: UInt16?
        var frameRateRaw: UInt8?
        var resolutionRaw: UInt8?
        var starred: Bool?
    }

    private static func metadata(_ bytes: [UInt8], pathPosition: Int,
                                 lower: Int, upper: Int) -> Metadata {
        var result = Metadata()
        // Pocket 3's known CompositePack layout puts `19 06` seven bytes
        // before the media-path field. Refuse to read offsets without that
        // anchor; this keeps neighboring records from donating metadata.
        let tag = pathPosition - 7
        guard tag >= lower, tag + 1 < upper,
              bytes[tag] == 0x19, bytes[tag + 1] == 0x06 else {
            result.starred = starBySignature(bytes, lower: lower, upper: upper)
            return result
        }
        let typePosition = tag - 2
        if typePosition >= lower { result.typeRaw = bytes[typePosition] }
        result.handle = readUInt32(bytes, at: tag - 10)
        result.sizeBytes = readUInt32(bytes, at: tag - 14)
        if result.typeRaw.map({ Pocket3MediaFileType(rawValue: $0).isVideo }) == true {
            result.durationSeconds = readUInt16(bytes, at: tag - 6)
            if tag - 4 >= lower, tag - 4 < upper {
                result.frameRateRaw = bytes[tag - 4]
            }
            if tag - 3 >= lower, tag - 3 < upper {
                result.resolutionRaw = bytes[tag - 3]
            }
        }
        result.starred = starBySignature(bytes, lower: lower, upper: upper)
        if result.starred == nil {
            let starPosition = tag + 8
            if starPosition >= lower, starPosition < upper,
               bytes[starPosition] == 0 || bytes[starPosition] == 1 {
                result.starred = bytes[starPosition] == 1
            }
        }
        return result
    }

    private static let starSignature: [UInt8] = [
        0x1B, 0x0A, 0x00, 0x00, 0x00, 0x02, 0x02, 0x01,
        0x14, 0x02, 0x15, 0x03
    ]

    private static func starBySignature(_ bytes: [UInt8], lower: Int,
                                        upper: Int) -> Bool? {
        let end = min(upper, bytes.count) - starSignature.count - 1
        guard lower <= end else { return nil }
        for position in lower...end {
            guard bytes[position..<(position + starSignature.count)].elementsEqual(
                starSignature[...]) else { continue }
            let value = bytes[position + starSignature.count]
            if value == 0 || value == 1 { return value == 1 }
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], at position: Int)
        -> UInt16? {
        guard position >= 0, position + 1 < bytes.count else { return nil }
        return UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], at position: Int)
        -> UInt32? {
        guard position >= 0, position + 3 < bytes.count else { return nil }
        let value = UInt32(bytes[position]) |
            UInt32(bytes[position + 1]) << 8 |
            UInt32(bytes[position + 2]) << 16 |
            UInt32(bytes[position + 3]) << 24
        return value == 0 ? nil : value
    }
}

public typealias Pocket3NativeMediaIndex = Pocket3MediaIndex
public typealias Pocket3NativeMediaIndexEntry = Pocket3MediaIndexEntry
