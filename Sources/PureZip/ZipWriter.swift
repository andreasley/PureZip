import Foundation

/// Builds a ZIP archive in memory.
///
/// Entries are compressed with DEFLATE unless storing them uncompressed is
/// smaller (e.g. for already-compressed or tiny files). File names are stored
/// as UTF-8 with the UTF-8 flag set when they contain non-ASCII characters.
/// ZIP64 records are written automatically when sizes, offsets, or the entry
/// count require them.
///
/// For large archives or large entries, prefer `ZipFileWriter`, which streams
/// straight to disk with constant memory usage.
public final class ZipWriter {
    private var output: [UInt8] = []
    private var records: [ZipEntryRecord] = []
    private var addedPaths: Set<String> = []
    private let level: CompressionLevel

    public init(level: CompressionLevel = .normal) {
        self.level = level
    }

    /// Total bytes of entry data written so far.
    public var count: Int { output.count }

    // MARK: - Adding entries

    /// Adds a file entry with the given contents.
    ///
    /// - Parameters:
    ///   - path: Relative archive path using `/` separators.
    ///   - data: The file contents.
    ///   - compress: Pass `false` to force storing without compression.
    ///   - modificationDate: Timestamp recorded in the archive.
    ///   - permissions: POSIX permission bits recorded in the archive.
    public func addFile(
        path: String,
        data: Data,
        compress: Bool = true,
        modificationDate: Date = Date(),
        permissions: UInt16 = 0o644
    ) throws {
        let normalizedPath = try ZipPath.normalizedArchivePath(path, isDirectory: false)
        guard addedPaths.insert(normalizedPath).inserted else {
            throw ZipError.duplicateEntry(normalizedPath)
        }

        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload: [UInt8]? = nil
        if compress, !data.isEmpty {
            let compressed = Deflate.compress(data, level: level)
            if compressed.count < data.count {
                method = 8
                payload = compressed
            }
        }

        let externalAttributes = (UInt32(permissions & 0o7777) | 0o100000) << 16
        try addEntry(
            normalizedPath: normalizedPath,
            method: method,
            crc32: crc,
            uncompressedSize: UInt64(data.count),
            payload: payload,
            storedData: payload == nil ? data : nil,
            modificationDate: modificationDate,
            externalAttributes: externalAttributes
        )
    }

    /// Adds a directory entry.
    public func addDirectory(
        path: String,
        modificationDate: Date = Date(),
        permissions: UInt16 = 0o755
    ) throws {
        let normalizedPath = try ZipPath.normalizedArchivePath(path, isDirectory: true)
        guard addedPaths.insert(normalizedPath).inserted else {
            throw ZipError.duplicateEntry(normalizedPath)
        }
        // 0x10 is the MS-DOS directory attribute.
        let externalAttributes = ((UInt32(permissions & 0o7777) | 0o040000) << 16) | 0x10
        try addEntry(
            normalizedPath: normalizedPath,
            method: 0,
            crc32: 0,
            uncompressedSize: 0,
            payload: nil,
            storedData: nil,
            modificationDate: modificationDate,
            externalAttributes: externalAttributes
        )
    }

    private func addEntry(
        normalizedPath: String,
        method: UInt16,
        crc32: UInt32,
        uncompressedSize: UInt64,
        payload: [UInt8]?,
        storedData: Data?,
        modificationDate: Date,
        externalAttributes: UInt32
    ) throws {
        let nameBytes = [UInt8](normalizedPath.utf8)
        guard nameBytes.count <= 0xFFFF else { throw ZipError.invalidPath(normalizedPath) }

        let isASCII = normalizedPath.allSatisfy(\.isASCII)
        let flags: UInt16 = isASCII ? 0 : 0x0800 // UTF-8 name flag
        let (dosTime, dosDate) = DOSDate.fields(from: modificationDate)
        let compressedSize = UInt64(payload?.count ?? storedData?.count ?? 0)
        let localHeaderOffset = UInt64(output.count)
        let needsZip64Sizes = uncompressedSize >= 0xFFFF_FFFF || compressedSize >= 0xFFFF_FFFF

        // Local file header.
        output.appendLE32(0x0403_4B50)
        output.appendLE16(needsZip64Sizes ? 45 : 20) // version needed to extract
        output.appendLE16(flags)
        output.appendLE16(method)
        output.appendLE16(dosTime)
        output.appendLE16(dosDate)
        output.appendLE32(crc32)
        if needsZip64Sizes {
            output.appendLE32(0xFFFF_FFFF)
            output.appendLE32(0xFFFF_FFFF)
        } else {
            output.appendLE32(UInt32(compressedSize))
            output.appendLE32(UInt32(uncompressedSize))
        }
        output.appendLE16(UInt16(nameBytes.count))
        output.appendLE16(needsZip64Sizes ? 20 : 0) // extra field length
        output.append(contentsOf: nameBytes)
        if needsZip64Sizes {
            output.appendLE16(0x0001)
            output.appendLE16(16)
            output.appendLE64(uncompressedSize)
            output.appendLE64(compressedSize)
        }

        if let payload {
            output.append(contentsOf: payload)
        } else if let storedData {
            output.append(contentsOf: storedData)
        }

        records.append(
            ZipEntryRecord(
                nameBytes: nameBytes,
                flags: flags,
                method: method,
                dosTime: dosTime,
                dosDate: dosDate,
                crc32: crc32,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                externalAttributes: externalAttributes
            )
        )
    }

    // MARK: - Finalizing

    /// Writes the central directory and returns the completed archive.
    /// The writer must not be used after calling this.
    public func finalize() -> Data {
        let centralDirectoryOffset = UInt64(output.count)
        output += ZipFormat.centralDirectory(records: records, startingAt: centralDirectoryOffset)
        defer {
            output = []
            records = []
            addedPaths = []
        }
        return Data(output)
    }
}

// MARK: - Little-endian append helpers

extension [UInt8] {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE16(_ value: Int) {
        appendLE16(UInt16(value))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendLE64(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}
