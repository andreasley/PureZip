import Foundation

/// Streams a ZIP archive to a file with constant memory usage.
///
/// Unlike `ZipWriter`, neither the archive nor individual entries are held in
/// memory: entry contents are compressed chunk by chunk as they arrive and
/// written straight to disk. Because CRC-32 and sizes are only known once an
/// entry ends, the local file header is patched in place afterwards (the file
/// must therefore be seekable — which regular files are).
///
/// ```swift
/// let writer = try ZipFileWriter(url: archiveURL)
/// try writer.addFile(path: "huge.bin", contentsOf: hugeFileURL)
/// try writer.addFile(path: "generated.txt") { stream in
///     for line in lines { try stream.write(Data(line.utf8)) }
/// }
/// try writer.finalize()
/// ```
///
/// A `ZipFileWriter` becomes unusable if any operation throws; subsequent
/// calls throw `ZipError.invalidState`.
public final class ZipFileWriter {
    fileprivate enum State {
        case ready
        case entryOpen
        case finalized
        case failed
    }

    private let url: URL
    private let handle: FileHandle
    private let level: CompressionLevel
    private var offset: UInt64 = 0
    private var records: [ZipEntryRecord] = []
    private var addedPaths: Set<String> = []
    private var state: State = .ready

    /// Creates the archive file and prepares for writing.
    public init(url: URL, level: CompressionLevel = .normal, overwrite: Bool = false) throws {
        do {
            try Data().write(to: url, options: overwrite ? [] : [.withoutOverwriting])
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw ZipError.destinationExists(url.path)
        }
        self.url = url
        self.level = level
        self.handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        if state != .finalized {
            try? handle.close()
        }
    }

    private func requireReady() throws {
        switch state {
        case .ready:
            return
        case .entryOpen:
            throw ZipError.invalidState("an entry is still being written")
        case .finalized:
            throw ZipError.invalidState("the archive was already finalized")
        case .failed:
            throw ZipError.invalidState("the writer is unusable after a previous error")
        }
    }

    // MARK: - Adding entries

    /// Adds a directory entry.
    public func addDirectory(
        path: String,
        modificationDate: Date = Date(),
        permissions: UInt16 = 0o755
    ) throws {
        try requireReady()
        let normalizedPath = try ZipPath.normalizedArchivePath(path, isDirectory: true)
        guard addedPaths.insert(normalizedPath).inserted else {
            throw ZipError.duplicateEntry(normalizedPath)
        }
        let nameBytes = [UInt8](normalizedPath.utf8)
        guard nameBytes.count <= 0xFFFF else { throw ZipError.invalidPath(normalizedPath) }
        let flags: UInt16 = normalizedPath.allSatisfy(\.isASCII) ? 0 : 0x0800
        let (dosTime, dosDate) = DOSDate.fields(from: modificationDate)
        let externalAttributes = ((UInt32(permissions & 0o7777) | 0o040000) << 16) | 0x10

        let headerOffset = offset
        var header: [UInt8] = []
        appendLocalHeader(
            to: &header, versionNeeded: 20, flags: flags, method: 0,
            dosTime: dosTime, dosDate: dosDate, crc32: 0,
            compressedField: 0, uncompressedField: 0,
            nameBytes: nameBytes, zip64Placeholder: false
        )
        try failable { try writeArchiveBytes(header) }

        records.append(
            ZipEntryRecord(
                nameBytes: nameBytes, flags: flags, method: 0,
                dosTime: dosTime, dosDate: dosDate, crc32: 0,
                compressedSize: 0, uncompressedSize: 0,
                localHeaderOffset: headerOffset, externalAttributes: externalAttributes
            )
        )
    }

    /// Adds a file entry with in-memory contents (compressing to memory first,
    /// which allows falling back to Store when DEFLATE does not help).
    public func addFile(
        path: String,
        data: Data,
        compress: Bool = true,
        modificationDate: Date = Date(),
        permissions: UInt16 = 0o644
    ) throws {
        try requireReady()
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
        try writeInMemoryEntry(
            normalizedPath: normalizedPath, data: data, crc: crc, method: method,
            payload: payload, modificationDate: modificationDate, permissions: permissions
        )
    }

    /// Async variant of `addFile(path:data:...)`.
    ///
    /// Runs off the caller's actor, hashing and compressing in chunks so
    /// `progress` sees intermediate snapshots and cancelling the surrounding
    /// task stops the work with `CancellationError`. A cancelled call leaves
    /// the writer unchanged and usable; the store-vs-DEFLATE fallback matches
    /// the synchronous variant.
    @concurrent
    public func addFile(
        path: String,
        data: Data,
        compress: Bool = true,
        modificationDate: Date = Date(),
        permissions: UInt16 = 0o644,
        progress: ZipProgressHandler? = nil
    ) async throws {
        try requireReady()
        let normalizedPath = try ZipPath.normalizedArchivePath(path, isDirectory: false)
        guard !addedPaths.contains(normalizedPath) else {
            throw ZipError.duplicateEntry(normalizedPath)
        }
        let (crc, compressed) = try Deflate.checksumAndCompress(
            data, level: level, compress: compress, path: normalizedPath, progress: progress
        )
        var method: UInt16 = 0
        var payload: [UInt8]? = nil
        if let compressed, compressed.count < data.count {
            method = 8
            payload = compressed
        }
        addedPaths.insert(normalizedPath)
        try writeInMemoryEntry(
            normalizedPath: normalizedPath, data: data, crc: crc, method: method,
            payload: payload, modificationDate: modificationDate, permissions: permissions
        )
        progress?(ZipProgress(
            completedBytes: UInt64(data.count), totalBytes: UInt64(data.count),
            currentPath: normalizedPath
        ))
    }

    /// Writes the header, payload, and central-directory record for an entry
    /// whose contents (and compressed form, if any) are already in memory.
    private func writeInMemoryEntry(
        normalizedPath: String,
        data: Data,
        crc: UInt32,
        method: UInt16,
        payload: [UInt8]?,
        modificationDate: Date,
        permissions: UInt16
    ) throws {
        let nameBytes = [UInt8](normalizedPath.utf8)
        guard nameBytes.count <= 0xFFFF else { throw ZipError.invalidPath(normalizedPath) }
        let compressedSize = UInt64(payload?.count ?? data.count)
        let uncompressedSize = UInt64(data.count)
        let flags: UInt16 = normalizedPath.allSatisfy(\.isASCII) ? 0 : 0x0800
        let (dosTime, dosDate) = DOSDate.fields(from: modificationDate)
        let externalAttributes = (UInt32(permissions & 0o7777) | 0o100000) << 16
        let needsZip64 = uncompressedSize >= 0xFFFF_FFFF || compressedSize >= 0xFFFF_FFFF

        let headerOffset = offset
        var header: [UInt8] = []
        appendLocalHeader(
            to: &header, versionNeeded: needsZip64 ? 45 : 20, flags: flags, method: method,
            dosTime: dosTime, dosDate: dosDate, crc32: crc,
            compressedField: needsZip64 ? 0xFFFF_FFFF : UInt32(compressedSize),
            uncompressedField: needsZip64 ? 0xFFFF_FFFF : UInt32(uncompressedSize),
            nameBytes: nameBytes, zip64Placeholder: needsZip64,
            zip64Sizes: needsZip64 ? (uncompressedSize, compressedSize) : nil
        )
        try failable {
            try writeArchiveBytes(header)
            if let payload {
                try writeArchiveBytes(payload)
            } else if !data.isEmpty {
                try writeArchiveData(data)
            }
        }

        records.append(
            ZipEntryRecord(
                nameBytes: nameBytes, flags: flags, method: method,
                dosTime: dosTime, dosDate: dosDate, crc32: crc,
                compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                localHeaderOffset: headerOffset, externalAttributes: externalAttributes
            )
        )
    }

    /// Adds a file entry whose contents are produced incrementally by `content`.
    ///
    /// The contents are compressed and written to disk as they arrive; memory
    /// usage is constant regardless of entry size. Because the final sizes are
    /// unknown while the header is written, ZIP64 size fields are reserved
    /// unless `expectedSize` shows the entry safely fits 32-bit fields.
    ///
    /// - Parameters:
    ///   - expectedSize: The anticipated uncompressed size, if known. Purely
    ///     an optimization hint; the entry may end up larger or smaller.
    ///   - compress: Pass `false` to store the contents without compression.
    ///   - content: Closure that writes the entry's bytes to the provided stream.
    public func addFile(
        path: String,
        expectedSize: UInt64? = nil,
        compress: Bool = true,
        modificationDate: Date = Date(),
        permissions: UInt16 = 0o644,
        content: (ZipEntryStream) throws -> Void
    ) throws {
        let (entry, stream) = try beginStreamedEntry(
            path: path, expectedSize: expectedSize, compress: compress,
            modificationDate: modificationDate, permissions: permissions,
            progress: nil, honorsCancellation: false
        )
        do {
            try content(stream)
        } catch {
            state = .failed
            throw error
        }
        try endStreamedEntry(entry, stream: stream)
    }

    /// Async variant of `addFile(path:expectedSize:...content:)`.
    ///
    /// Runs off the caller's actor and accepts an `async` content closure.
    /// Every `stream.write` reports a progress snapshot (with `expectedSize`
    /// as the total, when given) and checks for task cancellation. If the
    /// entry fails or is cancelled mid-write the writer becomes unusable,
    /// like any other streaming failure.
    @concurrent
    public func addFile(
        path: String,
        expectedSize: UInt64? = nil,
        compress: Bool = true,
        modificationDate: Date = Date(),
        permissions: UInt16 = 0o644,
        progress: ZipProgressHandler? = nil,
        content: (ZipEntryStream) async throws -> Void
    ) async throws {
        let (entry, stream) = try beginStreamedEntry(
            path: path, expectedSize: expectedSize, compress: compress,
            modificationDate: modificationDate, permissions: permissions,
            progress: progress, honorsCancellation: true
        )
        do {
            try await content(stream)
        } catch {
            state = .failed
            throw error
        }
        let totals = try endStreamedEntry(entry, stream: stream)
        progress?(ZipProgress(
            completedBytes: totals.uncompressed, totalBytes: totals.uncompressed,
            currentPath: entry.normalizedPath
        ))
    }

    /// Everything both streamed-entry variants share up to running the
    /// caller's content closure: validation, the placeholder local header,
    /// and the configured entry stream.
    private struct StreamedEntry {
        let normalizedPath: String
        let nameBytes: [UInt8]
        let flags: UInt16
        let method: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
        let externalAttributes: UInt32
        let headerOffset: UInt64
        let reserveZip64: Bool
    }

    private func beginStreamedEntry(
        path: String,
        expectedSize: UInt64?,
        compress: Bool,
        modificationDate: Date,
        permissions: UInt16,
        progress: ZipProgressHandler?,
        honorsCancellation: Bool
    ) throws -> (entry: StreamedEntry, stream: ZipEntryStream) {
        try requireReady()
        let normalizedPath = try ZipPath.normalizedArchivePath(path, isDirectory: false)
        guard addedPaths.insert(normalizedPath).inserted else {
            throw ZipError.duplicateEntry(normalizedPath)
        }
        let nameBytes = [UInt8](normalizedPath.utf8)
        guard nameBytes.count <= 0xFFFF else { throw ZipError.invalidPath(normalizedPath) }

        let flags: UInt16 = normalizedPath.allSatisfy(\.isASCII) ? 0 : 0x0800
        let (dosTime, dosDate) = DOSDate.fields(from: modificationDate)
        let externalAttributes = (UInt32(permissions & 0o7777) | 0o100000) << 16
        let method: UInt16 = compress ? 8 : 0

        // Reserve ZIP64 size fields unless the expected size fits 32 bits even
        // after worst-case DEFLATE expansion (~1/8192 for incompressible data).
        let reserveZip64: Bool
        if let expectedSize {
            reserveZip64 = expectedSize + expectedSize / 512 + 1_048_576 >= 0xFFFF_FFFF
        } else {
            reserveZip64 = true
        }

        let headerOffset = offset
        var header: [UInt8] = []
        appendLocalHeader(
            to: &header, versionNeeded: reserveZip64 ? 45 : 20, flags: flags, method: method,
            dosTime: dosTime, dosDate: dosDate, crc32: 0,
            compressedField: reserveZip64 ? 0xFFFF_FFFF : 0,
            uncompressedField: reserveZip64 ? 0xFFFF_FFFF : 0,
            nameBytes: nameBytes, zip64Placeholder: reserveZip64
        )

        state = .entryOpen
        do {
            try writeArchiveBytes(header)
        } catch {
            state = .failed
            throw error
        }
        let stream = ZipEntryStream(
            writer: self,
            encoder: compress ? DeflateEncoder(level: level) : nil,
            progress: progress,
            expectedTotalBytes: expectedSize,
            progressPath: normalizedPath,
            honorsCancellation: honorsCancellation
        )
        let entry = StreamedEntry(
            normalizedPath: normalizedPath, nameBytes: nameBytes, flags: flags,
            method: method, dosTime: dosTime, dosDate: dosDate,
            externalAttributes: externalAttributes,
            headerOffset: headerOffset, reserveZip64: reserveZip64
        )
        return (entry, stream)
    }

    @discardableResult
    private func endStreamedEntry(
        _ entry: StreamedEntry, stream: ZipEntryStream
    ) throws -> (crc: UInt32, uncompressed: UInt64, compressed: UInt64) {
        let totals: (crc: UInt32, uncompressed: UInt64, compressed: UInt64)
        do {
            totals = try stream.finish()

            if !entry.reserveZip64 {
                guard totals.compressed < 0xFFFF_FFFF, totals.uncompressed < 0xFFFF_FFFF else {
                    throw ZipError.limitExceeded(
                        "entry '\(entry.normalizedPath)' grew past 4 GiB but was expected to be smaller"
                    )
                }
            }

            // Patch CRC-32 and sizes into the local header now that they are known.
            try handle.seek(toOffset: entry.headerOffset + 14)
            var patch: [UInt8] = []
            patch.appendLE32(totals.crc)
            if entry.reserveZip64 {
                patch.appendLE32(0xFFFF_FFFF)
                patch.appendLE32(0xFFFF_FFFF)
            } else {
                patch.appendLE32(UInt32(totals.compressed))
                patch.appendLE32(UInt32(totals.uncompressed))
            }
            try handle.write(contentsOf: Data(patch))
            if entry.reserveZip64 {
                try handle.seek(toOffset: entry.headerOffset + 30 + UInt64(entry.nameBytes.count) + 4)
                var sizes: [UInt8] = []
                sizes.appendLE64(totals.uncompressed)
                sizes.appendLE64(totals.compressed)
                try handle.write(contentsOf: Data(sizes))
            }
            try handle.seek(toOffset: offset)
        } catch {
            state = .failed
            throw error
        }

        records.append(
            ZipEntryRecord(
                nameBytes: entry.nameBytes, flags: entry.flags, method: entry.method,
                dosTime: entry.dosTime, dosDate: entry.dosDate, crc32: totals.crc,
                compressedSize: totals.compressed, uncompressedSize: totals.uncompressed,
                localHeaderOffset: entry.headerOffset, externalAttributes: entry.externalAttributes
            )
        )
        state = .ready
        return totals
    }

    /// Adds a file entry by streaming an existing file's contents from disk.
    ///
    /// Modification date and permissions default to the source file's values.
    public func addFile(
        path: String,
        contentsOf fileURL: URL,
        compress: Bool = true,
        modificationDate: Date? = nil,
        permissions: UInt16? = nil
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let date = modificationDate ?? (attributes?[.modificationDate] as? Date) ?? Date()
        let filePermissions = permissions
            ?? (attributes?[.posixPermissions] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.uint16Value) }
            ?? 0o644
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        try addFile(
            path: path,
            expectedSize: size,
            compress: compress,
            modificationDate: date,
            permissions: filePermissions
        ) { stream in
            while let chunk = try input.read(upToCount: 1 << 19), !chunk.isEmpty {
                try stream.write(chunk)
            }
        }
    }

    /// Async variant of `addFile(path:contentsOf:...)`.
    ///
    /// Runs off the caller's actor, streaming the file in ~512 KiB chunks;
    /// each chunk reports a progress snapshot (total = the source file's
    /// size) and checks for task cancellation. If the entry fails or is
    /// cancelled mid-write the writer becomes unusable, like any other
    /// streaming failure.
    @concurrent
    public func addFile(
        path: String,
        contentsOf fileURL: URL,
        compress: Bool = true,
        modificationDate: Date? = nil,
        permissions: UInt16? = nil,
        progress: ZipProgressHandler? = nil
    ) async throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let date = modificationDate ?? (attributes?[.modificationDate] as? Date) ?? Date()
        let filePermissions = permissions
            ?? (attributes?[.posixPermissions] as? NSNumber).map { UInt16(truncatingIfNeeded: $0.uint16Value) }
            ?? 0o644
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        try await addFile(
            path: path,
            expectedSize: size,
            compress: compress,
            modificationDate: date,
            permissions: filePermissions,
            progress: progress
        ) { stream in
            while let chunk = try input.read(upToCount: 1 << 19), !chunk.isEmpty {
                try stream.write(chunk)
            }
        }
    }

    // MARK: - Finalizing

    /// Writes the central directory and closes the file.
    public func finalize() throws {
        try requireReady()
        try failable {
            let central = ZipFormat.centralDirectory(records: records, startingAt: offset)
            try writeArchiveBytes(central)
            try handle.close()
        }
        state = .finalized
    }

    // MARK: - Low-level output

    private func failable<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            state = .failed
            throw error
        }
    }

    private func writeArchiveBytes(_ bytes: [UInt8]) throws {
        try handle.write(contentsOf: Data(bytes))
        offset += UInt64(bytes.count)
    }

    private func writeArchiveData(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    /// Called by `ZipEntryStream` while an entry is open.
    fileprivate func writeEntryData(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private func appendLocalHeader(
        to output: inout [UInt8],
        versionNeeded: UInt16,
        flags: UInt16,
        method: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        crc32: UInt32,
        compressedField: UInt32,
        uncompressedField: UInt32,
        nameBytes: [UInt8],
        zip64Placeholder: Bool,
        zip64Sizes: (uncompressed: UInt64, compressed: UInt64)? = nil
    ) {
        output.appendLE32(0x0403_4B50)
        output.appendLE16(versionNeeded)
        output.appendLE16(flags)
        output.appendLE16(method)
        output.appendLE16(dosTime)
        output.appendLE16(dosDate)
        output.appendLE32(crc32)
        output.appendLE32(compressedField)
        output.appendLE32(uncompressedField)
        output.appendLE16(UInt16(nameBytes.count))
        output.appendLE16(zip64Placeholder ? 20 : 0)
        output.append(contentsOf: nameBytes)
        if zip64Placeholder {
            output.appendLE16(0x0001)
            output.appendLE16(16)
            output.appendLE64(zip64Sizes?.uncompressed ?? 0)
            output.appendLE64(zip64Sizes?.compressed ?? 0)
        }
    }
}

// MARK: - Entry stream

/// The destination handed to `ZipFileWriter.addFile(path:...content:)` —
/// write the entry's bytes to it in as many chunks as convenient.
public final class ZipEntryStream {
    private let writer: ZipFileWriter
    private let encoder: DeflateEncoder?
    // Set for entries opened through the async writer APIs: progress is
    // reported and task cancellation is checked on every write.
    private let progress: ZipProgressHandler?
    private let expectedTotalBytes: UInt64?
    private let progressPath: String?
    private let honorsCancellation: Bool
    private var crc: UInt32 = 0
    private var uncompressed: UInt64 = 0
    private var compressed: UInt64 = 0
    private var isFinished = false

    fileprivate init(
        writer: ZipFileWriter,
        encoder: DeflateEncoder?,
        progress: ZipProgressHandler? = nil,
        expectedTotalBytes: UInt64? = nil,
        progressPath: String? = nil,
        honorsCancellation: Bool = false
    ) {
        self.writer = writer
        self.encoder = encoder
        self.progress = progress
        self.expectedTotalBytes = expectedTotalBytes
        self.progressPath = progressPath
        self.honorsCancellation = honorsCancellation
    }

    /// Appends a chunk of the entry's contents.
    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0) }
    }

    /// Appends a chunk of the entry's contents.
    public func write(_ buffer: UnsafeRawBufferPointer) throws {
        guard !isFinished else {
            throw ZipError.invalidState("the entry stream was already closed")
        }
        if honorsCancellation { try Task.checkCancellation() }
        guard !buffer.isEmpty, let base = buffer.baseAddress else { return }
        crc = CRC32.checksum(buffer, seed: crc)
        uncompressed += UInt64(buffer.count)
        if let encoder {
            encoder.write(buffer)
            try drainEncoder()
        } else {
            try writer.writeEntryData(Data(bytes: base, count: buffer.count))
            compressed += UInt64(buffer.count)
        }
        progress?(ZipProgress(
            completedBytes: uncompressed, totalBytes: expectedTotalBytes, currentPath: progressPath
        ))
    }

    private func drainEncoder() throws {
        guard let encoder else { return }
        let output = encoder.takeOutput()
        if !output.isEmpty {
            try writer.writeEntryData(Data(output))
            compressed += UInt64(output.count)
        }
    }

    fileprivate func finish() throws -> (crc: UInt32, uncompressed: UInt64, compressed: UInt64) {
        guard !isFinished else {
            throw ZipError.invalidState("the entry stream was already closed")
        }
        isFinished = true
        if let encoder {
            encoder.finish()
            try drainEncoder()
        }
        return (crc, uncompressed, compressed)
    }
}
