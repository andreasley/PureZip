import Foundation

/// PureZip — a pure-Swift ZIP library.
///
/// Reads and writes ZIP archives (including ZIP64) with a DEFLATE
/// implementation written entirely in Swift; no zlib or other C dependencies.
///
/// High-level usage:
/// ```swift
/// // Compress a file or folder into a ZIP archive.
/// try await PureZip.zipItem(at: folderURL, to: archiveURL)
///
/// // Extract an archive.
/// try await PureZip.unzipItem(at: archiveURL, to: destinationURL)
///
/// // Work with archives in memory.
/// let writer = ZipWriter()
/// try writer.addFile(path: "readme.txt", data: text)
/// let archiveData = writer.finalize()
///
/// let archive = try ZipArchive(data: archiveData)
/// let restored = try archive.extractData(at: "readme.txt")
/// ```
///
/// Safety: extraction verifies CRC-32 checksums and declared sizes, enforces
/// configurable decompression limits (`ZipSecurityLimits`) to stop ZIP bombs,
/// sanitizes entry paths so no file can be written outside the destination
/// directory, and never creates symbolic links.
public enum PureZip {
    /// Compresses a file or directory into a new ZIP archive.
    ///
    /// For a directory, the directory itself becomes the archive's top-level
    /// entry (matching Finder's behavior). Symbolic links inside the tree are
    /// skipped.
    ///
    /// Runs off the caller's actor. Cancelling the surrounding task stops the
    /// operation with `CancellationError` and removes the partial archive.
    ///
    /// - Parameters:
    ///   - sourceURL: File or directory to compress.
    ///   - destinationURL: Where to write the `.zip` file.
    ///   - level: Compression speed/ratio trade-off.
    ///   - overwrite: Replace an existing file at `destinationURL`.
    ///   - progress: Called periodically with a snapshot of the operation's
    ///     progress, measured in uncompressed bytes read.
    @concurrent
    public static func zipItem(
        at sourceURL: URL,
        to destinationURL: URL,
        level: CompressionLevel = .normal,
        overwrite: Bool = false,
        progress: ZipProgressHandler? = nil
    ) async throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw ZipError.entryNotFound(sourceURL.path)
        }

        // Stream straight to disk: neither the archive nor any single entry
        // is held in memory.
        let writer = try ZipFileWriter(url: destinationURL, level: level, overwrite: overwrite)
        do {
            let totalBytes: UInt64
            if isDirectory.boolValue {
                totalBytes = try addDirectoryTree(at: sourceURL, to: writer, progress: progress)
            } else {
                totalBytes = fileSize(at: sourceURL) ?? 0
                var completedBytes: UInt64 = 0
                try addFile(
                    at: sourceURL, archivePath: sourceURL.lastPathComponent, to: writer,
                    completedBytes: &completedBytes, totalBytes: totalBytes, progress: progress
                )
            }
            try writer.finalize()
            progress?(ZipProgress(completedBytes: totalBytes, totalBytes: totalBytes, currentPath: nil))
        } catch {
            // Don't leave a partial archive behind.
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    /// Extracts a ZIP archive into a directory, creating it if necessary.
    ///
    /// Runs off the caller's actor and supports task cancellation. See
    /// `ZipArchive.extractAll(to:overwrite:progress:)` for the security
    /// guarantees and progress semantics.
    @concurrent
    public static func unzipItem(
        at sourceURL: URL,
        to destinationURL: URL,
        limits: ZipSecurityLimits = .default,
        overwrite: Bool = false,
        progress: ZipProgressHandler? = nil
    ) async throws {
        let archive = try ZipArchive(url: sourceURL, limits: limits)
        try await archive.extractAll(to: destinationURL, overwrite: overwrite, progress: progress)
    }

    // MARK: - Directory traversal

    /// Adds the directory tree rooted at `rootURL` and returns the total
    /// number of file bytes that were read (the progress total).
    private static func addDirectoryTree(
        at rootURL: URL, to writer: ZipFileWriter, progress: ZipProgressHandler?
    ) throws -> UInt64 {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        let rootName = root.lastPathComponent
        try writer.addDirectory(
            path: rootName,
            modificationDate: modificationDate(at: root) ?? Date(),
            permissions: posixPermissions(at: root) ?? 0o755
        )

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys, options: []
        ) else {
            throw ZipError.entryNotFound(root.path)
        }

        // Sort for deterministic archive layout.
        var children: [(relativePath: String, url: URL, values: URLResourceValues)] = []
        let rootPathLength = root.path.count + 1
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let relativePath = String(standardized.path.dropFirst(rootPathLength))
            guard !relativePath.isEmpty else { continue }
            let values = try standardized.resourceValues(forKeys: Set(keys))
            children.append((relativePath, standardized, values))
        }
        children.sort { $0.relativePath < $1.relativePath }

        // Progress total: every file byte that will be read and compressed.
        var totalBytes: UInt64 = 0
        for child in children
        where child.values.isSymbolicLink != true && child.values.isDirectory != true {
            totalBytes += UInt64(child.values.fileSize ?? 0)
        }

        var completedBytes: UInt64 = 0
        for (relativePath, url, values) in children {
            try Task.checkCancellation()
            if values.isSymbolicLink == true { continue }
            let archivePath = rootName + "/" + relativePath
            if values.isDirectory == true {
                try writer.addDirectory(
                    path: archivePath,
                    modificationDate: values.contentModificationDate ?? Date(),
                    permissions: posixPermissions(at: url) ?? 0o755
                )
            } else {
                try addFile(
                    at: url, archivePath: archivePath, to: writer,
                    completedBytes: &completedBytes, totalBytes: totalBytes, progress: progress
                )
            }
        }
        return totalBytes
    }

    /// Streams one file into the writer chunk by chunk, reporting per-chunk
    /// progress and honoring task cancellation between chunks.
    private static func addFile(
        at fileURL: URL,
        archivePath: String,
        to writer: ZipFileWriter,
        completedBytes: inout UInt64,
        totalBytes: UInt64,
        progress: ZipProgressHandler?
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let date = (attributes?[.modificationDate] as? Date) ?? Date()
        let permissions = (attributes?[.posixPermissions] as? NSNumber)
            .map { UInt16(truncatingIfNeeded: $0.uint16Value) } ?? 0o644
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }

        var completed = completedBytes
        try writer.addFile(
            path: archivePath,
            expectedSize: size,
            modificationDate: date,
            permissions: permissions
        ) { stream in
            while let chunk = try input.read(upToCount: 1 << 19), !chunk.isEmpty {
                try Task.checkCancellation()
                try stream.write(chunk)
                completed += UInt64(chunk.count)
                progress?(ZipProgress(
                    completedBytes: completed, totalBytes: totalBytes, currentPath: archivePath
                ))
            }
        }
        completedBytes = completed
    }

    private static func posixPermissions(at url: URL) -> UInt16? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return nil }
        return UInt16(truncatingIfNeeded: permissions.uint16Value)
    }

    private static func modificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func fileSize(at url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init)
    }
}
