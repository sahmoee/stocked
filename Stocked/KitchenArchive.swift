import Foundation
import zlib

/// Original, read-only ZIP/gzip implementation using Apple's system zlib. No paths are extracted.
/// Owner: Stocked; identical source is vendored by StockedMac. Deliberately excludes ZIP64,
/// encryption, split archives, executable prefixes, symlinks and unsupported compression.
nonisolated enum KitchenArchive {
    static let inputLimit = 32 * 1024 * 1024
    static let expandedLimit = 32 * 1024 * 1024
    static let entryLimit = 8 * 1024 * 1024
    static let countLimit = 500

    struct Entry: Sendable {
        let name: String
        let data: Data
    }

    struct Contents: Sendable {
        let entries: [Entry]
        /// Includes directories, so nested export readers can enforce a whole-import work budget.
        let entryCount: Int
    }

    enum ArchiveError: LocalizedError {
        case tooLarge, malformed, unsupported, unsafeName, duplicateName, checksum
        var errorDescription: String? {
            switch self {
            case .tooLarge: "This archive is too large. Export smaller groups (32 MB total, 500 files, 8 MB per file)."
            case .malformed: "This archive looks incomplete or damaged. Export it again from the original app."
            case .unsupported: "Use a standard, unencrypted ZIP export. Split archives, ZIP64 and this compression format aren’t supported."
            case .unsafeName: "This archive contains an unsafe file path or link. Nothing was imported."
            case .duplicateName: "This archive contains conflicting filenames. Export it again with unique filenames."
            case .checksum: "A file failed its integrity check. Export the archive again before importing."
            }
        }
    }

    private struct Record {
        let name: String
        let nameBytes: [UInt8]
        let flags: Int
        let method: Int
        let crc: UInt32
        let compressed: Int
        let expanded: Int
        let offset: Int
        let directory: Bool
    }

    static func read(_ data: Data) throws -> [Entry] {
        try readContents(data).entries
    }

    static func readContents(_ data: Data) throws -> Contents {
        try Task.checkCancellation()
        guard data.count <= inputLimit else { throw ArchiveError.tooLarge }
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ArchiveError.malformed }
        // An EOCD must end exactly at EOF, including its optional comment.
        let lower = max(0, bytes.count - 22 - 65_535)
        guard let end = stride(from: bytes.count - 22, through: lower, by: -1).first(where: {
            u32(bytes, $0) == 0x06054b50 && $0 + 22 + u16(bytes, $0 + 20) == bytes.count
        }) else { throw ArchiveError.malformed }
        let count = u16(bytes, end + 10)
        let centralSize = Int(u32(bytes, end + 12))
        let centralStart = Int(u32(bytes, end + 16))
        guard u16(bytes, end + 4) == 0, u16(bytes, end + 6) == 0,
              u16(bytes, end + 8) == count, count != 65_535,
              centralSize != Int(UInt32.max), centralStart != Int(UInt32.max)
        else { throw ArchiveError.unsupported }
        guard count <= countLimit else { throw ArchiveError.tooLarge }
        guard centralStart <= end, centralSize == end - centralStart else { throw ArchiveError.malformed }
        var cursor = centralStart
        var total = 0
        var names = Set<String>()
        var records: [Record] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard fits(cursor, 46, end), u32(bytes, cursor) == 0x02014b50 else { throw ArchiveError.malformed }
            let flags = u16(bytes, cursor + 8)
            let method = u16(bytes, cursor + 10)
            let compressed = Int(u32(bytes, cursor + 20))
            let expanded = Int(u32(bytes, cursor + 24))
            let nameLength = u16(bytes, cursor + 28)
            let extraLength = u16(bytes, cursor + 30)
            let commentLength = u16(bytes, cursor + 32)
            let offset = Int(u32(bytes, cursor + 42))
            guard u16(bytes, cursor + 6) <= 20, u16(bytes, cursor + 34) == 0,
                  flags & ~0x080e == 0, method == 0 || method == 8,
                  method != 0 || flags & 0x6 == 0,
                  compressed != Int(UInt32.max), expanded != Int(UInt32.max), offset != Int(UInt32.max)
            else { throw ArchiveError.unsupported }
            guard expanded <= entryLimit, compressed <= inputLimit,
                  total <= expandedLimit - expanded else { throw ArchiveError.tooLarge }
            total += expanded
            let length = 46 + nameLength + extraLength + commentLength
            guard fits(cursor, length, end), nameLength > 0, nameLength <= 1024 else { throw ArchiveError.malformed }
            let nameBytes = Array(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
            guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw ArchiveError.unsupported }
            try validatePath(name)
            let canonical = name.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard names.insert(canonical).inserted else { throw ArchiveError.duplicateName }
            let attributes = u32(bytes, cursor + 38)
            let unixKind = (attributes >> 16) & 0xf000
            guard unixKind == 0 || unixKind == 0x8000 || unixKind == 0x4000 else { throw ArchiveError.unsafeName }
            let directory = name.hasSuffix("/")
            guard (unixKind != 0x4000 || directory), (!directory || expanded == 0) else { throw ArchiveError.malformed }
            try validateExtra(bytes, start: cursor + 46 + nameLength, length: extraLength)
            records.append(Record(name: name, nameBytes: nameBytes, flags: flags, method: method,
                                  crc: u32(bytes, cursor + 16), compressed: compressed,
                                  expanded: expanded, offset: offset, directory: directory))
            cursor += length
        }
        guard cursor == end else { throw ArchiveError.malformed }
        if records.isEmpty {
            guard centralStart == 0 else { throw ArchiveError.malformed }
            return Contents(entries: [], entryCount: 0)
        }
        var lastEnd = 0
        var entries: [Entry] = []
        for row in records.sorted(by: { $0.offset < $1.offset }) {
            try Task.checkCancellation()
            let start = row.offset
            guard start == lastEnd, fits(start, 30, centralStart), u32(bytes, start) == 0x04034b50,
                  u16(bytes, start + 4) <= 20, u16(bytes, start + 6) == row.flags,
                  u16(bytes, start + 8) == row.method else { throw ArchiveError.malformed }
            let nameLength = u16(bytes, start + 26)
            let extraLength = u16(bytes, start + 28)
            guard nameLength == row.nameBytes.count, fits(start + 30, nameLength + extraLength, centralStart),
                  Array(bytes[(start + 30)..<(start + 30 + nameLength)]) == row.nameBytes
            else { throw ArchiveError.malformed }
            try validateExtra(bytes, start: start + 30 + nameLength, length: extraLength)
            let compressedStart = start + 30 + nameLength + extraLength
            guard fits(compressedStart, row.compressed, centralStart) else { throw ArchiveError.malformed }
            let hasDescriptor = row.flags & 8 != 0
            let localCRC = u32(bytes, start + 14)
            let localCompressed = Int(u32(bytes, start + 18))
            let localExpanded = Int(u32(bytes, start + 22))
            guard (localCRC == row.crc || (hasDescriptor && localCRC == 0)),
                  (localCompressed == row.compressed || (hasDescriptor && localCompressed == 0)),
                  (localExpanded == row.expanded || (hasDescriptor && localExpanded == 0))
            else { throw ArchiveError.malformed }
            var next = compressedStart + row.compressed
            if hasDescriptor {
                guard fits(next, 12, centralStart) else { throw ArchiveError.malformed }
                if u32(bytes, next) == 0x08074b50 { next += 4 }
                guard fits(next, 12, centralStart), u32(bytes, next) == row.crc,
                      Int(u32(bytes, next + 4)) == row.compressed,
                      Int(u32(bytes, next + 8)) == row.expanded else { throw ArchiveError.malformed }
                next += 12
            }
            lastEnd = next
            let compressedData = Data(bytes[compressedStart..<(compressedStart + row.compressed)])
            let output: Data
            if row.method == 0 {
                guard row.compressed == row.expanded else { throw ArchiveError.malformed }
                output = compressedData
            } else {
                output = try inflateData(compressedData, windowBits: -MAX_WBITS, limit: row.expanded)
            }
            guard output.count == row.expanded, checksum(output) == row.crc else { throw ArchiveError.checksum }
            if !row.directory { entries.append(Entry(name: row.name, data: output)) }
        }
        guard lastEnd == centralStart else { throw ArchiveError.malformed }
        return Contents(entries: entries, entryCount: count)
    }

    static func gunzip(_ data: Data, limit: Int = entryLimit) throws -> Data {
        guard data.count <= inputLimit, limit >= 0, limit <= expandedLimit else { throw ArchiveError.tooLarge }
        return try inflateData(data, windowBits: MAX_WBITS + 16, limit: limit)
    }

    private static func inflateData(_ data: Data, windowBits: Int32, limit: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw ArchiveError.unsupported }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { raw -> Data in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try Task.checkCancellation()
                let before = stream.total_in
                let status = buffer.withUnsafeMutableBytes { out -> Int32 in
                    stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(out.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let made = buffer.count - Int(stream.avail_out)
                guard result.count <= limit, made <= limit - result.count else { throw ArchiveError.tooLarge }
                result.append(contentsOf: buffer.prefix(made))
                if status == Z_STREAM_END {
                    // Trailing members/bytes are rejected instead of silently discarding content.
                    guard stream.avail_in == 0 else { throw ArchiveError.malformed }
                    return result
                }
                guard status == Z_OK, made > 0 || stream.total_in != before else { throw ArchiveError.malformed }
            }
        }
    }

    private static func validatePath(_ name: String) throws {
        guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw ArchiveError.unsafeName }
        let path = name.hasSuffix("/") ? String(name.dropLast()) : name
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw ArchiveError.unsafeName }
    }

    private static func validateExtra(_ bytes: [UInt8], start: Int, length: Int) throws {
        let end = start + length
        var at = start
        while at < end {
            guard fits(at, 4, end) else { throw ArchiveError.malformed }
            let tag = u16(bytes, at)
            let size = u16(bytes, at + 2)
            guard fits(at + 4, size, end) else { throw ArchiveError.malformed }
            guard tag != 0x0001, tag != 0x9901 else { throw ArchiveError.unsupported }
            at += 4 + size
        }
    }

    private static func fits(_ start: Int, _ length: Int, _ end: Int) -> Bool {
        start >= 0 && length >= 0 && start <= end && length <= end - start
    }
    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) << 8) }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    }
}
