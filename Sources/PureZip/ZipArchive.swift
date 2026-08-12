import Foundation

/// A read-only view of a ZIP archive.
///
/// Parsing is fully bounds-checked and reads only the central directory;
/// entry data is located and decompressed on demand. Extraction validates
/// every entry against its CRC-32 checksum and declared size, enforces
/// `ZipSecurityLimits`, sanitizes paths (rejecting traversal attempts),
/// and never creates symbolic links.
public struct ZipArchive: Sendable {
    /// All entries listed in the central directory, in archive order.
    public let entries: [ZipEntry]
    /// The security limits this archive was opened with.
    public let limits: ZipSecurityLimits

    private let data: Data
    private let entryIndexByPath: [String: Int]

    // MARK: - Signatures

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x0201_4B50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50

    // MARK: - Initialization

    /// Opens a ZIP archive from a file, memory-mapping it when possible.
    public init(url: URL, limits: ZipSecurityLimits = .default) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ZipError.notAZipFile
        }
        try self.init(data: data, limits: limits)
    }

    /// Opens a ZIP archive from in-memory data.
    public init(data: Data, limits: ZipSecurityLimits = .default) throws {
        self.data = data
        self.limits = limits
        self.entries = try data.withUnsafeBytes { buffer in
            try Self.parseCentralDirectory(buffer, limits: limits)
        }
        var indexByPath: [String: Int] = [:]
        indexByPath.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() where indexByPath[entry.path] == nil {
            indexByPath[entry.path] = index
        }
        self.entryIndexByPath = indexByPath
    }

    /// Returns the first entry with the given archive path, if any.
    public subscript(path: String) -> ZipEntry? {
        entryIndexByPath[path].map { entries[$0] }
    }

    // MARK: - Central directory parsing

    private static func parseCentralDirectory(
        _ buffer: UnsafeRawBufferPointer, limits: ZipSecurityLimits
    ) throws -> [ZipEntry] {
        guard buffer.count >= 22 else { throw ZipError.notAZipFile }

        // Locate the end-of-central-directory record by scanning backwards over
        // the maximum possible comment length. The comment must extend exactly
        // to the end of the file.
        var eocdOffset = -1
        let lowestCandidate = max(0, buffer.count - 22 - 65535)
        var candidate = buffer.count - 22
        while candidate >= lowestCandidate {
            if buffer.loadUnaligned(fromByteOffset: candidate, as: UInt32.self).littleEndian
                == endOfCentralDirectorySignature {
                let commentLength = Int(
                    buffer.loadUnaligned(fromByteOffset: candidate + 20, as: UInt16.self).littleEndian
                )
                if candidate + 22 + commentLength == buffer.count {
                    eocdOffset = candidate
                    break
                }
            }
            candidate -= 1
        }
        guard eocdOffset >= 0 else { throw ZipError.notAZipFile }

        let diskNumber = buffer.loadUnaligned(fromByteOffset: eocdOffset + 4, as: UInt16.self).littleEndian
        let centralDirectoryDisk = buffer.loadUnaligned(fromByteOffset: eocdOffset + 6, as: UInt16.self).littleEndian
        var totalEntries = UInt64(
            buffer.loadUnaligned(fromByteOffset: eocdOffset + 10, as: UInt16.self).littleEndian
        )
        var centralDirectorySize = UInt64(
            buffer.loadUnaligned(fromByteOffset: eocdOffset + 12, as: UInt32.self).littleEndian
        )
        var centralDirectoryOffset = UInt64(
            buffer.loadUnaligned(fromByteOffset: eocdOffset + 16, as: UInt32.self).littleEndian
        )

        var centralDirectoryEnd = UInt64(eocdOffset)

        // ZIP64: a locator record directly precedes the EOCD when present.
        let needsZip64 = totalEntries == 0xFFFF
            || centralDirectorySize == 0xFFFF_FFFF
            || centralDirectoryOffset == 0xFFFF_FFFF
        let locatorOffset = eocdOffset - 20
        let hasLocator = locatorOffset >= 0
            && buffer.loadUnaligned(fromByteOffset: locatorOffset, as: UInt32.self).littleEndian
                == zip64LocatorSignature

        if hasLocator {
            let totalDisks = buffer.loadUnaligned(fromByteOffset: locatorOffset + 16, as: UInt32.self).littleEndian
            guard totalDisks <= 1 else { throw ZipError.unsupportedFeature("multi-disk archive") }
            let zip64Offset = buffer.loadUnaligned(fromByteOffset: locatorOffset + 8, as: UInt64.self).littleEndian
            guard zip64Offset <= UInt64(locatorOffset), UInt64(locatorOffset) - zip64Offset >= 56 else {
                throw ZipError.corruptedData("invalid ZIP64 end-of-central-directory offset")
            }
            let z = Int(zip64Offset)
            guard buffer.loadUnaligned(fromByteOffset: z, as: UInt32.self).littleEndian
                == zip64EndOfCentralDirectorySignature else {
                throw ZipError.corruptedData("missing ZIP64 end-of-central-directory record")
            }
            let zipDisk = buffer.loadUnaligned(fromByteOffset: z + 16, as: UInt32.self).littleEndian
            let zipCDDisk = buffer.loadUnaligned(fromByteOffset: z + 20, as: UInt32.self).littleEndian
            guard zipDisk == 0, zipCDDisk == 0 else {
                throw ZipError.unsupportedFeature("multi-disk archive")
            }
            totalEntries = buffer.loadUnaligned(fromByteOffset: z + 32, as: UInt64.self).littleEndian
            centralDirectorySize = buffer.loadUnaligned(fromByteOffset: z + 40, as: UInt64.self).littleEndian
            centralDirectoryOffset = buffer.loadUnaligned(fromByteOffset: z + 48, as: UInt64.self).littleEndian
            centralDirectoryEnd = zip64Offset
        } else {
            guard !needsZip64 else {
                throw ZipError.corruptedData("ZIP64 sentinel values without ZIP64 records")
            }
            guard diskNumber == 0, centralDirectoryDisk == 0 else {
                throw ZipError.unsupportedFeature("multi-disk archive")
            }
        }

        guard totalEntries <= UInt64(limits.maxEntryCount) else {
            throw ZipError.limitExceeded("archive declares \(totalEntries) entries (limit \(limits.maxEntryCount))")
        }
        guard centralDirectoryOffset <= centralDirectoryEnd,
              centralDirectorySize <= centralDirectoryEnd - centralDirectoryOffset else {
            throw ZipError.corruptedData("central directory out of bounds")
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(totalEntries))
        var offset = Int(centralDirectoryOffset)
        let directoryEnd = Int(centralDirectoryOffset + centralDirectorySize)

        for _ in 0..<totalEntries {
            let entry = try parseCentralDirectoryRecord(buffer, offset: &offset, end: directoryEnd)
            entries.append(entry)
        }
        return entries
    }

    private static func parseCentralDirectoryRecord(
        _ buffer: UnsafeRawBufferPointer, offset: inout Int, end: Int
    ) throws -> ZipEntry {
        guard offset + 46 <= end else { throw ZipError.truncatedData }
        func u16(_ at: Int) -> UInt16 { buffer.loadUnaligned(fromByteOffset: offset + at, as: UInt16.self).littleEndian }
        func u32(_ at: Int) -> UInt32 { buffer.loadUnaligned(fromByteOffset: offset + at, as: UInt32.self).littleEndian }

        guard u32(0) == centralDirectoryHeaderSignature else {
            throw ZipError.corruptedData("invalid central directory record")
        }
        let versionMadeBy = u16(4)
        let flags = u16(8)
        let method = u16(10)
        let dosTime = u16(12)
        let dosDate = u16(14)
        let crc = u32(16)
        var compressedSize = UInt64(u32(20))
        var uncompressedSize = UInt64(u32(24))
        let nameLength = Int(u16(28))
        let extraLength = Int(u16(30))
        let commentLength = Int(u16(32))
        let diskStart = u16(34)
        let externalAttributes = u32(38)
        var localHeaderOffset = UInt64(u32(42))

        let recordLength = 46 + nameLength + extraLength + commentLength
        guard offset + recordLength <= end else { throw ZipError.truncatedData }

        let nameStart = offset + 46
        let nameBytes = [UInt8](
            UnsafeRawBufferPointer(rebasing: buffer[nameStart..<nameStart + nameLength])
        )

        // Parse the extra fields we understand.
        var unicodePathName: String?
        var extraOffset = nameStart + nameLength
        let extraEnd = extraOffset + extraLength
        while extraOffset + 4 <= extraEnd {
            let fieldID = buffer.loadUnaligned(fromByteOffset: extraOffset, as: UInt16.self).littleEndian
            let fieldSize = Int(buffer.loadUnaligned(fromByteOffset: extraOffset + 2, as: UInt16.self).littleEndian)
            let fieldStart = extraOffset + 4
            guard fieldStart + fieldSize <= extraEnd else {
                throw ZipError.corruptedData("invalid extra field")
            }
            switch fieldID {
            case 0x0001: // ZIP64 extended information
                var cursor = fieldStart
                func nextU64() throws -> UInt64 {
                    guard cursor + 8 <= fieldStart + fieldSize else {
                        throw ZipError.corruptedData("invalid ZIP64 extra field")
                    }
                    defer { cursor += 8 }
                    return buffer.loadUnaligned(fromByteOffset: cursor, as: UInt64.self).littleEndian
                }
                if uncompressedSize == 0xFFFF_FFFF { uncompressedSize = try nextU64() }
                if compressedSize == 0xFFFF_FFFF { compressedSize = try nextU64() }
                if localHeaderOffset == 0xFFFF_FFFF { localHeaderOffset = try nextU64() }
            case 0x7075: // Info-ZIP Unicode Path
                if fieldSize >= 5,
                   buffer.load(fromByteOffset: fieldStart, as: UInt8.self) == 1 {
                    let recordedCRC = buffer.loadUnaligned(fromByteOffset: fieldStart + 1, as: UInt32.self).littleEndian
                    if recordedCRC == CRC32.checksum(nameBytes) {
                        let utf8 = UnsafeRawBufferPointer(
                            rebasing: buffer[(fieldStart + 5)..<(fieldStart + fieldSize)]
                        )
                        unicodePathName = String(bytes: utf8, encoding: .utf8)
                    }
                }
            default:
                break
            }
            extraOffset = fieldStart + fieldSize
        }

        guard diskStart == 0 || diskStart == 0xFFFF else {
            throw ZipError.unsupportedFeature("multi-disk archive")
        }

        // Decode the entry name: UTF-8 if flagged (or if a valid Unicode Path
        // extra field is present), CP437 otherwise — with a lenient fallback
        // for the many archivers that write unflagged UTF-8.
        let path: String
        if let unicodePathName {
            path = unicodePathName
        } else if flags & 0x0800 != 0 {
            path = String(decoding: nameBytes, as: UTF8.self)
        } else {
            path = String(bytes: nameBytes, encoding: .utf8) ?? CP437.decode(nameBytes)
        }

        let madeByUnix = (versionMadeBy >> 8) == 3
        let fileType = (externalAttributes >> 16) & 0xF000
        let isSymbolicLink = madeByUnix && fileType == 0xA000
        let isDirectory = !isSymbolicLink
            && (path.hasSuffix("/") || (externalAttributes & 0x10 != 0 && uncompressedSize == 0))
        let permissions: UInt16? = madeByUnix ? UInt16((externalAttributes >> 16) & 0x0FFF) : nil

        offset += recordLength

        return ZipEntry(
            path: path,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            uncompressedSize: uncompressedSize,
            compressedSize: compressedSize,
            crc32: crc,
            modificationDate: DOSDate.date(dosTime: dosTime, dosDate: dosDate),
            posixPermissions: permissions,
            methodRawValue: method,
            flags: flags,
            localHeaderOffset: localHeaderOffset
        )
    }

    // MARK: - Extraction

    /// Decompresses a single entry into memory, verifying size and checksum.
    public func extractData(_ entry: ZipEntry) throws -> Data {
        guard !entry.isEncrypted else {
            throw ZipError.encryptedEntryUnsupported(entry.path)
        }
        guard let method = entry.compressionMethod else {
            throw ZipError.unsupportedCompressionMethod(entry.methodRawValue)
        }
        guard entry.uncompressedSize <= limits.maxUncompressedEntrySize else {
            throw ZipError.limitExceeded(
                "entry '\(entry.path)' declares \(entry.uncompressedSize) bytes "
                    + "(limit \(limits.maxUncompressedEntrySize))"
            )
        }
        guard entry.uncompressedSize <= UInt64(Int.max), entry.compressedSize <= UInt64(Int.max) else {
            throw ZipError.limitExceeded("entry '\(entry.path)' is too large for this platform")
        }

        let result: Data = try data.withUnsafeBytes { buffer in
            // Find the start of the entry's data past its local file header.
            // Sizes and CRC come from the central directory, which is authoritative.
            guard entry.localHeaderOffset <= UInt64(buffer.count),
                  Int(entry.localHeaderOffset) + 30 <= buffer.count else {
                throw ZipError.truncatedData
            }
            let headerOffset = Int(entry.localHeaderOffset)
            guard buffer.loadUnaligned(fromByteOffset: headerOffset, as: UInt32.self).littleEndian
                == Self.localFileHeaderSignature else {
                throw ZipError.corruptedData("invalid local file header")
            }
            let nameLength = Int(
                buffer.loadUnaligned(fromByteOffset: headerOffset + 26, as: UInt16.self).littleEndian
            )
            let extraLength = Int(
                buffer.loadUnaligned(fromByteOffset: headerOffset + 28, as: UInt16.self).littleEndian
            )
            let dataStart = headerOffset + 30 + nameLength + extraLength
            let compressedSize = Int(entry.compressedSize)
            guard dataStart <= buffer.count, compressedSize <= buffer.count - dataStart else {
                throw ZipError.truncatedData
            }
            let compressed = UnsafeRawBufferPointer(
                rebasing: buffer[dataStart..<dataStart + compressedSize]
            )

            switch method {
            case .store:
                guard entry.compressedSize == entry.uncompressedSize else {
                    throw ZipError.corruptedData("stored entry with mismatched sizes")
                }
                guard let base = compressed.baseAddress, !compressed.isEmpty else { return Data() }
                return Data(bytes: base, count: compressed.count)
            case .deflate:
                return try Inflate.decompress(compressed, expectedSize: Int(entry.uncompressedSize))
            }
        }

        guard CRC32.checksum(result) == entry.crc32 else {
            throw ZipError.checksumMismatch(entry.path)
        }
        return result
    }

    /// Decompresses the entry with the given path into memory.
    public func extractData(at path: String) throws -> Data {
        guard let entry = self[path] else { throw ZipError.entryNotFound(path) }
        return try extractData(entry)
    }

    /// Extracts all entries into `directory`, creating it if necessary.
    ///
    /// Security behavior:
    /// - Entry paths are sanitized; paths with `..` components throw `ZipError.unsafePath`.
    /// - Symbolic link entries are skipped, never created.
    /// - Files are never written through a pre-existing symlink that leads
    ///   outside the destination.
    /// - Total decompressed output is capped by `limits.maxTotalUncompressedSize`.
    public func extractAll(to directory: URL, overwrite: Bool = false) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let rootPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        var totalBytes: UInt64 = 0

        for entry in entries {
            if entry.isSymbolicLink { continue }

            guard let relativePath = ZipPath.sanitizedRelativePath(entry.path) else {
                throw ZipError.unsafePath(entry.path)
            }
            let target = directory.appendingPathComponent(relativePath, isDirectory: entry.isDirectory)

            // Resolve any pre-existing symlinks in the target's parent chain and
            // require the result to stay inside the destination. This runs before
            // anything is created or written.
            let parent = entry.isDirectory ? target : target.deletingLastPathComponent()
            let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedParent == rootPath || resolvedParent.hasPrefix(rootPath + "/") else {
                throw ZipError.unsafePath(entry.path)
            }

            if entry.isDirectory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            let (newTotal, didOverflow) = totalBytes.addingReportingOverflow(entry.uncompressedSize)
            totalBytes = didOverflow ? .max : newTotal
            guard totalBytes <= limits.maxTotalUncompressedSize else {
                throw ZipError.limitExceeded(
                    "total uncompressed size exceeds limit of \(limits.maxTotalUncompressedSize) bytes"
                )
            }

            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )

            // Never write through an existing symlink at the target itself.
            if let attributes = try? fileManager.attributesOfItem(atPath: target.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                guard overwrite else { throw ZipError.destinationExists(target.path) }
                try fileManager.removeItem(at: target)
            }

            let contents = try extractData(entry)
            do {
                try contents.write(to: target, options: overwrite ? [] : [.withoutOverwriting])
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                throw ZipError.destinationExists(target.path)
            }

            if let permissions = entry.posixPermissions {
                // Drop set-uid/set-gid/sticky bits; keep the file owner-accessible.
                let safePermissions = (permissions & 0o777) | 0o600
                try? fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: safePermissions)],
                    ofItemAtPath: target.path
                )
            }
            if let date = entry.modificationDate {
                try? fileManager.setAttributes(
                    [.modificationDate: date], ofItemAtPath: target.path
                )
            }
        }
    }
}
