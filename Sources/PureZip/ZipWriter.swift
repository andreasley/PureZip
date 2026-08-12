import Foundation

/// Builds a ZIP archive in memory.
///
/// Entries are compressed with DEFLATE unless storing them uncompressed is
/// smaller (e.g. for already-compressed or tiny files). File names are stored
/// as UTF-8 with the UTF-8 flag set when they contain non-ASCII characters.
/// ZIP64 records are written automatically when sizes, offsets, or the entry
/// count require them.
public final class ZipWriter {
    private struct PendingCentralRecord {
        let nameBytes: [UInt8]
        let flags: UInt16
        let method: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let externalAttributes: UInt32
        let isDirectory: Bool
    }

    private var output: [UInt8] = []
    private var records: [PendingCentralRecord] = []
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
            externalAttributes: externalAttributes,
            isDirectory: false
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
            externalAttributes: externalAttributes,
            isDirectory: true
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
        externalAttributes: UInt32,
        isDirectory: Bool
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
            PendingCentralRecord(
                nameBytes: nameBytes,
                flags: flags,
                method: method,
                dosTime: dosTime,
                dosDate: dosDate,
                crc32: crc32,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                externalAttributes: externalAttributes,
                isDirectory: isDirectory
            )
        )
    }

    // MARK: - Finalizing

    /// Writes the central directory and returns the completed archive.
    /// The writer must not be used after calling this.
    public func finalize() -> Data {
        let centralDirectoryOffset = UInt64(output.count)

        for record in records {
            var zip64Fields: [UInt64] = []
            let needsSizeFields = record.uncompressedSize >= 0xFFFF_FFFF
                || record.compressedSize >= 0xFFFF_FFFF
            if record.uncompressedSize >= 0xFFFF_FFFF { zip64Fields.append(record.uncompressedSize) }
            if record.compressedSize >= 0xFFFF_FFFF { zip64Fields.append(record.compressedSize) }
            if record.localHeaderOffset >= 0xFFFF_FFFF { zip64Fields.append(record.localHeaderOffset) }
            let extraLength = zip64Fields.isEmpty ? 0 : 4 + 8 * zip64Fields.count

            output.appendLE32(0x0201_4B50)
            output.appendLE16((3 << 8) | 20) // made by: Unix, PKZIP 2.0
            output.appendLE16(needsSizeFields || record.localHeaderOffset >= 0xFFFF_FFFF ? 45 : 20)
            output.appendLE16(record.flags)
            output.appendLE16(record.method)
            output.appendLE16(record.dosTime)
            output.appendLE16(record.dosDate)
            output.appendLE32(record.crc32)
            output.appendLE32(record.compressedSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(record.compressedSize))
            output.appendLE32(record.uncompressedSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(record.uncompressedSize))
            output.appendLE16(UInt16(record.nameBytes.count))
            output.appendLE16(UInt16(extraLength))
            output.appendLE16(0) // comment length
            output.appendLE16(0) // disk number start
            output.appendLE16(0) // internal attributes
            output.appendLE32(record.externalAttributes)
            output.appendLE32(record.localHeaderOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(record.localHeaderOffset))
            output.append(contentsOf: record.nameBytes)
            if !zip64Fields.isEmpty {
                output.appendLE16(0x0001)
                output.appendLE16(UInt16(8 * zip64Fields.count))
                for field in zip64Fields { output.appendLE64(field) }
            }
        }

        let centralDirectorySize = UInt64(output.count) - centralDirectoryOffset
        let entryCount = UInt64(records.count)
        let needsZip64End = entryCount >= 0xFFFF
            || centralDirectorySize >= 0xFFFF_FFFF
            || centralDirectoryOffset >= 0xFFFF_FFFF

        if needsZip64End {
            let zip64EndOffset = UInt64(output.count)
            output.appendLE32(0x0606_4B50)
            output.appendLE64(44) // size of the remainder of this record
            output.appendLE16((3 << 8) | 45)
            output.appendLE16(45)
            output.appendLE32(0) // this disk
            output.appendLE32(0) // central directory disk
            output.appendLE64(entryCount)
            output.appendLE64(entryCount)
            output.appendLE64(centralDirectorySize)
            output.appendLE64(centralDirectoryOffset)

            output.appendLE32(0x0706_4B50) // locator
            output.appendLE32(0)
            output.appendLE64(zip64EndOffset)
            output.appendLE32(1)
        }

        output.appendLE32(0x0605_4B50)
        output.appendLE16(0)
        output.appendLE16(0)
        output.appendLE16(entryCount >= 0xFFFF ? 0xFFFF : UInt16(entryCount))
        output.appendLE16(entryCount >= 0xFFFF ? 0xFFFF : UInt16(entryCount))
        output.appendLE32(centralDirectorySize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(centralDirectorySize))
        output.appendLE32(centralDirectoryOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(centralDirectoryOffset))
        output.appendLE16(0) // comment length

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
