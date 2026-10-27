import Foundation
import zlib

/// dotLottie (`.lottie`) files are ZIP archives: a `manifest.json` plus Lottie
/// JSON animations in `a/` (dotLottie 2) or `animations/` (dotLottie 1).
/// Images, themes and state machines in the archive are ignored.
enum DotLottie {
    private static let animationFolders = ["a/", "animations/"]

    static func isArchive(_ data: Data) -> Bool {
        data.starts(with: [0x50, 0x4B, 0x03, 0x04]) // "PK\u{3}\u{4}"
    }

    /// Returns the Lottie JSON of the animation the manifest starts with,
    /// or of the first animation in the archive when the manifest does not say.
    static func animationJSON(from data: Data, limit: Int) throws -> Data {
        let archive = try ZipArchive(data)
        let jsonEntries = archive.entries.filter { entry in
            entry.name.hasSuffix(".json") && animationFolders.contains { entry.name.hasPrefix($0) }
        }

        // A broken manifest is not fatal: the animation itself may still be fine.
        let preferredID = (try? manifest(in: archive, limit: limit))?.startAnimationID
        let preferred = preferredID.flatMap { id in
            animationFolders.lazy.compactMap { folder in
                jsonEntries.first { $0.name == "\(folder)\(id).json" }
            }.first
        }
        guard let entry = preferred ?? jsonEntries.min(by: { $0.name < $1.name }) else {
            throw TLottieError.invalidData
        }
        return try archive.contents(of: entry, limit: limit)
    }

    private static func manifest(in archive: ZipArchive, limit: Int) throws -> Manifest? {
        guard let entry = archive.entries.first(where: { $0.name == "manifest.json" }) else {
            return nil
        }
        return try JSONDecoder().decode(Manifest.self, from: archive.contents(of: entry, limit: limit))
    }
}

/// The parts of `manifest.json` that pick the animation to play.
private struct Manifest: Decodable {
    struct Animation: Decodable {
        let id: String
    }

    struct Initial: Decodable {
        let animation: String?
    }

    let animations: [Animation]?
    /// dotLottie 2.
    let initial: Initial?
    /// dotLottie 1.
    let activeAnimationId: String?

    var startAnimationID: String? {
        initial?.animation ?? activeAnimationId ?? animations?.first?.id
    }
}

/// Just enough of the ZIP format for dotLottie: the central directory and
/// stored or deflated entries. ZIP64, encryption and multi-disk archives are
/// rejected as invalid data.
struct ZipArchive {
    struct Entry {
        let name: String
        fileprivate let flags: UInt16
        fileprivate let method: UInt16
        fileprivate let crc32: UInt32
        fileprivate let compressedSize: Int
        fileprivate let uncompressedSize: Int
        fileprivate let localHeaderOffset: Int
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let endOfCentralDirectorySize = 22
    private static let centralDirectoryHeaderSize = 46
    private static let localHeaderSize = 30
    private static let maxCommentSize = 0xFFFF

    private let data: Data
    let entries: [Entry]

    init(_ data: Data) throws {
        // Index from 0 even when `data` is a slice.
        self.data = data.startIndex == 0 ? data : Data(data)
        self.entries = try Self.readCentralDirectory(self.data)
    }

    /// The uncompressed bytes of `entry`, checked against its CRC-32.
    func contents(of entry: Entry, limit: Int) throws -> Data {
        guard entry.flags & 0x1 == 0 else { // encrypted
            throw TLottieError.invalidData
        }
        guard entry.uncompressedSize <= limit else {
            throw TLottieError.decompressedSizeLimitExceeded(limit: limit)
        }

        let header = entry.localHeaderOffset
        guard try Self.uint32(data, at: header) == Self.localHeaderSignature else {
            throw TLottieError.invalidData
        }
        // The local header repeats the name and has its own extra field, so
        // its length can differ from the central directory's copy.
        let nameLength = Int(try Self.uint16(data, at: header + 26))
        let extraLength = Int(try Self.uint16(data, at: header + 28))
        let start = header + Self.localHeaderSize + nameLength + extraLength
        guard start <= data.count, entry.compressedSize <= data.count - start else {
            throw TLottieError.decompressionFailed
        }
        let payload = data.subdata(in: start ..< start + entry.compressedSize)

        let contents: Data
        switch entry.method {
        case 0: // stored
            contents = payload
        case 8: // deflate
            contents = try Gzip.inflateRaw(payload, limit: limit)
        default:
            throw TLottieError.invalidData
        }
        guard contents.count == entry.uncompressedSize, Self.crc32(of: contents) == entry.crc32 else {
            throw TLottieError.decompressionFailed
        }
        return contents
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        let end = try findEndOfCentralDirectory(data)
        let diskNumber = try uint16(data, at: end + 4)
        let entryCount = Int(try uint16(data, at: end + 10))
        let directoryOffset = try uint32(data, at: end + 16)
        // 0xFFFF / 0xFFFFFFFF mean the real values live in a ZIP64 record.
        guard diskNumber == 0, entryCount != 0xFFFF, directoryOffset != 0xFFFF_FFFF else {
            throw TLottieError.invalidData
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var offset = Int(directoryOffset)
        for _ in 0 ..< entryCount {
            guard try uint32(data, at: offset) == centralDirectorySignature else {
                throw TLottieError.invalidData
            }
            let nameLength = Int(try uint16(data, at: offset + 28))
            let extraLength = Int(try uint16(data, at: offset + 30))
            let commentLength = Int(try uint16(data, at: offset + 32))
            let nameStart = offset + centralDirectoryHeaderSize
            guard nameStart + nameLength <= data.count else {
                throw TLottieError.invalidData
            }
            entries.append(Entry(
                name: String(decoding: data[nameStart ..< nameStart + nameLength], as: UTF8.self),
                flags: try uint16(data, at: offset + 8),
                method: try uint16(data, at: offset + 10),
                crc32: try uint32(data, at: offset + 16),
                compressedSize: Int(try uint32(data, at: offset + 20)),
                uncompressedSize: Int(try uint32(data, at: offset + 24)),
                localHeaderOffset: Int(try uint32(data, at: offset + 42))
            ))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// The end record sits at the very end, followed only by an optional
    /// comment of up to 64 KiB, so search backwards from there.
    private static func findEndOfCentralDirectory(_ data: Data) throws -> Int {
        guard data.count >= endOfCentralDirectorySize else {
            throw TLottieError.invalidData
        }
        let last = data.count - endOfCentralDirectorySize
        let first = max(0, last - maxCommentSize)
        for offset in stride(from: last, through: first, by: -1)
            where try uint32(data, at: offset) == endOfCentralDirectorySignature {
            return offset
        }
        throw TLottieError.invalidData
    }

    private static func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= data.count - 2 else {
            throw TLottieError.invalidData
        }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else {
            throw TLottieError.invalidData
        }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func crc32(of data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(zlib.crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
        }
    }
}
